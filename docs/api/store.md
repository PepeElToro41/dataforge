# Store

Returned by [`dataforge.create_store`](./dataforge#dataforge-create-store-config). One store wraps one named datastore and hands out profiles for its keys.

## Config

```luau
type Config<T> = {
	name: string,
	template: T,

	migrations: { Migration }?,

	autosave_interval: number?,
	flush_interval: number?,
	lock_ttl: number?,
	load_timeout: number?,
	load_poll: number?,
	retry_attempts: number?,
	retry_base: number?,
}
```

| Field | Default | Description |
| --- | --- | --- |
| `name` | required | Datastore name. |
| `template` | required | Data a brand new key starts with. |
| `migrations` | `{}` | Ordered list of `{ name, apply }`. See [Migrations](../guide/migrations). |
| `autosave_interval` | `30` | Seconds between autosaves of locked profiles. |
| `flush_interval` | `autosave_interval` | Seconds between flushes of lockless profiles. |
| `lock_ttl` | `60` | Seconds a session lock stays valid without refresh. |
| `load_timeout` | `lock_ttl + 10` | Seconds `load` waits for a locked key before failing with `timeout`. |
| `load_poll` | `1` | Seconds between lock polls while waiting in `load`. |
| `retry_attempts` | `5` | Storage retries per operation. |
| `retry_base` | `1` | Seconds; exponential backoff base between retries. |

## Fields

| Field | Type | Description |
| --- | --- | --- |
| `config` | `ResolvedConfig<T>` | Config with every default filled in. |
| `datastore` | `DatastoreHandle` | Storage handle for `config.name`. |
| `closed` | `boolean` | `true` after `close()`. |
| `profiles` | `{ [string]: Profile<T> }` | Open locked profiles by key. |
| `lockless_profiles` | `{ [string]: LocklessProfile<T> }` | Open lockless profiles by key. |

## Methods

### `store:load(key, user_ids)`

```luau
(self: Store<T>, key: string, user_ids: { number }) -> Result<Profile<T>>
```

Takes the session lock on `key`, resolves any dangling transaction, runs migrations and returns the [Profile](./profile). Yields. Fails with `timeout` (`load_timeout`, carrying the holder's lock), `roblox`, `outdated` (the record was written by a newer server; no lock is taken), `migration_mismatch`, `tx_marker_invalid`, `already_loaded` or `store_closed`; see [Errors](./errors). `user_ids` is forwarded to the datastore for GDPR tracking.

### `store:wait_loaded(key, user_ids)`

```luau
(self: Store<T>, key: string, user_ids: { number }) -> Result<Profile<T>>
```

Returns the open profile for `key`; if a `load` is in flight, waits for it and returns the same result. Otherwise loads it.

### `store:get_loaded(key)`

```luau
(self: Store<T>, key: string) -> Profile<T>?
```

The open locked profile for `key`, or `nil`. Never yields.

### `store:get_lockless(key, user_ids)`

```luau
(self: Store<T>, key: string, user_ids: { number }) -> LocklessProfile<T>
```

Returns the [LocklessProfile](./lockless-profile) for `key`, creating it if needed. Never yields: a lockless profile does no storage work until `fetch` or its first flush. Throws a `store_closed` error table on a closed store.

### `store:peek(key)`

```luau
(self: Store<T>, key: string) -> Result<PeekProfile<T>>
```

Reads `key` once with `GetAsync` and returns a [PeekProfile](./peek-profile): the stored data (template if missing, migrations applied in memory) and the lock currently on the record, if any. Yields. Takes no lock, writes nothing, and the result is not tracked by the store nor accepted by transactions. Works while another server holds the key. Fails with `roblox`, `outdated`, `migration_mismatch` or `store_closed`.

### `store:transaction(profiles, transform, config?)`

```luau
(
	self: Store<T>,
	profiles: { ProfileBase<T> },
	transform: (data: { T }) -> { T } | false,
	config: TransactionConfig?
) -> Result<boolean>
```

Positional variant of [`dataforge.transaction`](./dataforge#dataforge-transaction-profiles-process-config) for profiles of this store. `transform` receives their data in order and returns the new data in the same order, or `false` to cancel. `Ok(false)` when cancelled, `Ok(true)` when committed; fails like `dataforge.transaction`, plus `store_closed`. A transform that returns no data for a participant throws (misuse).

### `store:close()`

```luau
(self: Store<T>) -> ()
```

Unloads every open profile (locked and lockless) and marks the store closed. Meant for `game:BindToClose`. Later `load` / `peek` / `transaction` calls fail with `store_closed`; `get_lockless` throws it.

## Events

Each fires for every profile of the store, with the profile as first argument.

```luau
store:on_change(function(profile, new, old) end)
store:on_save(function(profile) end)
store:on_closing(function(profile) end)
store:on_closed(function(profile) end)
store:on_lock_lost(function(profile) end)
```

See [Profile events](./profile#events) for when each one fires.
