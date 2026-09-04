local errors = require "../errors"
local mutex = require "../mutex"
local result = require "../result"
local types = require "../types"
local utils = require "../utils"
local common = require "./common"
local tx_handle = require "../tx/handle"

type Array<T> = { T }
type DataRecord = types.DataRecord
type HooksList<T... = ()> = types.HooksList<T...>
export type Profile<T = any> = types.Profile<T>
export type LoadOptions = types.LoadOptions

local profile = {}
profile.__index = profile

local function adquire_lock(load_options: LoadOptions): types.DataRecord
	local config = load_options.config
	local user_ids = load_options.user_ids
	local datastore = load_options._datastore
	local job_id = config._hook.job_id()
	local key = load_options.key

	local scheduler = config._scheduler

	local deadline = scheduler.now() + config.load_timeout
	-- the last lock seen on the record, reported when the load times out
	local last_lock: types.Lock? = nil
	-- set by the transform: the record lists more migrations than this server
	-- declares, so the lock must not be taken (the write is cancelled)
	local outdated_migrations: { string }? = nil

	while true do
		local now = scheduler.now()
		local lock_applied = utils.update_async(
			config,
			datastore,
			key,
			function(old: types.DataRecord?): types.DataRecord?
				outdated_migrations = nil
				if common.is_outdated(old, config) then
					outdated_migrations = (old :: types.DataRecord).migrations
					return nil
				end
				if common.is_locked_for(old :: types.DataRecord, job_id, now) then
					return nil
				end
				local record: types.DataRecord = old or {} :: types.DataRecord

				return {
					data = record.data,
					pending = record.pending,
					migrations = record.migrations or {},
					lock = {
						id = job_id,
						expires = now + config.lock_ttl,
					},
				}
			end,
			user_ids
		) :: types.DataRecord

		if outdated_migrations ~= nil then
			error(errors.outdated(key, outdated_migrations, common.all_migration_names(config.migrations)), 0)
		end
		if common.is_lock_owned(lock_applied, job_id) then
			return lock_applied
		end
		last_lock = if lock_applied then lock_applied.lock else nil

		while true do
			if scheduler.now() >= deadline then
				error(errors.timeout(key, last_lock), 0)
			end
			scheduler.wait(config.load_poll)

			local current = utils.get_async(config, datastore, key) :: types.DataRecord?
			last_lock = if current then current.lock else nil

			if not common.is_locked_for(current, job_id, scheduler.now()) then
				break
			end
		end
	end
end

local apply_migrations = common.apply_migrations

local function run_autosave_loop(self: Profile)
	local config = self.config
	local scheduler = config._scheduler

	scheduler.spawn(function()
		while true do
			scheduler.wait(config.autosave_interval)
			if not self.open then
				return
			end
			if not self.is_locked then
				-- released: nothing to refresh, nothing may be written
				continue
			end

			-- a failed write must not kill the loop: the next tick retries, and
			-- `write_data_record` gives the lock up after a full ttl of failures
			local ok, res = utils.try(self.save, self)
			if not ok then
				config._hook.warn(`datastore: autosave failed for "{self.key}": {tostring(res)}`)
			elseif not res.success then
				config._hook.warn(`datastore: autosave failed for "{self.key}": {tostring(res.error)}`)
			end
		end
	end)
end

local function fire_hooks<T...>(self: Profile, hooks: HooksList<T...>, ...: T...)
	for _, hook in hooks.hooks do
		local ok, err = utils.try(hook, ...)
		if not ok then
			self.config._hook.warn(`datastore: hook {hooks.type} failed for {self.key}: {tostring(err)}`)
		end
	end
end

local function set_data(self: Profile, data: any)
	local old = self._data
	local new = utils.deep_freeze(data)
	self._data = new
	fire_hooks(self, self._hooks.change, new, old)
end

--- Another server took the key: the profile closes without a release write.
--- Runs inside a write (mutex held by the caller), so it only closes the mutex:
--- the holder finishes, everything waiting on it is rejected.
local function process_lock_lost(self: Profile)
	if not self.open then
		return
	end
	self.open = false
	self._mutex:close(errors.profile_closed(self, "lock_lost"))
	fire_hooks(self, self._hooks.lock_lost)
	fire_hooks(self, self._hooks.closed)
end

type WriteOptions = {
	release: boolean,
	pending: types.Pending?,
}

--- Writes the data (and `pending`, if any) under our session lock, refreshing
--- or releasing it. Returns true when written; false and the lock now on the
--- record (nil when none) when the lock is not ours any more, in which case
--- the profile is closed. Throws a `roblox` error when storage fails.
local function write_data_record(self: Profile, options: WriteOptions): (boolean, types.Lock?)
	local config = self.config
	local scheduler = config._scheduler
	local datastore = self._datastore
	local now = scheduler.now()
	local job_id = config._hook.job_id()

	-- set by the transform: whether the write went through (the transform may
	-- run more than once when the storage retries it), and the lock it found
	local applied = false
	local seen_lock: types.Lock? = nil

	local function transform(old: any?): DataRecord?
		applied = false
		seen_lock = if old then old.lock else nil
		if not common.is_lock_owned(old, job_id) then
			return nil
		end
		applied = true

		local new_lock: types.Lock? = nil
		if not options.release then
			new_lock = {
				id = job_id,
				expires = now + config.lock_ttl,
				tx = nil,
			} :: types.Lock
		end

		return {
			data = self._data,
			migrations = self.migrations,
			pending = options.pending,
			lock = new_lock,
		}
	end

	local success, err = pcall(function()
		utils.update_async(config, datastore, self.key, transform, self.user_ids)
	end)

	if not success then
		if scheduler.now() - self.last_write > config.lock_ttl then
			-- We have not managed to refresh the lock for a full TTL; assume its gone.
			process_lock_lost(self)
		end

		error(err, 0)
	end

	if not applied then
		-- the transform bailed out: the lock is not ours any more
		process_lock_lost(self)
		return false, seen_lock
	end

	self.last_write = now
	self._dirty = false

	if options.pending == nil then
		-- the record is clean: every transaction waiting on that can drop its marker
		local cleanups = self._cleanup_txs
		self._cleanup_txs = {}
		for _, operation in cleanups do
			operation:cleaned()
		end
	end
	return true
end

--- Gives the lock taken by `adquire_lock` back, leaving the record otherwise
--- untouched. Used when the load fails after locking; a failure here is only
--- warned about (the lock expires on its own).
local function release_lock(load_options: LoadOptions)
	local config = load_options.config
	local job_id = config._hook.job_id()

	local ok, err = utils.try(function()
		utils.update_async(config, load_options._datastore, load_options.key, function(old: DataRecord?): DataRecord?
			if not common.is_lock_owned(old, job_id) then
				return nil
			end
			local record = old :: DataRecord
			return {
				data = record.data,
				pending = record.pending,
				migrations = record.migrations,
				lock = nil,
			}
		end, load_options.user_ids)
	end)
	if not ok then
		config._hook.warn(
			`datastore: could not release the lock of "{load_options.key}" after a failed load (it will expire): {tostring(
				err
			)}`
		)
	end
end

--- Turns the locked record into the data the profile starts with: resolves a
--- `pending`, falls back to the template, applies migrations. May throw.
local function resolve_loaded(load_options: LoadOptions, record: DataRecord): (any, { string }, boolean)
	local config = load_options.config
	local data = record.data
	local dirty = false

	if record.pending ~= nil then
		local outcome = tx_handle.resolve_pending(config._hook, config, record.pending, true)
		if outcome == "committed" then
			data = record.pending.data
		end
		dirty = true
	end

	local migrations = config.migrations
	local new_migrations: { string }

	if data == nil then
		data = utils.deep_copy(config.template)

		-- fresh template already matches the latest schema, mark every migration as applied
		new_migrations = table.create(#migrations) :: { string }
		for index, migration in migrations do
			new_migrations[index] = migration.name
		end
		dirty = true
	else
		local migrated = apply_migrations(load_options.key, data, record.migrations or {}, migrations)
		if not migrated.success then
			error(migrated.err, 0)
		end

		data = migrated.result
		new_migrations = migrated.new_migrations

		if migrated.applied then
			dirty = true
		end
	end

	return data, new_migrations, dirty
end

--- Takes the session lock and resolves the locked record into data. If the
--- resolution fails the lock is given back before rethrowing.
local function adquire_and_resolve(load_options: LoadOptions): (any, { string }, boolean)
	local record = adquire_lock(load_options)
	local config = load_options.config

	-- from here on the key is locked: anything failing must give it back
	local ok, data, new_migrations, dirty = pcall(resolve_loaded, load_options, record)
	if not ok then
		local err = data
		config._hook.warn(
			`datastore: load of "{load_options.key}" failed after taking its lock, releasing it: {tostring(err)}`
		)
		release_lock(load_options)
		error(err, 0)
	end
	return data, new_migrations, dirty
end

local function load_options_of(self: Profile): LoadOptions
	return {
		key = self.key,
		_datastore = self._datastore,
		config = self.config,
		user_ids = self.user_ids,
	}
end

local function assert_locked(self: Profile)
	if not self.is_locked then
		error(errors.released(self), 0)
	end
end

function profile.load(load_options: LoadOptions): Profile
	local data, new_migrations, dirty = adquire_and_resolve(load_options)
	local config = load_options.config

	local self: Profile = {} :: any
	self.kind = "locked"
	self.key = load_options.key
	self.user_ids = load_options.user_ids
	self._datastore = load_options._datastore
	self.open = true
	self.is_locked = true

	self.config = load_options.config
	self.migrations = new_migrations

	self._hooks = {
		change = { type = "change", hooks = {} },
		lock_lost = { type = "lock_lost", hooks = {} },
		save = { type = "save", hooks = {} },
		closing = { type = "closing", hooks = {} },
		closed = { type = "closed", hooks = {} },
	}

	self._data = nil
	set_data(self, data)
	-- the lock was just taken by `adquire_lock`; counts as a successful write
	self.last_write = config._scheduler.now()

	self._dirty = dirty
	self._mutex = mutex.create(config._scheduler)
	self._cleanup_txs = {}

	run_autosave_loop(self)
	return setmetatable(self, profile) :: any
end

function profile.get_data(self: Profile)
	common.assert_open(self)
	return self._data
end

--- Applies `dispatcher` to the current data. Returning nil or false leaves the
--- data untouched (Ok(false)); anything else becomes the new data and is
--- persisted on the next save (Ok(true)). Waits for any in-flight save on the
--- mutex. Fails with `profile_closed` / `released`; an error thrown by the
--- dispatcher propagates as is.
function profile.update(self: Profile, dispatcher: (any) -> any): types.Result<boolean>
	return result.capture(function()
		common.assert_open(self)
		assert_locked(self)

		return self._mutex:with(function()
			-- a release may have run while this call waited on the mutex
			assert_locked(self)
			local new = dispatcher(self._data)
			if new == nil or new == false then
				return false
			end
			set_data(self, new)
			self._dirty = true
			return true
		end)
	end)
end

function profile.on_change(self: Profile, callback: (new: any, old: any?) -> ())
	table.insert(self._hooks.change.hooks, callback)
end

function profile.on_save(self: Profile, callback: () -> ())
	table.insert(self._hooks.save.hooks, callback)
end

function profile.on_closing(self: Profile, callback: () -> ())
	table.insert(self._hooks.closing.hooks, callback)
end

function profile.on_closed(self: Profile, callback: () -> ())
	table.insert(self._hooks.closed.hooks, callback)
end

function profile.on_lock_lost(self: Profile, callback: () -> ())
	table.insert(self._hooks.lock_lost.hooks, callback)
end

--- Writes the data, refreshing the session lock. Fails with `profile_closed`,
--- `released`, `roblox`, or `lock_lost` (another server took the key; the
--- profile is closed).
function profile.save(self: Profile): types.Result<nil>
	return result.capture(function()
		common.assert_open(self)
		assert_locked(self)
		-- before the mutex so hooks can still run updates that land in this save
		fire_hooks(self, self._hooks.save)
		common.assert_open(self)
		assert_locked(self)
		self._mutex:with(function()
			-- without the lock the write would be cancelled and wrongly read as lost
			assert_locked(self)
			local written, lock = write_data_record(self, { release = false })
			if not written then
				error(errors.lock_lost(self, lock), 0)
			end
		end)
		return nil
	end)
end

--- Writes the data and gives the session lock back. The profile stays open
--- (another server may load the key meanwhile); `update` and `save` fail with
--- `released` until `readquire`. No-op when already released. Fails with
--- `profile_closed`, `roblox` (the lock stays on the record, `is_locked`
--- stays true) or `lock_lost` (the profile is closed).
function profile.release(self: Profile): types.Result<nil>
	return result.capture(function()
		common.assert_open(self)
		if not self.is_locked then
			return nil
		end
		self._mutex:with(function()
			-- an unload queued behind this call has flipped `open`: its own write
			-- gives the lock back
			if not self.open or not self.is_locked then
				return
			end
			local written, lock = write_data_record(self, { release = true })
			if not written then
				error(errors.lock_lost(self, lock), 0)
			end
			self.is_locked = false
		end)
		return nil
	end)
end

--- Takes the session lock again, waiting for a holder like `load` does, and
--- adopts the stored record (resolved pending, migrations) as the current
--- data. Fails with `timeout` (the profile stays open and released),
--- `profile_closed`, `roblox`, `outdated`, `migration_mismatch` or `tx_marker_invalid`. No-op when
--- already locked.
function profile.readquire(self: Profile): types.Result<nil>
	return result.capture(function()
		common.assert_open(self)
		if self.is_locked then
			return nil
		end
		self._mutex:with(function()
			common.assert_open(self)
			if self.is_locked then
				return
			end
			local ok, data, new_migrations, dirty = pcall(adquire_and_resolve, load_options_of(self))
			if not ok then
				local err: any = data
				if errors.is(err) and err.type == "outdated" then
					err.profile = self
				end
				error(err, 0)
			end

			self.migrations = new_migrations
			set_data(self, data)
			self._dirty = dirty
			self.last_write = self.config._scheduler.now()
			self.is_locked = true
		end)
		return nil
	end)
end

function profile.unload(self: Profile)
	if not self.open then
		return
	end
	-- last chance to update while the profile is still open
	fire_hooks(self, self._hooks.closing)
	if not self.open then
		return
	end

	self.open = false
	self._mutex:lock()
	self._mutex:close(errors.profile_closed(self, "unloaded"))
	local ok, err = utils.try(function()
		-- an already released profile has nothing on the record to give back;
		-- a lost lock (false) has nothing to give back either
		if self.is_locked then
			write_data_record(self, { release = true })
		end
	end)
	self._mutex:unlock()
	if not ok then
		self.config._hook.warn(`datastore: failed to release "{self.key}" (lock will expire): {tostring(err)}`)
	end
	fire_hooks(self, self._hooks.closed)
end

--- Yields until no operation holds or waits on the profile mutex. Once this
--- returns, the next update call is guaranteed not to yield (nothing is queued
--- ahead of it).
function profile.wait_settled(self: Profile)
	return self._mutex:wait_settled()
end

function profile.wait_closed(self: Profile)
	if self.open then
		error(`profile: {self.key} has not been closed`)
	end

	return self._mutex:wait_settled()
end

function is_profile(unknown: any)
	if type(unknown) ~= "table" then
		return false
	end
	return getmetatable(unknown) == profile
end

-- internal methods, used by transactions
profile._set_data = set_data
profile._write_record = write_data_record

return {
	load = profile.load,
	is = is_profile,
}
