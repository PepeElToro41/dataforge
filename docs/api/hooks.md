# Hooks & Schedulers

Backends for running the library outside Roblox (or over custom storage). Inside Roblox both are picked automatically; elsewhere they are passed on the store config:

```luau
dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0 },
	_hook = hook,           -- Hook, required outside Roblox
	_scheduler = scheduler, -- Scheduler, required outside Roblox
}
```

`dataforge.transaction` also accepts `_hook`, `_scheduler` and `_datastore` (marker datastore handle, default `hook.get_datastore("tx")`) in its config; they default to the first profile's.

# Hooks

A hook is how a store reaches storage. Deliberately not shaped like a Roblox DataStore: it is the minimum the library needs, so it can be implemented over anything.

## Hook

```luau
type Hook = {
	job_id: () -> string,
	get_datastore: (name: string) -> DatastoreHandle,
	warn: (message: string) -> (),
}
```

| Field | Description |
| --- | --- |
| `job_id()` | Identifies this server. Session locks and transaction ids carry it. |
| `get_datastore(name)` | Returns the handle for a named store. Called once per store name. |
| `warn(message)` | Receives non-fatal problems (a hook that threw, a write that could not be released) instead of a global `warn`. |

## DatastoreHandle

```luau
type DatastoreHandle = {
	name: string,
	get_async: (key: string) -> any?,
	set_async: (key: string, value: any, user_ids: { number }?) -> (),
	update_async: (key: string, transform: (old: any?) -> any?, user_ids: { number }?) -> any?,
	remove_async: ((key: string) -> ())?,
}
```

All methods throw on failure. `update_async(key, transform)` cancels when `transform` returns `nil` and returns the value stored after the call. `remove_async` is optional; it is used to delete transaction markers.

## `dataforge.hooks.roblox`

```luau
local hook = dataforge.hooks.roblox.create()
```

Adapts `DataStoreService`; `job_id` is `game.JobId` and `warn` is the global `warn`. This is the default inside Roblox; you only need to call it yourself to share a hook explicitly.

## `dataforge.hooks.memory`

```luau
local hook = dataforge.hooks.memory.create(scheduler)
```

In-memory backend meant for tests. Every handle created from one hook shares one backend table, so several stores over one hook behave like several servers. Values are deep-copied in and out.

```luau
type MemoryHook = Hook & {
	scheduler: Scheduler,
	data: { [string]: { [string]: any } },
	latency: number,
	ops: { { store: string, key: string, op: string } },
	warnings: { string },

	fail_next: (self, store: string, key: string, op: Op, mode: FailMode, message: string?) -> (),
	clear_failures: (self) -> (),
	dump: (self, store: string, key: string) -> any?,
}

type Op = "get_async" | "set_async" | "update_async" | "remove_async" | "*"
type FailMode = "before" | "after"
```

| Member | Description |
| --- | --- |
| `data` | Raw backend: `data[store][key]`. |
| `latency` | Seconds waited through the scheduler before every operation (default `0`). |
| `ops` | Log of every operation performed. |
| `warnings` | Every message the library reported through `warn`; nothing is printed. |
| `fail_next(store, key, op, mode, message?)` | The next matching operation throws. `"before"` throws without touching the backend; `"after"` performs the write and then throws (unknown outcome). `op = "*"` matches any operation. |
| `clear_failures()` | Drops pending injected failures. |
| `dump(store, key)` | Deep copy of the stored record. |

## Writing your own

Implement `Hook` and `DatastoreHandle` over your backend and pass it as `_hook` to `create_store`. Requirements:

- `update_async` must be atomic per key and honour `nil` from the transform as "cancel".
- Every method throws on failure; the library retries with exponential backoff.
- Handles for the same name from the same hook must see the same data.

# Schedulers

A scheduler is how the library spawns threads, waits and reads the clock. Inside Roblox it wraps `task`; in tests it is a virtual clock you advance by hand. Passed as `_scheduler` to `create_store`.

## Scheduler

```luau
type Scheduler = {
	spawn: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	defer: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	wait: (seconds: number?) -> number,
	now: () -> number,
}
```

Same contract as `task.spawn` / `task.defer` / `task.wait` / `os.clock`.

## `dataforge.schedulers.roblox`

```luau
local scheduler = dataforge.schedulers.roblox.create()
```

Wraps the `task` library and `os.clock`. Default inside Roblox.

## `dataforge.schedulers.virtual`

```luau
local scheduler = dataforge.schedulers.virtual.create()
```

Virtual-time scheduler for tests. Never yields the real thread: `wait` suspends the calling coroutine and registers it to resume at `now + seconds`.

```luau
type VirtualScheduler = Scheduler & {
	step: (dt: number) -> (),
	flush: () -> (),
	pending: () -> number,
	errors: { string },
}
```

| Member | Description |
| --- | --- |
| `step(dt)` | Advances the clock by `dt` and resumes every due thread in `(resume time, registration order)`. Threads that wait again while stepping are re-queued and run in the same step if still due. |
| `flush()` | Runs everything due at the current time. |
| `pending()` | Number of queued threads. |
| `errors` | Errors thrown by spawned threads. |

`spawn` runs the function immediately until its first yield; `defer` queues it for the current time.

## `dataforge.schedulers.zune`

```luau
local scheduler = require("@dataforge/schedulers/zune").create()
```

Wraps zune's task library for running the library under [zune](https://github.com/Scythe-Technology/Zune) with real time. Not exported from the main module.
