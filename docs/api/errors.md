# Errors

Every library call that can fail at runtime returns a `Result` instead of throwing. Programmer errors (a missing config field, a transaction over something that is not a profile, `ctx:set(profile, nil)`) still throw, and so does anything your own callbacks throw.

## Result

```luau
type Result<T> = Ok<T> | Err

type Ok<T> = { success: true, value: T, unwrap: (self) -> T }
type Err = { success: false, error: Error, unwrap: (self) -> never }
```

```luau
local result = store:load(key, { player.UserId })
if not result.success then
	warn(`could not load {key}: {result.error.message}`)
	if result.error.type == "timeout" then
		print("held by", result.error.lock and result.error.lock.id)
	end
	return
end
local profile = result.value
```

`unwrap()` returns the value, or throws the error table itself when the result failed: `pcall` callers still get `err.type` and the extra data, and `tostring(err)` (and an uncaught error) prints `message`.

```luau
local profile = store:load(key, { player.UserId }):unwrap()
```

## Error

```luau
type Error = {
	type: string,    -- one of the types below
	message: string, -- human readable; `tostring(err)` returns it
	...              -- extra data, per type
}
```

Narrow on `type`. The `profile` and `store` fields hold the object the error is about.

| `type` | Extra data | Meaning |
| --- | --- | --- |
| `roblox` | `op: "get_async" \| "update_async"`, `store: string`, `key: string`, `cause: any` | Storage kept failing after `retry_attempts`; `cause` is the last error the hook threw. |
| `timeout` | `key: string`, `lock: Lock?` | `load` / `readquire` gave up after `load_timeout`. `lock` is the last lock seen on the record (its holder). |
| `lock_lost` | `profile`, `lock: Lock?` | A write found the session lock is not ours: the profile is closed and nothing was written. `lock` is what the record holds now (`nil` when it was wiped). |
| `released` | `profile` | The profile was `release`d and not `readquire`d. |
| `lockless_locked` | `profile`, `lock: Lock` | Lockless: another server holds a live session lock on the key. The profile is closed. |
| `tx_lock_lost` | `profile`, `expected: Lock`, `lock: Lock?` | Lockless, inside a transaction: the transaction lock this profile held (`expected`) is gone or replaced (`lock`). The profile is closed. |
| `outdated` | `key: string`, `profile?`, `record_migrations: { string }`, `declared_migrations: { string }` | The record was written by a newer server (it lists more migrations than this store declares). Nothing is written and no lock is taken; a lockless queue is kept. `profile` is the profile the call ran on, `nil` for `store:load` and `store:peek`. |
| `not_fetched` | `profile` | Lockless `get_data` before any `fetch` / flush. Thrown, never returned. |
| `profile_closed` | `profile`, `reason: "unloaded" \| "lock_lost"` | The profile is closed (or closed while the call waited for it). |
| `migration_mismatch` | `key: string`, `index: number`, `expected: string`, `actual: string`, `applied: { string }`, `declared: { string }` | A name in the record's applied migrations differs from the declared one at `index` (`actual` vs `expected`). A record with *more* migrations than declared is `outdated` instead. |
| `tx_aborted` | `id: string`, `cause: Error?` | The transaction aborted. `cause` is the error of the participant that failed phase 1 (`roblox`, `lock_lost`, `tx_lock_lost`, ...); `nil` when the marker was already resolved as aborted by another server. |
| `tx_marker_invalid` | `id: string`, `value: any` | The marker datastore holds something other than `"committed"` / `"aborted"`. |
| `store_closed` | `store` | `store:close()` ran. |
| `already_loaded` | `store`, `key: string` | A locked profile for `key` is open (or loading) on this store. |

## Who returns what

| Call | Returns | Errors |
| --- | --- | --- |
| `store:load`, `store:wait_loaded` | `Result<Profile>` | `store_closed`, `already_loaded`, `timeout`, `roblox`, `outdated`, `migration_mismatch`, `tx_marker_invalid` |
| `store:peek`, `peek:refresh` | `Result<PeekProfile>` / `Result<T>` | `store_closed`, `roblox`, `outdated`, `migration_mismatch` |
| `store:transaction`, `dataforge.transaction` | `Result<boolean>` | `store_closed`, `profile_closed`, `released`, `tx_aborted`, and whatever flushing a lockless participant raised (`lockless_locked`, `outdated`, `roblox`, `migration_mismatch`) |
| `profile:update` | `Result<boolean>` | `profile_closed`, `released` |
| `profile:save` | `Result<nil>` | `profile_closed`, `released`, `roblox`, `lock_lost` |
| `profile:release` | `Result<nil>` | `profile_closed`, `roblox`, `lock_lost` |
| `profile:readquire` | `Result<nil>` | `profile_closed`, `timeout`, `roblox`, `outdated`, `migration_mismatch`, `tx_marker_invalid` |
| `lockless:fetch` | `Result<T>` | `profile_closed`, `lockless_locked`, `roblox`, `outdated`, `migration_mismatch`, `tx_marker_invalid` |
| `lockless:update` | `Result<boolean>` | `profile_closed` |
| `lockless:save` | `Result<nil>` | `profile_closed`, `lockless_locked`, `outdated`, `roblox`, `migration_mismatch` |

Thrown as error tables instead of returned (plain accessors): `profile:get_data()` (`profile_closed`, `not_fetched`) and `store:get_lockless` (`store_closed`).

## What still throws

- **Your callbacks.** An `update` dispatcher, a transaction `process` / `transform` or a migration `apply` that throws propagates as is (the profiles are released first). The library never wraps them.
- **Misuse.** Invalid config, a transaction over non-profiles / duplicates / profiles from different hooks / no profiles, `ctx:set(profile, nil)`, a `store:transaction` transform that returns no data for a participant, `wait_closed` on an open profile.
- **`unload` and `store:close`** never fail: a failed final write is reported through the hook's `warn`.
