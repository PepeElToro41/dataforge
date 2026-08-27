# Types

Every type below is exported from `src/types.luau`; the ones marked with a star are re-exported from the main module.

```luau
local dataforge = require "@dataforge"
type Profile<T> = dataforge.Profile<T>
```

## Configuration

### `Config<T>` ★

See [Store config](./store#config).

### `ResolvedConfig<T>`

`Config<T>` with every optional field filled in. Available as `store.config` and `profile.config`.

### `TransactionConfig` ★

See [TransactionConfig](./transactions#transactionconfig).

### `Migration`

```luau
type Migration = {
	name: string,
	apply: (data: unknown) -> unknown,
}
```

## Storage

### `Hook`, `DatastoreHandle`, `Scheduler`

Backends for running outside Roblox. See [Hooks](./hooks).

### `DataRecord<T>`, `Lock`, `Pending<T>`

What is stored under each key. See [Stored shapes](./transactions#stored-shapes).

## Profiles

### `ProfileBase<T>` ★

Shared shape of both profile kinds. See [ProfileBase](./profile#profilebase).

### `Profile<T>` ★

Session-locked profile. See [Profile](./profile).

### `LocklessProfile<T>` ★

Lockless profile. See [LocklessProfile](./lockless-profile).

### `PeekProfile<T>` ★

Read-only snapshot. See [PeekProfile](./peek-profile).

### `DataDispatcher<T>`

```luau
type DataDispatcher<T> = (T) -> (T | false)?
```

The transform passed to `update`. Returns the new data, or `nil` / `false` to leave it untouched.

## Transactions

### `TxContext` ★

See [TxContext](./transactions#txcontext).

### `TxOutcome`

```luau
type TxOutcome = "committed" | "aborted"
```

## Store

### `Store<T>` ★

See [Store](./store).
