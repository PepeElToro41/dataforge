--!strict

local types = require "./types"

--[[
	FIFO mutex for coroutines.
]]

export type Mutex = types.Mutex

local mutex = {}
mutex.__index = mutex

function mutex.create(scheduler: types.Scheduler): Mutex
	local self = {} :: Mutex
	self._locked = false
	self._closed = nil
	self._waiters = {}
	self._settlers = {}
	self.scheduler = scheduler

	return setmetatable(self, mutex) :: any
end

function mutex.lock(self: Mutex)
	if self._closed then
		error(self._closed, 0)
	end
	if not self._locked then
		self._locked = true
		return
	end
	table.insert(self._waiters, coroutine.running())
	-- resumed with a reason only when the mutex was closed while waiting
	local rejection = coroutine.yield()
	if rejection ~= nil then
		error(rejection, 0)
	end
end

local function resume_settlers(self: Mutex)
	local settlers = self._settlers
	self._settlers = {}
	for _, thread in settlers do
		self.scheduler.spawn(thread)
	end
end

function mutex.unlock(self: Mutex)
	if not self._locked then
		error "mutex: unlock called while not locked"
	end
	local next_waiter = table.remove(self._waiters, 1)
	if next_waiter == nil then
		self._locked = false
		resume_settlers(self)
		return
	end
	self.scheduler.spawn(next_waiter)
end

--- Rejects every current and future lock with `reason` (an `Error` table,
--- thrown as is). Idempotent: a second close keeps the first reason.
function mutex.close(self: Mutex, reason: any)
	if self._closed then
		return
	end
	self._closed = reason

	local waiters = self._waiters
	self._waiters = {}
	for _, thread in waiters do
		self.scheduler.spawn(thread, reason)
	end
end

function mutex.is_locked(self: Mutex): boolean
	return self._locked
end

function mutex.is_closed(self: Mutex): boolean
	return self._closed ~= nil
end

function mutex.with(self: Mutex, fn: () -> ...any): any
	self:lock()
	local ok, result = pcall(fn)
	self:unlock()
	if not ok then
		error(result, 0)
	end
	return result
end

--- Yields until the mutex is unlocked with no one waiting. Works after `close`.
function mutex.wait_settled(self: Mutex)
	if not self._locked then
		return
	end

	table.insert(self._settlers, coroutine.running())
	coroutine.yield()
end

return {
	create = mutex.create,
}
