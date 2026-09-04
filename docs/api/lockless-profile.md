# LocklessProfile

Profile without a session lock, returned by [`store:get_lockless`](./store#store-get-lockless-key-user-ids). Updates are queued and folded into storage in one `update_async`. Implements [ProfileBase](./profile#profilebase).

## Fields

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `"lockless"` | |
| `key` | `string` | Datastore key. |
| `open` | `boolean` | `false` once closed. |
| `fetched` | `boolean` | Whether the data has been read from storage (by `fetch` or a first flush). `get_data` throws `not_fetched` until then. |
| `queued_updates` | `{ (T) -> T \| false }` | Transforms waiting for the next flush. |
| `user_ids` | `{ number }` | As passed to `get_lockless`. |
| `migrations` | `{ string }` | Migration names on the record, once fetched. |
| `config` | `ResolvedConfig<T>` | The store's resolved config. |
| `datastore` | `DatastoreHandle` | The store's handle. |

## Methods

### `profile:fetch()`

```luau
(self: LocklessProfile<T>) -> Result<T>
```

Reads the record with `get_async`, resolves any dangling transaction, runs migrations and returns the data. Marks the profile fetched. Yields.

Fails with `lockless_locked` (and fires `on_lock_lost`, closing the profile) if another server holds an unexpired session lock on the key; the error carries that lock. Also `roblox`, `migration_mismatch`, `tx_marker_invalid`, `profile_closed`. Waits while a transaction lock is held.

### `profile:get_data()`

```luau
(self: LocklessProfile<T>) -> T
```

Local data: the last fetched/flushed value with queued updates applied. Throws a `profile_closed` or `not_fetched` error table (a plain accessor, no `Result`).

### `profile:update(fn)`

```luau
(self: LocklessProfile<T>, fn: (T) -> T | false) -> Result<boolean>
```

Queues `fn` to run against the **stored** data on the next flush. When the profile is fetched the local data is advanced right away (fires `on_change`). A transform returning `false` or `nil` is not queued. `Ok(true)` when queued, `Ok(false)` otherwise; fails with `profile_closed`. An error thrown by `fn` propagates as is.

`fn` must be **pure**: it is replayed at flush time on whatever is stored, which may differ from the local data.

### `profile:save()`

```luau
(self: LocklessProfile<T>) -> Result<nil>
```

Flushes the queue: fires `on_save`, then applies every queued transform to the stored data in one `update_async` and refreshes the local data with the result. Marks the profile fetched. Yields.

Fails, keeping the queue, with `lockless_locked` if another server holds a live session lock (the profile is closed), or `outdated` if the record lists more migrations than this store declares (written by a newer server). Neither case is retried. Also `roblox`, `migration_mismatch`, `profile_closed`; an error thrown by a queued transform propagates as is.

The flush loop calls this every `flush_interval` seconds when something is queued.

### `profile:unload()`

```luau
(self: LocklessProfile<T>) -> ()
```

Fires `on_closing`, closes the profile, flushes the queue if non-empty, fires `on_closed`. A failed final flush is reported with `warn`, including the number of changes lost.

### `profile:wait_settled()`

```luau
(self: LocklessProfile<T>) -> ()
```

Yields until no fetch/flush holds or waits on the profile mutex.

## Events

```luau
profile:on_change(function(new: T, old: T?) end)
profile:on_save(function() end)
profile:on_closing(function() end)
profile:on_closed(function() end)
profile:on_lock_lost(function() end)
```

| Event | Fires when |
| --- | --- |
| `change` | Local data replaced: `fetch`, `update` (when fetched), a flush, a committed transaction. |
| `save` | At the start of `save`, before the mutex is taken, so callbacks can still queue updates that land in this flush. |
| `closing` | At the start of `unload`, profile still open. |
| `closed` | After `unload` finished its final flush. Also after `lock_lost`. |
| `lock_lost` | A session lock showed up on the record: a locked profile owns the key now. The profile closes. |
