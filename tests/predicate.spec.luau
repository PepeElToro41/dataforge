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

local function writes(key: string): number
	return helpers.ops(hook, helpers.STORE, key, "update_async")
end

--- A predicate that rejects stored data with negative coins (a fresh key passes).
local function non_negative(data: Data?): boolean
	return data == nil or data.coins >= 0
end

TEST("store predicate", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("create validates the predicate and resolves it", function()
		CHECK(not pcall(dataforge.create_store, {
			name = "x",
			template = {},
			predicate = 5 :: any,
			_hook = hook,
			_scheduler = scheduler,
		}))
		CHECK(helpers.make_store(hook, scheduler).config.predicate == nil)
		local store = helpers.make_store(hook, scheduler, { predicate = non_negative })
		CHECK(store.config.predicate == non_negative)
	end)

	CASE("the predicate gets the raw stored data and the key", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 2 }, migrations = {} } }
		local seen: { { data: Data?, key: string } } = {}
		local store = helpers.make_store(hook, scheduler, {
			migrations = {
				{
					name = "items",
					apply = function(data: any)
						return { coins = data.coins, items = {} }
					end,
				},
			},
			predicate = function(data: Data?, key: string)
				table.insert(seen, { data = data, key = key })
				return true
			end,
		})

		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		CHECK(#seen == 1 and seen[1].key == "k")
		-- raw: the declared migration is applied only after the predicate passed
		CHECK(seen[1].data ~= nil and (seen[1].data :: Data).coins == 2)
		CHECK((seen[1].data :: any).items == nil)
		CHECK(profile:get_data().items ~= nil)

		-- an empty key reaches the predicate as nil, not as the template
		local empty = helpers.sync(scheduler, function()
			return store:load("fresh", {})
		end)
		CHECK(#seen == 2 and seen[2].key == "fresh" and seen[2].data == nil)
		CHECK(empty:get_data().coins == 0)
	end)

	CASE("load is rejected without taking the lock", function()
		hook.data[helpers.STORE] = { k = { data = { coins = -1 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler, { predicate = non_negative })

		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:load("k", {})
			end),
			"predicate_failed"
		)
		CHECK(err.key == "k" and err.op == "load" and err.profile == nil)
		CHECK(err.data.coins == -1)
		CHECK(string.find(tostring(err), "predicate rejected", 1, true) ~= nil)

		local record = helpers.record(hook, "k")
		CHECK(record.lock == nil and record.data.coins == -1)
		CHECK(store.profiles.k == nil and store._loading.k == nil)
		-- rejected inside the transform: one cancelled call, no poll loop
		CHECK(writes "k" == 1 and helpers.ops(hook, helpers.STORE, "k", "get_async") == 0)
	end)

	CASE("a rejected load does not wait for another server's lock", function()
		local other = helpers.make_store(helpers.server(hook), scheduler)
		local held = helpers.sync(scheduler, function()
			return other:load("k", {})
		end)
		helpers.sync(scheduler, function()
			held:update(helpers.set(-5)):unwrap()
			held:save():unwrap()
		end)

		local store = helpers.make_store(hook, scheduler, { predicate = non_negative })
		local handle = helpers.run(scheduler, function()
			return store:load("k", {})
		end)
		CHECK(handle.done)
		CHECK(helpers.err(handle, "predicate_failed").op == "load")
		CHECK(helpers.record(hook, "k").lock.id == held.lock_id)
	end)

	CASE("wait_loaded waiters get the rejection too", function()
		hook.data[helpers.STORE] = { k = { data = { coins = -1 }, migrations = {} } }
		hook.latency = 1
		local store = helpers.make_store(hook, scheduler, { predicate = non_negative })

		local loader = helpers.run(scheduler, function()
			return store:load("k", {})
		end)
		local waiter = helpers.run(scheduler, function()
			return store:wait_loaded("k", {})
		end)
		CHECK(not loader.done and not waiter.done)
		scheduler.step(1)

		CHECK(helpers.err(loader, "predicate_failed").op == "load")
		CHECK(helpers.err(waiter, "predicate_failed").op == "load")
	end)

	CASE("save is rejected inside the transform, keeping the lock and the stored data", function()
		local allow = true
		local store = helpers.make_store(hook, scheduler, {
			predicate = function()
				return allow
			end,
		})
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(5)):unwrap()
			profile:save():unwrap()
		end)

		allow = false
		helpers.sync(scheduler, function()
			profile:update(helpers.set(9)):unwrap()
		end)
		local before = writes "k"
		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:save()
			end),
			"predicate_failed"
		)
		CHECK(err.key == "k" and err.op == "save" and err.profile == profile)
		CHECK(err.data.coins == 5)

		-- nothing written, and the rejection is not a lost lock
		CHECK(writes "k" == before + 1)
		local record = helpers.record(hook, "k")
		CHECK(record.data.coins == 5 and record.lock ~= nil)
		CHECK(profile.open and profile.is_locked)
		CHECK(profile:get_data().coins == 9)

		-- the lock is still ours: the next save goes through once it passes again
		allow = true
		helpers.sync(scheduler, function()
			profile:save():unwrap()
		end)
		CHECK(helpers.record(hook, "k").data.coins == 9)
	end)

	CASE("release and readquire are rejected, leaving the profile usable", function()
		local allow = true
		local store = helpers.make_store(hook, scheduler, {
			predicate = function()
				return allow
			end,
		})
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)

		allow = false
		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:release()
			end),
			"predicate_failed"
		)
		CHECK(err.op == "save" and err.profile == profile)
		CHECK(profile.open and profile.is_locked)
		CHECK(helpers.record(hook, "k").lock ~= nil)

		allow = true
		helpers.sync(scheduler, function()
			profile:release():unwrap()
		end)
		CHECK(not profile.is_locked and helpers.record(hook, "k").lock == nil)

		allow = false
		local readquired = helpers.err(
			helpers.run(scheduler, function()
				return profile:readquire()
			end),
			"predicate_failed"
		)
		CHECK(readquired.op == "load" and readquired.profile == nil)
		CHECK(profile.open and not profile.is_locked)
		CHECK(helpers.record(hook, "k").lock == nil)

		allow = true
		helpers.sync(scheduler, function()
			profile:readquire():unwrap()
		end)
		CHECK(profile.is_locked)
	end)

	CASE("unload warns and leaves the lock to expire when the predicate rejects it", function()
		local allow = true
		local store = helpers.make_store(hook, scheduler, {
			predicate = function()
				return allow
			end,
		})
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)

		allow = false
		local closed = false
		profile:on_closed(function()
			closed = true
		end)
		helpers.sync(scheduler, function()
			profile:unload()
		end)

		CHECK(not profile.open and closed)
		CHECK(helpers.record(hook, "k").lock ~= nil)
		CHECK(#hook.warnings == 1)
		CHECK(string.find(hook.warnings[1], "predicate rejected", 1, true) ~= nil)
	end)

	CASE("a lockless fetch is rejected and the profile stays open", function()
		hook.data[helpers.STORE] = { k = { data = { coins = -1 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler, { predicate = non_negative })
		local profile = store:get_lockless("k", {})

		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:fetch()
			end),
			"predicate_failed"
		)
		CHECK(err.key == "k" and err.op == "fetch" and err.profile == profile)
		CHECK(err.data.coins == -1)
		CHECK(profile.open and not profile.fetched)
		CHECK(writes "k" == 0)
	end)

	CASE("a lockless save is rejected, keeping the queue", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 1 }, migrations = {} } }
		local allow = false
		local store = helpers.make_store(hook, scheduler, {
			predicate = function()
				return allow
			end,
		})
		local profile = store:get_lockless("k", {})
		helpers.sync(scheduler, function()
			profile:update(helpers.add(4)):unwrap()
		end)

		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:save()
			end),
			"predicate_failed"
		)
		CHECK(err.key == "k" and err.op == "save" and err.profile == profile)
		CHECK(err.data.coins == 1)
		CHECK(profile.open and not profile.fetched)
		CHECK(#profile.queued_updates == 1)
		CHECK(writes "k" == 1 and helpers.record(hook, "k").data.coins == 1)

		allow = true
		helpers.sync(scheduler, function()
			profile:save():unwrap()
		end)
		CHECK(helpers.record(hook, "k").data.coins == 5)
	end)

	CASE("peek is rejected and a rejected refresh keeps the snapshot", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 2 }, migrations = {} } }
		local allow = true
		local store = helpers.make_store(hook, scheduler, {
			predicate = function()
				return allow
			end,
		})
		local peek = helpers.sync(scheduler, function()
			return store:peek "k"
		end)
		CHECK(peek:get_data().coins == 2)

		allow = false
		local err = helpers.err(
			helpers.run(scheduler, function()
				return peek:refresh()
			end),
			"predicate_failed"
		)
		CHECK(err.key == "k" and err.op == "peek" and err.profile == nil)
		CHECK(peek:get_data().coins == 2)

		CHECK(helpers.err(
			helpers.run(scheduler, function()
				return store:peek "k"
			end),
			"predicate_failed"
		).op == "peek")
		CHECK(writes "k" == 0)
	end)

	CASE("a transaction aborts when the predicate rejects a participant", function()
		local allow = true
		local store = helpers.make_store(hook, scheduler, {
			predicate = function(_: Data?, key: string)
				return allow or key ~= "b"
			end,
		})
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		local b = helpers.sync(scheduler, function()
			return store:load("b", {})
		end)

		allow = false
		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:transaction({ a, b }, function(_)
					return { { coins = 1 }, { coins = 2 } }
				end)
			end),
			"tx_aborted"
		)
		CHECK(err.cause ~= nil and err.cause.type == "predicate_failed")
		CHECK(err.cause.key == "b" and err.cause.op == "save")
		CHECK(a:get_data().coins == 0 and b:get_data().coins == 0)
		CHECK(helpers.record(hook, "b").data == nil)
	end)

	CASE("a predicate that throws propagates and is not retried as a storage failure", function()
		local store = helpers.make_store(hook, scheduler, {
			retry_attempts = 3,
			predicate = function(): boolean
				error "predicate exploded"
			end,
		})

		local load = helpers.run(scheduler, function()
			return store:load("k", {})
		end)
		helpers.failed(load, "predicate exploded")
		CHECK(writes "k" == 1)
		CHECK(store.profiles.k == nil and helpers.record(hook, "k") == nil)

		local lockless = store:get_lockless("l", {})
		helpers.failed(
			helpers.run(scheduler, function()
				return lockless:save()
			end),
			"predicate exploded"
		)
		CHECK(writes "l" == 1 and lockless.open)

		helpers.failed(
			helpers.run(scheduler, function()
				return store:peek "p"
			end),
			"predicate exploded"
		)
	end)
end)

return plan
