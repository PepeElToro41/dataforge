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

Loading a key that is locked by another server waits (polling every `load_poll` seconds) until the lock is released or expires, and fails with `timeout` after `load_timeout` seconds; the error carries the holder's lock.

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

## Waiting

- `profile:wait_settled()` yields until no operation holds or waits on the profile. After it returns the next `update` is guaranteed not to yield.
- `profile:wait_closed()` yields until the profile is closed.
- `store:wait_loaded(key, user_ids)` returns the loaded profile for a key, waiting for an in-flight `load` if there is one.

## Loading the same key twice

`store:load` fails with `already_loaded` if the key is already loaded on this store. Use `store:get_loaded(key)` to look up an open profile and `store:wait_loaded` to wait for a load that is in progress.

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
