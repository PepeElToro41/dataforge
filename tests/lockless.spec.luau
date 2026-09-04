--!strict

local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

local scheduler: helpers.Scheduler
local hook: helpers.Hook

local add = helpers.add

local function writes(key: string): number
	return helpers.ops(hook, helpers.STORE, key, "update_async")
end

TEST("lockless profile", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("data errors until fetched; fetch reads without writing", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		CHECK(not g.fetched)
		local err = helpers.threw(function()
			return g:get_data()
		end, "not_fetched")
		CHECK(err.profile == g and string.find(tostring(err), "not been fetched") ~= nil)
		local data = helpers.sync(scheduler, function()
			return g:fetch()
		end)
		CHECK(g.fetched and data.coins == 0 and g:get_data() == data)
		CHECK(table.isfrozen(data :: any))
		CHECK(helpers.ops(hook, helpers.STORE, "g", "get_async") == 1 and writes "g" == 0)
		CHECK(helpers.record(hook, "g") == nil)
	end)

	CASE("fetch reads what is in storage", function()
		hook.data[helpers.STORE] = { g = { data = { coins = 8 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
		end)
		CHECK(g:get_data().coins == 8)
	end)

	CASE("updates before fetch are queued blind", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local calls = 0
		local ok = helpers.sync(scheduler, function()
			return g:update(function(data)
				calls += 1
				return add(3)(data)
			end)
		end)
		CHECK(ok == true and calls == 0)
		CHECK(#g.queued_updates == 1 and not g.fetched)
		CHECK(not pcall(g.get_data, g))
		-- fetch replays the queue over the stored data
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
		end)
		CHECK(calls == 1 and g:get_data().coins == 3)
		CHECK(#g.queued_updates == 1) -- still waiting for a save
	end)

	CASE("updates after fetch advance the local data and fire change", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local changes: { { any } } = {}
		g:on_change(function(new: helpers.Data, old: helpers.Data?)
			table.insert(changes, { new.coins :: any, if old then old.coins else "nil" })
		end)
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
			g:update(add(5)):unwrap()
			g:update(add(7)):unwrap()
		end)
		CHECK(g:get_data().coins == 12 and table.isfrozen(g:get_data() :: any))
		CHECK(#g.queued_updates == 2)
		CHECK(#changes == 3 and changes[2][1] == 5 and changes[2][2] == 0 and changes[3][1] == 12)
		-- false / nil are not queued
		for _, value in { false :: any, "nil" } do
			value = if value == "nil" then nil else value
			local ok = helpers.sync(scheduler, function()
				return g:update(function()
					return value :: any
				end)
			end)
			CHECK(ok == false)
		end
		CHECK(#g.queued_updates == 2 and #changes == 3)
	end)

	CASE("the flush loop writes the queue once and an idle profile costs nothing", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		scheduler.step(120)
		CHECK(#hook.ops == 0)
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
			g:update(add(5)):unwrap()
			g:update(add(7)):unwrap()
		end)
		scheduler.step(29)
		CHECK(writes "g" == 0)
		scheduler.step(1)
		CHECK(writes "g" == 1)
		local record = helpers.record(hook, "g")
		CHECK(record.data.coins == 12 and record.lock == nil and record.pending == nil)
		CHECK(#g.queued_updates == 0 and g:get_data().coins == 12)
		scheduler.step(120)
		CHECK(writes "g" == 1)
	end)

	CASE("save fires on_save first so hook updates land in that write", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local saves = 0
		g:on_save(function()
			saves += 1
			g:update(add(1)):unwrap()
		end)
		helpers.sync(scheduler, function()
			g:save():unwrap()
		end)
		CHECK(saves == 1)
		CHECK(helpers.record(hook, "g").data.coins == 1)
		CHECK(g.fetched and g:get_data().coins == 1)
	end)

	CASE("save before fetch marks the profile fetched with what landed", function()
		hook.data[helpers.STORE] = { g = { data = { coins = 10 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:update(add(3)):unwrap()
			g:save():unwrap()
		end)
		CHECK(g.fetched and g:get_data().coins == 13)
		CHECK(helpers.record(hook, "g").data.coins == 13)
		CHECK(helpers.ops(hook, helpers.STORE, "g", "get_async") == 0 and writes "g" == 1)
	end)

	CASE("queued updates replay on data another server changed", function()
		local store = helpers.make_store(hook, scheduler)
		local other = helpers.make_store(helpers.server(hook), scheduler)
		local g = store:get_lockless("g", {})
		local g2 = other:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
			g:update(add(10)):unwrap()
			g2:update(add(50)):unwrap()
			g2:save():unwrap()
		end)
		CHECK(g:get_data().coins == 10) -- local view lags
		helpers.sync(scheduler, function()
			g:save():unwrap()
		end)
		CHECK(g:get_data().coins == 60)
		CHECK(helpers.record(hook, "g").data.coins == 60)
		-- and a fetch on the other side sees it
		helpers.sync(scheduler, function()
			g2:fetch():unwrap()
		end)
		CHECK(g2:get_data().coins == 60)
	end)

	CASE("unload flushes only when something is queued, then rejects everything", function()
		local store = helpers.make_store(hook, scheduler)
		local idle = store:get_lockless("idle", {})
		helpers.sync(scheduler, function()
			idle:unload()
		end)
		CHECK(not idle.open and #hook.ops == 0)

		local g = store:get_lockless("g", {})
		local log: { string } = {}
		g:on_closing(function()
			CHECK(g.open)
			g:update(add(4)):unwrap()
			table.insert(log, "closing")
		end)
		g:on_closed(function()
			table.insert(log, "closed")
		end)
		helpers.sync(scheduler, function()
			g:unload()
		end)
		CHECK(table.concat(log, ",") == "closing,closed")
		CHECK(not g.open and store.lockless_profiles.g == nil)
		CHECK(helpers.record(hook, "g").data.coins == 4)
		local thrown = helpers.threw(function()
			return g:get_data()
		end, "profile_closed")
		CHECK(thrown.profile == g and thrown.reason == "unloaded")
		local rejected = helpers.err(
			helpers.run(scheduler, function()
				return g:update(add(1))
			end),
			"profile_closed"
		)
		CHECK(rejected.profile == g and rejected.reason == "unloaded")
		helpers.err(
			helpers.run(scheduler, function()
				return g:fetch()
			end),
			"profile_closed"
		)
		helpers.err(
			helpers.run(scheduler, function()
				return g:save()
			end),
			"profile_closed"
		)
		local ops = #hook.ops
		scheduler.step(120)
		CHECK(#hook.ops == ops)
	end)

	CASE("a session lock on the record rejects fetch, closes the profile and writes nothing", function()
		hook.data[helpers.STORE] = {
			g = { data = { coins = 1 }, migrations = {}, lock = { id = "other-server", expires = 60 } },
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local log: { string } = {}
		g:on_lock_lost(function()
			table.insert(log, "lock_lost")
		end)
		g:on_closed(function()
			table.insert(log, "closed")
		end)
		local before = helpers.record(hook, "g")
		local err = helpers.err(
			helpers.run(scheduler, function()
				return g:fetch()
			end),
			"profile_locked"
		)
		CHECK(err.profile == g and err.lock.id == "other-server" and err.lock.expires == 60)
		CHECK(string.find(tostring(err), "session locked", 1, true) ~= nil)
		CHECK(table.concat(log, ",") == "lock_lost,closed")
		CHECK(not g.open and store.lockless_profiles.g == nil)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "g")))
		CHECK(writes "g" == 0)
	end)

	CASE("a session lock on the record rejects save with a queue and writes nothing", function()
		hook.data[helpers.STORE] = {
			g = { data = { coins = 1 }, migrations = {}, lock = { id = "other-server", expires = 60 } },
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local lost = 0
		g:on_lock_lost(function()
			lost += 1
		end)
		helpers.sync(scheduler, function()
			g:update(add(5)):unwrap()
		end)
		local before = helpers.record(hook, "g")
		local err = helpers.err(
			helpers.run(scheduler, function()
				return g:save()
			end),
			"profile_locked"
		)
		CHECK(err.profile == g and err.lock.id == "other-server")
		CHECK(lost == 1 and not g.open)
		CHECK(#g.queued_updates == 1)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "g")))
	end)

	CASE("a queued dispatcher that throws fails the save with the raw error and keeps the queue", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:update(function()
				error "boom"
			end)
		end)
		CHECK(#g.queued_updates == 1)
		local save = helpers.run(scheduler, function()
			return g:save()
		end)
		helpers.failed(save, "boom")
		CHECK(type(save.result) == "string")
		-- the transform cancelled the write: one attempt, nothing retried, nothing stored
		CHECK(writes "g" == 1)
		CHECK(helpers.record(hook, "g") == nil)
		CHECK(g.open and not g.fetched and #g.queued_updates == 1)
		CHECK(not g._mutex:is_locked())
		-- the flush loop meets the same error and only warns
		local warnings = #hook.warnings
		scheduler.step(30)
		CHECK(#hook.warnings == warnings + 1)
		CHECK(string.find(hook.warnings[#hook.warnings], "boom", 1, true) ~= nil)
		CHECK(g.open)
	end)

	CASE("a session lock that appears after a successful save stops the flush loop from writing", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local lost = 0
		g:on_lock_lost(function()
			lost += 1
		end)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
			g:save():unwrap()
		end)
		CHECK(helpers.record(hook, "g").data.coins == 1)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
		end)
		-- another server session-locks the key now
		hook.data[helpers.STORE].g.lock = { id = "other-server", expires = 1000 }
		local before = helpers.record(hook, "g")
		scheduler.step(30) -- flush loop fires, is rejected, warns
		CHECK(lost == 1 and not g.open)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "g")))
		CHECK(store.lockless_profiles.g == nil)
		scheduler.step(120)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "g")))
	end)

	CASE("a real locked profile on another server locks the lockless one out", function()
		local locked_store = helpers.make_store(helpers.server(hook), scheduler)
		local locked = helpers.sync(scheduler, function()
			return locked_store:load("g", {})
		end)
		helpers.sync(scheduler, function()
			locked:update(helpers.set(3)):unwrap()
			locked:save():unwrap()
		end)
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local err = helpers.err(
			helpers.run(scheduler, function()
				return g:fetch()
			end),
			"profile_locked"
		)
		CHECK(err.lock.id == locked_store._hook.job_id())
		CHECK(not g.open)
		CHECK(
			helpers.record(hook, "g").data.coins == 3
				and helpers.record(hook, "g").lock.id == locked_store._hook.job_id()
		)
		CHECK(locked.open)
	end)

	CASE("an expired session lock is ignored and replaced", function()
		hook.data[helpers.STORE] = {
			g = { data = { coins = 1 }, migrations = {}, lock = { id = "dead-server", expires = 10 } },
		}
		local store = helpers.make_store(hook, scheduler)
		scheduler.step(11)
		local g = store:get_lockless("g", {})
		local lost = 0
		g:on_lock_lost(function()
			lost += 1
		end)
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		helpers.finished(fetch, "fetch over an expired session lock")
		CHECK(g:get_data().coins == 1)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
		end)
		local save = helpers.run(scheduler, function()
			g:save():unwrap()
		end)
		helpers.finished(save, "save over an expired session lock")
		CHECK(lost == 0 and g.open)
		local record = helpers.record(hook, "g")
		CHECK(record.data.coins == 2 and record.lock == nil)
	end)

	CASE("a live foreign transaction lock delays the write until it expires", function()
		hook.data[helpers.STORE] = {
			g = { data = { coins = 2 }, migrations = {}, lock = { id = "other-tx", expires = 10, tx = true } },
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		-- reads go through
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
		end)
		CHECK(g:get_data().coins == 2)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
		end)
		local save = helpers.run(scheduler, function()
			g:save():unwrap()
		end)
		CHECK(not save.done)
		scheduler.step(9)
		CHECK(not save.done)
		scheduler.step(1)
		helpers.finished(save)
		CHECK(g.open and g:get_data().coins == 3)
		local record = helpers.record(hook, "g")
		CHECK(record.data.coins == 3 and record.lock == nil)
	end)

	CASE("an expired transaction lock is written over at once", function()
		hook.data[helpers.STORE] = {
			g = { data = { coins = 2 }, migrations = {}, lock = { id = "other-tx", expires = 5, tx = true } },
		}
		local store = helpers.make_store(hook, scheduler)
		scheduler.step(6)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
			g:save():unwrap()
		end)
		CHECK(helpers.record(hook, "g").data.coins == 3 and helpers.record(hook, "g").lock == nil)
	end)

	CASE("a foreign pending without a marker is waited out, then aborted", function()
		hook.data[helpers.STORE] = {
			g = {
				data = { coins = 0 },
				migrations = {},
				pending = { tx_id = "dead-1", store = helpers.TX_STORE, expires = 60, data = { coins = 99 } },
			},
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		CHECK(not fetch.done)
		scheduler.step(59)
		CHECK(not fetch.done)
		scheduler.step(1)
		helpers.finished(fetch)
		CHECK(g:get_data().coins == 0)
		CHECK(helpers.markers(hook)["dead-1"] == "aborted")
		-- the record still carries the pending until a write folds it
		CHECK(helpers.record(hook, "g").pending ~= nil)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
			g:save():unwrap()
		end)
		local record = helpers.record(hook, "g")
		CHECK(record.pending == nil and record.data.coins == 1)
	end)

	CASE("a foreign pending with a committed marker is folded in", function()
		hook.data[helpers.TX_STORE] = { ["dead-1"] = "committed" }
		hook.data[helpers.STORE] = {
			g = {
				data = { coins = 0 },
				migrations = {},
				pending = { tx_id = "dead-1", store = helpers.TX_STORE, expires = 60, data = { coins = 99 } },
			},
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		-- the marker is already decided, but a fresh pending is still given its grace period
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		scheduler.step(60)
		helpers.finished(fetch)
		CHECK(g:get_data().coins == 99)
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
			g:save():unwrap()
		end)
		local record = helpers.record(hook, "g")
		CHECK(record.pending == nil and record.data.coins == 100)
	end)

	CASE("a save that meets a fresh foreign pending resolves it and writes on top", function()
		hook.data[helpers.STORE] = {
			g = {
				data = { coins = 0 },
				migrations = {},
				pending = { tx_id = "dead-1", store = helpers.TX_STORE, expires = 5, data = { coins = 99 } },
			},
		}
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			g:update(add(1)):unwrap()
		end)
		local save = helpers.run(scheduler, function()
			g:save():unwrap()
		end)
		CHECK(not save.done)
		scheduler.step(5)
		helpers.finished(save)
		CHECK(g:get_data().coins == 1)
		CHECK(helpers.record(hook, "g").pending == nil)
		CHECK(helpers.markers(hook)["dead-1"] == "aborted")
	end)

	CASE("update waits for an in-flight save; wait_settled returns once idle", function()
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		hook.latency = 1
		local save = helpers.run(scheduler, function()
			g:update(add(1)):unwrap()
			g:save():unwrap()
		end)
		local update = helpers.run(scheduler, function()
			return g:update(add(10))
		end)
		local settled = helpers.run(scheduler, function()
			g:wait_settled()
		end)
		CHECK(not save.done and not update.done and not settled.done)
		scheduler.step(1)
		helpers.finished(save)
		helpers.finished(update)
		helpers.finished(settled)
		CHECK(g:get_data().coins == 11)
		CHECK(helpers.record(hook, "g").data.coins == 1)
		CHECK(#g.queued_updates == 1)
	end)
end)

return plan
