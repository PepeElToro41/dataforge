# Getting Started

## Installation

Install with [Wally](https://wally.run). Add the dependency to your `wally.toml`:

```toml
[server-dependencies]
dataforge = "pepeeltoro41/dataforge@0.1.0"
```

Then run:

```sh
wally install
```

The package ends up in `ServerPackages`, and you require it as usual:

```luau
local dataforge = require(ServerPackages.dataforge)
```

## Create a store

```luau
local dataforge = require "@dataforge"

local store = dataforge.create_store {
	name = "PlayerData",
	template = { coins = 0, items = {} },
}
```

`name` is the datastore name, `template` is the data a brand new key starts with. Everything else is optional; see [Store config](../api/store#config) for timings and migrations.

## Load a profile

```luau
local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player)
	local key = `player_{player.UserId}`

	-- yields until the session lock is taken; throws on timeout or storage error
	local ok, profile = pcall(store.load, store, key, { player.UserId })
	if not ok then
		player:Kick("Could not load your data, please rejoin.")
		return
	end

	-- the profile closes on its own if another server steals the key
	profile:on_lock_lost(function()
		player:Kick("Your data was loaded elsewhere.")
	end)

	print(profile:get_data().coins)
end)
```

`store:load` acquires a session lock on the key. While this profile is open no other server can load it; a server that crashes without unloading leaves a lock that expires after `lock_ttl` (60 seconds by default). `lock_ttl`, `load_timeout` and the other timings are set on the store config; see [Store config](../api/store#config).

## Read and update

Data is **immutable**: `get_data()` returns a frozen table and `update` expects a *new* value back.

```luau
profile:update(function(data)
	return { coins = data.coins + 10, items = data.items }
end)

-- return false (or nil) to leave the data untouched
profile:update(function(data)
	if data.coins < 50 then
		return false
	end
	return { coins = data.coins - 50, items = data.items }
end)
```

Changes are written on the next autosave (every `autosave_interval`, default 30 seconds), on `save()` and on `unload()`.

## Unload

```luau
Players.PlayerRemoving:Connect(function(player)
	local profile = store:get_loaded(`player_{player.UserId}`)
	if profile then
		profile:unload() -- final write, releases the session lock
	end
end)

game:BindToClose(function()
	store:close() -- unloads every open profile of the store
end)
```

## Where to go next

- [Profiles](./profiles): lifecycle, events, `release` / `readquire`.
- [Lockless Profiles](./lockless-profiles): keys shared by many servers.
- [Transactions](./transactions): atomic updates across keys and stores.
- [Migrations](./migrations): evolving the shape of your data.
- [Testing](./testing): running the library outside Roblox in unit tests.
