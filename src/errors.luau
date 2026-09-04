--!strict

local types = require "./types"

--[[
	Error tables. Every runtime failure the library reports is one of these:
	a plain table with a `type`, a `message` and typed extra data, sharing one
	metatable so `tostring(err)` yields the message and `errors.is` can tell
	them apart from raw (string) errors thrown by user callbacks.
]]

type Array<T> = { T }
type Lock = types.Lock

local error_mt = {
	__tostring = function(self: any): string
		return self.message
	end,
}

local function make<T>(fields: T): T
	return setmetatable(fields :: any, error_mt) :: any
end

local errors = {}

function errors.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == error_mt
end

function errors.roblox(op: "get_async" | "update_async", store: string, key: string, cause: any): types.RobloxError
	return make {
		type = "roblox" :: "roblox",
		message = `datastore: {op} on "{store}/{key}" failed after retries: {tostring(cause)}`,
		op = op,
		store = store,
		key = key,
		cause = cause,
	}
end

function errors.timeout(key: string, lock: Lock?): types.TimeoutError
	return make {
		type = "timeout" :: "timeout",
		message = `datastore: timed out loading "{key}" (session locked by another server)`,
		key = key,
		lock = lock,
	}
end

function errors.lock_lost(profile: any, lock: Lock?): types.LockLostError
	return make {
		type = "lock_lost" :: "lock_lost",
		message = `datastore: profile "{profile.key}" lost its session lock`,
		profile = profile,
		lock = lock,
	}
end

function errors.not_locked(profile: any): types.NotLockedError
	return make {
		type = "not_locked" :: "not_locked",
		message = `datastore: profile "{profile.key}" does not hold its session lock`,
		profile = profile,
	}
end

function errors.profile_locked(profile: any, lock: Lock): types.ProfileLockedError
	return make {
		type = "profile_locked" :: "profile_locked",
		message = `datastore: "{profile.key}" is session locked`,
		profile = profile,
		lock = lock,
	}
end

function errors.tx_lock_lost(profile: any, expected: Lock, lock: Lock?): types.TxLockLostError
	return make {
		type = "tx_lock_lost" :: "tx_lock_lost",
		message = `datastore: transaction lock on "{profile.key}" was lost`,
		profile = profile,
		expected = expected,
		lock = lock,
	}
end

function errors.outdated(
	profile: any,
	record_migrations: Array<string>,
	declared_migrations: Array<string>
): types.OutdatedError
	return make {
		type = "outdated" :: "outdated",
		message = `datastore: "{profile.key}" was written by a newer server (record has {#record_migrations} applied migrations, this server declares {#declared_migrations})`,
		profile = profile,
		record_migrations = record_migrations,
		declared_migrations = declared_migrations,
	}
end

function errors.not_fetched(profile: any): types.NotFetchedError
	return make {
		type = "not_fetched" :: "not_fetched",
		message = `datastore: lockless profile "{profile.key}" has not been fetched`,
		profile = profile,
	}
end

function errors.profile_closed(profile: any, reason: "unloaded" | "lock_lost"): types.ProfileClosedError
	local message = if reason == "lock_lost"
		then `datastore: profile "{profile.key}" is closed (lock lost)`
		else `datastore: profile "{profile.key}" is closed`
	return make {
		type = "profile_closed" :: "profile_closed",
		message = message,
		profile = profile,
		reason = reason,
	}
end

--- The error a closed profile rejects calls with: the one its mutex was closed
--- with (carries the right reason), or a plain "unloaded" while `unload` is
--- still waiting for the mutex.
function errors.closed(profile: any): types.ProfileClosedError
	local closed = profile._mutex._closed
	if closed ~= nil then
		return closed
	end
	return errors.profile_closed(profile, "unloaded")
end

export type MigrationMismatchDetails = {
	index: number?,
	expected: string?,
	actual: string?,
	applied: Array<string>,
	declared: Array<string>,
}

function errors.migration_mismatch(key: string, details: MigrationMismatchDetails): types.MigrationMismatchError
	local reason = if details.index ~= nil
		then `migration mismatch at index {details.index}: record has "{details.actual}", declared is "{details.expected}"`
		else `record has {#details.applied} applied migrations but only {#details.declared} are declared`
	return make {
		type = "migration_mismatch" :: "migration_mismatch",
		message = `datastore: failed to apply migrations for "{key}": {reason}`,
		key = key,
		index = details.index,
		expected = details.expected,
		actual = details.actual,
		applied = details.applied,
		declared = details.declared,
	}
end

function errors.tx_aborted(id: string, cause: types.Error?): types.TxAbortedError
	local reason = if cause then (cause :: any).message else "marker resolved as aborted by another server"
	return make {
		type = "tx_aborted" :: "tx_aborted",
		message = `datastore: transaction {id} aborted: {reason}`,
		id = id,
		cause = cause,
	}
end

function errors.tx_marker_invalid(id: string, value: any): types.TxMarkerInvalidError
	return make {
		type = "tx_marker_invalid" :: "tx_marker_invalid",
		message = `datastore: unexpected tx marker value for {id}: {tostring(value)}`,
		id = id,
		value = value,
	}
end

function errors.store_closed(store: any): types.StoreClosedError
	return make {
		type = "store_closed" :: "store_closed",
		message = `datastore: store "{store.config.name}" is closed`,
		store = store,
	}
end

function errors.already_loaded(store: any, key: string): types.AlreadyLoadedError
	return make {
		type = "already_loaded" :: "already_loaded",
		message = `datastore: "{key}" is already loaded in this store`,
		store = store,
		key = key,
	}
end

return errors
