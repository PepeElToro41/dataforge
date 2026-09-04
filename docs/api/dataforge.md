# dataforge

The module returned by `require "@dataforge"`.

```luau
local dataforge = require "@dataforge"
```

## Functions

### `dataforge.create_store(config)`

```luau
function dataforge.create_store<T>(config: Config<T>): Store<T>
```

Creates a [Store](./store) over the datastore named `config.name`. See [Store config](./store#config) for every field.

Throws if `name` or `template` is missing.

### `dataforge.transaction(profiles, process, config?)`

```luau
function dataforge.transaction(
	profiles: { ProfileBase },
	process: (ctx: TxContext) -> boolean?,
	config: TransactionConfig?
): Result<boolean>
```

Atomically updates any set of profiles, across stores and mixing locked and lockless ones. `process` reads with `ctx:get(profile)` and stages writes with `ctx:set(profile, new)`; return `false` to cancel (nothing is written).

- `Ok(false)` when cancelled, `Ok(true)` when committed.
- Fails with `tx_aborted` (its `cause` says which participant failed and why), `profile_closed`, `released`, or what flushing a lockless participant raised. See [Errors](./errors).
- Throws on misuse (non-profiles, duplicates, no profiles, mixed hooks, `ctx:set(profile, nil)`) and when `process` throws.
- `config` defaults its retry settings to the first profile's.

See [Transactions](./transactions).

## Namespaces

`dataforge.hooks` and `dataforge.schedulers` hold the storage and time backends used to run the library outside Roblox. See [Hooks](./hooks).

## Exported types

```luau
export type Store<T = any>
export type Config<T = any>
export type TransactionConfig
export type TxContext
export type Profile<T = any>
export type LocklessProfile<T = any>
export type ProfileBase<T = any>
export type PeekProfile<T = any>
export type Result<T>
export type Error
```

See [Types](./types).
