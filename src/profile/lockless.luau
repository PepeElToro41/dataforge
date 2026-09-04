local common = require "./common"
local errors = require "../errors"
local mutex = require "../mutex"
local result = require "../result"
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
		error(errors.not_fetched(self), 0)
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

	local migrated = common.apply_migrations(self.key, data, applied, config.migrations)
	if not migrated.success then
		common.raise_migrations(self, migrated)
	end
	return migrated.result, migrated.new_migrations
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
	self._mutex:close(errors.profile_closed(self, "lock_lost"))
	fire_hooks(self, "lock_lost", self._hooks.lock_lost)
	fire_hooks(self, "closed", self._hooks.closed)
end

type SaveState = {
	applied: boolean,
	--- the lock found on the record (session or transaction), nil when none
	lock: types.Lock?,
	--- a live transaction lock is on the record; `tx_lock_expires` says until when
	tx_locked: boolean,
	tx_lock_expires: number,
	--- a session lock is on the record
	session_locked: boolean,
	tx_lock_lost: boolean,
	outdated: boolean,
	unknown_pending: types.Pending?,
	--- the transform threw (a migration or a queued dispatcher): rethrown after
	--- the storage call instead of being retried as a storage failure
	failure: any,
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
--- else, nothing is written and the call fails with `tx_lock_lost`.
---
--- Throws `lockless_locked` (a live session lock; the profile is closed),
--- `tx_lock_lost` (closed too), `outdated` (a newer server wrote the record;
--- nothing written), `migration_mismatch`, `roblox`, or whatever a queued
--- dispatcher / migration threw.
local function write_queued(self: LocklessProfile, options: WriteOptions)
	local config = self.config
	local scheduler = config._scheduler
	local datastore = self._datastore
	local queue = self.queued_updates
	local old_tx_lock = options.old_tx_lock
	local new_lock = options.tx_lock

	local state: SaveState = {
		applied = false,
		lock = nil,
		tx_locked = false,
		tx_lock_expires = 0,
		tx_lock_lost = false,
		session_locked = false,
		outdated = false,
		unknown_pending = nil,
		failure = nil,
	}

	local function transform_body(old: DataRecord?): DataRecord?
		local lock = if old then old.lock else nil
		state.lock = lock

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
		if common.is_outdated(old, config) then
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

	-- the body runs migrations and queued dispatchers (user code) and may raise
	-- a `migration_mismatch`: none of those is a storage failure, so the
	-- storage retry must not see them. They cancel the write and are rethrown.
	local function transform(old: DataRecord?): DataRecord?
		state.applied = false
		state.lock = nil
		state.tx_locked = false
		state.session_locked = false
		state.tx_lock_lost = false
		state.outdated = false
		state.unknown_pending = nil
		state.failure = nil

		local ok, new = pcall(transform_body, old)
		if not ok then
			state.failure = new
			return nil
		end
		return new
	end

	while true do
		local record = utils.update_async(config, datastore, self.key, transform, self.user_ids) :: DataRecord

		if state.failure ~= nil then
			error(state.failure, 0)
		end

		if state.session_locked then
			self._tx_lock = nil
			process_lock_lost(self)
			error(errors.lockless_locked(self, state.lock :: types.Lock), 0)
		end

		if state.tx_lock_lost then
			-- whatever is on the record now is not ours; do not touch it again
			self._tx_lock = nil
			process_lock_lost(self)
			error(errors.tx_lock_lost(self, old_tx_lock :: types.Lock, state.lock), 0)
		end

		if state.tx_locked then
			-- wait for the transaction to release the key (or its lock to expire)
			scheduler.wait(math.min(config.load_poll, math.max(state.tx_lock_expires - scheduler.now(), 0)))
			continue
		end

		if state.outdated then
			error(
				errors.outdated(self.key, record.migrations or {}, common.all_migration_names(config.migrations), self),
				0
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
--- Fails (keeping the queue) with `lockless_locked` if another server holds a
--- live session lock (the profile is closed), `outdated` if the record was
--- already written by a newer server, `migration_mismatch`, `roblox` or
--- `profile_closed`. An error thrown by a queued dispatcher propagates as is.
function lockless_profile.save(self: LocklessProfile): types.Result<nil>
	return result.capture(function()
		common.assert_open(self)
		-- before the mutex so hooks can still queue updates that land in this save
		fire_hooks(self, "save", self._hooks.save)
		common.assert_open(self)
		self._mutex:with(function()
			write_queued(self, {})
		end)
		return nil
	end)
end

function lockless_profile.unload(self: LocklessProfile)
	if not self.open then
		return
	end
	-- last chance to queue updates while the profile is still open
	fire_hooks(self, "closing", self._hooks.closing)
	-- a closing hook may have unloaded the profile itself
	if not self.open then
		return
	end

	self.open = false
	self._mutex:lock()
	-- everything still waiting on the mutex (and anything after) is rejected
	self._mutex:close(errors.profile_closed(self, "unloaded"))
	local ok, err = utils.try(function()
		if #self.queued_updates > 0 or self.dirty_pending then
			write_queued(self, {})
		end
	end)
	self._mutex:unlock()
	if not ok then
		self.config._hook.warn(
			`datastore: failed to flush "{self.key}" on unload ({#self.queued_updates} changes lost): {tostring(err)}`
		)
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

	local record = utils.get_async(config, datastore, self.key) :: DataRecord?

	local lock = if record then record.lock else nil
	if lock and not lock.tx and lock.expires > config._scheduler.now() then
		process_lock_lost(self)
		error(errors.lockless_locked(self, lock), 0)
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

--- Fails with `lockless_locked` (a session lock is on the record; the profile
--- is closed), `outdated` (a newer server wrote the record), `migration_mismatch`,
--- `roblox`, `tx_marker_invalid` or `profile_closed`. An error thrown by a
--- queued dispatcher propagates as is.
function lockless_profile.fetch(self: LocklessProfile): types.Result<any>
	return result.capture(function()
		common.assert_open(self)
		return self._mutex:with(function()
			return read_record(self)
		end)
	end)
end

--- Queues `dispatcher` to run against the stored data on the next save. When
--- the profile is fetched, the local data is advanced right away so `get_data()`
--- reflects the queued change. A dispatcher returning `false` (or nil) is a
--- no-op and is not queued (Ok(false)). Waits for any in-flight save/fetch on
--- the mutex. Fails with `profile_closed`; an error thrown by the dispatcher
--- propagates as is.
function lockless_profile.update(self: LocklessProfile, dispatcher: (any) -> any): types.Result<boolean>
	return result.capture(function()
		common.assert_open(self)

		return self._mutex:with(function()
			return queue_update(self, dispatcher)
		end)
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

			local ok, res = utils.try(self.save, self)
			if not ok then
				config._hook.warn(`datastore: failed to flush "{self.key}": {tostring(res)}`)
			elseif not res.success then
				config._hook.warn(`datastore: failed to flush "{self.key}": {tostring(res.error)}`)
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
