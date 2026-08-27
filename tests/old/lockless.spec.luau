--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH
local CHECK = assert

type Data = helpers.Data
type Lockless = dataforge.LocklessProfile<Data>

local scheduler: dataforge.Scheduler
local hook: dataforge.MemoryHook

local function ops(key: string, op: string?): number
	local n = 0
	for _, entry in hook.ops do
		if entry.store == helpers.STORE and entry.key == key and (op == nil or entry.op == op) then
			n += 1
		end
	end
	return n
end

local function add(amount: number)
	return function(data: Data): Data
		return { coins = data.coins + amount }
	end
end

TEST("lockless profiles", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)

	CASE("get errors until fetched; fetch reads without writing", function()
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		CHECK(not g:is_fetched())
		CHECK(not pcall(g.get, g))
		local data = helpers.sync(scheduler, function()
			return g:fetch()
		end)
		CHECK(g:is_fetched() and data.coins == 0 and g:get() == data)
		CHECK(ops("g", "get_async") == 1 and ops("g", "update_async") == 0)
		CHECK(helpers.record(hook, "g") == nil)
	end)

	CASE("updates are queued and flushed in one update_async; idle costs nothing", function()
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			g:fetch()
			g:update(add(5))
			g:update(add(7))
		end)
		CHECK(g:get().coins == 12)
		CHECK(g:has_pending_changes())
		CHECK(ops("g", "update_async") == 0)
		scheduler.step(30)
		CHECK(ops("g", "update_async") == 1)
		CHECK(helpers.record(hook, "g").data.coins == 12)
		CHECK(helpers.record(hook, "g").lock == nil)
		CHECK(not g:has_pending_changes())
		scheduler.step(120)
		CHECK(ops "g" == 2) -- the fetch and the single flush
	end)

	CASE("apply before fetch marks the profile fetched with what landed", function()
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			g:update(add(3))
		end)
		CHECK(not g:is_fetched())
		local data = helpers.sync(scheduler, function()
			return g:apply()
		end)
		CHECK(g:is_fetched() and data.coins == 3 and g:get().coins == 3)
	end)

	CASE("queued transforms replay on data changed by another server", function()
		local store = helpers.make_store(hook)
		local other = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		local g2: Lockless = other:load_lockless "g"
		helpers.sync(scheduler, function()
			g:fetch()
			g:update(add(10))
			g2:update(add(50))
			g2:apply()
		end)
		CHECK(g:get().coins == 10) -- local view lags
		helpers.sync(scheduler, function()
			g:apply()
		end)
		CHECK(g:get().coins == 60)
		CHECK(helpers.record(hook, "g").data.coins == 60)
	end)

	CASE("a live session lock blocks fetch and apply; an expired one does not", function()
		local store = helpers.make_store(hook)
		local locked = helpers.sync(scheduler, function()
			return store:load "g"
		end)
		helpers.sync(scheduler, function()
			locked:update(function()
				return { coins = 1 }
			end)
			locked:save()
		end)
		local lost = 0
		local other = helpers.make_store(hook, {
			on_lock_lost = function(profile)
				lost += 1
			end,
		})
		local g: Lockless = other:load_lockless "g"
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		CHECK(fetch.done and not fetch.ok)
		CHECK(string.find(tostring(fetch.result), "session locked") ~= nil, tostring(fetch.result))
		CHECK(lost == 1)
		helpers.sync(scheduler, function()
			g:update(add(1))
		end)
		local apply = helpers.run(scheduler, function()
			return g:apply()
		end)
		CHECK(apply.done and not apply.ok)
		CHECK(lost == 2 and g:is_open())
		CHECK(g:has_pending_changes()) -- queue kept

		helpers.kill(locked)
		scheduler.step(61)
		helpers.sync(scheduler, function()
			g:apply()
		end)
		CHECK(g:get().coins == 2)
		CHECK(helpers.record(hook, "g").lock == nil)
	end)

	CASE("mixes with locked profiles in a transaction: queue and pending land together", function()
		local store = helpers.make_store(hook)
		local a = helpers.sync(scheduler, function()
			return store:load "a"
		end)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			a:update(function()
				return { coins = 100 }
			end)
			g:fetch()
			g:update(add(1))
		end)
		local before = ops("g", "update_async")
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, g }, function(ctx)
				ctx:set(a, { coins = ctx:get(a).coins - 30 })
				ctx:set(g, { coins = ctx:get(g).coins + 30 })
				return nil
			end)
		end)
		CHECK(ok == true)
		-- begin (flush + tx lock) and prepare (pending + unlock)
		CHECK(ops("g", "update_async") == before + 2)
		CHECK(a:get().coins == 70 and g:get().coins == 31)
		CHECK(not g.tx_locked)
		CHECK(not g:has_pending_changes())

		local rg = helpers.record(hook, "g")
		CHECK(rg.data.coins == 1 and rg.pending.data.coins == 31 and rg.lock == nil)
		local ra = helpers.record(hook, "a")
		CHECK(ra.pending.data.coins == 70)
		CHECK(helpers.markers(hook)[rg.pending.tx] == "committed")

		-- next flush folds the pending and the marker is garbage collected
		scheduler.step(30)
		rg = helpers.record(hook, "g")
		CHECK(rg.pending == nil and rg.data.coins == 31)
		CHECK(helpers.record(hook, "a").pending == nil)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
		scheduler.step(60)
		CHECK(ops("g", "update_async") == before + 3)
	end)

	CASE("the transaction snapshot is exact: no lockless profile needs a fetch first", function()
		local store = helpers.make_store(hook)
		local other = helpers.make_store(hook)
		local a = helpers.sync(scheduler, function()
			return store:load "a"
		end)
		local g: Lockless = store:load_lockless "g"
		local g2: Lockless = other:load_lockless "g"
		helpers.sync(scheduler, function()
			a:update(function()
				return { coins = 100 }
			end)
			g2:update(add(5))
			g2:apply()
		end)
		CHECK(not g:is_fetched())
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, g }, function(ctx)
				CHECK(ctx:get(g).coins == 5) -- what the other server wrote, not a stale view
				ctx:set(a, { coins = ctx:get(a).coins - 30 })
				ctx:set(g, { coins = ctx:get(g).coins + 30 })
				return nil
			end)
		end)
		CHECK(ok == true and g:is_fetched() and g:get().coins == 35)
	end)

	CASE("another server's flush waits for the transaction lock", function()
		local store = helpers.make_store(hook)
		local other = helpers.make_store(hook)
		local a = helpers.sync(scheduler, function()
			return store:load "a"
		end)
		local g: Lockless = store:load_lockless "g"
		local g2: Lockless = other:load_lockless "g"
		helpers.sync(scheduler, function()
			a:update(function()
				return { coins = 100 }
			end)
			g:update(add(1))
		end)

		hook.latency = 1
		local handle = helpers.run(scheduler, function()
			return dataforge.transaction({ a, g }, function(ctx)
				ctx:set(a, { coins = ctx:get(a).coins - 30 })
				ctx:set(g, { coins = ctx:get(g).coins + 30 })
				return nil
			end)
		end)
		scheduler.step(1) -- g's begin landed: queue flushed, tx lock held
		local rg = helpers.record(hook, "g")
		CHECK(rg.data.coins == 1 and dataforge.is_tx_lock(rg) and g.tx_locked)

		local flush = helpers.run(scheduler, function()
			g2:update(add(5))
			g2:apply()
		end)
		scheduler.step(1)
		CHECK(not flush.done) -- blocked by the tx lock, polling
		scheduler.step(3) -- a prepared, g prepared (lock released), marker written
		CHECK(handle.done and handle.ok and handle.result == true, tostring(handle.result))
		CHECK(helpers.record(hook, "g").lock == nil)
		hook.latency = 0

		-- g2 now sees the pending; it is fresh so it waits the grace period, then
		-- folds the committed data and its own change on top
		scheduler.step(70)
		CHECK(flush.done and flush.ok, tostring(flush.result))
		CHECK(g2:get().coins == 36)
		CHECK(helpers.record(hook, "g").data.coins == 36)
	end)

	CASE("a dead coordinator's transaction lock expires after tx_lock_ttl", function()
		hook.data[helpers.STORE] = {
			g = {
				data = { coins = 2 },
				migrations = {},
				lock = { id = "dead:tx", expires = 10, tx = true },
			},
		}
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			g:update(add(1))
		end)
		local apply = helpers.run(scheduler, function()
			return g:apply()
		end)
		CHECK(not apply.done)
		scheduler.step(9)
		CHECK(not apply.done)
		scheduler.step(2)
		CHECK(apply.done and apply.ok, tostring(apply.result))
		CHECK(g:get().coins == 3)
		CHECK(helpers.record(hook, "g").lock == nil)
	end)

	CASE("another server waits out a fresh pending, then honours the marker", function()
		local store = helpers.make_store(hook)
		local a = helpers.sync(scheduler, function()
			return store:load "a"
		end)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			a:update(function()
				return { coins = 100 }
			end)
			g:fetch()
			return dataforge.transaction({ a, g }, function(ctx)
				ctx:set(a, { coins = 70 })
				ctx:set(g, { coins = 30 })
				return nil
			end)
		end)
		-- server dies before folding the pending
		helpers.kill(a)
		helpers.kill(g)

		local other = helpers.make_store(hook)
		local g2: Lockless = other:load_lockless "g"
		local fetch = helpers.run(scheduler, function()
			return g2:fetch()
		end)
		CHECK(not fetch.done)
		scheduler.step(59)
		CHECK(not fetch.done)
		scheduler.step(2)
		CHECK(fetch.done and fetch.ok, tostring(fetch.result))
		CHECK(g2:get().coins == 30)

		-- and a write folds it into `data`
		helpers.sync(scheduler, function()
			g2:update(add(1))
			g2:apply()
		end)
		local rg = helpers.record(hook, "g")
		CHECK(rg.pending == nil and rg.data.coins == 31)
	end)

	CASE("a pending without a marker is aborted after the grace period", function()
		hook.data[helpers.STORE] = {
			g = {
				data = { coins = 0 },
				migrations = {},
				pending = { tx = "dead-1", tx_store = helpers.TX_STORE, at = 0, data = { coins = 99 } },
			},
		}
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			g:update(add(1))
		end)
		local apply = helpers.run(scheduler, function()
			return g:apply()
		end)
		CHECK(not apply.done)
		scheduler.step(61)
		CHECK(apply.done and apply.ok, tostring(apply.result))
		CHECK(g:get().coins == 1)
		CHECK(helpers.markers(hook)["dead-1"] == "aborted")
		local rg = helpers.record(hook, "g")
		CHECK(rg.pending == nil and rg.data.coins == 1)
	end)

	CASE("unload flushes the queue and unregisters", function()
		local store = helpers.make_store(hook)
		local g: Lockless = store:load_lockless "g"
		helpers.sync(scheduler, function()
			g:update(add(4))
			g:unload()
		end)
		CHECK(not g:is_open())
		CHECK(store:get_loaded "g" == nil)
		CHECK(helpers.record(hook, "g").data.coins == 4)
		CHECK(not pcall(function()
			g:update(add(1))
		end))
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
return nil
