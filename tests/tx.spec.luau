--!strict

local dataforge = require "@dataforge"
local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

type Data = helpers.Data
type Kind = "locked" | "lockless"
type Participant = dataforge.ProfileBase<Data>

local scheduler: helpers.Scheduler
local hook: helpers.Hook

--[[
	Every case below is written once against `ProfileBase` and registered for
	three suites: both participants session-locked, both lockless, and mixed
	("a" locked, "b" lockless). Kind-specific behaviour is asked through the
	small helpers right below.
]]

--- Creates a participant of `kind` under `key` holding `coins`, persisted.
local function make(store: dataforge.Store<Data>, kind: Kind, key: string, coins: number): Participant
	if kind == "locked" then
		local profile = helpers.sync(scheduler, function()
			return store:load(key, {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(coins)):unwrap()
			profile:save():unwrap()
		end)
		return profile
	end
	local profile = store:get_lockless(key, {})
	helpers.sync(scheduler, function()
		profile:update(helpers.set(coins)):unwrap()
		profile:save():unwrap()
	end)
	return profile
end

local function is_dirty(participant: Participant): boolean
	if participant.kind == "locked" then
		return (participant :: any)._dirty
	end
	return (participant :: any).dirty_pending
end

--- What another server sees for `key` once every lock / pending grace has expired.
local function read_elsewhere(kind: Kind, key: string): Data
	local other = helpers.make_store(helpers.server(hook), scheduler)
	if kind == "locked" then
		local profile = helpers.sync(scheduler, function()
			return other:load(key, {})
		end)
		return profile:get_data()
	end
	local profile = other:get_lockless(key, {})
	helpers.sync(scheduler, function()
		profile:fetch():unwrap()
	end)
	return profile:get_data()
end

local function transfer(a: Participant, b: Participant, amount: number)
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

local function writes(key: string): number
	return helpers.ops(hook, helpers.STORE, key, "update_async")
end

local function suite(title: string, kind_a: Kind, kind_b: Kind)
	local lockless_count = (if kind_a == "lockless" then 1 else 0) + (if kind_b == "lockless" then 1 else 0)

	-- "a" holds 100 coins, "b" holds 0; both persisted
	local function setup(overrides: { [string]: any }?): (dataforge.Store<Data>, Participant, Participant)
		local store = helpers.make_store(hook, scheduler, overrides)
		local a = make(store, kind_a, "a", 100)
		local b = make(store, kind_b, "b", 0)
		hook.ops = {}
		return store, a, b
	end

	TEST(title, function()
		BEFORE_EACH(function()
			scheduler, hook = helpers.fresh()
		end)
		AFTER_EACH(function()
			helpers.quiet(scheduler)
		end)

		CASE("commits both keys through pending + marker, cleaned on the next save", function()
			local _, a, b = setup()
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			CHECK(ok == true)
			CHECK(a:get_data().coins == 70 and b:get_data().coins == 30)
			CHECK(table.isfrozen(a:get_data() :: any) and table.isfrozen(b:get_data() :: any))
			CHECK(is_dirty(a) and is_dirty(b))
			CHECK(a.open and b.open)
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())

			-- phase 1 left `pending` next to the old data, phase 2 wrote the marker
			local ra, rb = helpers.record(hook, "a"), helpers.record(hook, "b")
			CHECK(ra.data.coins == 100 and ra.pending.data.coins == 70)
			CHECK(rb.data.coins == 0 and rb.pending.data.coins == 30)
			CHECK(ra.lock == nil or ra.lock.tx == nil)
			CHECK(rb.lock == nil or rb.lock.tx == nil)
			local id, value = only_marker()
			CHECK(ra.pending.tx_id == id and rb.pending.tx_id == id)
			CHECK(ra.pending.store == helpers.TX_STORE and rb.pending.store == helpers.TX_STORE)
			CHECK(ra.pending.expires == 60 and rb.pending.expires == 60)
			CHECK(value == "committed")
			CHECK(string.find(id, hook.job_id(), 1, true) == 1)

			-- next autosave / flush writes clean records and the marker is removed
			scheduler.step(30)
			ra, rb = helpers.record(hook, "a"), helpers.record(hook, "b")
			CHECK(ra.pending == nil and ra.data.coins == 70)
			CHECK(rb.pending == nil and rb.data.coins == 30)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			CHECK(not is_dirty(a) and not is_dirty(b))
			CHECK(helpers.ops(hook, helpers.TX_STORE, nil, "remove_async") == 1)
		end)

		CASE("returning false cancels: nothing staged, no marker", function()
			local _, a, b = setup()
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 500))
			end)
			CHECK(ok == false)
			CHECK(a:get_data().coins == 100 and b:get_data().coins == 0)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			CHECK(helpers.record(hook, "a").pending == nil and helpers.record(hook, "b").pending == nil)
			-- locked participants make no storage call; lockless ones take and give back their tx lock
			CHECK(writes "a" == (if kind_a == "lockless" then 2 else 0))
			CHECK(writes "b" == (if kind_b == "lockless" then 2 else 0))
			CHECK(helpers.record(hook, "a").lock == nil or helpers.record(hook, "a").lock.tx == nil)
			CHECK(helpers.record(hook, "b").lock == nil or helpers.record(hook, "b").lock.tx == nil)
			CHECK((a :: any)._tx_lock == nil and (b :: any)._tx_lock == nil)
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
		end)

		CASE("a single changed key is a plain update (no pending, no marker)", function()
			local _, a, b = setup()
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, function(ctx)
					ctx:set(a, { coins = 1 })
					ctx:set(b, ctx:get(b)) -- same reference: not a change
					return nil
				end)
			end)
			CHECK(ok == true)
			CHECK(a:get_data().coins == 1 and b:get_data().coins == 0)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			CHECK(helpers.record(hook, "a").pending == nil)
			if kind_a == "locked" then
				CHECK(helpers.record(hook, "a").data.coins == 100) -- lands on the next save
			else
				-- the queued update rides the write that gives the transaction lock back
				CHECK(helpers.record(hook, "a").data.coins == 1)
			end
			scheduler.step(30)
			CHECK(helpers.record(hook, "a").data.coins == 1 and helpers.record(hook, "a").pending == nil)
		end)

		CASE("a process that stages nothing commits trivially", function()
			local _, a, b = setup()
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, function()
					return nil
				end)
			end)
			CHECK(ok == true)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			CHECK(not is_dirty(a) and not is_dirty(b))
		end)

		CASE("ctx:set with nil errors and releases the profiles", function()
			local _, a, b = setup()
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, function(ctx)
					ctx:set(a, nil :: any)
					return nil
				end)
			end)
			helpers.failed(handle, "requires a value")
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
			CHECK(a:get_data().coins == 100)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
		end)

		CASE("an error thrown by process propagates and releases the profiles", function()
			local _, a, b = setup()
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, function(ctx)
					ctx:set(a, { coins = 1 })
					error "process broke"
				end)
			end)
			helpers.failed(handle, "process broke")
			CHECK(type(handle.result) == "string") -- rethrown raw, not wrapped
			CHECK(a:get_data().coins == 100 and b:get_data().coins == 0)
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			-- the profiles are still usable
			helpers.sync(scheduler, function()
				a:update(helpers.set(5)):unwrap()
			end)
			CHECK(a:get_data().coins == 5)
		end)

		CASE("a closed participant is rejected", function()
			local _, a, b = setup()
			helpers.sync(scheduler, function()
				b:unload()
			end)
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			local err = helpers.err(handle, "profile_closed")
			CHECK(err.profile == b and err.reason == "unloaded")
			CHECK(a:get_data().coins == 100 and a.open)
			CHECK(not a._mutex:is_locked())
			-- rejected before any mutex was taken: a stays usable
			helpers.sync(scheduler, function()
				a:update(helpers.set(5)):unwrap()
			end)
			CHECK(a:get_data().coins == 5)
		end)

		CASE("a phase-1 failure aborts and the prepared participant is cleaned later", function()
			local _, a, b = setup { retry_attempts = 1 }
			hook.latency = 1
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			-- let the lockless tx locks land, then fail b's prepare
			helpers.tick(scheduler, lockless_count)
			hook:fail_next(helpers.STORE, "b", "update_async", "before", "storage down")
			helpers.tick(scheduler, 5)
			local err = helpers.err(handle, "tx_aborted")
			CHECK(err.cause ~= nil and err.cause.type == "roblox")
			CHECK(err.cause.key == "b" and err.cause.cause == "storage down")
			CHECK(string.find(tostring(err), "aborted", 1, true) ~= nil)
			CHECK(string.find(tostring(err), "storage down", 1, true) ~= nil)
			CHECK(a:get_data().coins == 100 and b:get_data().coins == 0)
			CHECK(a.open and b.open)
			local id, value = only_marker()
			CHECK(value == "aborted")
			CHECK(err.id == id)
			CHECK(helpers.record(hook, "a").pending ~= nil) -- prepared, not yet cleaned
			CHECK(helpers.record(hook, "b").pending == nil)
			CHECK(is_dirty(a))
			hook.latency = 0

			helpers.tick(scheduler, 30)
			CHECK(helpers.record(hook, "a").pending == nil)
			CHECK(helpers.record(hook, "a").data.coins == 100)
			CHECK(helpers.record(hook, "b").data.coins == 0)
			CHECK(helpers.record(hook, "b").lock == nil or helpers.record(hook, "b").lock.tx == nil)
		end)

		CASE("a phase-1 write with unknown outcome aborts and another server sees old data", function()
			local _, a, b = setup { retry_attempts = 1 }
			hook.latency = 1
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			helpers.tick(scheduler, lockless_count)
			hook:fail_next(helpers.STORE, "b", "update_async", "after")
			helpers.tick(scheduler, 5)
			local err = helpers.err(handle, "tx_aborted")
			CHECK(err.cause ~= nil and err.cause.type == "roblox" and err.cause.key == "b")
			CHECK(a:get_data().coins == 100)
			-- a lockless b does not know whether its lock write landed and closes itself
			CHECK(b.kind == "lockless" or b:get_data().coins == 0)
			-- b's pending actually landed, but the marker says aborted
			CHECK(helpers.record(hook, "b").pending ~= nil)
			local _, value = only_marker()
			CHECK(value == "aborted")
			hook.latency = 0

			helpers.kill(a)
			helpers.kill(b)
			helpers.tick(scheduler, 70)
			CHECK(read_elsewhere(kind_a, "a").coins == 100)
			CHECK(read_elsewhere(kind_b, "b").coins == 0)
		end)

		CASE("a coordinator dying between phase 1 and the marker resolves to aborted", function()
			local _, a, b = setup()
			hook.latency = 1
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			-- tx locks, then both prepares; the marker write is in flight now
			helpers.tick(scheduler, lockless_count + 2)
			CHECK(not handle.done)
			CHECK(helpers.record(hook, "a").pending ~= nil and helpers.record(hook, "b").pending ~= nil)
			CHECK(helpers.count(helpers.markers(hook)) == 0)

			coroutine.close(handle.thread :: thread)
			helpers.kill(a)
			helpers.kill(b)
			hook.latency = 0

			helpers.tick(scheduler, 70)
			CHECK(read_elsewhere(kind_a, "a").coins == 100)
			CHECK(read_elsewhere(kind_b, "b").coins == 0)
			local _, value = only_marker()
			CHECK(value == "aborted")
		end)

		CASE("a marker resolved as aborted by another server before the commit aborts without a cause", function()
			local _, a, b = setup()
			hook.latency = 1
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			-- tx locks, then both prepares; the marker write is in flight now
			helpers.tick(scheduler, lockless_count + 2)
			CHECK(not handle.done)
			local id = helpers.record(hook, "a").pending.tx_id
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			-- a reader elsewhere force-resolved the pending (its grace expired for them)
			hook.data[helpers.TX_STORE][id] = "aborted"

			helpers.tick(scheduler, 5)
			local err = helpers.err(handle, "tx_aborted")
			CHECK(err.id == id and err.cause == nil)
			CHECK(string.find(tostring(err), "another server", 1, true) ~= nil)
			CHECK(a:get_data().coins == 100 and b:get_data().coins == 0)
			CHECK(a.open and b.open)
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
			local _, value = only_marker()
			CHECK(value == "aborted")
		end)

		CASE("a participant closed while another is still held is rejected and no mutex stays locked", function()
			local _, a, b = setup()
			hook.latency = 1
			-- `a` is busy: the transaction queues on its mutex
			local save = helpers.run(scheduler, function()
				return a:save()
			end)
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			CHECK(not save.done and not handle.done)
			-- `b` closes meanwhile: once the transaction gets `a`, taking `b` is rejected
			local unload = helpers.run(scheduler, function()
				b:unload()
			end)
			helpers.tick(scheduler, 5)
			helpers.finished(save)
			helpers.finished(unload)
			local err = helpers.err(handle, "profile_closed")
			CHECK(err.profile == b and err.reason == "unloaded")
			CHECK(a.open and not b.open)
			CHECK(not a._mutex:is_locked(), "a's mutex was left locked")
			CHECK(a:get_data().coins == 100)
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			-- a is still usable
			helpers.sync(scheduler, function()
				a:update(helpers.set(5)):unwrap()
			end)
			CHECK(a:get_data().coins == 5)
		end)

		CASE("a coordinator dying after the commit resolves to the new data", function()
			local _, a, b = setup()
			helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			helpers.kill(a)
			helpers.kill(b)
			helpers.tick(scheduler, 70)
			CHECK(read_elsewhere(kind_a, "a").coins == 70)
			CHECK(read_elsewhere(kind_b, "b").coins == 30)
			-- nobody garbage-collects the marker: it stays, harmless
			local _, value = only_marker()
			CHECK(value == "committed")
		end)

		CASE("a marker write with unknown outcome is retried; participants wait for it", function()
			local _, a, b = setup { retry_attempts = 1 }
			hook:fail_next(helpers.TX_STORE, "*", "update_async", "after")
			local handle = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30))
			end)
			CHECK(not handle.done)
			-- the marker landed as committed, but the coordinator does not know yet
			local _, value = only_marker()
			CHECK(value == "committed")
			CHECK(a:get_data().coins == 100)

			-- a save on a participant waits on the mutex instead of writing old data
			local save = helpers.run(scheduler, function()
				a:save():unwrap()
			end)
			CHECK(not save.done)

			scheduler.step(1) -- settle retries and learns "committed"
			if not (handle.done and save.done) then
				-- seen failing twice on intermediate src states, never reproduced
				-- since; dump everything useful if it comes back
				local ops = {}
				for _, entry in hook.ops do
					table.insert(ops, `{entry.op} {entry.store}/{entry.key}`)
				end
				local markers = {}
				for id, outcome in helpers.markers(hook) do
					table.insert(markers, `{id}={tostring(outcome)}`)
				end
				print "--- marker unknown outcome: not finished after step(1)"
				print(`tx done={handle.done} ok={handle.ok} result={tostring(handle.result)}`)
				print(`save done={save.done} ok={save.ok} result={tostring(save.result)}`)
				print(
					`now={scheduler.now()} pending_threads={scheduler.pending()} errors={table.concat(
						scheduler.errors,
						" | "
					)}`
				)
				print(
					`a: open={a.open} locked={a._mutex:is_locked()} closed={a._mutex:is_closed()} waiters={#a._mutex._waiters}`
				)
				print(
					`b: open={b.open} locked={b._mutex:is_locked()} closed={b._mutex:is_closed()} waiters={#b._mutex._waiters}`
				)
				print(`markers: {table.concat(markers, ", ")}`)
				print(`ops: {table.concat(ops, ", ")}`)
			end
			CHECK(helpers.finished(handle) == true)
			CHECK(a:get_data().coins == 70 and b:get_data().coins == 30)
			helpers.finished(save)
			CHECK(helpers.record(hook, "a").data.coins == 70 and helpers.record(hook, "a").pending == nil)
		end)

		CASE("concurrent transactions over the same profiles serialize", function()
			local _, a, b = setup()
			hook.latency = 1
			local first = helpers.run(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 10))
			end)
			local second = helpers.run(scheduler, function()
				return dataforge.transaction({ b, a }, transfer(a, b, 20))
			end)
			CHECK(not first.done and not second.done)
			helpers.tick(scheduler, 20)
			CHECK(helpers.finished(first) == true)
			CHECK(helpers.finished(second) == true)
			CHECK(a:get_data().coins == 70 and b:get_data().coins == 30)
			CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
		end)

		CASE("spans stores: one global marker store, resolved by a fresh server", function()
			local _, a, _ = setup()
			local guilds = dataforge.create_store {
				name = "Guilds",
				template = { coins = 0 } :: Data,
				_hook = hook,
				_scheduler = scheduler,
			}
			local g = helpers.sync(scheduler, function()
				return guilds:load("g1", {})
			end)
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, g }, transfer(a, g, 40))
			end)
			CHECK(ok == true)
			CHECK(a:get_data().coins == 60 and g:get_data().coins == 40)

			local ra, rg = helpers.record(hook, "a"), hook:dump("Guilds", "g1")
			CHECK(ra.pending.store == helpers.TX_STORE and rg.pending.store == helpers.TX_STORE)
			CHECK(ra.pending.tx_id == rg.pending.tx_id)
			local id, value = only_marker()
			CHECK(id == ra.pending.tx_id and value == "committed")

			helpers.kill(a)
			helpers.kill(g)
			helpers.tick(scheduler, 70)
			CHECK(read_elsewhere(kind_a, "a").coins == 60)
			local again = dataforge.create_store {
				name = "Guilds",
				template = { coins = 0 } :: Data,
				_hook = helpers.server(hook),
				_scheduler = scheduler,
			}
			local g2 = helpers.sync(scheduler, function()
				return again:load("g1", {})
			end)
			CHECK(g2:get_data().coins == 40)
		end)

		CASE("tx_ttl and _datastore from the config are honoured", function()
			local _, a, b = setup()
			local custom = hook.get_datastore "custom-markers"
			local ok = helpers.sync(scheduler, function()
				return dataforge.transaction({ a, b }, transfer(a, b, 30), { tx_ttl = 5, _datastore = custom })
			end)
			CHECK(ok == true)
			local ra = helpers.record(hook, "a")
			CHECK(ra.pending.expires == 5 and ra.pending.store == "custom-markers")
			CHECK(helpers.count(helpers.markers(hook)) == 0)
			CHECK(hook.data["custom-markers"][ra.pending.tx_id] == "committed")

			-- a fresh server honours `pending.store` when resolving
			helpers.kill(a)
			helpers.kill(b)
			helpers.tick(scheduler, 70)
			CHECK(read_elsewhere(kind_a, "a").coins == 70)
		end)

		CASE("store:transaction commits the same way", function()
			local store, a, b = setup()
			local ok = helpers.sync(scheduler, function()
				return store:transaction({ a, b }, function(datas)
					return { { coins = datas[1].coins - 30 }, { coins = datas[2].coins + 30 } }
				end)
			end)
			CHECK(ok == true)
			CHECK(a:get_data().coins == 70 and b:get_data().coins == 30)
			local _, value = only_marker()
			CHECK(value == "committed")
		end)

		if kind_a == "locked" or kind_b == "locked" then
			local locked_key = if kind_a == "locked" then "a" else "b"

			CASE("a session lock stolen before the transaction aborts it and closes that profile", function()
				local _, a, b = setup()
				local lost = 0
				local victim = if locked_key == "a" then a else b
				local other = if locked_key == "a" then b else a
				victim:on_lock_lost(function()
					lost += 1
				end)
				local thief = helpers.make_store(helpers.server(hook), scheduler)
				hook.data[helpers.STORE][locked_key].lock = nil
				helpers.sync(scheduler, function()
					return thief:load(locked_key, {})
				end)

				local handle = helpers.run(scheduler, function()
					return dataforge.transaction({ a, b }, transfer(a, b, 30))
				end)
				helpers.tick(scheduler, 5)
				local err = helpers.err(handle, "tx_aborted")
				CHECK(err.cause ~= nil and err.cause.type == "lock_lost")
				CHECK(err.cause.profile == victim)
				CHECK(err.cause.lock ~= nil and err.cause.lock.id == thief._hook.job_id())
				CHECK(not victim.open and lost == 1)
				CHECK(other.open)
				CHECK(other:get_data().coins == (if other == a then 100 else 0))
				local _, value = only_marker()
				CHECK(value == "aborted")
				-- the thief's record was not touched
				CHECK(helpers.record(hook, locked_key).lock.id == thief._hook.job_id())
				CHECK(helpers.record(hook, locked_key).pending == nil)
			end)
		end

		if lockless_count > 0 then
			local lockless_key = if kind_b == "lockless" then "b" else "a"

			CASE("lockless participants are flushed under a short transaction lock", function()
				local _, a, b = setup()
				local g = if lockless_key == "a" then a else b
				helpers.sync(scheduler, function()
					g:update(helpers.add(1)):unwrap()
				end)
				hook.latency = 1
				local handle = helpers.run(scheduler, function()
					return dataforge.transaction({ a, b }, transfer(a, b, 30))
				end)
				helpers.tick(scheduler, lockless_count)
				local record = helpers.record(hook, lockless_key)
				CHECK(record.lock ~= nil and record.lock.tx == true, "tx lock not on the record")
				-- taken at t = (locks taken before it), ttl 10
				CHECK(record.lock.expires == lockless_count - 1 + 10)
				CHECK(record.lock.id == (g :: any)._tx_lock.id)
				CHECK(record.data.coins == (if lockless_key == "a" then 101 else 1)) -- queue flushed
				CHECK(#(g :: any).queued_updates == 0)

				helpers.tick(scheduler, 5)
				helpers.finished(handle)
				record = helpers.record(hook, lockless_key)
				CHECK(record.lock == nil and (g :: any)._tx_lock == nil)
				CHECK(record.pending ~= nil)
				CHECK(g:get_data().coins == (if lockless_key == "a" then 71 else 31))
			end)

			CASE("the snapshot is exact without a fetch first", function()
				local store = helpers.make_store(hook, scheduler)
				local a = make(store, kind_a, "a", 100)
				local other = helpers.make_store(helpers.server(hook), scheduler)
				local g2 = other:get_lockless("b", {})
				helpers.sync(scheduler, function()
					g2:update(helpers.set(5)):unwrap()
					g2:save():unwrap()
				end)
				local b = store:get_lockless("b", {})
				CHECK(not b.fetched)
				local seen
				local ok = helpers.sync(scheduler, function()
					return dataforge.transaction({ a, b }, function(ctx)
						seen = ctx:get(b).coins
						ctx:set(a, { coins = ctx:get(a).coins - 30 })
						ctx:set(b, { coins = ctx:get(b).coins + 30 })
						return nil
					end)
				end)
				CHECK(ok == true and seen == 5)
				CHECK(b.fetched and b:get_data().coins == 35)
			end)

			CASE("a lost transaction lock during phase 1 aborts and closes the lockless profile", function()
				local _, a, b = setup()
				local g = if lockless_key == "a" then a else b
				local lost = 0
				g:on_lock_lost(function()
					lost += 1
				end)
				hook.latency = 1
				local handle = helpers.run(scheduler, function()
					return dataforge.transaction({ a, b }, transfer(a, b, 30))
				end)
				helpers.tick(scheduler, lockless_count)
				-- someone wiped our transaction lock (a stale-lock cleanup, say)
				local wiped = hook.data[helpers.STORE][lockless_key].lock.id
				hook.data[helpers.STORE][lockless_key].lock = nil
				local before = helpers.record(hook, lockless_key)
				helpers.tick(scheduler, 5)
				local err = helpers.err(handle, "tx_aborted")
				CHECK(err.cause ~= nil and err.cause.type == "tx_lock_lost")
				CHECK(err.cause.profile == g)
				CHECK(err.cause.expected.id == wiped and err.cause.lock == nil)
				CHECK(not g.open and lost == 1)
				CHECK(helpers.deep_equal(before, helpers.record(hook, lockless_key)), "record touched after lock loss")
				local _, value = only_marker()
				CHECK(value == "aborted")
				hook.latency = 0
				helpers.tick(scheduler, 30)
				CHECK(helpers.record(hook, "a").pending == nil and helpers.record(hook, "b").pending == nil)
			end)

			CASE("another server's flush waits for the transaction lock, then folds the pending", function()
				local _, a, b = setup()
				local other = helpers.make_store(helpers.server(hook), scheduler)
				local g2 = other:get_lockless(lockless_key, {})
				hook.latency = 1
				local handle = helpers.run(scheduler, function()
					return dataforge.transaction({ a, b }, transfer(a, b, 30))
				end)
				helpers.tick(scheduler, lockless_count)
				local flush = helpers.run(scheduler, function()
					g2:update(helpers.add(5)):unwrap()
					g2:save():unwrap()
				end)
				scheduler.step(1)
				CHECK(not flush.done)
				helpers.tick(scheduler, 5)
				helpers.finished(handle)
				CHECK(helpers.record(hook, lockless_key).lock == nil)
				hook.latency = 0
				-- g2 met the fresh pending: waits its grace, then honours the (committed) marker
				helpers.tick(scheduler, 70)
				helpers.finished(flush)
				local expected = (if lockless_key == "a" then 70 else 30) + 5
				CHECK(g2:get_data().coins == expected)
				local record = helpers.record(hook, lockless_key)
				CHECK(record.data.coins == expected and record.pending == nil)
			end)

			CASE("cancelling releases the transaction lock", function()
				local _, a, b = setup()
				hook.latency = 1
				local handle = helpers.run(scheduler, function()
					return dataforge.transaction({ a, b }, function()
						return false
					end)
				end)
				helpers.tick(scheduler, lockless_count)
				CHECK(helpers.record(hook, lockless_key).lock.tx == true)
				helpers.tick(scheduler, lockless_count)
				CHECK(helpers.finished(handle) == false)
				CHECK(helpers.record(hook, lockless_key).lock == nil)
				CHECK(not a._mutex:is_locked() and not b._mutex:is_locked())
			end)
		end
	end)
end

suite("transactions (session-locked)", "locked", "locked")
suite("transactions (lockless)", "lockless", "lockless")
suite("transactions (mixed)", "locked", "lockless")

TEST("transactions (validation)", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("rejects empty lists, non-profiles, duplicates and foreign hooks", function()
		local store = helpers.make_store(hook, scheduler)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		local foreign = helpers.make_store(helpers.server(hook), scheduler)
		local f = foreign:get_lockless("f", {})

		helpers.failed(helpers.run(scheduler, function()
			return dataforge.transaction({}, function()
				return nil
			end)
		end))
		helpers.failed(
			helpers.run(scheduler, function()
				return dataforge.transaction({ a, {} :: any }, function()
					return nil
				end)
			end),
			"expects profiles"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return dataforge.transaction({ a, a }, function()
					return nil
				end)
			end),
			"twice"
		)
		helpers.failed(
			helpers.run(scheduler, function()
				return dataforge.transaction({ a, f }, function()
					return nil
				end)
			end),
			"hook"
		)
		CHECK(not a._mutex:is_locked() and not f._mutex:is_locked())
		CHECK(helpers.ops(hook, helpers.STORE, "f") == 0)
	end)

	CASE("a profile outside the transaction cannot be staged", function()
		local store = helpers.make_store(hook, scheduler)
		local a, b, c
		helpers.sync(scheduler, function()
			a = store:load("a", {}):unwrap()
			b = store:load("b", {}):unwrap()
			c = store:load("c", {}):unwrap()
		end)
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a, b }, function(ctx)
				ctx:set(c, { coins = 9 })
				return nil
			end)
		end)
		-- staged data for a stranger is ignored: nothing happened
		CHECK(ok == true)
		CHECK(c:get_data().coins == 0)
		CHECK(helpers.count(helpers.markers(hook)) == 0)
	end)

	CASE("the transaction config needs a hook and a scheduler outside roblox", function()
		local store = helpers.make_store(hook, scheduler)
		local a = helpers.sync(scheduler, function()
			return store:load("a", {})
		end)
		-- defaults come from the first profile
		local ok = helpers.sync(scheduler, function()
			return dataforge.transaction({ a }, function(ctx)
				ctx:set(a, { coins = 1 })
				return nil
			end, {})
		end)
		CHECK(ok == true and a:get_data().coins == 1)
		CHECK(not pcall(dataforge.transaction, { a }, function()
			return nil
		end, "not a table" :: any))
	end)
end)

return plan
