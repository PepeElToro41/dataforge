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

--[[
	Pending-chaining: several async operations spawned in the same frame, with
	storage latency so every one of them yields. They must run in spawn order
	and nothing may deadlock: every handle finishes, and the scheduler queue is
	empty once the loops stop.

	Order is verified through effects (what each write landed, what each
	transform saw), not through completion order: a mutex hands over to the next
	waiter before the holder returns, so completion order is not meaningful.
]]

--- Asserts every handle finished successfully; returns what each produced by name.
local function all_done(handles: { [string]: helpers.Handle }): { [string]: any }
	local values = {}
	for name, handle in handles do
		values[name] = helpers.finished(handle, name)
	end
	return values
end

local function none_done(handles: { [string]: helpers.Handle })
	for name, handle in handles do
		CHECK(not handle.done, `{name} finished early`)
	end
end

--- Drives the scheduler until every loop has exited and asserts nothing is left queued.
local function drain()
	helpers.tick(scheduler, 200)
	CHECK(scheduler.pending() == 0, `{scheduler.pending()} threads still queued`)
end

local function run(fn: () -> ...any): helpers.Handle
	return helpers.run(scheduler, fn)
end

TEST("pending chaining", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("locked: update, save, update, save, unload in one frame land in order", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		hook.latency = 1
		local handles = {
			update1 = run(function()
				return profile:update(helpers.set(1))
			end),
			save1 = run(function()
				profile:save():unwrap()
			end),
			update2 = run(function()
				return profile:update(helpers.set(2))
			end),
			save2 = run(function()
				profile:save():unwrap()
			end),
			unload = run(function()
				profile:unload()
			end),
		}
		CHECK(handles.update1.done) -- nothing ahead of it: no yield
		CHECK(not handles.save1.done and not handles.update2.done and not handles.unload.done)
		CHECK(not profile.open) -- unload flips it right away

		scheduler.step(1) -- save1 lands with update1's data
		local record = helpers.record(hook, "k")
		CHECK(record.data.coins == 1 and record.lock ~= nil)
		CHECK(handles.save1.done and handles.update2.done and not handles.save2.done)
		scheduler.step(1) -- save2 lands with update2's data
		record = helpers.record(hook, "k")
		CHECK(record.data.coins == 2 and record.lock ~= nil)
		CHECK(handles.save2.done and not handles.unload.done)
		scheduler.step(1) -- release
		all_done(handles)
		record = helpers.record(hook, "k")
		CHECK(record.data.coins == 2 and record.lock == nil)
		CHECK(helpers.ops(hook, helpers.STORE, "k", "update_async") == 4) -- lock, save, save, release
		drain()
	end)

	CASE("locked: an update queued behind an in-flight save sees the saved data", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		hook.latency = 1
		local seen
		local handles = {
			update1 = run(function()
				return profile:update(helpers.set(7))
			end),
			save = run(function()
				profile:save():unwrap()
			end),
			update2 = run(function()
				return profile:update(function(data)
					seen = data.coins
					return helpers.add(1)(data)
				end)
			end),
		}
		CHECK(seen == nil)
		helpers.tick(scheduler, 3)
		all_done(handles)
		CHECK(seen == 7 and profile:get_data().coins == 8)
		CHECK(helpers.record(hook, "k").data.coins == 7)
		helpers.kill(profile)
		drain()
	end)

	CASE("load, wait_loaded and a chained update on the waiter", function()
		local store = helpers.make_store(hook, scheduler)
		hook.latency = 1
		local handles = {
			load = run(function()
				return store:load("k", {})
			end),
			wait = run(function()
				local profile = store:wait_loaded("k", {}):unwrap()
				profile:update(helpers.set(3)):unwrap()
				profile:save():unwrap()
				return profile
			end),
			wait2 = run(function()
				return store:wait_loaded("k", {})
			end),
		}
		none_done(handles)
		scheduler.step(1)
		CHECK(handles.load.done and handles.wait2.done and not handles.wait.done)
		scheduler.step(1)
		local values = all_done(handles)
		CHECK(values.wait == values.load and values.wait2 == values.load)
		CHECK(helpers.record(hook, "k").data.coins == 3)
		helpers.kill(values.load)
		drain()
	end)

	CASE("lockless: update, fetch, update, save, unload in one frame land in order", function()
		hook.data[helpers.STORE] = { g = { data = { coins = 10 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler)
		local g = store:get_lockless("g", {})
		hook.latency = 1
		local fetched
		local handles = {
			update1 = run(function()
				return g:update(helpers.add(1))
			end),
			fetch = run(function()
				fetched = g:fetch():unwrap()
			end),
			update2 = run(function()
				return g:update(helpers.add(2))
			end),
			save = run(function()
				g:save():unwrap()
			end),
			unload = run(function()
				g:unload()
			end),
		}
		CHECK(handles.update1.done and not handles.fetch.done and not handles.update2.done)
		scheduler.step(1) -- fetch lands: stored 10 + the first queued update
		CHECK(fetched.coins == 11)
		CHECK(handles.update2.done and (g :: any)._data.coins == 13 and not handles.save.done)
		scheduler.step(1) -- save lands with both updates; unload has nothing left
		all_done(handles)
		CHECK(helpers.record(hook, "g").data.coins == 13)
		CHECK(helpers.ops(hook, helpers.STORE, "g", "update_async") == 1)
		CHECK(not g.open)
		drain()
	end)

	CASE("transaction, update and save on the same profiles in one frame", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {}):unwrap()
			b = store:load("b", {}):unwrap()
			a:update(helpers.set(100)):unwrap()
		end)
		hook.latency = 1
		local seen
		local handles = {
			tx = run(function()
				return dataforge.transaction({ a, b }, function(ctx)
					ctx:set(a, { coins = ctx:get(a).coins - 30 })
					ctx:set(b, { coins = ctx:get(b).coins + 30 })
					return nil
				end)
			end),
			update = run(function()
				return a:update(function(data)
					seen = data.coins
					return helpers.add(1)(data)
				end)
			end),
			save = run(function()
				a:save():unwrap()
			end),
		}
		none_done(handles)
		helpers.tick(scheduler, 10)
		CHECK(all_done(handles).tx == true)
		CHECK(seen == 70 and a:get_data().coins == 71 and b:get_data().coins == 30)
		local ra = helpers.record(hook, "a")
		CHECK(ra.data.coins == 71 and ra.pending == nil)
		helpers.kill(a)
		helpers.kill(b)
		drain()
	end)

	CASE("two transactions in opposite order plus an update do not deadlock", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b
		helpers.sync(scheduler, function()
			a = store:load("a", {}):unwrap()
			b = store:load("b", {}):unwrap()
			a:update(helpers.set(100)):unwrap()
		end)
		hook.latency = 1
		local seen: { number } = {}
		local function move(from: dataforge.ProfileBase<Data>, to: dataforge.ProfileBase<Data>, amount: number)
			return function(ctx: dataforge.TxContext)
				table.insert(seen, ctx:get(a).coins)
				ctx:set(from, { coins = ctx:get(from).coins - amount })
				ctx:set(to, { coins = ctx:get(to).coins + amount })
				return nil
			end
		end
		local seen_by_update
		local handles = {
			tx1 = run(function()
				return dataforge.transaction({ a, b }, move(a, b, 10))
			end),
			tx2 = run(function()
				return dataforge.transaction({ b, a }, move(b, a, 5))
			end),
			update = run(function()
				return b:update(function(data)
					seen_by_update = data.coins
					return helpers.add(1)(data)
				end)
			end),
		}
		none_done(handles)
		helpers.tick(scheduler, 20)
		local values = all_done(handles)
		CHECK(values.tx1 == true and values.tx2 == true)
		CHECK(seen[1] == 100 and seen[2] == 90) -- tx2 saw tx1's result
		-- the update queued on b before tx2 got there: it runs between the two
		CHECK(seen_by_update == 10)
		CHECK(a:get_data().coins == 95 and b:get_data().coins == 6)
		CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
		helpers.kill(a)
		helpers.kill(b)
		drain()
	end)

	CASE("a mixed transaction followed by the unload of both participants in one frame", function()
		local store = helpers.make_store(hook, scheduler)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		local g = store:get_lockless("g", {})
		helpers.sync(scheduler, function()
			a:update(helpers.set(100)):unwrap()
			g:update(helpers.set(1)):unwrap()
			g:save():unwrap()
		end)
		hook.latency = 1
		local handles = {
			tx = run(function()
				return dataforge.transaction({ a, g }, function(ctx)
					ctx:set(a, { coins = ctx:get(a).coins - 30 })
					ctx:set(g, { coins = ctx:get(g).coins + 30 })
					return nil
				end)
			end),
			unload_a = run(function()
				a:unload()
			end),
			unload_g = run(function()
				g:unload()
			end),
		}
		none_done(handles)
		helpers.tick(scheduler, 20)
		CHECK(all_done(handles).tx == true)
		CHECK(not a.open and not g.open)
		local ra, rg = helpers.record(hook, "a"), helpers.record(hook, "g")
		CHECK(ra.data.coins == 70 and ra.pending == nil and ra.lock == nil)
		CHECK(rg.data.coins == 31 and rg.pending == nil and rg.lock == nil)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
		drain()
	end)

	CASE("store:close in the same frame as an in-flight save and transaction", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b, g
		helpers.sync(scheduler, function()
			a = store:load("a", {}):unwrap()
			b = store:load("b", {}):unwrap()
			g = store:get_lockless("g", {})
			a:update(helpers.set(100)):unwrap()
			g:update(helpers.set(1)):unwrap()
		end)
		hook.latency = 1
		local handles = {
			save = run(function()
				b:save():unwrap()
			end),
			tx = run(function()
				return dataforge.transaction({ a, g }, function(ctx)
					ctx:set(a, { coins = ctx:get(a).coins - 30 })
					ctx:set(g, { coins = ctx:get(g).coins + 30 })
					return nil
				end)
			end),
			close = run(function()
				store:close()
			end),
		}
		CHECK(store.closed)
		none_done(handles)
		helpers.tick(scheduler, 20)
		CHECK(all_done(handles).tx == true)
		CHECK(not a.open and not b.open and not g.open)
		for _, key in { "a", "b", "g" } do
			local record = helpers.record(hook, key)
			CHECK(record.lock == nil and record.pending == nil, `record {key} not clean`)
		end
		CHECK(helpers.record(hook, "a").data.coins == 70 and helpers.record(hook, "g").data.coins == 31)
		drain()
	end)

	CASE("wait_settled resumes only after the queued chain", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		hook.latency = 1
		local handles = {
			save1 = run(function()
				profile:save():unwrap()
			end),
			save2 = run(function()
				profile:save():unwrap()
			end),
			settled = run(function()
				profile:wait_settled()
			end),
		}
		none_done(handles)
		scheduler.step(1)
		CHECK(handles.save1.done and not handles.save2.done and not handles.settled.done)
		scheduler.step(1)
		all_done(handles)
		-- once settled, an update does not yield
		helpers.sync(scheduler, function()
			profile:update(helpers.set(1)):unwrap()
		end)
		helpers.kill(profile)
		drain()
	end)

	CASE("a chain on a profile that loses its lock mid-way ends without deadlocking or writing", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		hook.latency = 1
		hook.data[helpers.STORE].k.lock.id = "thief"
		local before = helpers.record(hook, "k")
		local handles = {
			save = run(function()
				return profile:save()
			end),
			update = run(function()
				return profile:update(helpers.set(3))
			end),
			save2 = run(function()
				return profile:save()
			end),
			unload = run(function()
				profile:unload()
			end),
		}
		helpers.tick(scheduler, 5)
		for _, handle in handles :: { [string]: helpers.Handle } do
			CHECK(handle.done)
		end
		-- the first save's write is cancelled: it reports the loss (with the
		-- thief's lock); the unload already queued behind it still runs the
		-- chain out without throwing
		local err = helpers.err(handles.save, "lock_lost")
		CHECK(err.profile == profile and err.lock.id == "thief")
		CHECK(handles.update.ok and handles.save2.ok)
		helpers.finished(handles.unload, "unload")
		CHECK(not profile.open)
		CHECK(helpers.deep_equal(before, helpers.record(hook, "k")), "a lost profile wrote to the record")
		drain()
	end)
end)

return plan
