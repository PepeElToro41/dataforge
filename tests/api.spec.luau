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

--- What the package exposes to a consumer: the error / result helpers and the
--- public types (checked by the analyser through the annotations below).
TEST("public api surface", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("is_error tells library errors from anything else thrown", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:load("k", {})
			end),
			"already_loaded"
		)

		CHECK(dataforge.is_error(err))
		CHECK(not dataforge.is_error "datastore: something broke")
		CHECK(not dataforge.is_error { type = "already_loaded", message = "a look-alike" })
		CHECK(not dataforge.is_error(nil))

		-- the shape a consumer's own pcall wrapper deals with
		local ok, thrown = pcall(function()
			profile:get_data()
			error("raised by game code", 0)
		end)
		CHECK(not ok and not dataforge.is_error(thrown))

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("the result helpers are exported and only build well-formed results", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		local err = helpers.err(
			helpers.run(scheduler, function()
				return store:load("k", {})
			end),
			"already_loaded"
		)

		local ok: dataforge.Result<number> = dataforge.result.ok(7)
		CHECK(dataforge.result.is(ok) and ok.success and ok:unwrap() == 7)

		local failed = dataforge.result.err(err)
		CHECK(dataforge.result.is(failed) and not failed.success and failed.error == err)
		-- `result.err` asserts on an `Error`, so a malformed result cannot be built
		CHECK(not pcall(dataforge.result.err, "not an error" :: any))

		local captured = dataforge.result.capture(function()
			error(err, 0)
		end)
		CHECK(not captured.success and captured.error == err)

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("a dispatcher returning nil to cancel type-checks and cancels", function()
		local store = helpers.make_store(hook, scheduler)
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)

		-- the common shape in game code: nil leaves the data untouched, no
		-- `or false` wrapper needed
		local spend: dataforge.DataDispatcher<Data> = function(data)
			if data.coins < 5 then
				return nil
			end
			return { coins = data.coins - 5, items = data.items }
		end

		local changed = helpers.sync(scheduler, function()
			return profile:update(spend)
		end)
		CHECK(changed == false and profile:get_data().coins == 0)

		helpers.sync(scheduler, function()
			profile:update(helpers.set(8)):unwrap()
		end)
		changed = helpers.sync(scheduler, function()
			return profile:update(spend)
		end)
		CHECK(changed == true and profile:get_data().coins == 3)

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)

	CASE("the Migration type is exported", function()
		local migrations: { dataforge.Migration } = {
			{
				name = "add-items",
				apply = function(data: any): any
					return { coins = data.coins, items = {} }
				end,
			},
		}
		hook.data[helpers.STORE] = { k = { data = { coins = 2 }, migrations = {} } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations })
		local profile = helpers.sync(scheduler, function()
			return store:load("k", {})
		end)
		CHECK(profile:get_data().coins == 2 and profile:get_data().items ~= nil)
		CHECK(profile.migrations[1] == "add-items")

		helpers.sync(scheduler, function()
			profile:unload()
		end)
	end)
end)

return plan
