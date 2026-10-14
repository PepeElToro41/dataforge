--!strict

local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

local scheduler: helpers.Scheduler
local hook: helpers.Hook

--[[
	Per-acquisition session locks: every `load` / `readquire` stamps its own
	`{job_id}#{n}` on the record, so two sessions of one key on the same server
	contend through the record like sessions on different servers do.
]]
TEST("session locks (per acquisition)", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("a rejoin on the same server waits for the leaving session's last write", function()
		local store = helpers.make_store(hook, scheduler)
		local first = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			first:update(helpers.set(7)):unwrap()
		end)

		-- the release write is in flight for a tick: the window a player who
		-- leaves and rejoins the same server lands in
		hook.latency = 1
		local unload = helpers.run(scheduler, function()
			first:unload()
		end)
		CHECK(not unload.done)
		CHECK(not first.open)
		CHECK(store:get_loaded "k1" == nil, "a closing profile leaves the registry before its final write")

		local rejoin = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(not rejoin.done, "the rejoin waits on the record lock instead of failing already_loaded")

		helpers.tick(scheduler, 5)
		helpers.finished(unload, "unload")
		local second = helpers.finished(rejoin, "rejoin")

		CHECK(second ~= first)
		CHECK(second:get_data().coins == 7, "the rejoin includes the first session's final write")
		CHECK(second.lock_id ~= first.lock_id)
		CHECK(store:get_loaded "k1" == second)
		CHECK(helpers.record(hook, "k1").lock.id == second.lock_id)

		hook.latency = 0
		helpers.sync(scheduler, function()
			second:unload()
		end)
	end)

	CASE("the late unregister of a closing profile does not evict the new one", function()
		local store = helpers.make_store(hook, scheduler)
		local first = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)

		hook.latency = 1
		local unload = helpers.run(scheduler, function()
			first:unload()
		end)
		local rejoin = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.tick(scheduler, 5)
		helpers.finished(unload, "unload")
		local second = helpers.finished(rejoin, "rejoin")

		-- `first` fired `closed` (its safety-net unregister) after `second` was
		-- registered: the identity guard must have kept `second`
		CHECK(store:get_loaded "k1" == second)

		hook.latency = 0
		helpers.sync(scheduler, function()
			second:unload()
		end)
	end)

	CASE("two sequential acquisitions of one key get different lock ids", function()
		local store = helpers.make_store(hook, scheduler)
		local first = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local first_id = first.lock_id
		CHECK(helpers.locked_by(helpers.record(hook, "k1").lock, hook))
		CHECK(helpers.record(hook, "k1").lock.id == first_id)
		-- `{job_id}#{n}`: `#` keeps profile locks out of the transaction id
		-- namespace (`{job_id}-{n}`), which lockless writes compare by id
		CHECK(string.match(first_id, `^{hook.job_id()}#%d+$`) ~= nil, first_id)

		helpers.sync(scheduler, function()
			first:unload()
		end)
		CHECK(helpers.record(hook, "k1").lock == nil)

		local second = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(second.lock_id ~= first_id)
		CHECK(helpers.record(hook, "k1").lock.id == second.lock_id)

		helpers.sync(scheduler, function()
			second:unload()
		end)
	end)

	CASE("saves and autosaves re-stamp the same lock id", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local id = profile.lock_id

		helpers.sync(scheduler, function()
			profile:update(helpers.set(1)):unwrap()
			profile:save():unwrap()
		end)
		CHECK(profile.lock_id == id and helpers.record(hook, "k1").lock.id == id)

		helpers.sync(scheduler, function()
			profile:update(helpers.set(2)):unwrap()
		end)
		scheduler.step(30) -- autosave
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 2, "autosave did not land")
		CHECK(profile.lock_id == id and record.lock.id == id)
		CHECK(record.lock.expires == 90, "the lock is refreshed, not replaced")

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("readquire mints a new lock id", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local id = profile.lock_id

		helpers.sync(scheduler, function()
			profile:release():unwrap()
		end)
		CHECK(helpers.record(hook, "k1").lock == nil)
		CHECK(profile.lock_id == id, "a released profile keeps its (unusable) id until readquire")

		helpers.sync(scheduler, function()
			profile:readquire():unwrap()
		end)
		CHECK(profile.lock_id ~= id)
		CHECK(helpers.record(hook, "k1").lock.id == profile.lock_id)

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("a stale session on the same server cannot write over a newer acquisition", function()
		-- two stores over one hook: same job id, same storage, two acquisitions
		local a = helpers.make_store(hook, scheduler, { autosave_interval = 100 })
		local b = helpers.make_store(hook, scheduler, { autosave_interval = 100 })

		local stale = helpers.sync(scheduler, function()
			return a:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			stale:update(helpers.set(1)):unwrap()
			stale:save():unwrap()
		end)

		-- nothing refreshes the lock for a full ttl, so the next acquisition steals it
		helpers.tick(scheduler, 61)
		local fresh = helpers.sync(scheduler, function()
			return b:load("k1", {})
		end)
		CHECK(fresh.lock_id ~= stale.lock_id)
		CHECK(fresh:get_data().coins == 1)
		local before = helpers.record(hook, "k1")

		helpers.sync(scheduler, function()
			stale:update(helpers.set(99)):unwrap()
		end)
		local err = helpers.err(
			helpers.run(scheduler, function()
				return stale:save()
			end),
			"lock_lost"
		)
		CHECK(err.lock ~= nil and err.lock.id == fresh.lock_id)
		CHECK(not stale.open and a:get_loaded "k1" == nil)

		local after = helpers.record(hook, "k1")
		CHECK(after.data.coins == before.data.coins, "the stale session must not write")
		CHECK(after.lock.id == fresh.lock_id)
		CHECK(b:get_loaded "k1" == fresh)

		helpers.sync(scheduler, function()
			fresh:unload()
		end)
	end)

	CASE("a second load of an open profile is still already_loaded", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:load("k1", {})
			end),
			"already_loaded"
		)
		CHECK(err.key == "k1" and profile.open)
		CHECK(store:get_loaded "k1" == profile)

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("close unloads every profile while they detach from the registry", function()
		local store = helpers.make_store(hook, scheduler)
		local keys = { "k1", "k2", "k3", "k4" }
		local profiles = {}
		for _, key in keys do
			local profile = helpers.sync(scheduler, function()
				return store:load(key, {})
			end)
			helpers.sync(scheduler, function()
				profile:update(helpers.set(5)):unwrap()
			end)
			table.insert(profiles, profile)
		end
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
			g:update(helpers.set(3)):unwrap()
		end)

		-- detaching mutates `store.profiles` while `close` iterates it
		hook.latency = 1
		local closing = helpers.run(scheduler, function()
			store:close()
		end)
		helpers.tick(scheduler, 10)
		helpers.finished(closing, "close")

		for _, profile in profiles do
			CHECK(not profile.open, `{profile.key} was not unloaded`)
			local record = helpers.record(hook, profile.key)
			CHECK(record.lock == nil and record.data.coins == 5, `{profile.key} did not write on close`)
		end
		CHECK(not g.open and helpers.record(hook, "g").data.coins == 3)
		CHECK(helpers.count(store.profiles) == 0 and helpers.count(store.lockless_profiles) == 0)
	end)
end)

return plan
