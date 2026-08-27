--!strict

local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

local scheduler: helpers.Scheduler
local hook: helpers.Hook

TEST("session-locked profile", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("load takes the lock and starts from the template", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", { 42 })
		end)
		CHECK(profile.kind == "locked" and profile.open)
		CHECK(profile:get_data().coins == 0)
		CHECK(table.isfrozen(profile:get_data() :: any))
		CHECK(profile._dirty) -- template not persisted yet
		local record = helpers.record(hook, "k1")
		CHECK(record.data == nil)
		CHECK(record.lock.id == hook.job_id() and record.lock.expires == 60 and record.lock.tx == nil)
		CHECK(helpers.ops(hook, helpers.STORE, "k1") == 1)
	end)

	CASE("load reads existing data", function()
		hook.data[helpers.STORE] = { k1 = { data = { coins = 9 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(profile:get_data().coins == 9)
		CHECK(not profile._dirty)
	end)

	CASE("update replaces the data immutably and fires change", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local changes: { { any } } = {}
		profile:on_change(function(new, old)
			table.insert(changes, { new.coins, if old then old.coins else "nil" })
		end)
		local first = profile:get_data()
		CHECK(not pcall(function()
			(first :: any).coins = 5
		end))

		local ok = helpers.sync(scheduler, function()
			return profile:update(function(current: helpers.Data)
				return { coins = current.coins + 10 }
			end)
		end)
		CHECK(ok == true)
		CHECK(profile:get_data().coins == 10 and profile:get_data() ~= first)
		CHECK(table.isfrozen(profile:get_data() :: any))
		CHECK(#changes == 1 and changes[1][1] == 10 and changes[1][2] == 0)

		-- false / nil discard
		for _, value in { false :: any, "nil" } do
			value = if value == "nil" then nil else value
			local discarded = helpers.sync(scheduler, function()
				return profile:update(function()
					return value :: any
				end)
			end)
			CHECK(discarded == false)
		end
		CHECK(profile:get_data().coins == 10)
		CHECK(#changes == 1)

		-- the transform gets the current data
		helpers.sync(scheduler, function()
			profile:update(function(current)
				CHECK(current.coins == 10)
				return current
			end)
		end)
		CHECK(#changes == 2)
	end)

	CASE("save fires on_save before writing so hook updates land in that save", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local saves = 0
		profile:on_save(function()
			saves += 1
			profile:update(helpers.set(77))
		end)
		helpers.sync(scheduler, function()
			profile:save()
		end)
		CHECK(saves == 1)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 77)
		CHECK(record.lock.expires == 60)
		CHECK(not profile._dirty)
		CHECK(profile.last_write == 0)
	end)

	CASE("autosave writes and refreshes the lock every interval", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(42))
		end)
		CHECK(helpers.record(hook, "k1").data == nil)
		scheduler.step(29)
		CHECK(helpers.record(hook, "k1").data == nil)
		scheduler.step(1)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 42)
		CHECK(record.lock.expires == 90)
		CHECK(not profile._dirty)
		CHECK(profile.last_write == 30)
		scheduler.step(30)
		CHECK(helpers.record(hook, "k1").lock.expires == 120)
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 3)
	end)

	CASE("unload fires closing while open, writes, releases the lock, then fires closed", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local log: { string } = {}
		profile:on_closing(function()
			CHECK(profile.open)
			profile:update(helpers.set(5))
			table.insert(log, "closing")
		end)
		profile:on_closed(function()
			CHECK(not profile.open)
			table.insert(log, "closed")
		end)
		helpers.sync(scheduler, function()
			profile:unload()
		end)
		CHECK(table.concat(log, ",") == "closing,closed")
		local record = helpers.record(hook, "k1")
		CHECK(record.lock == nil)
		CHECK(record.data.coins == 5)
		CHECK(store:get_loaded "k1" == nil)

		-- everything is rejected now
		CHECK(not pcall(profile.get_data, profile))
		helpers.failed(
			helpers.run(scheduler, function()
				return profile:update(helpers.set(1))
			end),
			"closed"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				profile:save()
			end),
			"closed"
		)
		-- a second unload is a no-op
		helpers.sync(scheduler, function()
			profile:unload()
		end)
		CHECK(#log == 2)
		helpers.sync(scheduler, function()
			profile:wait_closed()
		end)
		-- the autosave loop stopped
		local ops = #hook.ops
		scheduler.step(120)
		CHECK(#hook.ops == ops)
	end)

	CASE("wait_closed errors on an open profile and waits for the release write", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(not pcall(profile.wait_closed, profile))
		hook.latency = 1
		local unload = helpers.run(scheduler, function()
			profile:unload()
		end)
		CHECK(not profile.open and not unload.done)
		local waiter = helpers.run(scheduler, function()
			profile:wait_closed()
		end)
		CHECK(not waiter.done)
		scheduler.step(1)
		helpers.finished(unload)
		helpers.finished(waiter)
	end)

	CASE("a second server waits until the holder unloads", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(3))
		end)
		local handle = helpers.run(scheduler, function()
			return b:load("k1", {})
		end)
		CHECK(not handle.done)
		scheduler.step(5)
		CHECK(not handle.done)
		helpers.sync(scheduler, function()
			profile_a:unload()
		end)
		CHECK(not handle.done)
		scheduler.step(1) -- next poll sees the released lock
		helpers.finished(handle)
		CHECK(handle.result:get_data().coins == 3)
		CHECK(helpers.record(hook, "k1").lock.id == b._hook.job_id())
	end)

	CASE("load times out while the holder keeps refreshing", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		local handle = helpers.run(scheduler, function()
			return b:load("k1", {})
		end)
		helpers.tick(scheduler, 69)
		CHECK(not handle.done)
		helpers.tick(scheduler, 2)
		helpers.failed(handle, "timed out")
		CHECK(helpers.record(hook, "k1").lock.id == hook.job_id())
	end)

	CASE("a dead server's lock is taken after the ttl with its last saved data", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(9))
			profile_a:save()
		end)
		helpers.kill(profile_a)

		local handle = helpers.run(scheduler, function()
			return b:load("k1", {})
		end)
		helpers.tick(scheduler, 59)
		CHECK(not handle.done)
		helpers.tick(scheduler, 2)
		helpers.finished(handle)
		CHECK(handle.result:get_data().coins == 9)
		CHECK(helpers.record(hook, "k1").lock.id == b._hook.job_id())
	end)

	CASE("a stolen lock is detected on the next write and the profile closes without writing", function()
		local lost, closed = 0, 0
		local a = helpers.make_store(hook, scheduler, { autosave_interval = 100 })
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		profile_a:on_lock_lost(function()
			lost += 1
		end)
		profile_a:on_closed(function()
			closed += 1
		end)
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(1))
		end)
		scheduler.step(61)
		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_b:update(helpers.set(2))
			profile_b:save()
		end)
		CHECK(profile_a.open) -- does not know yet
		local writes = helpers.ops(hook, helpers.STORE, "k1", "update_async")

		scheduler.step(40) -- a's autosave at t=100
		CHECK(not profile_a.open)
		CHECK(lost == 1 and closed == 1)
		CHECK(a:get_loaded "k1" == nil)
		CHECK(profile_a._mutex:is_closed())
		local after = helpers.record(hook, "k1")
		-- b's own autosave refreshed the lock meanwhile; a wrote nothing (its data was 1)
		CHECK(after.lock.id == b._hook.job_id() and after.data.coins == 2)
		-- exactly two writes since: a's cancelled one and b's autosave
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == writes + 2)

		helpers.failed(
			helpers.run(scheduler, function()
				profile_a:save()
			end),
			"closed"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return profile_a:update(helpers.set(3))
			end),
			"closed"
		)
		-- unload after the loss writes nothing
		local ops = #hook.ops
		helpers.sync(scheduler, function()
			profile_a:unload()
		end)
		CHECK(#hook.ops == ops and closed == 1)
		CHECK(profile_b.open)
	end)

	CASE("a lock that changed id under us closes the profile on an explicit save", function()
		local store = helpers.make_store(hook, scheduler)
		local lost = 0
		store:on_lock_lost(function()
			lost += 1
		end)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(4))
		end)
		hook.data[helpers.STORE].k1.lock.id = "someone-else"
		local before = helpers.record(hook, "k1")
		local save = helpers.run(scheduler, function()
			profile:save()
		end)
		-- the write is cancelled inside the transform; save returns (no error) but the profile is closed
		CHECK(save.done and save.ok, tostring(save.result))
		CHECK(not profile.open and lost == 1)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "k1")))
	end)

	CASE("a lock that vanished closes the profile the same way", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		hook.data[helpers.STORE].k1.lock = nil
		local before = helpers.record(hook, "k1")
		scheduler.step(30)
		CHECK(not profile.open)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "k1")))
		CHECK(store:get_loaded "k1" == nil)
	end)

	CASE("a lock is treated as lost after a full ttl of failed writes", function()
		local lost = 0
		local store = helpers.make_store(hook, scheduler, { retry_attempts = 1 })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		profile:on_lock_lost(function()
			lost += 1
		end)
		for _ = 1, 3 do
			hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		end
		scheduler.step(30) -- fails (30s since the lock write)
		CHECK(profile.open)
		scheduler.step(30) -- fails (60s)
		CHECK(profile.open)
		scheduler.step(30) -- fails (90s > ttl) -> lost
		CHECK(not profile.open)
		CHECK(lost == 1)
		CHECK(store:get_loaded "k1" == nil)
	end)

	CASE("writes that recover within the ttl keep the profile open", function()
		local store = helpers.make_store(hook, scheduler, { retry_attempts = 1 })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		scheduler.step(30)
		CHECK(profile.open and profile.last_write == 0)
		scheduler.step(30)
		CHECK(profile.open and profile.last_write == 60)
	end)

	CASE("storage errors are retried with exponential backoff", function()
		local store = helpers.make_store(hook, scheduler)
		for _ = 1, 3 do
			hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		end
		local handle = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(not handle.done)
		scheduler.step(1) -- retry 2 (fails)
		CHECK(not handle.done)
		scheduler.step(2) -- retry 3 (fails)
		CHECK(not handle.done)
		scheduler.step(3)
		CHECK(not handle.done)
		scheduler.step(1) -- retry 4 at t=7 succeeds
		helpers.finished(handle)
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 4)

		-- the retries run out
		local profile = handle.result
		for _ = 1, 5 do
			hook:fail_next(helpers.STORE, "k1", "update_async", "before", "down")
		end
		local save = helpers.run(scheduler, function()
			profile:save()
		end)
		scheduler.step(15)
		helpers.failed(save, "down")
		CHECK(profile.open)
	end)

	CASE("release writes, clears the lock and keeps the profile open but frozen", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(7))
			profile:release()
		end)
		CHECK(profile.open and not profile.is_locked)
		CHECK(store:get_loaded "k1" == profile)
		local record = helpers.record(hook, "k1")
		CHECK(record.lock == nil and record.data.coins == 7)
		CHECK(not profile._dirty)
		CHECK(profile:get_data().coins == 7)

		helpers.failed(
			helpers.run(scheduler, function()
				return profile:update(helpers.set(1))
			end),
			"does not hold"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				profile:save()
			end),
			"does not hold"
		)
		CHECK(profile.open)

		-- no autosave while released, and a second release is a no-op
		local ops = #hook.ops
		scheduler.step(90)
		helpers.sync(scheduler, function()
			profile:release()
		end)
		CHECK(#hook.ops == ops)
		CHECK(helpers.deep_equal(record, helpers.record(hook, "k1")))
	end)

	CASE("readquire takes the lock back and adopts what another server stored", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		local changes: { number } = {}
		profile_a:on_change(function(new)
			table.insert(changes, new.coins)
		end)
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(1))
			profile_a:release()
		end)

		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)
		CHECK(profile_b:get_data().coins == 1)
		helpers.sync(scheduler, function()
			profile_b:update(helpers.set(2))
			profile_b:unload()
		end)

		scheduler.step(5)
		-- readquire is a no-op while locked, so it must not be yet
		CHECK(not profile_a.is_locked)
		helpers.sync(scheduler, function()
			profile_a:readquire()
		end)
		CHECK(profile_a.is_locked and profile_a.open)
		CHECK(profile_a:get_data().coins == 2)
		CHECK(table.concat(changes, ",") == "1,2")
		CHECK(not profile_a._dirty)
		CHECK(profile_a.last_write == 5)
		local record = helpers.record(hook, "k1")
		CHECK(record.lock.id == hook.job_id() and record.lock.expires == 65)

		-- back to normal: update, autosave, unload releases
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(3))
		end)
		scheduler.step(30)
		CHECK(helpers.record(hook, "k1").data.coins == 3)
		local ops = #hook.ops
		helpers.sync(scheduler, function()
			profile_a:readquire() -- no-op
		end)
		CHECK(#hook.ops == ops)
		helpers.sync(scheduler, function()
			profile_a:unload()
		end)
		CHECK(helpers.record(hook, "k1").lock == nil)
	end)

	CASE("readquire waits for the holder and times out like load", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_a:release()
		end)
		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)

		local handle = helpers.run(scheduler, function()
			profile_a:readquire()
		end)
		CHECK(not handle.done)
		helpers.tick(scheduler, 71)
		helpers.failed(handle, "timed out")
		CHECK(profile_a.open and not profile_a.is_locked)
		CHECK(profile_b.open and profile_b.is_locked)

		-- once the holder lets go, the next attempt succeeds after the poll
		helpers.sync(scheduler, function()
			profile_b:unload()
		end)
		helpers.sync(scheduler, function()
			profile_a:readquire()
		end)
		CHECK(profile_a.is_locked)
		CHECK(helpers.record(hook, "k1").lock.id == hook.job_id())
	end)

	CASE("unload of a released profile writes nothing", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:release()
		end)
		local log: { string } = {}
		profile:on_closing(function()
			table.insert(log, "closing")
		end)
		profile:on_closed(function()
			table.insert(log, "closed")
		end)
		local ops = #hook.ops
		helpers.sync(scheduler, function()
			profile:unload()
		end)
		CHECK(#hook.ops == ops)
		CHECK(table.concat(log, ",") == "closing,closed")
		CHECK(not profile.open and store:get_loaded "k1" == nil)
		CHECK(helpers.record(hook, "k1").lock == nil)
	end)

	CASE("a released profile cannot join a transaction", function()
		local store = helpers.make_store(hook, scheduler)
		local a = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local b = helpers.sync(scheduler, function()
			return store:load("k2", {})
		end)
		helpers.sync(scheduler, function()
			a:release()
		end)
		helpers.failed(
			helpers.run(scheduler, function()
				return store:transaction({ a, b }, function(datas)
					return { { coins = 1 }, { coins = 2 } }
				end)
			end),
			"does not hold its session lock"
		)
		CHECK(a.open and b.open)
		CHECK(b:get_data().coins == 0)
	end)

	CASE("readquire resolves a committed pending left on the record", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:release()
		end)
		hook.data[helpers.STORE].k1.pending = {
			tx_id = "other-1",
			store = helpers.TX_STORE,
			expires = 1000,
			data = { coins = 50 },
		}
		hook.data[helpers.TX_STORE] = { ["other-1"] = "committed" }
		helpers.sync(scheduler, function()
			profile:readquire()
		end)
		CHECK(profile:get_data().coins == 50)
		CHECK(profile._dirty) -- the record still carries the pending until the next save
		scheduler.step(30)
		local record = helpers.record(hook, "k1")
		CHECK(record.pending == nil and record.data.coins == 50)
	end)

	CASE("update waits for an in-flight save", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		hook.latency = 1
		local save = helpers.run(scheduler, function()
			profile:save()
		end)
		local update = helpers.run(scheduler, function()
			return profile:update(helpers.set(3))
		end)
		CHECK(not save.done and not update.done)
		scheduler.step(1)
		helpers.finished(save)
		helpers.finished(update)
		CHECK(helpers.record(hook, "k1").data.coins == 0)
		CHECK(profile:get_data().coins == 3 and profile._dirty)
	end)
end)

return plan
