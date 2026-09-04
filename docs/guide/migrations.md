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

## Rules

- **Never remove or rename** a migration that has shipped. Records refer to it by name.
- **Append only.** New migrations go at the end of the list.
- Keep `apply` pure and total: it runs on every old record it meets, including ones you forgot existed.

## Old servers and new records

A record carries the list of migrations applied to it. A lockless profile whose store declares *fewer* migrations than the record lists refuses to flush it: `save` fails with an `outdated` error (carrying both migration lists), keeping the queue. During a rolling deploy this means old servers stop writing shared keys that new servers have already upgraded, instead of corrupting them.

A locked `load`, a lockless `fetch` and a `peek` fail with `migration_mismatch` when the record's list does not prefix-match the declared one: either a name differs (`index`, `expected`, `actual`) or the record lists more migrations than declared. The lock taken by a failed `load` is given back.

## When migrations fail

If an `apply` throws, the error propagates as is (it is your code, not wrapped in a `Result`), the load fails and the record is left as it was. Nothing is written until the migration succeeds.
