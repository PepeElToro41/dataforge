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
			profile:update(helpers.set(77)):unwrap()
		end)
		helpers.sync(scheduler, function()
			profile:save():unwrap()
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
			profile:update(helpers.set(42)):unwrap()
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
			profile:update(helpers.set(5)):unwrap()
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
		local thrown = helpers.threw(function()
			return profile:get_data()
		end, "profile_closed")
		CHECK(thrown.profile == profile and thrown.reason == "unloaded")
		local rejected = helpers.err(
			helpers.run(scheduler, function()
				return profile:update(helpers.set(1))
			end),
			"profile_closed"
		)
		CHECK(rejected.profile == profile and rejected.reason == "unloaded")
		CHECK(string.find(tostring(rejected), "closed", 1, true) ~= nil)
		helpers.err(
			helpers.run(scheduler, function()
				return profile:save()
			end),
			"profile_closed"
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
			profile_a:update(helpers.set(3)):unwrap()
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
		local loaded = helpers.finished(handle)
		CHECK(loaded:get_data().coins == 3)
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
		local err = helpers.err(handle, "timeout")
		CHECK(err.key == "k1")
		CHECK(err.lock ~= nil and err.lock.id == hook.job_id(), "timeout should carry the holder's lock")
		CHECK(string.find(tostring(err), "timed out", 1, true) ~= nil)
		CHECK(helpers.record(hook, "k1").lock.id == hook.job_id())
	end)

	CASE("a dead server's lock is taken after the ttl with its last saved data", function()
		local a = helpers.make_store(hook, scheduler)
		local b = helpers.make_store(helpers.server(hook), scheduler)
		local profile_a = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_a:update(helpers.set(9)):unwrap()
			profile_a:save():unwrap()
		end)
		helpers.kill(profile_a)

		local handle = helpers.run(scheduler, function()
			return b:load("k1", {})
		end)
		helpers.tick(scheduler, 59)
		CHECK(not handle.done)
		helpers.tick(scheduler, 2)
		local loaded = helpers.finished(handle)
		CHECK(loaded:get_data().coins == 9)
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
			profile_a:update(helpers.set(1)):unwrap()
		end)
		scheduler.step(61)
		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile_b:update(helpers.set(2)):unwrap()
			profile_b:save():unwrap()
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

		local rejected = helpers.err(
			helpers.run(scheduler, function()
				return profile_a:save()
			end),
			"profile_closed"
		)
		CHECK(rejected.profile == profile_a and rejected.reason == "lock_lost")
		rejected = helpers.err(
			helpers.run(scheduler, function()
				return profile_a:update(helpers.set(3))
			end),
			"profile_closed"
		)
		CHECK(rejected.reason == "lock_lost")
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
			profile:update(helpers.set(4)):unwrap()
		end)
		hook.data[helpers.STORE].k1.lock.id = "someone-else"
		local before = helpers.record(hook, "k1")
		local save = helpers.run(scheduler, function()
			return profile:save()
		end)
		-- the write is cancelled inside the transform: save fails with lock_lost
		-- (carrying the lock now on the record) and the profile is closed
		local err = helpers.err(save, "lock_lost")
		CHECK(err.profile == profile)
		CHECK(err.lock ~= nil and err.lock.id == "someone-else")
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

	CASE("release after a stolen or vanished lock fails with lock_lost and writes nothing", function()
		local store = helpers.make_store(hook, scheduler)
		local stolen = helpers.sync(scheduler, function()
			return store:load("stolen", {})
		end)
		local vanished = helpers.sync(scheduler, function()
			return store:load("vanished", {})
		end)
		hook.data[helpers.STORE].stolen.lock.id = "thief"
		hook.data[helpers.STORE].vanished.lock = nil
		local before_stolen = helpers.record(hook, "stolen")
		local before_vanished = helpers.record(hook, "vanished")

		local err = helpers.err(
			helpers.run(scheduler, function()
				return stolen:release()
			end),
			"lock_lost"
		)
		CHECK(err.profile == stolen and err.lock ~= nil and err.lock.id == "thief")
		CHECK(not stolen.open and stolen.is_locked)
		CHECK(helpers.deep_equal(before_stolen, helpers.record(hook, "stolen")))

		err = helpers.err(
			helpers.run(scheduler, function()
				return vanished:release()
			end),
			"lock_lost"
		)
		CHECK(err.profile == vanished and err.lock == nil)
		CHECK(not vanished.open)
		CHECK(helpers.deep_equal(before_vanished, helpers.record(hook, "vanished")))
	end)

	CASE("an update whose dispatcher throws propagates the raw error and keeps the profile usable", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local handle = helpers.run(scheduler, function()
			return profile:update(function()
				error "boom"
			end)
		end)
		helpers.failed(handle, "boom")
		CHECK(type(handle.result) == "string")
		CHECK(profile.open and not profile._mutex:is_locked())
		local ok = helpers.sync(scheduler, function()
			return profile:update(helpers.set(2))
		end)
		CHECK(ok == true and profile:get_data().coins == 2)
	end)

	CASE("unwrap returns the value or throws the error table", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {}):unwrap()
		end)
		CHECK(profile.kind == "locked")
		local thrown = helpers.threw(function()
			return store:load("k1", {}):unwrap()
		end, "already_loaded")
		CHECK(thrown.key == "k1" and thrown.store == store)
		CHECK(string.find(tostring(thrown), "already loaded", 1, true) ~= nil)
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
		local profile = helpers.finished(handle)
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 4)

		-- the retries run out
		for _ = 1, 5 do
			hook:fail_next(helpers.STORE, "k1", "update_async", "before", "down")
		end
		local save = helpers.run(scheduler, function()
			return profile:save()
		end)
		scheduler.step(15)
		local err = helpers.err(save, "roblox")
		CHECK(err.op == "update_async" and err.store == helpers.STORE and err.key == "k1")
		CHECK(err.cause == "down")
		CHECK(string.find(tostring(err), "down", 1, true) ~= nil)
		CHECK(profile.open)
	end)

	CASE("release writes, clears the lock and keeps the profile open but frozen", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(7)):unwrap()
			profile:release():unwrap()
		end)
		CHECK(profile.open and not profile.is_locked)
		CHECK(store:get_loaded "k1" == profile)
		local record = helpers.record(hook, "k1")
		CHECK(record.lock == nil and record.data.coins == 7)
		CHECK(not profile._dirty)
		CHECK(profile:get_data().coins == 7)

		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:update(helpers.set(1))
			end),
			"not_locked"
		)
		CHECK(err.profile == profile)
		CHECK(string.find(tostring(err), "does not hold", 1, true) ~= nil)
		helpers.err(
			helpers.run(scheduler, function()
				return profile:save()
			end),
			"not_locked"
		)
		CHECK(profile.open)

		-- no autosave while released, and a second release is a no-op
		local ops = #hook.ops
		scheduler.step(90)
		helpers.sync(scheduler, function()
			profile:release():unwrap()
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
			profile_a:update(helpers.set(1)):unwrap()
			profile_a:release():unwrap()
		end)

		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)
		CHECK(profile_b:get_data().coins == 1)
		helpers.sync(scheduler, function()
			profile_b:update(helpers.set(2)):unwrap()
			profile_b:unload()
		end)

		scheduler.step(5)
		-- readquire is a no-op while locked, so it must not be yet
		CHECK(not profile_a.is_locked)
		helpers.sync(scheduler, function()
			profile_a:readquire():unwrap()
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
			profile_a:update(helpers.set(3)):unwrap()
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
			profile_a:release():unwrap()
		end)
		local profile_b = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)

		local handle = helpers.run(scheduler, function()
			return profile_a:readquire()
		end)
		CHECK(not handle.done)
		helpers.tick(scheduler, 71)
		local err = helpers.err(handle, "timeout")
		CHECK(err.key == "k1" and err.lock ~= nil and err.lock.id == b._hook.job_id())
		CHECK(profile_a.open and not profile_a.is_locked)
		CHECK(profile_b.open and profile_b.is_locked)

		-- once the holder lets go, the next attempt succeeds after the poll
		helpers.sync(scheduler, function()
			profile_b:unload()
		end)
		helpers.sync(scheduler, function()
			profile_a:readquire():unwrap()
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
			profile:release():unwrap()
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
			a:release():unwrap()
		end)
		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:transaction({ a, b }, function(datas)
					return { { coins = 1 }, { coins = 2 } }
				end)
			end),
			"not_locked"
		)
		CHECK(err.profile == a)
		CHECK(a.open and b.open)
		CHECK(b:get_data().coins == 0)
	end)

	CASE("readquire resolves a committed pending left on the record", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:release():unwrap()
		end)
		hook.data[helpers.STORE].k1.pending = {
			tx_id = "other-1",
			store = helpers.TX_STORE,
			expires = 1000,
			data = { coins = 50 },
		}
		hook.data[helpers.TX_STORE] = { ["other-1"] = "committed" }
		helpers.sync(scheduler, function()
			profile:readquire():unwrap()
		end)
		CHECK(profile:get_data().coins == 50)
		CHECK(profile._dirty) -- the record still carries the pending until the next save
		scheduler.step(30)
		local record = helpers.record(hook, "k1")
		CHECK(record.pending == nil and record.data.coins == 50)
	end)

	CASE("a corrupt transaction marker fails the load with tx_marker_invalid and releases the lock", function()
		hook.data[helpers.STORE] = {
			k1 = {
				data = { coins = 1 },
				migrations = {},
				pending = { tx_id = "dead-1", store = helpers.TX_STORE, expires = 0, data = { coins = 5 } },
			},
		}
		-- a hook whose marker store answers with garbage
		local real = hook.get_datastore
		local corrupt: any = {
			job_id = hook.job_id,
			warn = hook.warn,
			get_datastore = function(name: string)
				local handle = real(name)
				if name ~= helpers.TX_STORE then
					return handle
				end
				return {
					name = name,
					get_async = handle.get_async,
					set_async = handle.set_async,
					remove_async = handle.remove_async,
					update_async = function()
						return "garbage"
					end,
				}
			end,
		}
		local store = helpers.make_store(corrupt, scheduler)
		local handle = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		local err = helpers.err(handle, "tx_marker_invalid")
		CHECK(err.id == "dead-1" and err.value == "garbage")
		CHECK(store:get_loaded "k1" == nil)
		local record = helpers.record(hook, "k1")
		CHECK(record.lock == nil, "lock left behind by a failed load")
		CHECK(record.data.coins == 1 and record.pending ~= nil)
	end)

	CASE("update waits for an in-flight save", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		hook.latency = 1
		local save = helpers.run(scheduler, function()
			profile:save():unwrap()
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
