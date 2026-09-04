--!strict

local helpers = require "./helpers"
local testlib = require "./testlib"

local plan = testlib.plan()
local TEST, CASE, BEFORE_EACH, AFTER_EACH = plan.TEST, plan.CASE, plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

local scheduler: helpers.Scheduler
local hook: helpers.Hook

-- two migrations that record what they ran on
local ran: { string }

local function migrations()
	return {
		{
			name = "add_items",
			apply = function(data: any)
				table.insert(ran, "add_items")
				return { coins = data.coins, items = {} }
			end,
		},
		{
			name = "double_coins",
			apply = function(data: any)
				table.insert(ran, "double_coins")
				return { coins = data.coins * 2, items = data.items }
			end,
		},
	}
end

local function seed(record: any)
	hook.data[helpers.STORE] = { k1 = record }
end

TEST("migrations (session-locked)", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
		ran = {}
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("a fresh key uses the template and counts every migration as applied", function()
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(#ran == 0)
		CHECK(profile:get_data().coins == 0 and profile:get_data().items == nil)
		CHECK(profile.migrations[1] == "add_items" and profile.migrations[2] == "double_coins")
		helpers.sync(scheduler, function()
			profile:save():unwrap()
		end)
		local record = helpers.record(hook, "k1")
		CHECK(record.migrations[1] == "add_items" and record.migrations[2] == "double_coins")
	end)

	CASE("missing migrations run in order and are persisted on the next save", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(table.concat(ran, ",") == "add_items,double_coins")
		CHECK(profile:get_data().coins == 6 and profile:get_data().items ~= nil)
		CHECK(profile._dirty)
		-- not written yet: the lock write keeps the stored migrations list
		CHECK(#helpers.record(hook, "k1").migrations == 0)
		scheduler.step(30)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 6)
		CHECK(record.migrations[1] == "add_items" and record.migrations[2] == "double_coins")
	end)

	CASE("only the migrations after the applied prefix run", function()
		seed { data = { coins = 3, items = { "x" } }, migrations = { "add_items" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(table.concat(ran, ",") == "double_coins")
		CHECK(profile:get_data().coins == 6 and profile:get_data().items[1] == "x")
	end)

	CASE("a fully migrated record runs nothing and is not dirty", function()
		seed { data = { coins = 3, items = {} }, migrations = { "add_items", "double_coins" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(#ran == 0)
		CHECK(not profile._dirty)
		CHECK(profile:get_data().coins == 3)
	end)

	CASE("migrations run once across servers", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:unload()
		end)
		local other = helpers.make_store(helpers.server(hook), scheduler, { migrations = migrations() })
		local reloaded = helpers.sync(scheduler, function()
			return other:load("k1", {})
		end)
		CHECK(#ran == 2)
		CHECK(reloaded:get_data().coins == 6)
	end)

	CASE("a name mismatch fails the load", function()
		seed { data = { coins = 3 }, migrations = { "something_else" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local handle = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		local err = helpers.err(handle, "migration_mismatch")
		CHECK(err.key == "k1" and err.index == 1)
		CHECK(err.actual == "something_else" and err.expected == "add_items")
		CHECK(#err.applied == 1 and #err.declared == 2 and err.declared[2] == "double_coins")
		CHECK(string.find(tostring(err), "migration mismatch", 1, true) ~= nil)
		CHECK(#ran == 0)
		CHECK(store:get_loaded "k1" == nil)
		-- the key can be loaded again by this store (no "already loaded")
		local again = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.err(again, "migration_mismatch")
	end)

	CASE("a record written by a newer server fails the load with outdated and takes no lock", function()
		seed { data = { coins = 3 }, migrations = { "add_items", "double_coins", "future" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local handle = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		local err = helpers.err(handle, "outdated")
		CHECK(err.key == "k1" and err.profile == nil)
		CHECK(#err.record_migrations == 3 and err.record_migrations[3] == "future")
		CHECK(#err.declared_migrations == 2)
		CHECK(string.find(tostring(err), "newer server", 1, true) ~= nil)
		CHECK(#ran == 0)
		-- the lock write was cancelled, so there is nothing to release: one storage call
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 1)
		CHECK(helpers.record(hook, "k1").lock == nil)
		CHECK(store:get_loaded "k1" == nil)
		-- even while another server holds the key: outdated is decided first
		hook.data[helpers.STORE].k1.lock = { id = "other", expires = scheduler.now() + 60 }
		helpers.err(
			helpers.run(scheduler, function()
				return store:load("k1", {})
			end),
			"outdated"
		)
	end)

	CASE("readquire fails with outdated when a newer server wrote the record meanwhile", function()
		seed { data = { coins = 3 }, migrations = { "add_items", "double_coins" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.sync(scheduler, function()
			profile:release():unwrap()
		end)
		hook.data[helpers.STORE].k1.migrations = { "add_items", "double_coins", "future" }
		local err = helpers.err(
			helpers.run(scheduler, function()
				return profile:readquire()
			end),
			"outdated"
		)
		CHECK(err.key == "k1" and err.profile == profile)
		CHECK(#err.record_migrations == 3 and #err.declared_migrations == 2)
		CHECK(profile.open and not profile.is_locked)
		CHECK(helpers.record(hook, "k1").lock == nil)
	end)

	CASE("a failed load leaves no lock behind", function()
		seed { data = { coins = 3 }, migrations = { "wrong" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		helpers.err(
			helpers.run(scheduler, function()
				return store:load("k1", {})
			end),
			"migration_mismatch"
		)
		-- the data is untouched and nobody owns the key
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 3)
		CHECK(record.lock == nil, "lock left behind by a failed load")
	end)

	CASE("a migration that throws propagates the raw error and leaves no lock behind", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, {
			migrations = { {
				name = "broken",
				apply = function()
					error "migration broke"
				end,
			} },
		})
		local handle = helpers.run(scheduler, function()
			return store:load("k1", {})
		end)
		helpers.failed(handle, "migration broke")
		CHECK(type(handle.result) == "string")
		CHECK(store:get_loaded "k1" == nil)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 3 and record.lock == nil)
	end)

	CASE("a committed pending is migrated on load", function()
		hook.data[helpers.TX_STORE] = { ["dead-1"] = "committed" }
		seed {
			data = { coins = 1 },
			migrations = {},
			pending = { tx_id = "dead-1", store = helpers.TX_STORE, expires = 0, data = { coins = 5 } },
		}
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local profile = helpers.sync(scheduler, function()
			return store:load("k1", {})
		end)
		CHECK(profile:get_data().coins == 10 and profile:get_data().items ~= nil)
		CHECK(profile._dirty)
		scheduler.step(30)
		local record = helpers.record(hook, "k1")
		CHECK(record.pending == nil and record.data.coins == 10 and #record.migrations == 2)
	end)
end)

TEST("migrations (lockless)", function()
	BEFORE_EACH(function()
		scheduler, hook = helpers.fresh()
		ran = {}
	end)
	AFTER_EACH(function()
		helpers.quiet(scheduler)
	end)

	CASE("fetch migrates locally without writing", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		local data = helpers.sync(scheduler, function()
			return g:fetch()
		end)
		CHECK(table.concat(ran, ",") == "add_items,double_coins")
		CHECK(data.coins == 6 and data.items ~= nil)
		CHECK(g.migrations[2] == "double_coins")
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 0)
		CHECK(#helpers.record(hook, "k1").migrations == 0)
		-- nothing queued: the flush loop does not write the migration by itself
		scheduler.step(60)
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 0)
	end)

	CASE("save writes migrated data and the applied names", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		helpers.sync(scheduler, function()
			g:save():unwrap()
		end)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 6 and record.data.items ~= nil)
		CHECK(record.migrations[1] == "add_items" and record.migrations[2] == "double_coins")
		CHECK(g:get_data().coins == 6)
	end)

	CASE("queued updates replay after the migrations", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		helpers.sync(scheduler, function()
			g:update(function(data)
				-- sees migrated data
				CHECK(data.items ~= nil)
				return { coins = data.coins + 1, items = data.items }
			end)
			g:save():unwrap()
		end)
		-- (3 * 2) + 1, not (3 + 1) * 2
		CHECK(helpers.record(hook, "k1").data.coins == 7)
		CHECK(g:get_data().coins == 7)
	end)

	CASE("a fresh key uses the template and counts every migration as applied", function()
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		helpers.sync(scheduler, function()
			g:fetch():unwrap()
		end)
		CHECK(#ran == 0 and g:get_data().coins == 0)
		CHECK(#g.migrations == 2)
		helpers.sync(scheduler, function()
			g:update(helpers.add(1)):unwrap()
			g:save():unwrap()
		end)
		local record = helpers.record(hook, "k1")
		CHECK(record.data.coins == 1 and #record.migrations == 2)
	end)

	CASE("fetch fails with outdated when a newer server wrote the record", function()
		seed { data = { coins = 3 }, migrations = { "add_items", "double_coins", "future" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		local err = helpers.err(
			helpers.run(scheduler, function()
				return g:fetch()
			end),
			"outdated"
		)
		CHECK(err.key == "k1" and err.profile == g)
		CHECK(#err.record_migrations == 3 and err.record_migrations[3] == "future")
		CHECK(#err.declared_migrations == 2)
		CHECK(#ran == 0)
		CHECK(g.open and not g.fetched)
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 0)
	end)

	CASE("a record written by a newer server is left alone", function()
		seed { data = { coins = 3 }, migrations = { "add_items", "double_coins", "future" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		helpers.sync(scheduler, function()
			g:update(helpers.add(1)):unwrap()
		end)
		local save = helpers.run(scheduler, function()
			return g:save()
		end)
		local err = helpers.err(save, "outdated")
		CHECK(err.profile == g and err.key == "k1")
		CHECK(#err.record_migrations == 3 and err.record_migrations[3] == "future")
		CHECK(#err.declared_migrations == 2)
		CHECK(string.find(tostring(err), "newer server", 1, true) ~= nil)
		CHECK(g.open)
		CHECK(#g.queued_updates == 1)
		CHECK(helpers.record(hook, "k1").data.coins == 3)
		-- the flush loop keeps failing (warned) and nothing is written
		local warnings = #hook.warnings
		scheduler.step(60)
		CHECK(#hook.warnings > warnings)
		CHECK(helpers.record(hook, "k1").data.coins == 3)
		CHECK(g.open)
	end)

	CASE("a name mismatch fails fetch and save", function()
		seed { data = { coins = 3 }, migrations = { "wrong" } }
		local store = helpers.make_store(hook, scheduler, { migrations = migrations() })
		local g = store:get_lockless("k1", {})
		local err = helpers.err(
			helpers.run(scheduler, function()
				return g:fetch()
			end),
			"migration_mismatch"
		)
		CHECK(err.key == "k1" and err.index == 1 and err.actual == "wrong" and err.expected == "add_items")
		err = helpers.err(
			helpers.run(scheduler, function()
				return g:save()
			end),
			"migration_mismatch"
		)
		CHECK(err.index == 1 and err.actual == "wrong")
		-- the transform cancelled the write: not retried as a storage failure
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 1)
		CHECK(g.open and not g.fetched)
		CHECK(helpers.record(hook, "k1").data.coins == 3)
	end)

	CASE("a migration that throws propagates the raw error on fetch and save", function()
		seed { data = { coins = 3 }, migrations = {} }
		local store = helpers.make_store(hook, scheduler, {
			migrations = { {
				name = "broken",
				apply = function()
					error "migration broke"
				end,
			} },
		})
		local g = store:get_lockless("k1", {})
		local fetch = helpers.run(scheduler, function()
			return g:fetch()
		end)
		helpers.failed(fetch, "migration broke")
		CHECK(type(fetch.result) == "string")
		local save = helpers.run(scheduler, function()
			return g:save()
		end)
		helpers.failed(save, "migration broke")
		CHECK(helpers.ops(hook, helpers.STORE, "k1", "update_async") == 1)
		CHECK(g.open and not g.fetched and not g._mutex:is_locked())
		CHECK(helpers.record(hook, "k1").data.coins == 3)
	end)
end)

return plan
