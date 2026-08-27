--!strict

local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

local scheduler: helpers.Scheduler
local hook: helpers.Hook

local function reads(key: string): number
	return helpers.ops(hook, helpers.STORE, key, "get_async")
end
local function writes(key: string): number
	return helpers.ops(hook, helpers.STORE, key, "update_async")
end

TEST("peek profile", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("missing key resolves to the template without writing", function()
		local store = helpers.make_store(hook, scheduler)
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(peek.kind == "peek" and peek.key == "k")
		CHECK(peek:get_data().coins == 0 and peek._data == peek:get_data())
		CHECK(table.isfrozen(peek:get_data() :: any))
		CHECK(peek.lock == nil and peek.pending == nil)
		CHECK(#peek.migrations == 0)
		CHECK(reads "k" == 1 and writes "k" == 0)
		CHECK(helpers.record(hook, "k") == nil)
	end)

	CASE("reads what is in storage", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 8 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler)
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(peek:get_data().coins == 8)
	end)

	CASE("shows a session lock held by another server and keeps the data", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		helpers.sync(scheduler, function()
			profile:update(helpers.set(5))
			profile:save()
		end)

		local other = helpers.make_store(helpers.server(hook), scheduler)
		local peek = helpers.sync(scheduler, function()
			return other:peek("k")
		end)
		CHECK(peek.lock ~= nil)
		CHECK(peek.lock.id == hook.job_id() and peek.lock.tx == nil)
		CHECK(peek:get_data().coins == 5)

		helpers.sync(scheduler, function()
			profile:release()
		end)
		helpers.sync(scheduler, function()
			peek:refresh()
		end)
		CHECK(peek.lock == nil)
		CHECK(profile.open and store.profiles.k == profile)
	end)

	CASE("refresh re-reads with one get_async", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(peek:get_data().coins == 0)
		local before_reads, before_writes = reads "k", writes "k"

		helpers.sync(scheduler, function()
			profile:update(helpers.set(3))
			profile:save()
		end)
		local data = helpers.sync(scheduler, function()
			return peek:refresh()
		end)
		CHECK(data.coins == 3 and peek:get_data() == data)
		CHECK(table.isfrozen(data :: any))
		CHECK(reads "k" == before_reads + 1)
		CHECK(writes "k" == before_writes + 1) -- the profile's save, not the peek
	end)

	CASE("applies migrations in memory only", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 2 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler, {
			migrations = {
				{
					name = "items",
					apply = function(data: any)
						return { coins = data.coins, items = {} }
					end,
				},
			},
		})
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(peek:get_data().items ~= nil)
		CHECK(#peek.migrations == 1 and peek.migrations[1] == "items")
		local record = helpers.record(hook, "k")
		CHECK(#record.migrations == 0 and record.data.items == nil)
		CHECK(writes "k" == 0)
	end)

	CASE("missing key lists every declared migration", function()
		local store = helpers.make_store(hook, scheduler, {
			migrations = { { name = "a", apply = function(data: any)
				return data
			end } },
		})
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(#peek.migrations == 1 and peek.migrations[1] == "a")
	end)

	CASE("throws when the record has migrations this server does not declare", function()
		hook.data[helpers.STORE] = { k = { data = { coins = 2 }, migrations = { "newer" } } }
		local store = helpers.make_store(hook, scheduler)
		local handle = helpers.run(scheduler, function()
			return store:peek("k")
		end)
		helpers.failed(handle, "failed to apply migrations")
		CHECK(writes "k" == 0)
	end)

	CASE("exposes a pending marker as stored", function()
		local pending = { tx_id = "x-1", store = helpers.STORE, expires = 100, data = { coins = 9 } }
		hook.data[helpers.STORE] = { k = { data = { coins = 1 }, migrations = {}, pending = pending } }
		local store = helpers.make_store(hook, scheduler)
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		CHECK(peek:get_data().coins == 1)
		CHECK(peek.pending ~= nil and peek.pending.tx_id == "x-1")
		CHECK(helpers.ops(hook, helpers.TX_STORE) == 0)
	end)

	CASE("cannot join a transaction", function()
		local store = helpers.make_store(hook, scheduler)
		local peek = helpers.sync(scheduler, function()
			return store:peek("k")
		end)
		local handle = helpers.run(scheduler, function()
			return store:transaction({ peek :: any }, function(datas)
				return datas
			end)
		end)
		helpers.failed(handle)
		CHECK(writes "k" == 0)
	end)

	CASE("throws once the store is closed", function()
		local store = helpers.make_store(hook, scheduler)
		helpers.sync(scheduler, function()
			store:close()
		end)
		local handle = helpers.run(scheduler, function()
			return store:peek("k")
		end)
		helpers.failed(handle, "store is closed")
	end)
end)

return plan
