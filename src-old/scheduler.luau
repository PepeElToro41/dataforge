--!strict

--[[
	Virtual-time task scheduler.

	Never yields the real thread. `wait` suspends the calling coroutine and
	registers it to resume at `now + seconds`; `step(dt)` advances the virtual
	clock and resumes every due thread in (resume_time, registration order).
	Threads that wait again while stepping are re-queued and processed in the
	same step if they are still due.

	Plug it into the library with `runtime.set(scheduler)`.
]]

export type Scheduler = {
	now: () -> number,
	spawn: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	defer: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	wait: (seconds: number?) -> number,
	step: (dt: number) -> (),
	flush: () -> (),
	pending: () -> number,
	errors: { string },
}

type Entry = {
	at: number,
	seq: number,
	thread: thread,
	-- wait entries resume with the time they were resumed at,
	-- deferred entries resume with their stored args
	args: { any }?,
}

local Scheduler = {}

function Scheduler.new(): Scheduler
	local time = 0
	local seq = 0
	local queue: { Entry } = {}
	local errors: { string } = {}

	local function insert(entry: Entry)
		-- keep sorted by (at, seq); scan from the back since most inserts are late
		local index = #queue
		while index >= 1 do
			local other = queue[index]
			if other.at < entry.at or (other.at == entry.at and other.seq < entry.seq) then
				break
			end
			index -= 1
		end
		table.insert(queue, index + 1, entry)
	end

	local function resume(thread: thread, ...: any)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			local message = `scheduler: thread error: {tostring(err)}`
			table.insert(errors, message)
			print(message)
		end
	end

	local function to_thread(fn: ((...any) -> ...any) | thread): thread
		if type(fn) == "thread" then
			return fn
		end
		return coroutine.create(fn)
	end

	local self = {} :: Scheduler
	self.errors = errors

	function self.now(): number
		return time
	end

	function self.spawn(fn, ...)
		local thread = to_thread(fn)
		resume(thread, ...)
		return thread
	end

	function self.defer(fn, ...)
		local thread = to_thread(fn)
		seq += 1
		insert { at = time, seq = seq, thread = thread, args = { ... } }
		return thread
	end

	function self.wait(seconds)
		local thread = coroutine.running()
		if not coroutine.isyieldable() then
			error "scheduler.wait called from a non-yieldable thread; run your code inside scheduler.spawn"
		end
		local delay = math.max(seconds or 0, 0)
		seq += 1
		local started = time
		insert { at = time + delay, seq = seq, thread = thread }
		local resumed_at: number = coroutine.yield()
		return resumed_at - started
	end

	function self.step(dt)
		local target = time + math.max(dt, 0)
		while #queue > 0 and queue[1].at <= target do
			local entry = table.remove(queue, 1) :: Entry
			if entry.at > time then
				time = entry.at
			end
			if coroutine.status(entry.thread) == "dead" then
				continue
			end
			if entry.args then
				resume(entry.thread, table.unpack(entry.args))
			else
				resume(entry.thread, time)
			end
		end
		time = target
	end

	function self.flush()
		self.step(0)
	end

	function self.pending(): number
		return #queue
	end

	return self
end

return Scheduler
