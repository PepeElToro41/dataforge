--!strict

local dataforge = require "@dataforge"
local memory = require "@dataforge/hooks/memory"
local result = require "@dataforge/result"
local virtual = require "@dataforge/schedulers/virtual"
local types = require "@dataforge/types"

--[[
	Shared test helpers: a fresh virtual scheduler + memory hook per test, a
	`run` wrapper that executes library calls inside the scheduler and records
	the result, and a `server` wrapper that gives a second "server" (own job id)
	over the same storage.
]]

export type Handle = {
	done: boolean,
	ok: boolean,
	result: any,
	thread: thread?,
}

export type Scheduler = virtual.VirtualScheduler
export type Hook = memory.MemoryHook
export type Data = { coins: number, items: { string }? }

local helpers = {}

helpers.STORE = "PlayerData"
helpers.TX_STORE = "tx"

function helpers.fresh(): (Scheduler, Hook)
	local scheduler = virtual.create()
	local hook = memory.create(scheduler)
	return scheduler, hook
end

local HEX = "0123456789abcdef"
local function random_id(): string
	local chars = table.create(16)
	for index = 1, 16 do
		local nibble = math.random(1, 16)
		chars[index] = string.sub(HEX, nibble, nibble)
	end
	return table.concat(chars)
end

--- A hook that shares `hook`'s storage but owns a different job id: another server.
function helpers.server(hook: Hook): types.Hook
	local id = random_id()
	return {
		job_id = function()
			return id
		end,
		get_datastore = hook.get_datastore,
		warn = hook.warn,
	}
end

function helpers.run(scheduler: Scheduler, fn: () -> ...any): Handle
	local handle: Handle = { done = false, ok = false, result = nil, thread = nil }
	handle.thread = scheduler.spawn(function()
		local ok, result = pcall(fn)
		handle.done = true
		handle.ok = ok
		handle.result = result
	end)
	return handle
end

--- A call's outcome unwrapped: a Result must be successful (its value is
--- returned), anything else is returned as is.
local function unwrap(value: any, what: string, level: number): any
	if result.is(value) then
		if not value.success then
			error(`{what} failed: {tostring(value.error)} ({value.error.type})`, level + 1)
		end
		return value.value
	end
	return value
end

--- Runs `fn` inside the scheduler and asserts it finished synchronously and
--- successfully (a Result it returned must be Ok; its value is returned).
function helpers.sync(scheduler: Scheduler, fn: () -> ...any): any
	local handle = helpers.run(scheduler, fn)
	assert(handle.done, "expected call to complete without waiting")
	if not handle.ok then
		error(`call failed: {tostring(handle.result)}`, 2)
	end
	return unwrap(handle.result, "call", 2)
end

--- Asserts a handle finished successfully (message includes the error
--- otherwise) and returns what it produced (a Result's value).
function helpers.finished(handle: Handle, what: string?): any
	assert(handle.done, `{what or "call"} did not finish`)
	assert(handle.ok, `{what or "call"} failed: {tostring(handle.result)}`)
	return unwrap(handle.result, what or "call", 2)
end

--- Asserts a handle finished with a thrown error containing `pattern`.
function helpers.failed(handle: Handle, pattern: string?)
	assert(handle.done, "call did not finish")
	assert(not handle.ok, `expected failure, got {tostring(handle.result)}`)
	if pattern then
		assert(
			string.find(tostring(handle.result), pattern, 1, true) ~= nil,
			`expected error containing "{pattern}", got: {tostring(handle.result)}`
		)
	end
end

--- Asserts a handle finished (without throwing) with a failed Result of
--- `error_type`; returns the error for field checks.
function helpers.err(handle: Handle, error_type: string): any
	assert(handle.done, "call did not finish")
	assert(handle.ok, `expected a failed result, call threw: {tostring(handle.result)}`)
	assert(result.is(handle.result), `expected a Result, got {tostring(handle.result)}`)
	assert(not handle.result.success, `expected a failed result, got success`)
	local err = handle.result.error
	assert(err.type == error_type, `expected a "{error_type}" error, got "{tostring(err.type)}": {tostring(err)}`)
	return err
end

--- Calls `fn` and asserts it threw an error table of `error_type`; returns it.
function helpers.threw(fn: () -> ...any, error_type: string): any
	local ok, err = pcall(fn)
	assert(not ok, "expected the call to throw")
	assert(
		type(err) == "table" and err.type == error_type,
		`expected a thrown "{error_type}" error, got: {tostring(err)}`
	)
	return err
end

--- Steps the scheduler `seconds` times by one second (keeps autosave loops alive).
function helpers.tick(scheduler: Scheduler, seconds: number)
	for _ = 1, seconds do
		scheduler.step(1)
	end
end

function helpers.make_store(
	hook: types.Hook,
	scheduler: Scheduler,
	overrides: { [string]: any }?
): dataforge.Store<Data>
	local config: any = {
		name = helpers.STORE,
		template = { coins = 0 },
		_hook = hook,
		_scheduler = scheduler,
	}
	if overrides then
		for key, value in overrides do
			config[key] = value
		end
	end
	return dataforge.create_store(config)
end

--- Simulates a server dying: the profile stops its loops and never writes again.
function helpers.kill(profile: any)
	profile.open = false
end

function helpers.record(hook: Hook, key: string): any
	return hook:dump(helpers.STORE, key)
end

function helpers.markers(hook: Hook): { [string]: any }
	return hook.data[helpers.TX_STORE] or {}
end

function helpers.count(tbl: { [any]: any }): number
	local n = 0
	for _ in tbl do
		n += 1
	end
	return n
end

--- Number of logged operations matching store / key / op ("*" or nil = any).
function helpers.ops(hook: Hook, store: string?, key: string?, op: string?): number
	local n = 0
	for _, entry in hook.ops do
		if
			(store == nil or entry.store == store)
			and (key == nil or entry.key == key)
			and (op == nil or entry.op == op)
		then
			n += 1
		end
	end
	return n
end

--- Fails if any internal thread (autosave, flush, settle) raised.
function helpers.quiet(scheduler: Scheduler)
	assert(#scheduler.errors == 0, `scheduler recorded errors: {table.concat(scheduler.errors, " | ")}`)
end

local function deep_equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deep_equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end
helpers.deep_equal = deep_equal

function helpers.add(amount: number)
	return function(data: Data): Data
		return { coins = data.coins + amount, items = data.items }
	end
end

function helpers.set(coins: number)
	return function(_: Data): Data
		return { coins = coins }
	end
end

return helpers
