--!strict

local dataforge = require "@dataforge"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE = plan.TEST, plan.CASE
local CHECK = assert

local function create()
	return dataforge.schedulers.virtual.create()
end

TEST("virtual scheduler", function()
	CASE("spawn runs immediately until the first wait", function()
		local s = create()
		local log = {}
		s.spawn(function()
			table.insert(log, "start")
			s.wait(1)
			table.insert(log, "after")
		end)
		CHECK(#log == 1 and log[1] == "start")
		CHECK(s.pending() == 1)
		s.step(0.5)
		CHECK(#log == 1)
		s.step(0.5)
		CHECK(#log == 2 and log[2] == "after")
		CHECK(s.now() == 1)
		CHECK(s.pending() == 0)
	end)

	CASE("spawn passes its arguments", function()
		local s = create()
		local got
		s.spawn(function(a, b)
			got = a + b
		end, 1, 2)
		CHECK(got == 3)
	end)

	CASE("resumes in order of resume time, then registration order", function()
		local s = create()
		local log = {}
		s.spawn(function()
			s.wait(3)
			table.insert(log, "c")
		end)
		s.spawn(function()
			s.wait(1)
			table.insert(log, "a1")
		end)
		s.spawn(function()
			s.wait(1)
			table.insert(log, "a2")
		end)
		s.spawn(function()
			s.wait(2)
			table.insert(log, "b")
		end)
		s.step(10)
		CHECK(table.concat(log, ",") == "a1,a2,b,c")
	end)

	CASE("re-waits during a step are processed if still due", function()
		local s = create()
		local ticks = 0
		s.spawn(function()
			while true do
				s.wait(1)
				ticks += 1
			end
		end)
		s.step(5)
		CHECK(ticks == 5, `expected 5 ticks, got {ticks}`)
		CHECK(s.now() == 5)
		s.step(0.5)
		CHECK(ticks == 5)
		s.step(0.5)
		CHECK(ticks == 6)
	end)

	CASE("wait returns elapsed virtual time and clock advances to the resume point", function()
		local s = create()
		local elapsed, seen_now
		s.spawn(function()
			elapsed = s.wait(2)
			seen_now = s.now()
		end)
		s.step(10)
		CHECK(elapsed == 2)
		CHECK(seen_now == 2)
		CHECK(s.now() == 10)
	end)

	CASE("wait(0) and wait(nil) resume on the next step", function()
		local s = create()
		local count = 0
		s.spawn(function()
			s.wait(0)
			count += 1
			s.wait()
			count += 1
		end)
		CHECK(count == 0)
		s.flush()
		CHECK(count == 2)
		CHECK(s.now() == 0)
	end)

	CASE("defer runs on the next flush with its args, not immediately", function()
		local s = create()
		local ran: any = false
		s.defer(function(value: any)
			ran = value
		end, "yes")
		CHECK(ran == false)
		CHECK(s.pending() == 1)
		s.flush()
		CHECK(ran :: any == "yes")
	end)

	CASE("spawn can resume an existing thread with values", function()
		local s = create()
		local got
		local thread = coroutine.create(function()
			got = coroutine.yield()
		end)
		coroutine.resume(thread)
		s.spawn(thread, "hello")
		CHECK(got == "hello")
	end)

	CASE("dead threads queued by defer are skipped", function()
		local s = create()
		local thread = coroutine.create(function() end)
		coroutine.resume(thread)
		s.defer(thread)
		s.flush()
		CHECK(s.pending() == 0)
		CHECK(#s.errors == 0)
	end)

	CASE("errors in threads are recorded, not raised", function()
		local s = create()
		s.spawn(function()
			s.wait(1)
			error "boom"
		end)
		s.step(1)
		CHECK(#s.errors == 1)
		CHECK(string.find(s.errors[1], "boom") ~= nil)
	end)

	CASE("step with several due entries advances now to each resume point", function()
		local s = create()
		local seen = {}
		for _, delay in { 1, 2, 3 } do
			s.spawn(function()
				s.wait(delay)
				table.insert(seen, s.now())
			end)
		end
		s.step(2.5)
		CHECK(#seen == 2 and seen[1] == 1 and seen[2] == 2)
		CHECK(s.now() == 2.5)
		CHECK(s.pending() == 1)
	end)
end)

return plan
