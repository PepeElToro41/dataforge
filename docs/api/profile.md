# Profile

Session-locked profile, returned by [`store:load`](./store#store-load-key-user-ids). Implements [ProfileBase](#profilebase) plus lock management.

## Fields

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `"locked"` | |
| `key` | `string` | Datastore key. |
| `open` | `boolean` | `false` once closed; most methods throw then. |
| `is_locked` | `boolean` | Whether the session lock is held. `true` after `load`, `false` after `release`. |
| `last_write` | `number` | Time of the last successful write. |
| `user_ids` | `{ number }` | As passed to `load`. |
| `migrations` | `{ string }` | Migration names applied to this record. |
| `config` | `ResolvedConfig<T>` | The store's resolved config. |
| `datastore` | `DatastoreHandle` | The store's handle. |

## Methods

### `profile:get_data()`

```luau
(self: Profile<T>) -> T
```

Current data, deep-frozen. Never mutate it. Throws if the profile is closed.

### `profile:update(fn)`

```luau
(self: Profile<T>, fn: (T) -> T | false) -> boolean
```

Calls `fn` with the current data. Returning a new value replaces the data (fires `on_change`, marks dirty); returning `false` or `nil` leaves it untouched. Returns whether the data changed. Throws if closed or released.

### `profile:save()`

```luau
(self: Profile<T>) -> ()
```

Writes the data now (fires `on_save` first) and refreshes the lock. Yields. Throws if closed or released, or when storage keeps failing after retries.

### `profile:release()`

```luau
(self: Profile<T>) -> ()
```

Writes the data and gives the session lock back, keeping the profile open so another server may take the key. Afterwards `is_locked` is `false`; `update` / `save` throw, no autosave runs, the profile cannot join a transaction and `unload` writes nothing. No-op when already released.

### `profile:readquire()`

```luau
(self: Profile<T>) -> ()
```

Takes the session lock again, waiting like `load` does, and adopts the stored record (resolved pending, migrations) as the current data, firing `on_change`. Throws on timeout, leaving the profile open and released. No-op when already locked.

### `profile:unload()`

```luau
(self: Profile<T>) -> ()
```

Fires `on_closing`, closes the profile, writes the data and releases the lock (when locked), then fires `on_closed`. No-op when already closed. A failed final write is reported with `warn`.

### `profile:wait_settled()`

```luau
(self: Profile<T>) -> ()
```

Yields until no operation holds or waits on the profile mutex. After it returns, the next `update` is guaranteed not to yield.

### `profile:wait_closed()`

```luau
(self: Profile<T>) -> ()
```

Yields until the profile is closed.

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
| `change` | The data was replaced: `update`, `readquire`, a committed transaction. |
| `save` | Just before a write (`save`, autosave, `release`, `unload`). |
| `closing` | At the start of `unload`, while the profile is still open. Last chance to `update` before the final write. |
| `closed` | Once the profile is closed and its final write, if any, is done. Also after `lock_lost`. |
| `lock_lost` | A write found the lock owned by someone else, or it expired. The profile is closed and nothing was written. |

## ProfileBase

The part shared by locked and lockless profiles. Transactions accept any `ProfileBase`.

```luau
type ProfileBase<T> = {
	kind: "locked" | "lockless",
	key: string,
	config: ResolvedConfig<T>,
	user_ids: { number },
	datastore: DatastoreHandle,
	open: boolean,
	migrations: { string },

	get_data: (self) -> T,
	update: (self, (T) -> T | false) -> boolean,
	save: (self) -> (),
	unload: (self) -> (),
	wait_settled: (self) -> (),

	on_change: (self, callback: (new: T, old: T?) -> ()) -> (),
	on_save: (self, callback: () -> ()) -> (),
	on_closing: (self, callback: () -> ()) -> (),
	on_closed: (self, callback: () -> ()) -> (),
	on_lock_lost: (self, callback: () -> ()) -> (),
}
```
