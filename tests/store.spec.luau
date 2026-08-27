--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

type Data = helpers.Data

local scheduler: helpers.Scheduler
local hook: helpers.Hook

TEST("store", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("create validates its config", function()
		CHECK(not pcall(dataforge.create_store, nil :: any))
		CHECK(not pcall(dataforge.create_store, { template = {}, _hook = hook, _scheduler = scheduler } :: any))
		CHECK(not pcall(dataforge.create_store, { name = "", template = {}, _hook = hook, _scheduler = scheduler }))
		CHECK(not pcall(dataforge.create_store, { name = "x", _hook = hook, _scheduler = scheduler } :: any))
		-- outside roblox both hook and scheduler are required
		CHECK(not pcall(dataforge.create_store, { name = "x", template = {}, _scheduler = scheduler }))
		CHECK(not pcall(dataforge.create_store, { name = "x", template = {}, _hook = hook }))
		CHECK(pcall(dataforge.create_store, { name = "x", template = {}, _hook = hook, _scheduler = scheduler }))
	end)

	CASE("config defaults are resolved", function()
		local store = helpers.make_store(hook, scheduler)
		local config = store.config
		CHECK(config.lock_ttl == 60)
		CHECK(config.load_timeout == 70)
		CHECK(config.load_poll == 1)
		CHECK(config.autosave_interval == 30)
		CHECK(config.flush_interval == 30)
		CHECK(config.retry_attempts == 5 and config.retry_base == 1)
		CHECK(#config.migrations == 0)
		CHECK(store.datastore.name == helpers.STORE)

		local custom = helpers.make_store(hook, scheduler, { lock_ttl = 20, autosave_interval = 5 })
		CHECK(custom.config.load_timeout == 30)
		CHECK(custom.config.flush_interval == 5)
		local explicit = helpers.make_store(hook, scheduler, { autosave_interval = 5, flush_interval = 9 })
		CHECK(explicit.config.flush_interval == 9)
	end)

	CASE("load registers the profile and rejects a second load of the same key", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", { 1 })
		end)
		CHECK(profile.key == "k1" and profile.kind == "locked")
		CHECK(profile.user_ids[1] == 1)
		CHECK(store:get_loaded "k1" == profile)
		CHECK(store.profiles.k1 == profile)

		local again = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.failed(again, "already loaded")

		helpers.sync(scheduler, function()
			profile:unload()
		end)
		CHECK(store:get_loaded "k1" == nil)
		local reloaded = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(reloaded ~= profile and reloaded.open)
	end)

	CASE("a load in flight rejects a second load and get_loaded stays nil", function()
		local store = helpers.make_store(hook, scheduler)
		hook.latency = 1
		local first = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(not first.done)
		CHECK(store:get_loaded "k1" == nil)
		local second = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.failed(second, "already loaded")
		scheduler.step(1)
		helpers.finished(first)
	end)

	CASE("wait_loaded returns the existing profile or loads it", function()
		local store = helpers.make_store(hook, scheduler)
		local loaded = helpers.sync(scheduler, function()
			return store:wait_loaded("k1", {})
		end)
		CHECK(loaded.open and store:get_loaded "k1" == loaded)
		local same = helpers.sync(scheduler, function()
			return store:wait_loaded("k1", {})
		end)
		CHECK(same == loaded)
	end)

	CASE("wait_loaded waits for a load in flight and gets the same instance", function()
		local store = helpers.make_store(hook, scheduler)
		hook.latency = 1
		local load = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		local w1 = helpers.run(scheduler, function()
			return store:wait_loaded("k1", {})
		end)
		local w2 = helpers.run(scheduler, function()
			return store:wait_loaded("k1", {})
		end)
		CHECK(not load.done and not w1.done and not w2.done)
		scheduler.step(1)
		helpers.finished(load)
		helpers.finished(w1)
		helpers.finished(w2)
		CHECK(w1.result == load.result and w2.result == load.result)
		-- only one lock write happened
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 1)
	end)

	CASE("a failed load rejects every waiter with the error", function()
		local store = helpers.make_store(hook, scheduler, { retry_attempts = 1 })
		hook.latency = 1
		hook:fail_next(helpers.STORE, "k1", "update_async", "before", "storage down")
		local load = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		local waiter = helpers.run(scheduler, function()
			return store:wait_loaded("k1", {})
		end)
		scheduler.step(1)
		helpers.failed(load, "storage down")
		helpers.failed(waiter, "storage down")
		CHECK(store:get_loaded "k1" == nil)
		-- the key is free again
		local retry = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		scheduler.step(1)
		helpers.finished(retry)
	end)

	CASE("get_lockless returns one instance per key and does no storage work", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", { 7 })
		CHECK(g.kind == "lockless" and g.key == "g" and g.open and not g.fetched)
		CHECK(store:get_lockless("g", {}) == g)
		CHECK(store.lockless_profiles.g == g)
		CHECK(#hook.ops == 0)
		scheduler.step(120)
		CHECK(#hook.ops == 0)

		helpers.sync(scheduler, function()
			g:unload()
		end)
		CHECK(store.lockless_profiles.g == nil)
		CHECK(store:get_lockless("g", {}) ~= g)
	end)

	CASE("store hooks forward every profile hook with the profile first", function()
		local store = helpers.make_store(hook, scheduler)
		local log: { string } = {}
		store:on_change(function(profile, new, old)
			table.insert(log, `change:{profile.key}:{new.coins}:{if old then old.coins else "nil"}`)
		end)
		store:on_save(function(profile)
			table.insert(log, `save:{profile.key}`)
		end)
		store:on_closing(function(profile)
			table.insert(log, `closing:{profile.key}`)
		end)
		store:on_closed(function(profile)
			table.insert(log, `closed:{profile.key}`)
		end)
		store:on_lock_lost(function(profile)
			table.insert(log, `lock_lost:{profile.key}`)
		end)

		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		-- the initial set_data happens before forwarding is attached
		CHECK(#log == 0)
		helpers.sync(scheduler, function()
			a:update(helpers.set(5))
			a:save()
		end)
		CHECK(log[1] == "change:a:5:0" and log[2] == "save:a", table.concat(log, ","))

		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:fetch()
			g:update(helpers.add(2))
			g:save()
		end)
		CHECK(log[3] == "change:g:0:nil" and log[4] == "change:g:2:0" and log[5] == "save:g", table.concat(log, ","))
		-- the save writes the queue and re-sets the data from what landed
		CHECK(log[6] == "change:g:2:2", table.concat(log, ","))

		helpers.sync(scheduler, function()
			a:unload()
			g:unload()
		end)
		CHECK(log[7] == "closing:a" and log[8] == "closed:a", table.concat(log, ","))
		CHECK(log[9] == "closing:g" and log[10] == "closed:g", table.concat(log, ","))
		CHECK(#log == 10, table.concat(log, ","))
	end)

	CASE("lock_lost forwards for locked and lockless profiles", function()
		local store = helpers.make_store(hook, scheduler)
		local lost: { string } = {}
		store:on_lock_lost(function(profile)
			table.insert(lost, profile.key)
		end)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		hook.data[helpers.STORE].a.lock.id = "thief"
		local save = helpers.run(scheduler, function()
			a:save()
		end)
		CHECK(save.done)
		CHECK(not a.open)

		local g = store:get_lockless("g", {})
		hook.data[helpers.STORE].g = { data = { coins = 1 }, migrations = {}, lock = { id = "thief", expires = 100 } }
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		helpers.failed(fetch, "session locked")
		CHECK(#lost == 2 and lost[1] == "a" and lost[2] == "g")
		CHECK(store:get_loaded "a" == nil and store.lockless_profiles.g == nil)
	end)

	CASE("a throwing store hook is warned about, not propagated", function()
		local store = helpers.make_store(hook, scheduler)
		store:on_change(function()
			error "hook broke"
		end)
		local after = 0
		store:on_change(function()
			after += 1
		end)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		local ok = helpers.sync(scheduler, function()
			return a:update(helpers.set(1))
		end)
		CHECK(ok == true and a:get_data().coins == 1)
		CHECK(after == 1)
	end)

	CASE("close unloads every profile, waits for them and rejects everything after", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b, g
		helpers.sync(scheduler, function()
			a = store:load("a", {})
			b = store:load("b", {})
			g = store:get_lockless("g", {})
			a:update(helpers.set(1))
			g:update(helpers.add(3))
		end)
		hook.latency = 1
		local close = helpers.run(scheduler, function()
			store:close()
		end)
		CHECK(store.closed)
		CHECK(not close.done)
		-- all three unloads run concurrently: one latency step finishes them all
		scheduler.step(1)
		helpers.finished(close, "close")
		CHECK(not a.open and not b.open and not g.open)
		CHECK(helpers.record(hook, "a").lock == nil and helpers.record(hook, "a").data.coins == 1)
		CHECK(helpers.record(hook, "b").lock == nil)
		CHECK(helpers.record(hook, "g").data.coins == 3)
		CHECK(helpers.count(store.profiles) == 0 and helpers.count(store.lockless_profiles) == 0)

		helpers.failed(
			helpers.run(scheduler, function()
				return store:load("c", {})
			end),
			"closed"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return store:wait_loaded("c", {})
			end),
			"closed"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return store:get_lockless("c", {})
			end),
			"closed"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return store:transaction({ a }, function(datas)
					return datas
				end)
			end),
			"closed"
		)
		-- second close is a no-op and does not yield
		helpers.sync(scheduler, function()
			store:close()
		end)
	end)

	CASE("close with nothing loaded returns synchronously", function()
		local store = helpers.make_store(hook, scheduler)
		helpers.sync(scheduler, function()
			store:close()
		end)
		CHECK(store.closed)
	end)

	CASE("close keeps going when one unload fails", function()
		local store = helpers.make_store(hook, scheduler, { retry_attempts = 1 })
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {})
			b = store:load("b", {})
		end)
		hook:fail_next(helpers.STORE, "a", "update_async", "before")
		local close = helpers.run(scheduler, function()
			store:close()
		end)
		helpers.finished(close, "close")
		CHECK(not a.open and not b.open)
		-- a's release failed: its lock stays (and expires), b released
		CHECK(helpers.record(hook, "a").lock ~= nil)
		CHECK(helpers.record(hook, "b").lock == nil)
	end)

	CASE("store:transaction takes datas in order and returns them in order", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {})
			b = store:load("b", {})
			a:update(helpers.set(10))
		end)
		local seen
		local ok = helpers.sync(scheduler, function()
			return store:transaction({ b, a }, function(datas)
				seen = { datas[1].coins, datas[2].coins }
				return { { coins = datas[1].coins + 1 }, { coins = datas[2].coins + 1 } }
			end)
		end)
		CHECK(ok == true)
		CHECK(seen[1] == 0 and seen[2] == 10)
		CHECK(b:get_data().coins == 1 and a:get_data().coins == 11)
		CHECK(helpers.count(helpers.markers(hook)) == 1)
	end)

	CASE("store:transaction returning false cancels without storage calls", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {})
			b = store:load("b", {})
		end)
		local before = #hook.ops
		local ok = helpers.sync(scheduler, function()
			return store:transaction({ a, b }, function()
				return false
			end)
		end)
		CHECK(ok == false)
		CHECK(#hook.ops == before)
		CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
	end)

	CASE("store:transaction errors when the transform drops a participant", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {})
			b = store:load("b", {})
		end)
		local handle = helpers.run(scheduler, function()
			return store:transaction({ a, b }, function(datas)
				return { { coins = 1 } }
			end)
		end)
		helpers.failed(handle, "returned no data")
		CHECK(a:get_data().coins == 0 and b:get_data().coins == 0)
		CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
	end)

	CASE("store:transaction over a single profile is a plain update", function()
		local store = helpers.make_store(hook, scheduler)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		local ok = helpers.sync(scheduler, function()
			return store:transaction({ a }, function(datas)
				return { { coins = datas[1].coins + 5 } }
			end)
		end)
		CHECK(ok == true and a:get_data().coins == 5 and a._dirty)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
	end)
end)

return plan
