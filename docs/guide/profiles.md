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

Once a profile is closed (`unload`, `store:close`, or lock lost) every method except the event registrations throws. `profile.open` tells you whether it is still usable.

## Session lock

The lock lives inside the stored record as `{ id, expires }`. `load` takes it with a compare-and-set `update_async`, every later write checks that `lock.id` is still ours, and the autosave loop pushes `expires` forward. If a write finds a different id the lock was lost: the profile closes, `on_lock_lost` fires and nothing is written.

Loading a key that is locked by another server waits (polling every `load_poll` seconds) until the lock is released or expires, and throws after `load_timeout` seconds.

### Release and readquire

A profile can hand the lock back without closing:

```luau
profile:release()   -- write, give the lock back; profile stays open
profile.is_locked   -- false

-- ... another server may load the key meanwhile ...

profile:readquire() -- take the lock again, adopt whatever is stored
profile.is_locked   -- true
```

While released, `update` and `save` throw, no autosave runs, the profile cannot join a transaction and `unload` writes nothing. `readquire` waits like `load` and replaces the local data with the stored record (firing `on_change`).

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

`store:load` throws if the key is already loaded on this store. Use `store:get_loaded(key)` to look up an open profile and `store:wait_loaded` to wait for a load that is in progress.
