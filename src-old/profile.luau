--!strict

local Mutex = require "./mutex"
local Tx = require "./tx"
local runtime = require "./runtime"
local types = require "./types"
local util = require "./util"

--[[
	Profile: the handle for one loaded key. Owns the session lock, the in-memory
	(frozen) data and the autosave loop.

	Session locking lives inside the record itself (`record.lock`):
	- load acquires it with a compare-and-set update_async;
	- every write re-checks `lock.id == server_id` and cancels otherwise, which is
	  how a stolen lock is detected;
	- autosave refreshes `lock.expires`; unload clears the lock.
]]

export type WriteStatus = "ok" | "lock_lost"

export type WriteOptions = {
	release: boolean?,
	pending: types.Pending?,
}

-- Minimal view of the store a profile needs (avoids a require cycle).
export type StoreLike = {
	config: {
		name: string,
		template: any,
		hook: types.Hook,
		migrations: { types.Migration },
		on_changed: ((profile: any, new: any, old: any) -> ())?,
		on_lock_lost: ((profile: any) -> ())?,
		autosave_interval: number,
		lock_ttl: number,
		load_timeout: number,
		load_poll: number,
		[any]: any,
	},
	server_id: string,
	data_store: types.StoreHandle,
	tx_store: types.StoreHandle,
	call: (self: any, fn: () -> any) -> any,
	_unregister: (self: any, profile: any) -> (),
	[any]: any,
}

export type Profile<T = any> = {
	kind: "locked",
	key: string,
	user_ids: { number }?,
	store: StoreLike,
	data: T,
	dirty: boolean,
	open: boolean,
	migrations: { string },
	mutex: Mutex.Mutex,
	unresolved_tx: Tx.Tx?,
	cleanup_txs: { Tx.Tx },
	last_ok_at: number,

	get: (self: Profile<T>) -> T,
	update: (self: Profile<T>, transform: (data: T) -> T | false) -> boolean,
	save: (self: Profile<T>) -> (),
	unload: (self: Profile<T>) -> (),
	is_open: (self: Profile<T>) -> boolean,

	_write_record: (self: Profile<T>, opts: WriteOptions) -> WriteStatus,
	_settle_tx: (self: Profile<T>) -> (),
	_set_data: (self: Profile<T>, new: T) -> (),
	_participant: (self: Profile<T>) -> Tx.Participant,
	_on_lost: (self: Profile<T>) -> (),
}

local Profile = {}
Profile.__index = Profile

local function is_locked_by_other(record: any, server_id: string, now: number): boolean
	if type(record) ~= "table" or record.lock == nil then
		return false
	end
	local lock = record.lock
	return lock.id ~= server_id and lock.expires > now
end

-- Acquires the session lock and returns the record as stored after acquisition.
local function acquire(store: StoreLike, key: string, user_ids: { number }?): types.Record
	local config = store.config
	local deadline = runtime.now() + config.load_timeout

	while true do
		local now = runtime.now()
		local applied = false
		local after = store:call(function()
			return store.data_store.update_async(key, function(old: any?)
				applied = false
				if is_locked_by_other(old, store.server_id, now) then
					return nil
				end
				local record: types.Record = if type(old) == "table" then old else {}
				applied = true
				return {
					data = record.data,
					pending = record.pending,
					migrations = record.migrations or {},
					lock = { id = store.server_id, expires = now + config.lock_ttl },
				}
			end, user_ids)
		end)
		if applied then
			return after :: types.Record
		end

		-- Someone else holds the lock: poll cheaply with get_async until it is
		-- released or expires, then try the compare-and-set again.
		while true do
			if runtime.now() >= deadline then
				error(`datastore: timed out loading "{key}" (session locked by another server)`)
			end
			runtime.wait(config.load_poll)
			local current = store:call(function()
				return store.data_store.get_async(key)
			end)
			if not is_locked_by_other(current, store.server_id, runtime.now()) then
				break
			end
		end
	end
end

function Profile.load<T>(store: StoreLike, key: string, user_ids: { number }?): Profile<T>
	local config = store.config
	local record = acquire(store, key, user_ids)

	local data: any = record.data
	local dirty = false

	if record.pending ~= nil then
		-- A transaction was in flight when the previous holder died. The marker
		-- decides. We own the key now, so force the resolution.
		local outcome = Tx.resolve_pending(store, record.pending, true)
		if outcome == "committed" then
			data = record.pending.data
		end
		dirty = true
	end

	if data == nil then
		data = util.deep_copy(config.template)
		dirty = true
	end

	local applied: { string }, migrated: boolean
	data, applied, migrated = util.migrate(config.migrations, data, record.migrations)
	dirty = dirty or migrated

	local self: Profile<T> = setmetatable({
		kind = "locked",
		key = key,
		user_ids = user_ids,
		store = store,
		data = util.deep_freeze(data),
		dirty = dirty,
		open = true,
		migrations = applied,
		mutex = Mutex.new(),
		unresolved_tx = nil,
		cleanup_txs = {},
		last_ok_at = runtime.now(),
	}, Profile) :: any

	runtime.spawn(function()
		while true do
			runtime.wait(config.autosave_interval)
			if not self.open then
				return
			end
			local ok, err = util.try(self.save, self)
			if not ok and self.open then
				runtime.warn(`datastore: autosave failed for "{key}": {tostring(err)}`)
			end
		end
	end)

	return self
end

function Profile.get<T>(self: Profile<T>): T
	return self.data
end

function Profile.is_open<T>(self: Profile<T>): boolean
	return self.open
end

function Profile.update<T>(self: Profile<T>, transform: (data: T) -> T | false): boolean
	if not self.open then
		error(`datastore: profile "{self.key}" is closed`)
	end
	return self.mutex:with(function()
		self:_settle_tx()
		if not self.open then
			error(`datastore: profile "{self.key}" is closed`)
		end
		local new = transform(self.data)
		if new == false then
			return false
		end
		if new == nil then
			error "datastore: update transform must return the new data or false"
		end
		if (new :: any) ~= self.data then
			self:_set_data(util.deep_freeze(new :: any))
		end
		return true
	end)
end

function Profile.save<T>(self: Profile<T>)
	if not self.open then
		error(`datastore: profile "{self.key}" is closed`)
	end
	self.mutex:with(function()
		self:_settle_tx()
		if not self.open then
			error(`datastore: profile "{self.key}" is closed`)
		end
		local status = self:_write_record {}
		if status == "lock_lost" then
			error(`datastore: session lock for "{self.key}" was lost`)
		end
	end)
end

function Profile.unload<T>(self: Profile<T>)
	if not self.open then
		return
	end
	-- Closing: no new updates; autosave loop exits on its next tick.
	self.open = false
	self.mutex:lock()
	local ok, err = pcall(function()
		self:_settle_tx()
		self:_write_record { release = true }
	end)
	self.store:_unregister(self)
	self.mutex:unlock()
	if not ok then
		runtime.warn(`datastore: failed to release "{self.key}" (lock will expire): {tostring(err)}`)
	end
end

--- Writes the current state with a lock check. Returns "lock_lost" (and closes the
--- profile) when the record is no longer locked by this server. Throws when the
--- storage keeps failing.
function Profile._write_record<T>(self: Profile<T>, opts: WriteOptions): WriteStatus
	local store = self.store
	local config = store.config
	local now = runtime.now()
	local applied = false

	local function transform(old: any?): any?
		applied = false
		if type(old) ~= "table" or old.lock == nil or old.lock.id ~= store.server_id then
			return nil
		end
		applied = true
		local record: types.Record = {
			data = self.data,
			migrations = self.migrations,
			pending = opts.pending,
			lock = if opts.release then nil else { id = store.server_id, expires = now + config.lock_ttl },
		}
		return record
	end

	local ok, err = pcall(function()
		store:call(function()
			return store.data_store.update_async(self.key, transform, self.user_ids)
		end)
	end)

	if not ok then
		if runtime.now() - self.last_ok_at > config.lock_ttl then
			-- We have not managed to refresh the lock for a full TTL; assume it is gone.
			self:_on_lost()
		end
		error(err, 0)
	end

	if not applied then
		self:_on_lost()
		return "lock_lost"
	end

	self.last_ok_at = now
	if opts.pending == nil then
		self.dirty = false
		local txs = self.cleanup_txs
		self.cleanup_txs = {}
		for _, tx in txs do
			tx:cleaned()
		end
	end
	return "ok"
end

-- If a transaction involving this profile has an unknown outcome, block until it
-- is known and applied. Callers hold the mutex.
function Profile._settle_tx<T>(self: Profile<T>)
	local tx = self.unresolved_tx
	if tx ~= nil then
		tx:settle()
	end
end

function Profile._set_data<T>(self: Profile<T>, new: T)
	local old = self.data
	self.data = new
	self.dirty = true
	local on_changed = self.store.config.on_changed
	if on_changed then
		local ok, err = util.try(on_changed, self, new, old)
		if not ok then
			runtime.warn(`datastore: on_changed callback failed for "{self.key}": {tostring(err)}`)
		end
	end
end

--- Adapter used by the transaction coordinator (see tx.luau).
function Profile._participant<T>(self: Profile<T>): Tx.Participant
	local store = self.store
	return {
		profile = self,
		store = store,
		sort_key = store.config.name .. "\0" .. self.key,
		lockless = false,
		lock = function()
			self.mutex:lock()
		end,
		unlock = function()
			self.mutex:unlock()
		end,
		is_open = function()
			return self.open
		end,
		settle_pending = function()
			self:_settle_tx()
		end,
		begin = function() end,
		snapshot = function()
			return self.data
		end,
		set_data = function(new)
			self:_set_data(new)
		end,
		prepare = function(_, pending)
			return self:_write_record { pending = pending }
		end,
		apply_committed = function(new, tx)
			self.unresolved_tx = nil
			table.insert(self.cleanup_txs, tx)
			if self.open then
				self:_set_data(new)
			end
		end,
		apply_aborted = function(prepared)
			self.unresolved_tx = nil
			if prepared then
				-- record still carries `pending`; next save writes it clean
				self.dirty = true
			end
		end,
	}
end

function Profile._on_lost<T>(self: Profile<T>)
	if not self.open then
		return
	end
	self.open = false
	self.store:_unregister(self)
	local on_lock_lost = self.store.config.on_lock_lost
	if on_lock_lost then
		local ok, err = util.try(on_lock_lost, self)
		if not ok then
			runtime.warn(`datastore: on_lock_lost callback failed for "{self.key}": {tostring(err)}`)
		end
	end
end

return Profile
