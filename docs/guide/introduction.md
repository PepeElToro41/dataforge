# Introduction

**DataForge** is built around three ideas:

- **Transactions.** Any set of keys, across any number of stores, can be updated atomically: every key commits or none of them does. This holds even if the server dies halfway through, thanks to a two-phase protocol with a marker compare-and-set.
- **Two profile kinds.** *Session-locked* profiles own a key for as long as they are loaded (the classic per-player model). *Lockless* profiles never take a lock, so any number of servers can share a key; their updates are queued and folded into storage in one call.
- **Immutable data.** Transforms return new values instead of mutating the old one. Data is deep-frozen, and change detection is a reference comparison, so there is no way to accidentally mutate state behind the library's back.

On top of that it ships with **migrations** (named, ordered, recorded per key) and can run outside Roblox, so everything is unit-testable.

## How it fits together

```luau
local players = dataforge.create_store { name = "Players", template = { coins = 0 } } --> Store
local guilds = dataforge.create_store { name = "Guilds", template = { bank = 0 } }    --> Store

local player = players:load("player_1", { 1 })     --> Profile          (session-locked)
local guild = guilds:get_lockless("guild_7", {})   --> LocklessProfile  (no lock, queued updates)

-- move 30 coins from a player into a shared guild bank, atomically, across both stores
dataforge.transaction({ player, guild }, function(ctx)
	local player_data = ctx:get(player)
	local guild_data = ctx:get(guild)

	if player_data.coins < 30 then
		return false -- cancel, nothing is written
	end

	ctx:set(player, { coins = player_data.coins - 30 })
	ctx:set(guild, { bank = guild_data.bank + 30 })
end)
```

A **Store** wraps one named datastore and holds its configuration (template, migrations, timings). It hands out profiles, forwards their events and closes them all on shutdown.

A **Profile** is the in-memory view of one key. It exposes the current data through `get_data()`, accepts changes through `update(fn)` and writes them back with `save()` (also on an autosave / flush loop) and `unload()`.

A **transaction** takes any mix of profiles from any stores, reads their data, stages new values and commits them all at once.

## Next

Head to [Getting Started](./getting-started) to install the library and load your first profile.
