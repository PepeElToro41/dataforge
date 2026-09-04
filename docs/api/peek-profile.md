# PeekProfile

Read-only snapshot of a key, returned by [`store:peek`](./store#store-peek-key). One `GetAsync`, nothing written: it shows the stored data and whatever lock is on the record right now, can be refreshed.

It is **not** a [ProfileBase](./profile#profilebase): no session lock, no `update` / `save` / `unload`, no events, and transactions reject it. The store does not track it either (`close` ignores it).

## Fields

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `"peek"` | |
| `key` | `string` | Datastore key. |
| `lock` | `Lock?` | Lock on the record at the last read: a session lock (`tx == nil`) or a transaction lock (`tx == true`). `nil` when free. An expired lock is still reported; compare `expires` with the scheduler clock if that matters. |
| `pending` | `Pending<T>?` | Transaction marker on the record, as stored. Never resolved: `get_data()` is the plain data, not `pending.data`. |
| `migrations` | `{ string }` | Migration names after the in-memory migrations of the last read. |
| `_config` | `ResolvedConfig<T>` | The store's resolved config. |
| `_datastore` | `DatastoreHandle` | The store's handle. |

## Methods

### `peek:get_data()`

```luau
(self: PeekProfile<T>) -> T
```

Data from the last read, frozen. The template when the key does not exist. Migrations declared by the store are applied in-memory; the record itself is not updated (a later `load` or flush does that).

### `peek:refresh()`

```luau
(self: PeekProfile<T>) -> Result<T>
```

Calls `GetAsync` again and replaces `lock`, `pending`, `migrations` and the data. Returns the new data. Yields. Fails with `roblox`, `outdated` or `migration_mismatch`, leaving the previous snapshot in place.
