--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH
local CHECK = assert

local scheduler: dataforge.Scheduler
local hook: dataforge.MemoryHook

TEST("store / profile", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)

	CASE("load returns the template for a new key", function()
		local store = helpers.make_store(hook)
		local profile = helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		CHECK(profile.key == "k1")
		CHECK(profile:get().coins == 0)
		CHECK(profile:is_open())
		CHECK(store:get_loaded "k1" == profile)
		-- lock acquired
		local record = helpers.record(hook, "k1")
		CHECK(record.lock ~= nil and record.lock.id == store.server_id)
		CHECK(record.lock.expires == 60)
	end)

	CASE("data is frozen and updates are immutable", function()
		local store = helpers.make_store(hook)
		local profile = helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		local data = profile:get()
		CHECK(not pcall(function()
			(data :: any).coins = 5
		end))

		local changed: { { any } } = {}
		store.config.on_changed = function(p, new, old)
			table.insert(changed, { p.key :: any, new.coins, if old then old.coins else nil })
		end

		local ok = helpers.sync(scheduler, function()
			return profile:update(function(current: helpers.Data)
				return { coins = current.coins + 10 }
			end)
		end)
		CHECK(ok == true)
		CHECK(profile:get().coins == 10)
		CHECK(table.isfrozen(profile:get() :: any))
		CHECK(#changed == 1 and changed[1][2] == 10 and changed[1][3] == 0)

		-- false discards
		local discarded = helpers.sync(scheduler, function()
			return profile:update(function()
				return false
			end)
		end)
		CHECK(discarded == false)
		CHECK(profile:get().coins == 10)

		-- same ref is a no-op (no callback)
		helpers.sync(scheduler, function()
			return profile:update(function(current)
				return current
			end)
		end)
		CHECK(#changed == 1)

		-- nil is an error
		local handle = helpers.run(scheduler, function()
			return profile:update(function()
				return nil :: any
			end)
		end)
		CHECK(handle.done and not handle.ok)
	end)

	CASE("autosave persists data and refreshes the lock", function()
		local store = helpers.make_store(hook)
		local profile = helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		helpers.sync(scheduler, function()
			return profile:update(function()
				return { coins = 42 }
			end)
		end)
		CHECK(helpers.record(hook, "k1").data == nil)
		scheduler.step(30)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 42)
		CHECK(record.lock.expires == 90)
		CHECK(profile.dirty == false)
	end)

	CASE("unload releases the lock and another store can load the data", function()
		local store = helpers.make_store(hook)
		local profile = helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		helpers.sync(scheduler, function()
			profile:update(function()
				return { coins = 7 }
			end)
			profile:unload()
		end)
		CHECK(not profile:is_open())
		CHECK(store:get_loaded "k1" == nil)
		local record = helpers.record(hook, "k1")
		CHECK(record.lock == nil)
		CHECK(record.data.coins == 7)

		-- operations on a closed profile fail
		local handle = helpers.run(scheduler, function()
			profile:update(function()
				return { coins = 1 }
			end)
		end)
		CHECK(handle.done and not handle.ok)

		local other = helpers.make_store(hook)
		local reloaded = helpers.sync(scheduler, function()
			return other:load "k1"
		end)
		CHECK(reloaded:get().coins == 7)
	end)

	CASE("loading the same key twice in one store errors", function()
		local store = helpers.make_store(hook)
		helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		local handle = helpers.run(scheduler, function()
			return store:load "k1"
		end)
		CHECK(handle.done and not handle.ok)
		CHECK(string.find(tostring(handle.result), "already loaded") ~= nil)
	end)

	CASE("migrations apply once and are recorded", function()
		hook.data[helpers.STORE] = { k1 = { data = { coins = 3 }, migrations = {} } }
		local applied = 0
		local config = {
			migrations = {
				{
					name = "add_items",
					apply = function(data)
						applied += 1
						return { coins = data.coins, items = {} }
					end,
				},
			},
		}
		local store = helpers.make_store(hook, config)
		local profile = helpers.sync(scheduler, function()
			return store:load "k1"
		end)
		CHECK(applied == 1)
		CHECK(profile:get().items ~= nil and profile:get().coins == 3)
		helpers.sync(scheduler, function()
			profile:unload()
		end)
		local record = helpers.record(hook, "k1")
		CHECK(record.migrations[1] == "add_items")

		local again = helpers.make_store(hook, config)
		local reloaded = helpers.sync(scheduler, function()
			return again:load "k1"
		end)
		CHECK(applied == 1)
		CHECK(reloaded:get().items ~= nil)
	end)

	CASE("storage errors are retried with backoff", function()
		local store = helpers.make_store(hook)
		hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		hook:fail_next(helpers.STORE, "k1", "update_async", "before")
		local handle = helpers.run(scheduler, function()
			return store:load "k1"
		end)
		CHECK(not handle.done)
		scheduler.step(1) -- first retry
		CHECK(not handle.done)
		scheduler.step(2) -- second retry succeeds
		CHECK(handle.done and handle.ok, tostring(handle.result))
	end)

	CASE("close unloads every profile", function()
		local store = helpers.make_store(hook)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load "a"
			b = store:load "b"
		end)
		local handle = helpers.run(scheduler, function()
			store:close()
		end)
		scheduler.step(1)
		CHECK(handle.done and handle.ok)
		CHECK(not a:is_open() and not b:is_open())
		CHECK(helpers.record(hook, "a").lock == nil)
		CHECK(helpers.record(hook, "b").lock == nil)
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
return nil
