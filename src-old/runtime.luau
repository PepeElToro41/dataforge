--!nocheck
--!nolint UnknownGlobal

--[[
	Runtime indirection. Everything in the library that needs to spawn threads,
	wait or read the clock goes through this module, so it can be swapped for the
	virtual-time scheduler in tests (see scheduler.luau).

	Defaults:
	- Roblox: task.* + DateTime (wall-clock seconds, fractional)
	- zune:   zune.task + zune.time
]]

export type Runtime = {
	spawn: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	defer: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	wait: (seconds: number?) -> number,
	now: () -> number,
}

local current: Runtime? = nil

local function detect(): Runtime?
	if typeof(task) == "table" and typeof(DateTime) == "table" then
		return {
			spawn = task.spawn,
			defer = task.defer,
			wait = task.wait,
			now = function()
				return DateTime.now().UnixTimestampMillis / 1000
			end,
		}
	end
	if typeof(zune) == "table" and zune.task ~= nil then
		return {
			spawn = zune.task.spawn,
			defer = zune.task.defer,
			wait = zune.task.wait,
			now = function()
				return zune.time.timestampMillis() / 1000
			end,
		}
	end
	return nil
end

current = detect()

local runtime = {}

local function get(): Runtime
	local impl = current
	if impl == nil then
		error "datastore: no runtime available. Call runtime.set(impl) first."
	end
	return impl
end

--- Replace the active runtime (tests plug the virtual scheduler in here).
function runtime.set(impl: Runtime?)
	current = impl or detect()
end

function runtime.get(): Runtime
	return get()
end

function runtime.spawn(fn: ((...any) -> ...any) | thread, ...: any): thread
	return get().spawn(fn, ...)
end

function runtime.defer(fn: ((...any) -> ...any) | thread, ...: any): thread
	return get().defer(fn, ...)
end

function runtime.wait(seconds: number?): number
	return get().wait(seconds)
end

function runtime.now(): number
	return get().now()
end

--- `warn` where available (Roblox), otherwise print.
function runtime.warn(message: string)
	if typeof(warn) == "function" then
		warn(message)
	else
		print(`[warn] {message}`)
	end
end

return runtime
