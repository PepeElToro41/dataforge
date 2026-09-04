# Transactions

Atomic updates over any set of profiles. Entry points: [`dataforge.transaction`](./dataforge#dataforge-transaction-profiles-process-config) and [`store:transaction`](./store#store-transaction-profiles-transform-config). Protocol details are in the [guide](../guide/transactions#how-it-works).

## `dataforge.transaction(profiles, process, config?)`

```luau
function dataforge.transaction(
	profiles: { ProfileBase },
	process: (ctx: TxContext) -> boolean?,
	config: TransactionConfig?
): Result<boolean>
```

| Result | When |
| --- | --- |
| `Ok(true)` | Committed: every changed participant holds its new data. |
| `Ok(false)` | `process` returned `false`; nothing was written. |
| `Err(tx_aborted)` | Aborted during phase 1: `cause` is the participant's error (`lock_lost`, `tx_lock_lost`, `roblox`, ...), or `nil` when another server already resolved the marker as aborted. |
| `Err(profile_closed)`, `Err(not_locked)` | A participant is closed or released. |
| `Err(profile_locked)`, `Err(outdated)`, `Err(roblox)`, `Err(migration_mismatch)` | Flushing a lockless participant before the snapshot failed. |

Misuse (non-profiles, duplicates, no profiles, mixed hooks, `ctx:set(profile, nil)`) and errors thrown by `process` throw. See [Errors](./errors).

Requirements:

- Locked participants must hold their lock (`is_locked == true`).
- Lockless participants are flushed and fetched first; their queued updates land before the transaction reads them.

## TxContext

```luau
type TxContext = {
	get: <T>(self: TxContext, profile: ProfileBase<T>) -> T,
	set: <T>(self: TxContext, profile: ProfileBase<T>, new: T) -> (),
}
```

### `ctx:get(profile)`

The participant's current data (frozen). For lockless profiles this is exactly what is stored, read under the transaction lock.

### `ctx:set(profile, new)`

Stages `new` as the participant's post-transaction data. A profile whose staged value is the same reference as its current data is treated as unchanged and skipped. When only one profile changed, the transaction degenerates to a plain write.

## TransactionConfig

```luau
type TransactionConfig = {
	tx_ttl: number?,
	lock_ttl: number?,
	retry_attempts: number?,
	retry_base: number?,
}
```

| Field | Default | Description |
| --- | --- | --- |
| `tx_ttl` | `60` | Seconds. Grace period other readers give this transaction's `pending` before force-resolving it (fallback `"aborted"`). Stamped on the pending as `expires`. |
| `lock_ttl` | `10` | Seconds a lockless key stays under the transaction lock between snapshot and prepare. |
| `retry_attempts` | first profile's (`5`) | Storage retries per operation. |
| `retry_base` | first profile's (`1`) | Backoff base in seconds. |

## Stored shapes

What a transaction leaves on the records and in the marker store. Useful when inspecting storage or writing tools on top of the library.

```luau
type Pending<T> = {
	tx_id: string,   -- "{job_id}-{n}"
	store: string,   -- marker datastore name
	expires: number, -- time after which non-owners may force-resolve
	data: T,         -- post-transaction data
}

type Lock = {
	id: string,
	expires: number,
	tx: boolean?,    -- true: short transaction lock on a lockless key
}

type DataRecord<T> = {
	data: T?,
	lock: Lock?,
	pending: Pending<T>?,
	migrations: { string },
}
```

Marker: `tx[<tx_id>] = "committed" | "aborted"`. Whatever the marker says is the truth; it is deleted best-effort once every participant has written a clean record.
