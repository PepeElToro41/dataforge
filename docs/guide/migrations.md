# Migrations

Migrations let you change the shape of stored data without touching every key by hand. They are declared on the store, applied when a key is loaded or fetched, and their names are recorded on the record so each one runs exactly once per key.

## Declaring

```luau
local store = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0, gems = 0, inventory = { slots = {} } },
	migrations = {
		{
			name = "add_gems",
			apply = function(data)
				return { coins = data.coins, gems = 0 }
			end,
		},
		{
			name = "nest_inventory",
			apply = function(data)
				return { coins = data.coins, gems = data.gems, inventory = { slots = data.items or {} } }
			end,
		},
	},
}
```

- Migrations run **in order**, skipping the ones already listed in the record's `migrations` array.
- `apply` receives the data as stored (an older shape) and returns the new data. Like every transform it must return a **new** value; the input is not mutated.
- A brand new key starts from `template` and is stamped with every migration name, so migrations never run on template data.

## TypeScript

TypeScript 5.4 or newer is required for the migration declarations. `Migration<T>`
checks a step's output against `T`; omitting the generic keeps the output
`unknown`. Input always remains `unknown`, because stored data may have an older
shape. Narrow it with an appropriate old-schema guard before accessing fields.

`Config<T>.migrations` accepts an empty history or a tuple whose final migration
returns the store schema `T`. Earlier steps may return intermediate shapes.
`NoInfer<T>` prevents migration outputs from weakening the schema inferred from
the template. This checks TypeScript assignability, not runtime validity or exact
object equality. It does not automatically check that adjacent steps agree.

```ts
import dataforge = require("@rbxts/dataforge");

interface PlayerData {
	coins: number;
	gems: number;
}

const migrations: dataforge.Migrations<PlayerData> = [
	{ name: "add_coins", apply: () => ({ coins: 0 }) },
	{ name: "add_gems", apply: () => ({ coins: 0, gems: 0 }) },
];

const store = dataforge.create_store<PlayerData>({
	name: "PlayerData",
	template: { coins: 0, gems: 0 },
	migrations,
});
```

The example uses constant outputs only to illustrate the types. Real migrations
should validate and preserve the appropriate fields from their input.

Previously, any return value was accepted by `Migration.apply`. A final migration
that returns the wrong shape now produces a type error. Separately declared
histories typed as `Migration[]` also need a tuple annotation such as
`Migrations<PlayerData>`, because an arbitrary array cannot prove the final
step's output. For intermediate output checks, annotate individual entries with
`Migration<IntermediateSchema>`. Continue validating stored data at runtime.

Run `npm ci` and `npm run test:types` from the repository root to check the
positive and negative declaration fixtures.

## Rules

- **Never remove or rename** a migration that has shipped. Records refer to it by name.
- **Append only.** New migrations go at the end of the list.
- Keep `apply` pure and total: it runs on every old record it meets, including ones you forgot existed.

## Old servers and new records

A record carries the list of migrations applied to it. When a store declares *fewer* migrations than the record lists, the record was written by a newer server and this one must not touch it: every read or write of that key fails with an `outdated` error carrying both lists (`record_migrations`, `declared_migrations`). `store:load` and `readquire` cancel the lock write, so no lock is taken; a lockless `save` keeps its queue; `fetch` and `peek` return no data. During a rolling deploy this means old servers stop touching keys that new servers have already upgraded, instead of corrupting them.

When a *name* in the record's list differs from the declared one at the same position, the call fails with `migration_mismatch` (`index`, `expected`, `actual`) instead: the two servers disagree about history, not just about how far along it is. The lock taken by a `load` that fails this way is given back.

## When migrations fail

If an `apply` throws, the error propagates as is (it is your code, not wrapped in a `Result`), the load fails and the record is left as it was. Nothing is written until the migration succeeds.
