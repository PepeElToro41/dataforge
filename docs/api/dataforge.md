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
): boolean
```

Atomically updates any set of profiles, across stores and mixing locked and lockless ones. `process` reads with `ctx:get(profile)` and stages writes with `ctx:set(profile, new)`; return `false` to cancel (nothing is written).

- Returns `false` when cancelled, `true` when committed.
- Throws when aborted.
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
```

See [Types](./types).
