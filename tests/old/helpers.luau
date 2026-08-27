--!strict

local dataforge = require "@dataforge"

--[[
	Shared test helpers: a fresh virtual scheduler per test, a memory hook and a
	`run` wrapper that executes library calls inside the scheduler and records
	the result so tests can step virtual time and inspect it afterwards.
]]

export type Handle = {
	done: boolean,
	ok: boolean,
	result: any,
	thread: thread?,
}

local helpers = {}

helpers.STORE = "PlayerData"
helpers.TX_STORE = "PlayerData/tx"

function helpers.fresh(): (dataforge.Scheduler, dataforge.MemoryHook)
	local scheduler = dataforge.scheduler.new()
	dataforge.runtime.set(scheduler)
	local hook = dataforge.hooks.memory()
	return scheduler, hook
end

function helpers.run(scheduler: dataforge.Scheduler, fn: () -> ...any): Handle
	local handle: Handle = { done = false, ok = false, result = nil, thread = nil }
	handle.thread = scheduler.spawn(function()
		local ok, result = pcall(fn)
		handle.done = true
		handle.ok = ok
		handle.result = result
	end)
	return handle
end

--- Runs `fn` inside the scheduler and asserts it finished synchronously and successfully.
function helpers.sync(scheduler: dataforge.Scheduler, fn: () -> ...any): any
	local handle = helpers.run(scheduler, fn)
	assert(handle.done, "expected call to complete without waiting")
	if not handle.ok then
		error(`call failed: {tostring(handle.result)}`, 2)
	end
	return handle.result
end

export type Data = { coins: number, items: { string }? }

function helpers.make_store(hook: dataforge.MemoryHook, overrides: { [string]: any }?): dataforge.Store<Data>
	local config: any = {
		name = helpers.STORE,
		template = { coins = 0 },
		hook = hook,
	}
	if overrides then
		for key, value in overrides do
			config[key] = value
		end
	end
	return dataforge.create_store(config)
end

--- Simulates a server dying: the profile stops autosaving and never releases its lock.
function helpers.kill(profile: any)
	profile.open = false
	profile.store:_unregister(profile)
end

function helpers.record(hook: dataforge.MemoryHook, key: string): any
	return hook:dump(helpers.STORE, key)
end

function helpers.markers(hook: dataforge.MemoryHook): { [string]: any }
	return hook.data[helpers.TX_STORE] or {}
end

function helpers.count(tbl: { [any]: any }): number
	local n = 0
	for _ in tbl do
		n += 1
	end
	return n
end

return helpers
