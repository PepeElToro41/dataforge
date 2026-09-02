local common = require "./common"
local mutex = require "../mutex"
local tx_handle = require "../tx/handle"
local types = require "../types"
local utils = require "../utils"

type Array<T> = { T }
type LoadOptions = types.LoadOptions
type DataRecord = types.DataRecord
export type LocklessProfile<T = any> = types.LocklessProfile<T>

local lockless_profile = {}
lockless_profile.__index = lockless_profile

function lockless_profile.get_data(self: LocklessProfile)
	common.assert_open(self)
	if not self.fetched then
		error(`datastore: lockless profile "{self.key}" has not been fetched`)
	end
	return self._data
end

--- The data a record stands for once its `pending` (if any) is accounted for:
--- `pending.data` when that transaction is known to have committed, the plain
--- data otherwise. Returns nil when the outcome is not known yet; pure, so it
--- can run inside a transform (the caller resolves the marker outside).
local function pending_data(self: LocklessProfile, record: DataRecord): (boolean, any)
	local pending = record.pending
	if not pending then
		return true, record.data
	end

	local outcome = self._known_outcomes[pending.tx_id]
	if outcome == nil then
		return false, nil
	end
	if outcome == "committed" then
		return true, pending.data
	end
	return true, record.data
end

--- Learns the outcome of a foreign `pending`. Until the pending's `expires` it
--- is given time (its coordinator may still be running); after that the marker
--- is force-resolved with fallback "aborted". Yields, so never inside a transform.
local function resolve_unknown_pending(self: LocklessProfile, pending: types.Pending)
	local config = self.config
	while true do
		local outcome: types.TxOutcome? = tx_handle.resolve_pending(config._hook, config, pending, false)
		if outcome ~= nil then
			self._known_outcomes[pending.tx_id] = outcome :: types.TxOutcome
			return
		end
		config._scheduler.wait(config.load_poll)
	end
end

local function resolve_record(self: LocklessProfile, record: DataRecord?, data: any): (any, { string })
	local config = self.config
	local applied: { string } = {}

	if record then
		applied = record.migrations or {}
	end

	if data == nil then
		return utils.deep_copy(config.template), common.all_migration_names(config.migrations)
	end

	local result = common.apply_migrations(data, applied, config.migrations)
	if not result.success then
		error(`datastore: failed to apply migrations for "{self.key}": {result.err}`)
	end
	return result.result, result.new_migrations
end

local function replay(queue: Array<types.DataDispatcher<any>>, data: any): any
	for _, dispatcher in queue do
		local result = dispatcher(data)
		if result ~= nil and result ~= false then
			data = result
		end
	end
	return data
end

local function fire_hooks<T...>(self: LocklessProfile, name: string, hooks: Array<(T...) -> ()>, ...: T...)
	for _, hook in hooks do
		local ok, err = utils.try(hook, ...)
		if not ok then
			self.config._hook.warn(`datastore: hook {name} failed for {self.key}: {tostring(err)}`)
		end
	end
end

local function set_data(self: LocklessProfile, data: any)
	local old = self._data
	local new = utils.deep_freeze(data)
	self._data = new
	fire_hooks(self, "change", self._hooks.change, new, old)
end

--- A session lock showed up on the record: a locked profile owns the key now
--- and this profile lost its lockless standing. Closes it (no write; the
--- queue stays for the error message). Caller holds the mutex.
local function process_lock_lost(self: LocklessProfile)
	if not self.open then
		return
	end
	self.open = false
	self._mutex:close(`datastore: profile "{self.key}" is session locked`)
	fire_hooks(self, "lock_lost", self._hooks.lock_lost)
	fire_hooks(self, "closed", self._hooks.closed)
end

type SaveState = {
	applied: boolean,
	--- a live transaction lock is on the record; `tx_lock_expires` says until when
	tx_locked: boolean,
	tx_lock_expires: number,
	--- a session lock is on the record
	session_locked: boolean,
	tx_lock_lost: boolean,
	outdated: boolean,
	unknown_pending: types.Pending?,
}

type WriteOptions = types.LocklessWriteOptions

--- Folds the queued updates into storage with one update_async: the stored
--- data (whatever any server left there) goes through migrations, then every
--- queued update, and what lands becomes the local data. Caller holds the mutex.
---
--- `options.tx_lock` leaves a short transaction lock on the record (kept in
--- `self._tx_lock`). `options.old_tx_lock` is the lock this write expects to
--- find on the record: the write only goes through (and clears that lock) when
--- the stored lock has the same id. If the lock is gone or belongs to someone
--- else, nothing is written and the call fails with "lock_lost".
local function write_queued(self: LocklessProfile, options: WriteOptions)
	local config = self.config
	local scheduler = config._scheduler
	local datastore = self._datastore
	local queue = self.queued_updates
	local old_tx_lock = options.old_tx_lock
	local new_lock = options.tx_lock

	local state: SaveState = {
		applied = false,
		tx_locked = false,
		tx_lock_expires = 0,
		tx_lock_lost = false,
		session_locked = false,
		outdated = false,
		unknown_pending = nil,
	}

	local function transform(old: DataRecord?): DataRecord?
		state.applied = false
		state.tx_locked = false
		state.session_locked = false
		state.tx_lock_lost = false
		state.outdated = false
		state.unknown_pending = nil

		local lock = if old then old.lock else nil

		-- a live session lock means a locked profile owns this key now: the
		-- profile lost its lockless standing, whatever else it expected on the
		-- record. An expired one belongs to a dead server and is written over.
		if lock and not lock.tx then
			if lock.expires > scheduler.now() then
				state.session_locked = true
				return nil
			end
			lock = nil
		end

		if old_tx_lock then
			-- only our own transaction lock may be replaced; anything else
			-- (no lock, or a different one) means we no longer hold the key
			if not lock or lock.id ~= old_tx_lock.id then
				state.tx_lock_lost = true
				return nil
			end
		elseif lock and lock.expires > scheduler.now() then
			-- a live transaction lock (another server's, or a stale one of ours)
			-- blocks the write until it is released or expires; the caller waits
			state.tx_locked = true
			state.tx_lock_expires = lock.expires
			return nil
		end

		-- more migrations applied than this server declares: a newer server
		-- already touched the record, so this server must not write to it
		if old and old.migrations and #old.migrations > #config.migrations then
			state.outdated = true
			return nil
		end

		-- a `pending` left by some transaction (ours after commit, or another
		-- server's) decides which data this write builds on
		local base: any = nil
		if old then
			local known, folded = pending_data(self, old)
			if not known then
				state.unknown_pending = old.pending
				return nil
			end
			base = folded
		end

		local data, migrations = resolve_record(self, old, base)
		data = replay(queue, data)

		state.applied = true

		return {
			data = data,
			migrations = migrations,
			pending = options.pending,
			lock = new_lock,
		}
	end

	while true do
		local record = utils.retry(config, function()
			return datastore.update_async(self.key, transform, self.user_ids)
		end) :: DataRecord

		if state.session_locked then
			self._tx_lock = nil
			process_lock_lost(self)
			error(`datastore: "{self.key}" is session locked`)
		end

		if state.tx_lock_lost then
			-- whatever is on the record now is not ours; do not touch it again
			self._tx_lock = nil
			process_lock_lost(self)
			error(`datastore: lock_lost for "{self.key}"`)
		end

		if state.tx_locked then
			-- wait for the transaction to release the key (or its lock to expire)
			scheduler.wait(math.min(config.load_poll, math.max(state.tx_lock_expires - scheduler.now(), 0)))
			continue
		end

		if state.outdated then
			error(
				`datastore: "{self.key}" was written by a newer server (record has {#record.migrations} applied migrations, this server declares {#config.migrations})`
			)
		end

		local unknown = state.unknown_pending
		if unknown then
			-- learn the outcome (may wait for the coordinator), then write again
			resolve_unknown_pending(self, unknown)
			continue
		end

		if not state.applied then
			error(`datastore: unexpected cancelled write for "{self.key}"`)
		end

		-- the queue is now in storage; the local view restarts from what landed.
		-- Whatever `pending` the record carried was folded in, so its outcome is
		-- no longer needed (a pending written now gets its outcome at settle).
		self._known_outcomes = {}
		self._tx_lock = new_lock
		self.queued_updates = {}
		self.dirty_pending = options.pending ~= nil
		self.migrations = record.migrations
		set_data(self, record.data)
		self.fetched = true

		if options.pending == nil then
			-- the record is clean: every transaction waiting on that can drop its marker
			local cleanups = self._cleanup_txs
			self._cleanup_txs = {}
			for _, operation in cleanups do
				operation:cleaned()
			end
		end
		return
	end
end

--- Inserts `dispatcher` into the queue (no storage call; it lands on the next
--- save / flush / unload). When fetched, the local data is advanced right away.
--- Caller holds the mutex.
local function queue_update(self: LocklessProfile, dispatcher: types.DataDispatcher<any>): boolean
	if not self.fetched then
		table.insert(self.queued_updates, dispatcher)
		return true
	end

	local result = dispatcher(self._data)
	if result == nil or result == false then
		return false
	end

	table.insert(self.queued_updates, dispatcher)
	set_data(self, result)
	return true
end

--- Applies every queued update to the stored data in one update_async and
--- refreshes the local data with the result. Marks the profile fetched.
--- Throws (keeping the queue) if another server holds a live session lock, or
--- if the record was already written by a newer server (more migrations applied
--- than this server declares). Neither case is retried.
function lockless_profile.save(self: LocklessProfile)
	common.assert_open(self)
	-- before the mutex so hooks can still queue updates that land in this save
	fire_hooks(self, "save", self._hooks.save)
	common.assert_open(self)
	self._mutex:with(function()
		write_queued(self, {})
	end)
end

function lockless_profile.unload(self: LocklessProfile)
	if not self.open then
		return
	end
	-- last chance to queue updates while the profile is still open
	fire_hooks(self, "closing", self._hooks.closing)

	self.open = false
	self._mutex:lock()
	-- everything still waiting on the mutex (and anything after) is rejected
	self._mutex:close(`datastore: profile "{self.key}" is closed`)
	local ok, err = utils.try(function()
		if #self.queued_updates > 0 or self.dirty_pending then
			write_queued(self, {})
		end
	end)
	self._mutex:unlock()
	if not ok then
		self.config._hook.warn(`datastore: failed to flush "{self.key}" on unload ({#self.queued_updates} changes lost): {tostring(err)}`)
	end
	fire_hooks(self, "closed", self._hooks.closed)
end

function lockless_profile.on_change(self: LocklessProfile, callback: (new: any, old: any?) -> ())
	table.insert(self._hooks.change, callback)
end

function lockless_profile.on_save(self: LocklessProfile, callback: () -> ())
	table.insert(self._hooks.save, callback)
end

function lockless_profile.on_closing(self: LocklessProfile, callback: () -> ())
	table.insert(self._hooks.closing, callback)
end

function lockless_profile.on_closed(self: LocklessProfile, callback: () -> ())
	table.insert(self._hooks.closed, callback)
end

--- Fires when a session lock shows up on the record: a locked profile owns
--- the key now, this profile is closed.
function lockless_profile.on_lock_lost(self: LocklessProfile, callback: () -> ())
	table.insert(self._hooks.lock_lost, callback)
end

--- Yields until no operation holds or waits on the profile mutex. Once this
--- returns, the next update call is guaranteed not to yield (nothing is queued
--- ahead of it).
function lockless_profile.wait_settled(self: LocklessProfile)
	return self._mutex:wait_settled()
end

--- Reads the stored record (get_async) into the local data: migrations are
--- applied, then the queued updates replayed on top, so `get_data()` reflects the
--- local changes still waiting for a save. Marks the profile fetched. Throws
--- (keeping the queue) if any session lock is on the record. Caller holds the mutex.
local function read_record(self: LocklessProfile)
	local config = self.config
	local datastore = self._datastore

	local record = utils.retry(config, function()
		return datastore.get_async(self.key)
	end) :: DataRecord?

	local lock = if record then record.lock else nil
	if lock and not lock.tx and lock.expires > config._scheduler.now() then
		process_lock_lost(self)
		error(`datastore: "{self.key}" is session locked`)
	end
	-- an expired session lock belongs to a dead server: ignored, the next write clears it
	-- a transaction lock does not matter for a read: the data under it is the
	-- data until that transaction's `pending` lands (handled below)

	-- a `pending` on the record: find out whether it committed (the record is
	-- left as is; the next write folds it in)
	local base: any = nil
	if record then
		local known, folded = pending_data(self, record)
		if not known then
			resolve_unknown_pending(self, record.pending :: types.Pending)
			known, folded = pending_data(self, record)
		end
		base = folded
	end

	local data, migrations = resolve_record(self, record, base)
	data = replay(self.queued_updates, data)

	self.migrations = migrations
	set_data(self, data)
	self.fetched = true
	return self._data
end

function lockless_profile.fetch(self: LocklessProfile)
	common.assert_open(self)
	return self._mutex:with(function()
		return read_record(self)
	end)
end

--- Queues `dispatcher` to run against the stored data on the next save. When
--- the profile is fetched, the local data is advanced right away so `get_data()`
--- reflects the queued change. A dispatcher returning `false` (or nil) is a
--- no-op and is not queued. Waits for any in-flight save/fetch on the mutex.
function lockless_profile.update(self: LocklessProfile, dispatcher: (any) -> any): boolean
	common.assert_open(self)

	return self._mutex:with(function()
		return queue_update(self, dispatcher)
	end)
end

--- Periodically flushes the queue (only when there is something to write; an
--- idle lockless profile costs no storage calls). Stops once the profile closes.
local function run_flush_loop(self: LocklessProfile)
	local config = self.config
	local scheduler = config._scheduler

	scheduler.spawn(function()
		while true do
			scheduler.wait(config.flush_interval)
			if not self.open then
				return
			end
			if #self.queued_updates == 0 and not self.dirty_pending then
				continue
			end

			local ok, err = utils.try(self.save, self)
			if not ok then
				config._hook.warn(`datastore: failed to flush "{self.key}": {tostring(err)}`)
			end
		end
	end)
end

-- its called create not load because it doesnt do anything in the Datastore
function lockless_profile.create(options: LoadOptions): LocklessProfile
	local self = {} :: LocklessProfile
	self.kind = "lockless"
	self.key = options.key
	self.user_ids = options.user_ids
	self._datastore = options._datastore
	self.open = true

	self.config = options.config
	self.migrations = nil :: any

	self._data = nil
	self._mutex = mutex.create(options.config._scheduler)
	self.fetched = false
	self.queued_updates = {}
	self.dirty_pending = false
	self._tx_lock = nil
	self._known_outcomes = {}
	self._cleanup_txs = {}
	self._hooks = { change = {}, save = {}, closing = {}, closed = {}, lock_lost = {} }

	setmetatable(self, lockless_profile)
	run_flush_loop(self)
	return self :: any
end

function is_lockless_profile(unknown: any)
	if type(unknown) ~= "table" then
		return false
	end
	return getmetatable(unknown) == lockless_profile
end

-- internal methods, used by transactions
lockless_profile._write_queued = write_queued
lockless_profile._queue_update = queue_update
lockless_profile._set_data = set_data

return {
	create = lockless_profile.create,
	is = is_lockless_profile,
}
