--!strict

local LocklessProfile = require "./lockless"
local Profile = require "./profile"
local retry = require "./retry"
local runtime = require "./runtime"
local types = require "./types"
local util = require "./util"

export type Profile<T = any> = Profile.Profile<T>
export type LocklessProfile<T = any> = LocklessProfile.LocklessProfile<T>
export type AnyProfile<T = any> = Profile<T> | LocklessProfile<T>

export type Config<T = any> = {
	name: string,
	template: T,
	hook: types.Hook,
	migrations: { types.Migration<T> }?,
	on_changed: ((profile: AnyProfile<T>, new: T, old: T?) -> ())?,
	--- locked profile: the session lock was stolen (profile closes).
	--- lockless profile: a fetch/apply hit another server's live session lock (profile stays open).
	on_lock_lost: ((profile: AnyProfile<T>) -> ())?,
	autosave_interval: number?, -- seconds, default 30 (locked profiles)
	flush_interval: number?, -- seconds, default autosave_interval (lockless profiles)
	lock_ttl: number?, -- seconds, default 60
	--- seconds, default 10. How long a transaction may hold a lockless key
	--- between flushing it and writing `pending`; a crashed coordinator frees
	--- the key after this.
	tx_lock_ttl: number?,
	load_timeout: number?, -- seconds, default lock_ttl + 10
	load_poll: number?, -- seconds, default 1
	retry_attempts: number?, -- default 5
	retry_base: number?, -- seconds, default 1
}

type ResolvedConfig<T = any> = {
	name: string,
	template: T,
	hook: types.Hook,
	migrations: { types.Migration<T> },
	on_changed: ((profile: AnyProfile<T>, new: T, old: T?) -> ())?,
	on_lock_lost: ((profile: AnyProfile<T>) -> ())?,
	autosave_interval: number,
	flush_interval: number,
	lock_ttl: number,
	tx_lock_ttl: number,
	load_timeout: number,
	load_poll: number,
	retry_attempts: number,
	retry_base: number,
}

export type Store<T = any> = {
	config: ResolvedConfig<T>,
	server_id: string,
	data_store: types.StoreHandle,
	tx_store: types.StoreHandle,
	profiles: { [string]: AnyProfile<T> },
	closed: boolean,

	load: (self: Store<T>, key: string, user_ids: { number }?) -> Profile<T>,
	load_lockless: (self: Store<T>, key: string, user_ids: { number }?) -> LocklessProfile<T>,
	get_loaded: (self: Store<T>, key: string) -> AnyProfile<T>?,
	close: (self: Store<T>) -> (),
	call: (self: Store<T>, fn: () -> any) -> any,
	_unregister: (self: Store<T>, profile: AnyProfile<T>) -> (),
}

type Impl = Store & {
	_loading: { [string]: boolean },
}

local Store = {}
Store.__index = Store

function Store.new<T>(config: Config<T>): Store<T>
	assert(type(config) == "table", "datastore: config must be a table")
	assert(type(config.name) == "string" and #config.name > 0, "datastore: config.name is required")
	assert(config.template ~= nil, "datastore: config.template is required")
	assert(type(config.hook) == "table", "datastore: config.hook is required")

	local lock_ttl = config.lock_ttl or 60
	local autosave_interval = config.autosave_interval or 30
	local resolved: ResolvedConfig<T> = {
		name = config.name,
		template = config.template,
		hook = config.hook,
		migrations = config.migrations or {},
		on_changed = config.on_changed,
		on_lock_lost = config.on_lock_lost,
		autosave_interval = autosave_interval,
		flush_interval = config.flush_interval or autosave_interval,
		lock_ttl = lock_ttl,
		tx_lock_ttl = config.tx_lock_ttl or 10,
		load_timeout = config.load_timeout or (lock_ttl + 10),
		load_poll = config.load_poll or 1,
		retry_attempts = config.retry_attempts or 5,
		retry_base = config.retry_base or 1,
	}

	local self: Impl = setmetatable({
		config = resolved,
		server_id = util.uid(),
		data_store = config.hook.get_store(config.name),
		tx_store = config.hook.get_store(config.name .. "/tx"),
		profiles = {},
		closed = false,
		_loading = {},
	}, Store) :: any
	return self
end

--- Runs a storage call with the configured retry policy.
function Store.call(self: Impl, fn: () -> any): any
	return retry(self.config.retry_attempts, self.config.retry_base, fn)
end

local function begin_load(self: Impl, key: string)
	if self.closed then
		error "datastore: store is closed"
	end
	if self.profiles[key] ~= nil or self._loading[key] then
		error(`datastore: "{key}" is already loaded in this store`)
	end
	self._loading[key] = true
end

--- Loads `key` under a session lock. Yields until the lock is acquired.
function Store.load<T>(self: Impl, key: string, user_ids: { number }?): Profile<T>
	begin_load(self, key)
	local ok, result = pcall(Profile.load, self, key, user_ids)
	self._loading[key] = nil
	if not ok then
		error(result, 0)
	end
	local profile = result :: Profile<T>
	self.profiles[key] = profile
	return profile
end

--- Creates a lockless handle for `key`. Makes no storage call; use `fetch()` or
--- `apply()` to populate it.
function Store.load_lockless<T>(self: Impl, key: string, user_ids: { number }?): LocklessProfile<T>
	begin_load(self, key)
	local profile = LocklessProfile.new(self, key, user_ids)
	self._loading[key] = nil
	self.profiles[key] = profile
	return profile :: any
end

function Store.get_loaded<T>(self: Impl, key: string): AnyProfile<T>?
	return self.profiles[key]
end

function Store._unregister(self: Impl, profile: AnyProfile)
	if self.profiles[profile.key] == profile then
		self.profiles[profile.key] = nil
	end
end

function Store.close(self: Impl)
	if self.closed then
		return
	end
	self.closed = true
	local remaining = 0
	for _, profile in self.profiles do
		remaining += 1
		runtime.spawn(function()
			local ok, err = util.try(profile.unload, profile)
			if not ok then
				runtime.warn(`datastore: unload failed for "{profile.key}": {tostring(err)}`)
			end
			remaining -= 1
		end)
	end
	while remaining > 0 do
		runtime.wait(0.1)
	end
end

return Store
