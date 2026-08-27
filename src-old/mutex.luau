--!strict

local runtime = require "./runtime"

--[[
	FIFO mutex for coroutines. `lock` yields the caller until the mutex is free;
	`unlock` hands the mutex to the next waiter (resumed through the runtime so
	the behaviour is identical under the virtual scheduler).
]]

export type Mutex = {
	lock: (self: Mutex) -> (),
	unlock: (self: Mutex) -> (),
	is_locked: (self: Mutex) -> boolean,
	with: (self: Mutex, fn: () -> ...any) -> any,
}

type Impl = Mutex & {
	_locked: boolean,
	_waiters: { thread },
}

local Mutex = {}
Mutex.__index = Mutex

function Mutex.new(): Mutex
	local self: Impl = setmetatable({
		_locked = false,
		_waiters = {},
	}, Mutex) :: any
	return self
end

function Mutex.lock(self: Impl)
	if not self._locked then
		self._locked = true
		return
	end
	table.insert(self._waiters, coroutine.running())
	coroutine.yield()
end

function Mutex.unlock(self: Impl)
	if not self._locked then
		error "mutex: unlock called while not locked"
	end
	local next_waiter = table.remove(self._waiters, 1)
	if next_waiter == nil then
		self._locked = false
		return
	end
	-- ownership transfers directly to the waiter; it stays locked
	runtime.spawn(next_waiter)
end

function Mutex.is_locked(self: Impl): boolean
	return self._locked
end

function Mutex.with(self: Impl, fn: () -> ...any): any
	self:lock()
	local ok, result = pcall(fn)
	self:unlock()
	if not ok then
		error(result, 0)
	end
	return result
end

return Mutex
