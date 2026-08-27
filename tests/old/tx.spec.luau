--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH
local CHECK = assert

type Data = helpers.Data
type Profile = dataforge.Profile<Data>

local scheduler: dataforge.Scheduler
local hook: dataforge.MemoryHook

-- loads "a" (100 coins) and "b" (0 coins) in a fresh store and saves both
local function setup(overrides: { [string]: any }?): (dataforge.Store<Data>, Profile, Profile)
	local store = helpers.make_store(hook, overrides)
	local _ = store
	local a, b
	helpers.sync(scheduler, function()
		a = store:load "a"
		b = store:load "b"
		a:update(function()
			return { coins = 100 }
		end)
		a:save()
		b:save()
	end)
	return store, a, b
end

local function transfer(a: Profile, b: Profile, amount: number)
	return function(ctx: dataforge.TxContext): boolean?
		local from: Data, to: Data = ctx:get(a), ctx:get(b)
		if from.coins < amount then
			return false
		end
		ctx:set(a, { coins = from.coins - amount })
		ctx:set(b, { coins = to.coins + amount })
		return nil
	end
end

local function only_marker(): (string, any)
	local markers = helpers.markers(hook)
	CHECK(helpers.count(markers) == 1, `expected exactly one marker, got {helpers.count(markers)}`)
	for id, value in markers do
		return id, value
	end
	error "unreachable"
end

TEST("transactions", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)

	CASE("commits both keys and cleans up on the next save", function()
		local store, a, b = setup()
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		CHECK(ok == true)
		CHECK(a:get().coins == 70 and b:get().coins == 30)
		CHECK(table.isfrozen(a:get() :: any))

		-- phase 1 left `pending` on both records, phase 2 wrote the marker
		local ra, rb = helpers.record(hook, "a"), helpers.record(hook, "b")
		CHECK(ra.data.coins == 100 and ra.pending.data.coins == 70)
		CHECK(rb.data.coins == 0 and rb.pending.data.coins == 30)
		local id, value = only_marker()
		CHECK(ra.pending.tx == id and rb.pending.tx == id)
		CHECK(value == "committed")

		-- next autosave writes clean records and the marker is garbage collected
		scheduler.step(30)
		ra, rb = helpers.record(hook, "a"), helpers.record(hook, "b")
		CHECK(ra.pending == nil and ra.data.coins == 70)
		CHECK(rb.pending == nil and rb.data.coins == 30)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
	end)

	CASE("returning false aborts without touching storage", function()
		local store, a, b = setup()
		local before = #hook.ops
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 500))
		end)
		CHECK(ok == false)
		CHECK(a:get().coins == 100 and b:get().coins == 0)
		CHECK(#hook.ops == before)
	end)

	CASE("a single changed key is a plain update (no marker)", function()
		local store, a, b = setup()
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, b }, function(ctx)
				ctx:set(a, { coins = 1 })
				ctx:set(b, ctx:get(b))
				return nil
			end)
		end)
		CHECK(ok == true)
		CHECK(a:get().coins == 1)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
		CHECK(a.dirty == true and b.dirty == false)
	end)

	CASE("touching a profile outside the transaction is rejected", function()
		local store, a, b = setup()
		local c = helpers.sync(scheduler, function()
			return store:load "c"
		end)
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, function(ctx)
				ctx:set(c, { coins = 1 })
				return nil
			end)
		end)
		CHECK(handle.done and not handle.ok)
		CHECK(a:get().coins == 100 and b:get().coins == 0)
		-- mutexes released
		CHECK(not a.mutex:is_locked() and not b.mutex:is_locked())
	end)

	CASE("a phase-1 failure aborts and nothing changes", function()
		local store, a, b = setup { retry_attempts = 1 }
		hook:fail_next(helpers.STORE, "b", "update_async", "before")
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		CHECK(handle.done and not handle.ok)
		CHECK(string.find(tostring(handle.result), "aborted") ~= nil, tostring(handle.result))
		CHECK(a:get().coins == 100 and b:get().coins == 0)

		local _, value = only_marker()
		CHECK(value == "aborted")
		CHECK(helpers.record(hook, "a").pending ~= nil) -- prepared, not yet cleaned
		CHECK(helpers.record(hook, "b").pending == nil)
		CHECK(a:is_open() and b:is_open())

		scheduler.step(30)
		CHECK(helpers.record(hook, "a").pending == nil)
		CHECK(helpers.record(hook, "a").data.coins == 100)
	end)

	CASE("a phase-1 write with unknown outcome aborts safely", function()
		local store, a, b = setup { retry_attempts = 1 }
		hook:fail_next(helpers.STORE, "b", "update_async", "after")
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		CHECK(handle.done and not handle.ok)
		CHECK(a:get().coins == 100 and b:get().coins == 0)
		-- b's pending actually landed, but the marker says aborted
		CHECK(helpers.record(hook, "b").pending ~= nil)
		local _, value = only_marker()
		CHECK(value == "aborted")

		-- server dies; another server loads both keys -> old data everywhere
		helpers.kill(a)
		helpers.kill(b)
		scheduler.step(61)
		local other = helpers.make_store(hook)
		local a2 = helpers.sync(scheduler, function()
			return other:load "a"
		end)
		local b2 = helpers.sync(scheduler, function()
			return other:load "b"
		end)
		CHECK(a2:get().coins == 100 and b2:get().coins == 0)
	end)

	CASE("crash after phase 1 but before the marker resolves to aborted", function()
		local store, a, b = setup { retry_attempts = 1 }
		hook.latency = 1
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		scheduler.step(1) -- a prepared
		scheduler.step(1) -- b prepared, marker write in flight
		CHECK(not handle.done)
		CHECK(helpers.record(hook, "a").pending ~= nil and helpers.record(hook, "b").pending ~= nil)
		CHECK(helpers.count(helpers.markers(hook)) == 0)

		-- the coordinator dies mid-flight
		coroutine.close(handle.thread :: thread)
		helpers.kill(a)
		helpers.kill(b)
		hook.latency = 0

		scheduler.step(61)
		local other = helpers.make_store(hook)
		local a2 = helpers.sync(scheduler, function()
			return other:load "a"
		end)
		local b2 = helpers.sync(scheduler, function()
			return other:load "b"
		end)
		CHECK(a2:get().coins == 100 and b2:get().coins == 0)
		local _, value = only_marker()
		CHECK(value == "aborted")
		-- clean records on the next save
		scheduler.step(30)
		CHECK(helpers.record(hook, "a").pending == nil)
		CHECK(helpers.record(hook, "b").pending == nil)
	end)

	CASE("crash after commit resolves to the new data on reload", function()
		local store, a, b = setup()
		helpers.sync(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		-- die before the clean autosave
		helpers.kill(a)
		helpers.kill(b)
		scheduler.step(61)
		local other = helpers.make_store(hook)
		local a2 = helpers.sync(scheduler, function()
			return other:load "a"
		end)
		local b2 = helpers.sync(scheduler, function()
			return other:load "b"
		end)
		CHECK(a2:get().coins == 70 and b2:get().coins == 30)
		scheduler.step(30)
		CHECK(helpers.record(hook, "a").data.coins == 70 and helpers.record(hook, "a").pending == nil)
		CHECK(helpers.record(hook, "b").data.coins == 30 and helpers.record(hook, "b").pending == nil)
		-- the coordinator died, so nobody garbage-collects the marker; it stays (harmless)
		local _, value = only_marker()
		CHECK(value == "committed")
	end)

	CASE("a marker write with unknown outcome freezes participants until resolved", function()
		local store, a, b = setup { retry_attempts = 1 }
		hook:fail_next(helpers.TX_STORE, "*", "update_async", "after")
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		CHECK(not handle.done)
		-- the marker landed as committed, but the coordinator does not know yet
		local _, value = only_marker()
		CHECK(value == "committed")
		CHECK(a:get().coins == 100)

		-- a save on a participant must wait for the outcome instead of writing old data
		local save = helpers.run(scheduler, function()
			a:save()
		end)
		CHECK(not save.done)

		scheduler.step(1) -- settle retries and learns "committed"
		CHECK(handle.done and handle.ok and handle.result == true, tostring(handle.result))
		CHECK(a:get().coins == 70 and b:get().coins == 30)
		CHECK(save.done and save.ok, tostring(save.result))
		CHECK(helpers.record(hook, "a").data.coins == 70)
	end)

	CASE("a lost lock during phase 1 aborts and closes that profile", function()
		local store, a, b = setup { retry_attempts = 1 }
		-- someone else steals b's lock behind our back
		local thief = helpers.make_store(hook)
		hook.data[helpers.STORE].b.lock = nil
		helpers.sync(scheduler, function()
			return thief:load "b"
		end)

		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 30))
		end)
		CHECK(handle.done and not handle.ok)
		CHECK(string.find(tostring(handle.result), "lock lost") ~= nil, tostring(handle.result))
		CHECK(not b:is_open())
		CHECK(a:is_open())
		CHECK(a:get().coins == 100)
		local _, value = only_marker()
		CHECK(value == "aborted")
	end)

	CASE("concurrent transactions over the same profiles serialize", function()
		local store, a, b = setup()
		hook.latency = 1
		local first = helpers.run(scheduler, function()
			return dataforge.transaction({ a, b }, transfer(a, b, 10))
		end)
		local second = helpers.run(scheduler, function()
			return dataforge.transaction({ b, a }, transfer(a, b, 20))
		end)
		CHECK(not first.done and not second.done)
		scheduler.step(10)
		CHECK(first.done and first.ok and first.result == true, tostring(first.result))
		CHECK(second.done and second.ok and second.result == true, tostring(second.result))
		CHECK(a:get().coins == 70 and b:get().coins == 30)
	end)

	CASE("spans stores: marker lives in the first store's tx store and reload resolves it", function()
		local store, a, _ = setup()
		local other = dataforge.create_store { name = "Guilds", template = { coins = 0 } :: Data, hook = hook }
		local g = helpers.sync(scheduler, function()
			return other:load "g1"
		end)
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, g }, transfer(a, g, 40))
		end)
		CHECK(ok == true)
		CHECK(a:get().coins == 60 and g:get().coins == 40)

		-- "Guilds" < "PlayerData": the marker is in Guilds/tx, both pendings point there
		local ra, rg = helpers.record(hook, "a"), hook:dump("Guilds", "g1")
		CHECK(ra.pending.tx_store == "Guilds/tx" and rg.pending.tx_store == "Guilds/tx")
		CHECK(helpers.count(helpers.markers(hook)) == 0)
		local markers = hook.data["Guilds/tx"]
		CHECK(markers[ra.pending.tx] == "committed")

		-- die before cleaning; a fresh server resolves the cross-store pending
		helpers.kill(a)
		helpers.kill(g)
		scheduler.step(61)
		local again = helpers.make_store(hook)
		local a2 = helpers.sync(scheduler, function()
			return again:load "a"
		end)
		CHECK(a2:get().coins == 60)
		local _ = store
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
return nil
