--!strict

local dataforge = require "@dataforge"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE = plan.TEST, plan.CASE
local CHECK = assert

TEST("scheduler", function()
	CASE("spawn runs immediately until the first wait", function()
		local s = dataforge.scheduler.new()
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

	CASE("resumes in order of resume time, then registration order", function()
		local s = dataforge.scheduler.new()
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
		local s = dataforge.scheduler.new()
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
		local s = dataforge.scheduler.new()
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

	CASE("defer runs on the next flush, not immediately", function()
		local s = dataforge.scheduler.new()
		local ran: boolean = false
		s.defer(function(value)
			ran = value
		end, true)
		CHECK(ran == false)
		s.flush()
		CHECK(ran)
	end)

	CASE("spawn can resume an existing thread", function()
		local s = dataforge.scheduler.new()
		local got
		local thread = coroutine.create(function()
			got = coroutine.yield()
		end)
		coroutine.resume(thread)
		s.spawn(thread, "hello")
		CHECK(got == "hello")
	end)

	CASE("errors in threads are recorded, not raised", function()
		local s = dataforge.scheduler.new()
		s.spawn(function()
			s.wait(1)
			error "boom"
		end)
		s.step(1)
		CHECK(#s.errors == 1)
		CHECK(string.find(s.errors[1], "boom") ~= nil)
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
return nil
