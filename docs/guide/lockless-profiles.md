# Lockless Profiles

A `LocklessProfile` never takes a session lock, so any number of servers can read and write the same key. Use it for shared state like guilds, leaderboards or global settings.

## Creating one

```luau
local guild = store:get_lockless("guild_7", {})
```

`get_lockless` never yields and does no work, they are very cheap to create so it's fine to create them on-the-go. The profile is closed with `unload()` or `store:close()`.

## Reading

```luau
local data = guild:fetch():unwrap() -- GetAsync; returns the stored data
local same = guild:get_data()       -- cached copy; throws `not_fetched` until the profile is fetched
```

`fetch` prepares and get the current data. It fails with `lockless_locked` (the error carries the lock) if another server holds a **session** lock (a locked profile owns it) and fires `on_lock_lost`, and with `outdated` if a newer server already wrote the record. It waits if the key only holds a short **transaction** lock. This uses GetAsync so its cheaper.

Calling this method is optional, and store can be used without it, but no data will be retrieved until the queued updates flushes (if theres any) 

::: info Session locks close the profile
If a **session** lock is present on the key (another server loaded it as a locked profile). Profile will be closed and `on_lock_lost` will be fired.
:::

## Writing

Updates are **queued**, not applied to storage right away:

```luau
guild:update(function(data)
	return { bank = data.bank + 10 }
end)
```

The queue is flushed in **one** `update_async` that replays every queued transform on whatever is currently stored. This is what lets many servers write the same key without stepping on each other.

::: warning Transforms must be pure
Transform must depend only on the `data` it receives and have no side effects: no `math.random`, no `os.time()`, no writes to other state, as other servers can interact with it at the same time.

```luau
-- wrong: depends on local state captured at call time
local bonus = compute_bonus()
guild:update(function(data)
	return { bank = data.bank + bonus } -- fine only if `bonus` never changes
end)

-- wrong: side effect runs every replay
guild:update(function(data)
	fire_event() -- may fire more than once
	return { bank = data.bank + 10 }
end)
```
:::

Flushes happen:

- on `guild:save()`,
- on the flush loop, every `flush_interval` seconds, only when something is queued (an idle profile costs no storage calls),
- on `unload()`.

When the profile is already fetched, `update` advances the local data immediately so `get_data()` reflects the queued change. A transform returning `false` or `nil` is not queued.

A flush can fail without losing the queue: `save` returns `Err(lockless_locked)` when a session lock showed up (the profile closes), `Err(outdated)` when a newer server already wrote the record, or `Err(roblox)` when storage kept failing. See [Errors](../api/errors).


## In transactions

Lockless profiles can join [transactions](./transactions) alongside locked ones. The transaction first flushes the queue and takes a transaction lock on the key, so the data it reads is exact and nobody else writes in between.
