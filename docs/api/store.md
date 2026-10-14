# Store

Returned by [`dataforge.create_store`](./dataforge#dataforge-create-store-config). One store wraps one named datastore and hands out profiles for its keys.

## Config

```luau
type Config<T> = {
	name: string,
	template: T,

	migrations: { Migration }?,
	predicate: Predicate<T>?,

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
| `predicate` | none | Gate on a key's stored data; a rejected key fails with `predicate_failed`. See [Predicate](#predicate). |
| `autosave_interval` | `30` | Seconds between autosaves of locked profiles. |
| `flush_interval` | `autosave_interval` | Seconds between flushes of lockless profiles. |
| `lock_ttl` | `60` | Seconds a session lock stays valid without refresh. |
| `load_timeout` | `lock_ttl + 10` | Seconds `load` waits for a locked key before failing with `timeout`. |
| `load_poll` | `1` | Seconds between lock polls while waiting in `load`. |
| `retry_attempts` | `5` | Storage retries per operation. |
| `retry_base` | `1` | Seconds; exponential backoff base between retries. |

### Predicate

```luau
type Predicate<T> = (data: T?, key: string) -> boolean
```

Decides whether this server may work with a key at all. Every call that reads or writes a key runs it against the **raw stored data** first and fails with `predicate_failed` when it returns `false`:

| Call | When it runs | On rejection |
| --- | --- | --- |
| `store:load`, `profile:readquire` | Inside the lock's `update_async` transform, before the lock is taken | No lock is taken, nothing is written, no profile is registered. The call does not wait for another server's lock either. |
| `profile:save` / `release` / autosave / `unload`'s final write | Inside the write's `update_async` transform | Nothing is written. The profile keeps its session lock and stays open, so a later save can go through again (a rejected write during `unload` is reported with `warn` and the lock is left to expire). |
| `lockless:fetch` | After the `get_async` | Nothing is adopted; the profile stays open and keeps its queue. |
| `lockless:save` / flush / `unload` | Inside the flush's `update_async` transform | Nothing is written, the queue is kept. |
| `store:peek`, `peek:refresh` | After the `get_async` | No snapshot is returned; a refresh keeps the previous one. |

```luau
local store = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0 },

	-- never touch a key some other system has flagged
	predicate = function(data, key)
		return data == nil or not data.frozen
	end,
}

local result = store:load(key, { player.UserId })
if not result.success and result.error.type == "predicate_failed" then
	print(`{result.error.key} rejected on {result.error.op}`, result.error.data)
end
```

`data` is the record's data exactly as it is in storage: `nil` when the key does not exist yet (a fresh key is **not** the template at this point) and with the store's migrations *not* applied yet. A write is gated on what is stored, not on the data about to be written.

The predicate runs inside the `update_async` transform, so it must be **pure**: no yielding, no storage calls, no mutation of `data`. It may run more than once per call when storage retries the transform. An error thrown inside it is not treated as a storage failure: the write is cancelled and the error propagates as is (thrown, not returned as a `Result`).

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

Takes the session lock on `key`, resolves any dangling transaction, runs migrations and returns the [Profile](./profile). Yields. Fails with `timeout` (`load_timeout`, carrying the holder's lock), `roblox`, `outdated` (the record was written by a newer server; no lock is taken), `predicate_failed` ([`config.predicate`](#predicate) rejected the stored data; no lock is taken), `migration_mismatch`, `tx_marker_invalid`, `already_loaded` (a profile for `key` is still open on this store) or `store_closed`; see [Errors](./errors). `user_ids` is forwarded to the datastore for GDPR tracking.

A profile that is closing is not "already loaded": `unload` drops it from the store before its final write, so this call takes the key as soon as that write lands (waiting on the record lock meanwhile). See [Loading the same key twice](../guide/profiles#loading-the-same-key-twice).

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

Reads `key` once with `GetAsync` and returns a [PeekProfile](./peek-profile): the stored data (template if missing, migrations applied in memory) and the lock currently on the record, if any. Yields. Takes no lock, writes nothing, and the result is not tracked by the store nor accepted by transactions. Works while another server holds the key. Fails with `roblox`, `outdated`, `predicate_failed`, `migration_mismatch` or `store_closed`.

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

`on_change` also reports the data a key loads with, right after `store:load` registered the profile and before any `wait_loaded` waiter resumes; that first call has `old == nil`. Locked profiles cannot report it themselves (their hooks are attached after the load set the data), so this is the place to reconcile a key's initial state.

```luau
store:on_change(function(profile, new, old) end)
store:on_save(function(profile) end)
store:on_closing(function(profile) end)
store:on_closed(function(profile) end)
store:on_lock_lost(function(profile) end)
```

See [Profile events](./profile#events) for when each one fires.
