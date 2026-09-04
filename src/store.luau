--! strict

local errors = require "./errors"
local result = require "./result"
local types = require "./types"
local utils = require "./utils"
local roblox_scheduler = require "./schedulers/roblox"
local roblox_hook = require "./hooks/roblox"
local profile = require "./profile/profile"
local lockless_profile = require "./profile/lockless"
local peek_profile = require "./profile/peek"
local tx = require "./tx/handle"

type Array<T> = { T }

type Config<T> = types.Config<T>
type ResolvedConfig<T> = types.ResolvedConfig<T>
type Scheduler = types.Scheduler

type ProfileBase<T = any> = types.ProfileBase<T>
type Profile<T = any> = types.Profile<T>
type LocklessProfile<T = any> = types.LocklessProfile<T>
type PeekProfile<T = any> = types.PeekProfile<T>
type HooksList<T... = ()> = types.HooksList<T...>
type Result<T> = types.Result<T>

export type Store<T = any> = {
	_loading: { [string]: boolean },
	_loading_locks: { [string]: { thread } },

	_hook: types.Hook,
	_scheduler: types.Scheduler,

	_datastore: types.DatastoreHandle,
	closed: boolean,

	profiles: { [string]: Profile<T> },
	lockless_profiles: { [string]: LocklessProfile<T> },

	_hooks: {
		change: HooksList<ProfileBase<T>, T, T?>,
		save: HooksList<ProfileBase<T>>,
		closing: HooksList<ProfileBase<T>>,
		closed: HooksList<ProfileBase<T>>,
		lock_lost: HooksList<ProfileBase<T>>,
	},

	config: ResolvedConfig<T>,
	--- Takes the session lock for `key` and loads it. Yields. Fails with
	--- `store_closed`, `already_loaded`, `timeout`, `roblox`,
	--- `migration_mismatch` or `tx_marker_invalid`.
	load: (self: Store<T>, key: string, user_ids: { number }) -> Result<Profile<T>>,
	--- Returns the profile for `key`, waiting for it to load or loading it if
	--- nobody has yet. Waiters get the same Result as the load.
	wait_loaded: (self: Store<T>, key: string, user_ids: { number }) -> Result<Profile<T>>,
	get_loaded: (self: Store<T>, key: string) -> Profile<T>?,

	--- Returns the lockless profile for `key`, creating it if needed. Never
	--- yields: a lockless profile does no storage work until `fetch`. Throws a
	--- `store_closed` error on a closed store.
	get_lockless: (self: Store<T>, key: string, user_ids: { number }) -> LocklessProfile<T>,

	--- Read-only snapshot of `key` via `GetAsync`: the current data and lock.
	--- Yields. The result is not tracked by the store, takes no lock and cannot
	--- join a transaction. Fails with `store_closed`, `roblox` or
	--- `migration_mismatch`.
	peek: (self: Store<T>, key: string) -> Result<PeekProfile<T>>,

	--- Atomically updates profiles of this store (locked or lockless). `transform`
	--- gets their data in order and returns the new data in the same order, or
	--- false to cancel. Ok(false) when cancelled, Ok(true) when committed; fails
	--- like `dataforge.transaction`. `config` fills in what the store does not
	--- know (ttls, retry); hook and scheduler default to the store's.
	transaction: (
		self: Store<T>,
		profiles: Array<ProfileBase<T>>,
		transform: (data: Array<T>) -> Array<T> | false,
		config: types.TransactionConfig?
	) -> Result<boolean>,

	on_change: (self: Store<T>, callback: (profile: Profile<T>, new: T, old: T?) -> ()) -> (),
	on_save: (self: Store<T>, callback: (profile: Profile<T>) -> ()) -> (),
	on_closing: (self: Store<T>, callback: (profile: Profile<T>) -> ()) -> (),
	on_closed: (self: Store<T>, callback: (profile: Profile<T>) -> ()) -> (),
	on_lock_lost: (self: Store<T>, callback: (profile: Profile<T>) -> ()) -> (),

	close: (self: Store<T>) -> (),
}

--- Resumes every `wait_loaded` caller with the load's Result, or with a raw
--- error (`res == nil`) they rethrow.
local function resume_load_locks(self: Store, key: string, res: Result<Profile>?, raw: any?)
	local loading_locks = self._loading_locks[key]
	if not loading_locks then
		return
	end
	self._loading_locks[key] = nil

	for _, thread in loading_locks do
		self.config._scheduler.spawn(thread, res, raw)
	end
end

local function insert_loaded_lock(self: Store, key: string)
	local thread = coroutine.running()

	local waiters = self._loading_locks[key]
	if waiters == nil then
		waiters = {}
		self._loading_locks[key] = waiters
	end
	table.insert(waiters, thread)
end

local function unregister_profile(self: Store, profile: Profile)
	local key = profile.key
	if self.profiles[key] == profile then
		self.profiles[key] = nil
	end
end

local function fire_hooks<T...>(self: Store, hooks: HooksList<T...>, ...: T...)
	for _, hook in hooks.hooks do
		local ok, err = utils.try(hook, ...)
		if not ok then
			self._hook.warn(`datastore: store hook {hooks.type} failed: {tostring(err)}`)
		end
	end
end

--- Subscribes to every hook of `profile` and re-fires the matching store hook
--- with the profile as first argument, followed by the profile hook's arguments.
local function forward_hooks(self: Store, profile: ProfileBase<any>)
	local hooks = self._hooks

	profile:on_change(function(new, old)
		fire_hooks(self, hooks.change, profile, new, old)
	end)
	profile:on_save(function()
		fire_hooks(self, hooks.save, profile)
	end)
	profile:on_closing(function()
		fire_hooks(self, hooks.closing, profile)
	end)
	profile:on_closed(function()
		fire_hooks(self, hooks.closed, profile)
	end)
	profile:on_lock_lost(function()
		fire_hooks(self, hooks.lock_lost, profile)
	end)
end

local store = {}
store.__index = store

function store.create<T>(config: Config<T>): Store<T>
	assert(type(config) == "table", "datastore: config must be a table")
	assert(type(config.name) == "string" and #config.name > 0, "datastore: config.name is required")
	assert(config.template ~= nil, "datastore: config.template is required")

	local lock_ttl = config.lock_ttl or 60
	local hook = config._hook
	local scheduler = config._scheduler

	if not hook and game then
		hook = roblox_hook.create()
	end
	if not scheduler and game and task then
		scheduler = roblox_scheduler.create()
	end

	assert(hook, "for non roblox environments, you need to provide a datastore hook")
	assert(scheduler, "for non roblox environments, you need to provide a task scheduler")

	local resolved: ResolvedConfig<T> = {
		name = config.name,
		template = config.template,

		_hook = hook,
		_scheduler = scheduler,

		migrations = config.migrations or {},

		autosave_interval = config.autosave_interval or 30,
		flush_interval = config.flush_interval or config.autosave_interval or 30,
		lock_ttl = lock_ttl,
		load_timeout = config.load_timeout or (lock_ttl + 10),
		load_poll = config.load_poll or 1,
		retry_attempts = config.retry_attempts or 5,
		retry_base = config.retry_base or 1,
	}

	local self = {} :: Store<T>
	self.config = resolved
	self._hook = resolved._hook
	self._scheduler = resolved._scheduler
	self._datastore = resolved._hook.get_datastore(resolved.name)

	self.profiles = {}
	self.lockless_profiles = {}
	self.closed = false

	self._loading = {}
	self._loading_locks = {}

	self._hooks = {
		change = { type = "change", hooks = {} },
		save = { type = "save", hooks = {} },
		closing = { type = "closing", hooks = {} },
		closed = { type = "closed", hooks = {} },
		lock_lost = { type = "lock_lost", hooks = {} },
	}

	return setmetatable(self, store) :: any
end

function store.load(self: Store, key: string, user_ids: { number }): Result<Profile>
	if self.closed then
		return result.err(errors.store_closed(self))
	end
	if self.profiles[key] ~= nil or self._loading[key] then
		return result.err(errors.already_loaded(self, key))
	end
	self._loading[key] = true

	local ok, loaded = utils.try(profile.load, {
		key = key,
		config = self.config,
		user_ids = user_ids,
		_datastore = self._datastore,
	})
	self._loading[key] = nil

	if not ok then
		if errors.is(loaded) then
			local failure = result.err(loaded)
			resume_load_locks(self, key, failure)
			return failure
		end
		-- a migration threw: everyone waiting gets the raw error too
		resume_load_locks(self, key, nil, loaded)
		error(loaded, 0)
	end

	loaded:on_closed(function()
		unregister_profile(self, loaded)
	end)
	forward_hooks(self, loaded)

	self.profiles[key] = loaded
	local success = result.ok(loaded)
	resume_load_locks(self, key, success)
	return success
end

--- Returns the profile for `key`, waiting for it to load or loading it if
--- nobody has yet. Waiters get the same Result (or raw error) as the load.
function store.wait_loaded(self: Store, key: string, user_ids: { number }): Result<Profile>
	if self.closed then
		return result.err(errors.store_closed(self))
	end

	local existing = self.profiles[key]
	if existing ~= nil then
		return result.ok(existing)
	end

	if not self._loading[key] then
		return self:load(key, user_ids)
	end
	insert_loaded_lock(self, key)

	local res, raw = coroutine.yield()
	if res == nil then
		error(raw, 0)
	end
	return res
end

function store.get_loaded(self: Store, key: string): Profile?
	return self.profiles[key]
end

function store.get_lockless(self: Store, key: string, user_ids: { number }): LocklessProfile
	if self.closed then
		error(errors.store_closed(self), 0)
	end

	local existing = self.lockless_profiles[key]
	if existing ~= nil then
		return existing
	end

	local profile = lockless_profile.create {
		key = key,
		config = self.config,
		user_ids = user_ids,
		_datastore = self._datastore,
	}

	profile:on_closed(function()
		if self.lockless_profiles[key] == profile then
			self.lockless_profiles[key] = nil
		end
	end)
	forward_hooks(self, profile)

	self.lockless_profiles[key] = profile
	return profile
end

--- One `get_async` on `key`, no write. Never registered in the store: `close`
--- does not know about it and hooks do not fire for it.
function store.peek(self: Store, key: string): Result<PeekProfile>
	if self.closed then
		return result.err(errors.store_closed(self))
	end

	return peek_profile.create {
		key = key,
		_config = self.config,
		_datastore = self._datastore,
	}
end

function store.on_change(self: Store, callback: (profile: ProfileBase, new: any, old: any?) -> ())
	table.insert(self._hooks.change.hooks, callback)
end

function store.on_save(self: Store, callback: (profile: ProfileBase) -> ())
	table.insert(self._hooks.save.hooks, callback)
end

function store.transaction(
	self: Store,
	profiles: Array<ProfileBase>,
	transform: (data: Array<any>) -> Array<any> | false,
	config: types.TransactionConfig?
): Result<boolean>
	if self.closed then
		return result.err(errors.store_closed(self))
	end

	local resolved = tx.resolve_config(config, {
		_hook = self._hook,
		_scheduler = self._scheduler,
		retry_attempts = self.config.retry_attempts,
		retry_base = self.config.retry_base,
	})

	return tx.run(resolved, profiles, function(ctx)
		local datas = table.create(#profiles)
		for index, participant in profiles do
			datas[index] = ctx:get(participant)
		end

		local transformed = transform(datas)
		if transformed == false then
			return false
		end
		local new_datas = transformed :: Array<any>

		for index, participant in profiles do
			local new = new_datas[index]
			if new == nil then
				error(`datastore: transaction transform returned no data for "{participant.key}" (index {index})`)
			end
			ctx:set(participant, new)
		end
		return true
	end)
end

--- Unloads every profile (locked and lockless) concurrently and waits for all
--- of them. Loads and transactions are rejected from the first line on.
function store.close(self: Store)
	if self.closed then
		return
	end
	self.closed = true

	local scheduler = self._scheduler
	local thread = coroutine.running()
	local remaining = 0
	local waiting = false

	local function unload(profile: ProfileBase)
		remaining += 1
		scheduler.spawn(function()
			local ok, err = utils.try(profile.unload, profile)
			if not ok then
				self._hook.warn(`datastore: unload failed for "{profile.key}": {tostring(err)}`)
			end
			remaining -= 1
			if remaining == 0 and waiting then
				scheduler.spawn(thread)
			end
		end)
	end

	for _, profile in self.profiles do
		unload(profile)
	end
	for _, profile in self.lockless_profiles do
		unload(profile)
	end

	if remaining > 0 then
		waiting = true
		coroutine.yield()
	end
end

function store.on_closing(self: Store, callback: (profile: ProfileBase) -> ())
	table.insert(self._hooks.closing.hooks, callback)
end

function store.on_closed(self: Store, callback: (profile: ProfileBase) -> ())
	table.insert(self._hooks.closed.hooks, callback)
end

function store.on_lock_lost(self: Store, callback: (profile: ProfileBase) -> ())
	table.insert(self._hooks.lock_lost.hooks, callback)
end

return {
	create = store.create,
}
