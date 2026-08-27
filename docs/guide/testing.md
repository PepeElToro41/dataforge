# Testing

The library runs anywhere Luau runs. Storage goes through a **hook** and time goes through a **scheduler**, and both have in-memory, deterministic implementations meant for tests.

## Setup

```luau
local dataforge = require "@dataforge"

local scheduler = dataforge.schedulers.virtual.create()
local hook = dataforge.hooks.memory.create(scheduler)

local store = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0 },
	_hook = hook,
	_scheduler = scheduler,
}
```

Outside Roblox `_hook` and `_scheduler` are required; the store asserts otherwise.

## Virtual time

The virtual scheduler never yields the real thread. `wait` suspends the calling coroutine until the virtual clock reaches `now + seconds`; you advance the clock yourself:

```luau
local profile
scheduler.spawn(function()
	profile = store:load("player_1", {})
end)
scheduler.flush()          -- run everything that is due right now

profile:update(function(d) return { coins = 5 } end)
scheduler.step(30)         -- 30 virtual seconds pass: autosave fires

assert(hook:dump("PlayerData", "player_1").data.coins == 5)
```

- `scheduler.step(dt)` advances the clock by `dt` and resumes every thread due by then, in `(resume time, registration order)`.
- `scheduler.flush()` runs everything due at the current time.
- `scheduler.pending()` is the number of queued threads.
- `scheduler.errors` collects errors thrown by spawned threads.

## Memory hook

```luau
hook.latency = 0.5                       -- every operation waits this long (virtual seconds)
hook:fail_next("PlayerData", "player_1", "update_async", "before")  -- next matching op throws
hook:fail_next("PlayerData", "player_1", "set_async", "after")      -- op is performed, then throws
hook:clear_failures()

hook:dump("PlayerData", "player_1")     -- raw record as stored
hook.ops                                 -- log of every operation: { store, key, op }
hook.warnings                            -- everything the library reported through `warn`
```

`"after"` failures simulate an unknown outcome (the call died after the write went through), which is the interesting case for transactions.

## Simulating another server

Every store created over the same memory hook shares its storage. A second "server" is just a hook with a different `job_id` over the same backend:

```luau
local other = {
	job_id = function() return "other-server" end,
	get_datastore = hook.get_datastore,
	warn = hook.warn,
}

local store_b = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0 },
	_hook = other,
	_scheduler = scheduler,
}
-- store_b:load("player_1", {}) now waits for store's lock to expire
```

## Running the library's own tests

```
zune run tests/lib.spec.luau
```
