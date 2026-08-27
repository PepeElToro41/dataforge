# Transactions

A transaction updates any set of profiles atomically: either every participant ends up with its new data, or none does. Participants can come from different stores and mix locked and lockless profiles.

## Usage

```luau
local committed = dataforge.transaction({ player, guild }, function(ctx)
	local p = ctx:get(player)
	local g = ctx:get(guild)

	if p.coins < 30 then
		return false -- cancel: nothing is written
	end

	ctx:set(player, { coins = p.coins - 30 })
	ctx:set(guild, { bank = g.bank + 30 })
end)
```

- Returns `true` when committed, `false` when the callback cancelled.
- Throws when the transaction was **aborted** (a participant lost its lock, storage failed, ...).
- A transaction that changes only one profile is a plain write, no marker involved.

Every store also has a positional shorthand for its own profiles:

```luau
store:transaction({ a, b }, function(data)
	return { { coins = data[1].coins - 5 }, { coins = data[2].coins + 5 } }
end)
```

::: warning Lockless profiles are locked during a transaction
A lockless participant holds a short-lived, unique transaction lock on its key while the transaction takes place. Other servers writing that key wait for it (they do not fail), and the lock is released as soon as the transaction finishes; if the server dies, it expires after `lock_ttl` (10 seconds by default). Keep transaction callbacks fast so shared keys are not held longer than needed.
:::

## Rules

- `ctx:get(profile)` returns the current (frozen) data; `ctx:set(profile, new)` stages a new value. Changes are compared by reference, so returning the same table means "unchanged".
- Do not call `update` / `save` on the participants inside the callback; go through `ctx`.
- A released locked profile (`is_locked == false`) cannot participate.
- Lockless participants are flushed and fetched before the callback runs, so what you read is exactly what is stored.

## How it works

The protocol is two-phase with a **marker** as the single source of truth. Its point is that a crash at any moment leaves the keys in a state that every later reader resolves the same way.

0. **Lock lockless keys.** Each lockless participant flushes its queue and takes a short transaction lock (`lock.tx = true`) in one `update_async`. Other lockless writers wait for it; a dead transactions's lock expires after `lock_ttl` (default 10 seconds).
1. **Prepare.** Each changed profile writes its post-transaction data as `record.pending`, leaving the committed `data` untouched. Locked profiles do it under their usual lock check; lockless ones require their transaction lock to still be theirs and release it in the same write.
2. **Commit.** The coordinator compare-and-sets the marker `tx[id] = "committed"` in the global marker datastore (`"aborted"` if phase 1 failed). Whatever the marker says is the truth.

Anyone who later loads or fetches a record with a dangling `pending` resolves it with the same compare-and-set, using `"aborted"` as fallback. A locked loader forces it immediately (it owns the key); lockless readers give a live coordinator until `pending.expires` (`tx_ttl`, default 60 seconds) to finish before forcing.

If the marker write itself has an unknown outcome, participants block until a retry answers; old data is never written over a possibly-committed transaction. Records are cleaned on their next save or flush, and the marker is removed best-effort once every participant is clean.

## Configuration

The third argument tunes timings; retry settings default to the first profile's:

```luau
dataforge.transaction(profiles, process, {
	tx_ttl = 60,        -- grace others give this tx's pending before force-resolving
	lock_ttl = 10,      -- how long a lockless key stays locked between snapshot and prepare
	retry_attempts = 5,
	retry_base = 1,     -- seconds, exponential backoff base
})
```

See [Transactions API](../api/transactions) for the full reference.
