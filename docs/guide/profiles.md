# Profiles

A session-locked `Profile` is the in-memory view of one key that this server currently owns. It is what `store:load` returns.

## Lifecycle

```
store:load(key)      take the session lock, resolve pending transactions,
                     run migrations, return the profile
profile:update(fn)   change the data in memory (marks it dirty)
autosave loop        every autosave_interval: write if dirty, refresh the lock
profile:save()       write now
profile:unload()     final write, release the lock, close the profile
```

Once a profile is closed (`unload`, `store:close`, or lock lost) every method except the event registrations fails with a `profile_closed` error (`get_data` throws it). `profile.open` tells you whether it is still usable.

Every fallible method returns a [`Result`](../api/errors): check `success`, read `error.type`, or call `unwrap()` to throw instead.

## Session lock

The lock lives inside the stored record as `{ id, expires }`. `load` takes it with a compare-and-set `update_async`, every later write checks that `lock.id` is still ours, and the autosave loop pushes `expires` forward. If a write finds a different id the lock was lost: the profile closes, `on_lock_lost` fires and nothing is written. The `save` or `release` that found out fails with `lock_lost`, carrying the lock now on the record (the thief's, or `nil` when it was wiped).

`lock.id` identifies the **acquisition**, not the server: it is `{job_id}#{n}`, with a counter that moves on every `load` and `readquire` (the profile keeps it in `profile.lock_id`). So two sessions of one key on the same server hold different ids and contend through the record exactly like sessions on two servers do — one waits for the other's final write instead of writing over it.

Loading a key that is locked elsewhere waits (polling every `load_poll` seconds) until the lock is released or expires, and fails with `timeout` after `load_timeout` seconds; the error carries the holder's lock.

### Release and readquire

A profile can hand the lock back without closing:

```luau
profile:release()   -- write, give the lock back; profile stays open
profile.is_locked   -- false

-- ... another server may load the key meanwhile ...

profile:readquire() -- take the lock again, adopt whatever is stored
profile.is_locked   -- true
```

While released, `update` and `save` fail with `released`, no autosave runs, the profile cannot join a transaction and `unload` writes nothing. `readquire` waits like `load` (failing with `timeout` the same way) and replaces the local data with the stored record (firing `on_change`).

## Gating keys with a predicate

A store can declare a `predicate`: before any key is locked, written, fetched or peeked, it runs against the **raw stored data** and the key, and a `false` rejects the call with `predicate_failed`.

```luau
local store = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0 },

	predicate = function(data, key)
		return data == nil or not data.frozen
	end,
}
```

On a load the check happens inside the lock's `update_async` transform, so a rejected key is never locked (and the load does not wait for another server's lock either). On a save it happens inside the write's transform, so nothing is written while the profile keeps its lock and stays open. The predicate must be pure: it runs inside a transform, may run again when storage retries it, and must not yield. See [Predicate](../api/store#predicate).

## Events

```luau
profile:on_change(function(new, old) end)  -- data replaced (update, readquire, transaction)
profile:on_save(function() end)            -- a write is about to happen
profile:on_closing(function() end)         -- unload started, profile still open: last chance to update
profile:on_closed(function() end)          -- profile closed and its final write is done
profile:on_lock_lost(function() end)       -- lock stolen / expired; profile is closed
```

The same events exist on the store with the profile as first argument, so you can wire everything in one place:

```luau
store:on_change(function(profile, new, old) end)
store:on_lock_lost(function(profile) end)
```

The store's `on_change` also reports the data a key loads with, with `old == nil`, before any `wait_loaded` waiter resumes — a profile's own `on_change` cannot, since it is attached after the load set the data. So a single store-level listener sees every value a key ever has, and nothing needs reconciling by hand after `load` returns.

## Waiting

- `profile:wait_settled()` yields until no operation holds or waits on the profile. After it returns the next `update` is guaranteed not to yield.
- `profile:wait_closed()` yields until the profile is closed.
- `store:wait_loaded(key, user_ids)` returns the loaded profile for a key, waiting for an in-flight `load` if there is one.

## Loading the same key twice

`store:load` fails with `already_loaded` while a profile for the key is **open** on this store. Use `store:get_loaded(key)` to look up an open profile and `store:wait_loaded` to wait for a load that is in progress.

A profile that is closing does not count: `unload` drops it from the store before its final write, so loading the key again right away (a player who leaves and rejoins the same server) is allowed. That load waits on the record lock until the final write lands, then loads the data it wrote — it may take up to one `load_poll` tick.

## Peeking without a lock

To look at a key without taking its lock (a leaderboard entry, an offline player), `store:peek` reads it once with `GetAsync` and returns a read-only snapshot:

```luau
local peek = store:peek(key):unwrap() -- yields, one GetAsync
peek:get_data()                       -- stored data (template if missing), frozen
peek.lock                             -- Lock of the current holder, or nil if its not session-locked. This is not up-to-date and its only retrieved once.
peek:refresh()                        -- GetAsync again, also refreshes peek.lock
```

::: warning Newer servers make peek fail
`store:peek` and `peek:refresh` fail with `outdated` if the stored value was written by a newer server with extra migrations (the record lists migrations this store does not declare), and with `migration_mismatch` if the names disagree. The data cannot be interpreted by this server, so no snapshot is returned. Check the result instead of unwrapping if the store may run alongside newer versions of the game.
:::

A peek never writes, works while another server holds the key, and cannot be updated or passed to a transaction. See [PeekProfile](../api/peek-profile).
