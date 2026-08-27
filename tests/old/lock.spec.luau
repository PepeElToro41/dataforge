--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH
local CHECK = assert

local scheduler: dataforge.Scheduler
local hook: dataforge.MemoryHook

TEST("session locking", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)

	CASE("a second server waits until the first unloads", function()
		local a = helpers.make_store(hook)
		local b = helpers.make_store(hook)
		local profile_a = helpers.sync(scheduler, function()
			return a:load "k1"
		end)

		local handle = helpers.run(scheduler, function()
			return b:load "k1"
		end)
		CHECK(not handle.done)
		scheduler.step(5)
		CHECK(not handle.done)

		helpers.sync(scheduler, function()
			profile_a:unload()
		end)
		scheduler.step(1) -- next poll sees the released lock
		CHECK(handle.done and handle.ok, tostring(handle.result))
		CHECK(helpers.record(hook, "k1").lock.id == b.server_id)
	end)

	CASE("load times out while the holder keeps refreshing", function()
		local a = helpers.make_store(hook)
		local b = helpers.make_store(hook)
		helpers.sync(scheduler, function()
			return a:load "k1"
		end)
		local handle = helpers.run(scheduler, function()
			return b:load "k1"
		end)
		-- step in 1s increments so a's autosave (every 30s) keeps the lock fresh
		for _ = 1, 75 do
			scheduler.step(1)
		end
		CHECK(handle.done and not handle.ok)
		CHECK(string.find(tostring(handle.result), "timed out") ~= nil, tostring(handle.result))
		CHECK(helpers.record(hook, "k1").lock.id == a.server_id)
	end)

	CASE("a dead server's lock is stolen after the ttl", function()
		local a = helpers.make_store(hook)
		local b = helpers.make_store(hook)
		local profile_a = helpers.sync(scheduler, function()
			return a:load "k1"
		end)
		helpers.sync(scheduler, function()
			profile_a:update(function()
				return { coins = 9 }
			end)
			profile_a:save()
		end)
		helpers.kill(profile_a)

		local handle = helpers.run(scheduler, function()
			return b:load "k1"
		end)
		scheduler.step(59)
		CHECK(not handle.done)
		scheduler.step(2)
		CHECK(handle.done and handle.ok, tostring(handle.result))
		local profile_b = handle.result :: dataforge.Profile<helpers.Data>
		CHECK(profile_b:get().coins == 9)
	end)

	CASE("the old holder detects the stolen lock and closes", function()
		local lost = {}
		local a = helpers.make_store(hook, {
			autosave_interval = 100, -- misses the refresh window on purpose
			on_lock_lost = function(profile)
				table.insert(lost, profile.key)
			end,
		})
		local b = helpers.make_store(hook)
		local profile_a = helpers.sync(scheduler, function()
			return a:load "k1"
		end)
		scheduler.step(61)
		local profile_b = helpers.sync(scheduler, function()
			return b:load "k1"
		end)
		CHECK(profile_b:is_open())
		CHECK(profile_a:is_open()) -- does not know yet

		scheduler.step(40) -- a's autosave at t=100
		CHECK(not profile_a:is_open())
		CHECK(#lost == 1 and lost[1] == "k1")
		CHECK(a:get_loaded "k1" == nil)
		-- b's data is untouched by a's failed write
		CHECK(helpers.record(hook, "k1").lock.id == b.server_id)

		-- explicit save on the closed profile errors
		local handle = helpers.run(scheduler, function()
			profile_a:save()
		end)
		CHECK(handle.done and not handle.ok)
	end)

	CASE("a lock is treated as lost after a full ttl of failed writes", function()
		local lost = 0
		local a = helpers.make_store(hook, {
			retry_attempts = 1,
			on_lock_lost = function()
				lost += 1
			end,
		})
		local profile_a = helpers.sync(scheduler, function()
			return a:load "k1"
		end)
		-- every write for the next 90s fails
		for _ = 1, 3 do
			hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		end
		scheduler.step(30) -- fails (30s since last ok)
		CHECK(profile_a:is_open())
		scheduler.step(30) -- fails (60s)
		CHECK(profile_a:is_open())
		scheduler.step(30) -- fails (90s > ttl) -> lost
		CHECK(not profile_a:is_open())
		CHECK(lost == 1)
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
return nil
