--!strict

local Mutex = require "./mutex"
local Tx = require "./tx"
local runtime = require "./runtime"
local types = require "./types"
local util = require "./util"

--[[
	LocklessProfile: a handle for one key that never takes the session lock.

	Changes are queued as pure transforms and replayed, in one update_async, on
	whatever the storage holds at that moment (`apply`). Idle profiles make no
	storage calls at all. Several servers may use the same key concurrently.

	Locks on the key:
	- a session lock (a locked profile on some server) blocks fetch/apply:
	  `on_lock_lost` fires and they throw, the queue is kept;
	- a transaction lock (`lock.tx == true`, see below) is short-lived, so
	  fetch/apply wait for it instead.

	`fetched` is false until `fetch()` (GetAsync) or the first `apply()` fills
	the local view; `get()` errors before that.

	Transactions: `begin` flushes the queue and takes a transaction lock in the
	same update_async, so the coordinator's snapshot is exact and no other
	server can write until `prepare` writes `pending` and releases the lock
	(again one update_async). A coordinator that dies in between leaves a lock
	that expires after `tx_lock_ttl`.
]]

type StoreLike = {
	config: {
		name: string,
		template: any,
		hook: types.Hook,
		migrations: { types.Migration },
		on_changed: ((profile: any, new: any, old: any) -> ())?,
		on_lock_lost: ((profile: any) -> ())?,
		lock_ttl: number,
		tx_lock_ttl: number,
		load_timeout: number,
		load_poll: number,
		flush_interval: number,
		[any]: any,
	},
	server_id: string,
	data_store: types.StoreHandle,
	tx_store: types.StoreHandle,
	call: (self: any, fn: () -> any) -> any,
	_unregister: (self: any, profile: any) -> (),
	[any]: any,
}

export type LocklessProfile<T = any> = {
	kind: "lockless",
	key: string,
	user_ids: { number }?,
	store: StoreLike,
	open: boolean,
	fetched: boolean,
	--- last value seen in storage (frozen); nil until fetched
	base: T?,
	--- base with the queue applied (frozen); nil until fetched
	view: T?,
	queue: { (data: T) -> T | false },
	mutex: Mutex.Mutex,
	unresolved_tx: Tx.Tx?,
	cleanup_txs: { Tx.Tx },
	known_outcomes: { [string]: types.TxOutcome },
	--- a transaction left `pending` on the record; the next flush cleans it
	dirty_pending: boolean,
	--- this profile holds the transaction lock on its key right now
	tx_locked: boolean,

	get: (self: LocklessProfile<T>) -> T,
	is_fetched: (self: LocklessProfile<T>) -> boolean,
	is_open: (self: LocklessProfile<T>) -> boolean,
	has_pending_changes: (self: LocklessProfile<T>) -> boolean,
	update: (self: LocklessProfile<T>, transform: (data: T) -> T | false) -> boolean,
	fetch: (self: LocklessProfile<T>) -> T,
	apply: (self: LocklessProfile<T>) -> T,
	unload: (self: LocklessProfile<T>) -> (),

	_settle_tx: (self: LocklessProfile<T>) -> (),
	_participant: (self: LocklessProfile<T>) -> Tx.Participant,
}

type WriteOptions = {
	--- take the transaction lock (flush + snapshot)
	take_lock: boolean?,
	--- write `pending` (requires holding the transaction lock); releases the lock
	pending: types.Pending?,
}

type WriteState = {
	applied: boolean,
	--- a lock held by someone else blocked the write; `tx` says which kind
	blocked: { tx: boolean }?,
	lock_lost: boolean,
	unknown_pending: types.Pending?,
}

local LocklessProfile = {}
LocklessProfile.__index = LocklessProfile

local function tx_lock_id(self: LocklessProfile): string
	return util.tx_lock_id(self.store.server_id)
end

--- An unexpired lock held by anyone but this profile's own transaction lock.
local function foreign_lock(self: LocklessProfile, record: any, now: number): types.Lock?
	if type(record) ~= "table" or record.lock == nil then
		return nil
	end
	local lock: types.Lock = record.lock
	if lock.expires <= now or lock.id == tx_lock_id(self) then
		return nil
	end
	return lock
end

local function fire_changed(self: LocklessProfile, new: any, old: any)
	local on_changed = self.store.config.on_changed
	if on_changed then
		local ok, err = util.try(on_changed, self, new, old)
		if not ok then
			runtime.warn(`datastore: on_changed callback failed for "{self.key}": {tostring(err)}`)
		end
	end
end

--- Another server holds an unexpired session lock on the key: the profile cannot
--- read or write until it expires. Fires `on_lock_lost` (the profile stays open,
--- the queue is kept) and throws.
local function blocked_by_lock(self: LocklessProfile)
	local on_lock_lost = self.store.config.on_lock_lost
	if on_lock_lost then
		local ok, err = util.try(on_lock_lost, self)
		if not ok then
			runtime.warn(`datastore: on_lock_lost callback failed for "{self.key}": {tostring(err)}`)
		end
	end
	error(`datastore: "{self.key}" is session locked by another server`)
end

--- A transaction on another server holds the key. Polls until the lock is gone
--- (they are short-lived) or `load_timeout` passes.
local function wait_tx_lock(self: LocklessProfile)
	local store = self.store
	local config = store.config
	local deadline = runtime.now() + config.load_timeout
	while true do
		runtime.wait(config.load_poll)
		local current = store:call(function()
			return store.data_store.get_async(self.key)
		end)
		local lock = foreign_lock(self, current, runtime.now())
		if lock == nil then
			return
		end
		if not lock.tx then
			blocked_by_lock(self)
		end
		if runtime.now() >= deadline then
			error(`datastore: timed out waiting for a transaction lock on "{self.key}"`)
		end
	end
end

--- Reacts to a lock found on the record: waits out a transaction lock, throws
--- on a session lock.
local function handle_lock(self: LocklessProfile, lock: types.Lock)
	if lock.tx then
		wait_tx_lock(self)
	else
		blocked_by_lock(self)
	end
end

local function replay(queue: { (data: any) -> any }, data: any): any
	for _, transform in queue do
		local result = transform(data)
		if result == nil then
			error "datastore: update transform must return the new data or false"
		end
		if result ~= false then
			data = util.deep_freeze(result)
		end
	end
	return data
end

--- Blocks until `pending` (found on the record) has a known outcome. Returns nil
--- when the record moved on (pending resolved and cleaned by someone else).
local function wait_outcome(self: LocklessProfile, pending: types.Pending): types.TxOutcome?
	local store = self.store
	while true do
		local outcome = Tx.resolve_pending(store, pending, false)
		if outcome ~= nil then
			return outcome :: types.TxOutcome
		end
		runtime.wait(store.config.load_poll)
		local current = store:call(function()
			return store.data_store.get_async(self.key)
		end)
		if type(current) ~= "table" or current.pending == nil or current.pending.tx ~= pending.tx then
			return nil
		end
	end
end

--- Resolves the data of a stored record (folding a known pending) and applies
--- migrations. Pure; used both inside update transforms and after get_async.
local function resolve_record(
	self: LocklessProfile,
	record: any,
	known: { [string]: types.TxOutcome }
): (any, { string })
	local config = self.store.config
	local data: any = nil
	local applied: { string }? = nil
	if type(record) == "table" then
		data = record.data
		applied = record.migrations
		if record.pending ~= nil and known[record.pending.tx] == "committed" then
			data = record.pending.data
		end
	end
	if data == nil then
		data = util.deep_copy(config.template)
	end
	local migrated, names = util.migrate(config.migrations, data, applied)
	return util.deep_freeze(migrated), names
end

local function set_view(self: LocklessProfile, base: any)
	local old = self.view
	self.base = base
	self.fetched = true
	self.view = replay(self.queue, base)
	if self.view ~= old then
		fire_changed(self, self.view, old)
	end
end

--- One update_async that folds the queue and, per `opts`, takes the transaction
--- lock or writes `pending` (which releases it). Callers hold the mutex.
--- Returns "lock_lost" when `pending` was requested but the transaction lock
--- was no longer ours (expired and taken over); nothing is written then.
local function write(self: LocklessProfile, opts: WriteOptions): Tx.PrepareStatus
	local store = self.store
	local config = store.config
	local queue = self.queue
	local known = self.known_outcomes
	local my_lock_id = tx_lock_id(self)
	local state: WriteState = { applied = false, blocked = nil, lock_lost = false, unknown_pending = nil }

	local function transform(old: any?): any?
		state.applied = false
		state.blocked = nil
		state.lock_lost = false
		state.unknown_pending = nil
		local now = runtime.now()

		local lock = foreign_lock(self, old, now)
		if lock ~= nil then
			state.blocked = { tx = lock.tx == true }
			return nil
		end
		if opts.pending ~= nil then
			local held = type(old) == "table"
				and old.lock ~= nil
				and old.lock.id == my_lock_id
				and old.lock.expires > now
			if not held then
				state.lock_lost = true
				return nil
			end
		end
		if type(old) == "table" and old.pending ~= nil and known[old.pending.tx] == nil then
			state.unknown_pending = old.pending
			return nil
		end

		local data, migrations = resolve_record(self, old, known)
		data = replay(queue, data)
		local record: types.Record = {
			data = data,
			migrations = migrations,
			pending = opts.pending,
			lock = if opts.take_lock then { id = my_lock_id, expires = now + config.tx_lock_ttl, tx = true } else nil,
		}
		state.applied = true
		return record
	end

	while true do
		local result = store:call(function()
			return store.data_store.update_async(self.key, transform, self.user_ids)
		end)
		local blocked = state.blocked
		if blocked ~= nil then
			handle_lock(self, { id = "", expires = math.huge, tx = blocked.tx })
			continue
		end
		if state.lock_lost then
			self.tx_locked = false
			return "lock_lost"
		end
		local unknown = state.unknown_pending
		if unknown ~= nil then
			local outcome = wait_outcome(self, unknown)
			if outcome ~= nil then
				known[unknown.tx] = outcome :: types.TxOutcome
			end
			continue
		end
		if not state.applied then
			error(`datastore: unexpected cancelled write for "{self.key}"`)
		end

		local record = result :: types.Record
		-- the queue was folded into storage; start fresh from what landed
		self.queue = {}
		self.dirty_pending = record.pending ~= nil
		self.tx_locked = opts.take_lock == true
		set_view(self, util.deep_freeze(record.data))
		if record.pending == nil then
			local txs = self.cleanup_txs
			self.cleanup_txs = {}
			for _, tx in txs do
				tx:cleaned()
			end
		end
		return "ok"
	end
end

local function fetch_locked(self: LocklessProfile): any
	local store = self.store
	while true do
		local record = store:call(function()
			return store.data_store.get_async(self.key)
		end)
		local lock = foreign_lock(self, record, runtime.now())
		if lock ~= nil then
			handle_lock(self, lock)
			continue
		end
		if type(record) == "table" and record.pending ~= nil and self.known_outcomes[record.pending.tx] == nil then
			local outcome = wait_outcome(self, record.pending)
			if outcome ~= nil then
				self.known_outcomes[record.pending.tx] = outcome :: types.TxOutcome
			end
			continue
		end
		local data = resolve_record(self, record, self.known_outcomes)
		set_view(self, data)
		return self.view
	end
end

local function assert_open(self: LocklessProfile)
	if not self.open then
		error(`datastore: profile "{self.key}" is closed`)
	end
end

function LocklessProfile.new<T>(store: StoreLike, key: string, user_ids: { number }?): LocklessProfile<T>
	local self: LocklessProfile<T> = setmetatable({
		kind = "lockless",
		key = key,
		user_ids = user_ids,
		store = store,
		open = true,
		fetched = false,
		base = nil,
		view = nil,
		queue = {},
		mutex = Mutex.new(),
		unresolved_tx = nil,
		cleanup_txs = {},
		known_outcomes = {},
		dirty_pending = false,
		tx_locked = false,
	}, LocklessProfile) :: any

	local config = store.config
	runtime.spawn(function()
		while true do
			runtime.wait(config.flush_interval)
			if not self.open then
				return
			end
			if #self.queue == 0 and not self.dirty_pending then
				continue
			end
			local ok, err = util.try(self.apply, self)
			if not ok and self.open then
				runtime.warn(`datastore: flush failed for "{key}": {tostring(err)}`)
			end
		end
	end)

	return self
end

function LocklessProfile.get<T>(self: LocklessProfile<T>): T
	if not self.fetched then
		error(`datastore: profile "{self.key}" has not been fetched`)
	end
	return self.view :: T
end

function LocklessProfile.is_fetched<T>(self: LocklessProfile<T>): boolean
	return self.fetched
end

function LocklessProfile.is_open<T>(self: LocklessProfile<T>): boolean
	return self.open
end

function LocklessProfile.has_pending_changes<T>(self: LocklessProfile<T>): boolean
	return #self.queue > 0
end

--- Queues `transform`. It runs later inside update_async on the stored data, so
--- it must be pure and must not capture the current view. Locally the view is
--- advanced right away when the profile is fetched.
function LocklessProfile.update<T>(self: LocklessProfile<T>, transform: (data: T) -> T | false): boolean
	assert_open(self)
	return self.mutex:with(function()
		self:_settle_tx()
		assert_open(self)
		if self.fetched then
			local old = self.view
			local result = transform(old :: T)
			if result == false then
				return false
			end
			if result == nil then
				error "datastore: update transform must return the new data or false"
			end
			table.insert(self.queue, transform)
			if (result :: any) ~= old then
				self.view = util.deep_freeze(result :: any)
				fire_changed(self, self.view, old)
			end
			return true
		end
		table.insert(self.queue, transform)
		return true
	end)
end

--- Reads the stored value (GetAsync) into the local view. Waits out a
--- transaction lock; throws if the key is session locked by another server.
function LocklessProfile.fetch<T>(self: LocklessProfile<T>): T
	assert_open(self)
	return self.mutex:with(function()
		self:_settle_tx()
		assert_open(self)
		return fetch_locked(self)
	end)
end

--- Flushes queued changes in one update_async and refreshes the local view with
--- what landed. No-op when fetched and nothing is queued (use `fetch` to
--- refresh). Waits out a transaction lock; throws if the key is session locked
--- by another server (the queue is kept).
function LocklessProfile.apply<T>(self: LocklessProfile<T>): T
	assert_open(self)
	return self.mutex:with(function()
		self:_settle_tx()
		assert_open(self)
		-- nothing to flush (a flush that queued up behind another one, typically)
		if self.fetched and #self.queue == 0 and not self.dirty_pending then
			return self.view
		end
		write(self, {})
		return self.view
	end)
end

function LocklessProfile.unload<T>(self: LocklessProfile<T>)
	if not self.open then
		return
	end
	self.open = false
	self.mutex:lock()
	local ok, err = pcall(function()
		self:_settle_tx()
		if #self.queue > 0 or self.dirty_pending then
			write(self, {})
		end
	end)
	self.store:_unregister(self)
	self.mutex:unlock()
	if not ok then
		runtime.warn(`datastore: failed to flush "{self.key}" on unload ({#self.queue} changes lost): {tostring(err)}`)
	end
end

function LocklessProfile._settle_tx<T>(self: LocklessProfile<T>)
	local tx = self.unresolved_tx
	if tx ~= nil then
		tx:settle()
	end
end

function LocklessProfile._participant<T>(self: LocklessProfile<T>): Tx.Participant
	local store = self.store
	return {
		profile = self,
		store = store,
		sort_key = store.config.name .. "\0" .. self.key,
		lockless = true,
		lock = function()
			self.mutex:lock()
		end,
		unlock = function()
			if self.tx_locked then
				-- the transaction ended without writing pending (cancelled, aborted
				-- early or failed): give the key back
				local ok, err = pcall(write, self, {})
				if not ok then
					runtime.warn(
						`datastore: failed to release tx lock on "{self.key}" (expires in {store.config.tx_lock_ttl}s): {tostring(
							err
						)}`
					)
					self.tx_locked = false
				end
			end
			self.mutex:unlock()
		end,
		is_open = function()
			return self.open
		end,
		settle_pending = function()
			self:_settle_tx()
		end,
		begin = function()
			write(self, { take_lock = true })
		end,
		snapshot = function()
			return self.view
		end,
		set_data = function(new)
			table.insert(self.queue, function()
				return new
			end)
			write(self, {})
		end,
		prepare = function(_, pending)
			return write(self, { pending = pending })
		end,
		apply_committed = function(new, tx)
			self.unresolved_tx = nil
			self.known_outcomes[tx.id] = "committed"
			table.insert(self.cleanup_txs, tx)
			-- storage still holds base + pending; the local view moves on now
			local old = self.view
			self.base = new
			self.view = replay(self.queue, new)
			self.dirty_pending = true
			if self.view ~= old then
				fire_changed(self, self.view, old)
			end
		end,
		apply_aborted = function(prepared, tx)
			self.unresolved_tx = nil
			self.known_outcomes[tx.id] = "aborted"
			self.dirty_pending = prepared
		end,
	}
end

--- Whether a stored record is held by a transaction lock (vs a session lock).
LocklessProfile.is_tx_lock = util.is_tx_lock

return LocklessProfile
