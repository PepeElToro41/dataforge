--[[
	Transaction functions. No object: everything takes a
	`ResolvedTransactionConfig` (hook, scheduler, marker datastore, ttls) so
	profiles and the top-level module share one config without a handle class.

	This module must not require the profile modules: they require it to resolve
	foreign `pending` entries.
]]

local types = require "../types"
local utils = require "../utils"
local roblox_scheduler = require "../schedulers/roblox"
local roblox_hook = require "../hooks/roblox"
local tx_operation = require "./operation"

type Array<T> = { T }

type ProfileBase<T = any> = types.ProfileBase<T>
type Profile<T = any> = types.Profile<T>
type LocklessProfile<T = any> = types.LocklessProfile<T>

type DatastoreHandle = types.DatastoreHandle
type TransactionConfig = types.TransactionConfig
type ResolvedTransactionConfig = types.ResolvedTransactionConfig

type TxOutcome = types.TxOutcome
type TxPatch = types.TxPatch
export type TxContext = types.TxContext

local tx_handle = {}

--- Name of the single, global marker datastore shared by every transaction.
local TX_STORE_NAME = "tx"

--- Returns the global marker datastore. Every transaction, whatever stores it
--- touches, writes its outcome marker here under its tx id.
function tx_handle.get_tx_store(hook: types.Hook): DatastoreHandle
	return hook.get_datastore(TX_STORE_NAME)
end

function tx_handle.store_name(): string
	return TX_STORE_NAME
end

--- Compare-and-set the marker for `id` in `datastore`: keeps an existing
--- outcome, otherwise stores `fallback`. Returns the outcome now on record.
local function resolve_marker_in(
	config: types.RetryConfig,
	datastore: DatastoreHandle,
	id: string,
	fallback: TxOutcome
): TxOutcome
	local result = utils.retry(config, function()
		return datastore.update_async(id, function(current: any?)
			if current == "committed" or current == "aborted" then
				return current
			end
			return fallback
		end)
	end)

	if result ~= "committed" and result ~= "aborted" then
		error(`datastore: unexpected tx marker value for {id}: {tostring(result)}`)
	end
	return result :: TxOutcome
end

--- Reads the marker for `id`, writing `fallback` if it has not been decided yet.
function tx_handle.resolve_marker(config: ResolvedTransactionConfig, id: string, fallback: TxOutcome): TxOutcome
	return resolve_marker_in(config, config._datastore, id, fallback)
end

--- Resolves a `pending` found on a record. With `force = false` a pending
--- that has not reached its `expires` is left alone (returns nil) so a live
--- coordinator gets the chance to commit; otherwise the marker is CAS-resolved
--- with fallback "aborted". Works with a store config or a transaction config:
--- only their hook, scheduler and retry policy are used.
function tx_handle.resolve_pending(
	hook: types.Hook,
	config: types.RetryConfig,
	pending: types.Pending,
	force: boolean
): TxOutcome?
	if not force and config._scheduler.now() < (pending.expires or 0) then
		return nil
	end

	-- `pending.store` names the marker datastore the coordinator used; honour it
	-- rather than assuming it matches ours.
	local datastore = hook.get_datastore(pending.store)
	return resolve_marker_in(config, datastore, pending.tx_id, "aborted")
end

--- One counter per process: transaction ids are `{job_id}-{n}` and must not
--- repeat across transactions, whatever config each one resolved.
local tx_counter = utils.counter()

--- Fills the transaction config with defaults. `defaults` (a store's hook and
--- scheduler, typically) wins over the Roblox fallbacks, `config` over both.
function tx_handle.resolve_config(config: TransactionConfig?, defaults: TransactionConfig?): ResolvedTransactionConfig
	local given: TransactionConfig = config or {}
	assert(type(given) == "table", "datastore: transaction config must be a table")
	local fallback: TransactionConfig = defaults or {}

	local hook = given._hook or fallback._hook
	local scheduler = given._scheduler or fallback._scheduler

	if not hook and game then
		hook = roblox_hook.create()
	end
	if not scheduler and game and task then
		scheduler = roblox_scheduler.create()
	end
	assert(hook, "datastore: transaction config needs a hook outside Roblox")
	assert(scheduler, "datastore: transaction config needs a scheduler outside Roblox")

	return {
		_hook = hook,
		_scheduler = scheduler,
		_datastore = given._datastore or fallback._datastore or tx_handle.get_tx_store(hook),
		_counter = tx_counter,

		tx_ttl = given.tx_ttl or fallback.tx_ttl or 60,
		lock_ttl = given.lock_ttl or fallback.lock_ttl or 10,
		retry_attempts = given.retry_attempts or fallback.retry_attempts or 5,
		retry_base = given.retry_base or fallback.retry_base or 1,
	}
end

--- Structural check (no require of the profile modules, see header).
local function is_profile(unknown: any): boolean
	if type(unknown) ~= "table" then
		return false
	end
	return (unknown.kind == "locked" or unknown.kind == "lockless") and unknown._mutex ~= nil
end

local function sort_key(participant: ProfileBase): string
	return participant.config.name .. "\0" .. participant.key
end

local function profile_sort(a: ProfileBase, b: ProfileBase): boolean
	return sort_key(a) < sort_key(b)
end

--- Phase 1 order: locked participants first. A lockless key is held under a
--- short transaction lock until its pending is written, so keep that window short.
local function prepare_sort(a: TxPatch, b: TxPatch): boolean
	local a_lockless = a.profile.kind == "lockless"
	local b_lockless = b.profile.kind == "lockless"
	if a_lockless ~= b_lockless then
		return not a_lockless
	end
	return sort_key(a.profile) < sort_key(b.profile)
end

--- Locks every profile mutex in order. The returned function releases them in
--- reverse and, for a lockless profile still holding its storage transaction
--- lock (the transaction ended before writing `pending`), gives the key back.
local function lock_profiles(profiles: Array<ProfileBase>)
	for _, participant in profiles do
		participant._mutex:lock()
	end
	return function()
		for index = #profiles, 1, -1 do
			local participant = profiles[index]
			local lockless = participant :: LocklessProfile
			if participant.kind == "lockless" and lockless._tx_lock then
				local ok, err = utils.try(function()
					lockless:_write_queued {
						old_tx_lock = lockless._tx_lock,
					}
				end)
				if not ok then
					participant.config._hook.warn(
						`datastore: failed to release tx lock on "{participant.key}" (it will expire): {tostring(err)}`
					)
					lockless._tx_lock = nil
				end
			end
			participant._mutex:unlock()
		end
	end
end

local function assert_open_profiles(profiles: Array<ProfileBase>)
	for _, participant in profiles do
		if not participant.open then
			error(`datastore: transaction failed, profile "{participant.key}" is closed`)
		end
		if participant.kind == "locked" and not (participant :: Profile).is_locked then
			error(`datastore: transaction failed, profile "{participant.key}" does not hold its session lock`)
		end
	end
end

--- Flushes every lockless participant and leaves a short transaction lock on
--- its record (see `lock_ttl`), so the snapshot taken next is exact.
local function adquire_lockless_lock(config: ResolvedTransactionConfig, profiles: Array<ProfileBase>)
	for _, participant in profiles do
		if participant.kind == "lockless" then
			(participant :: LocklessProfile):_write_queued {
				tx_lock = {
					id = `{config._hook.job_id()}-{config._counter()}`,
					expires = config._scheduler.now() + config.lock_ttl,
					tx = true,
				},
			}
		end
	end
end

local function get_snapshots(profiles: Array<ProfileBase>)
	local snapshots: { [ProfileBase]: any } = {}

	for _, participant in profiles do
		-- the mutex is held and lockless participants were just flushed, so `_data`
		-- is current; not `get_data()`: an unload queued behind this transaction
		-- has already flipped `open` and must not abort it
		snapshots[participant] = participant._data
	end

	return snapshots
end

local function locked_patch(participant: Profile, new_data: any): TxPatch
	local patch = {} :: TxPatch
	patch.profile = participant
	patch.new_data = new_data
	patch.prepared = false

	function patch.prepare(pending)
		return participant:_write_record { release = false, pending = pending }
	end
	function patch.commit(operation)
		table.insert(participant._cleanup_txs, operation)
		-- always, even when an unload queued behind this transaction has already
		-- flipped `open`: its release write must carry the committed data
		participant:_set_data(new_data)
		participant._dirty = true
	end
	function patch.abort(_)
		if patch.prepared then
			-- record still carries `pending`; next save writes it clean
			participant._dirty = true
		end
	end

	return patch
end

local function lockless_patch(participant: LocklessProfile, new_data: any): TxPatch
	local patch = {} :: TxPatch
	patch.profile = participant
	patch.new_data = new_data
	patch.prepared = false

	function patch.prepare(pending)
		-- releases the transaction lock taken in `adquire_lockless_lock`; fails
		-- (nothing written) if that lock is gone or someone else's by now
		participant:_write_queued {
			pending = pending,
			old_tx_lock = participant._tx_lock,
		}
		return true
	end
	function patch.commit(operation)
		participant._known_outcomes[operation.id] = "committed"
		table.insert(participant._cleanup_txs, operation)
		-- storage still holds old data + pending; the local data moves on now
		participant:_set_data(new_data)
		participant.dirty_pending = true
	end
	function patch.abort(operation)
		participant._known_outcomes[operation.id] = "aborted"
		participant.dirty_pending = patch.prepared
	end

	return patch
end

local function make_patch(participant: ProfileBase, new_data: any): TxPatch
	if participant.kind == "locked" then
		return locked_patch(participant :: Profile, new_data)
	end
	return lockless_patch(participant :: LocklessProfile, new_data)
end

--- Runs `process(ctx)` over the given profiles (any store, locked or lockless)
--- and commits every `ctx:set` atomically. Returns false when `process`
--- returns false. Throws when the transaction aborts.
function tx_handle.run(
	config: ResolvedTransactionConfig,
	profiles: Array<ProfileBase>,
	process: (ctx: TxContext) -> boolean?
): boolean
	local seen: { [ProfileBase]: boolean } = {}
	local profile_list: Array<ProfileBase> = {}

	for _, profile in profiles do
		if not is_profile(profile) then
			error "datastore: transaction expects profiles"
		end
		if not profile.open then
			error "datastore: all profiles in a transaction must be open"
		end
		if profile.kind == "locked" and not (profile :: Profile).is_locked then
			error(`datastore: transaction failed, profile "{profile.key}" does not hold its session lock`)
		end
		if seen[profile] then
			error "datastore: a profile was provided twice in a transaction"
		end
		if profile.config._hook ~= config._hook then
			error "datastore: all profiles in a transaction must share the transaction's hook"
		end

		seen[profile] = true
		table.insert(profile_list, profile)
	end

	if #profile_list == 0 then
		error "datastore: transactions need at least one profile"
	end
	profile_list = utils.sorted(profile_list, profile_sort)

	local unlock_all = lock_profiles(profile_list)

	local ok, result: boolean = utils.try(function()
		assert_open_profiles(profile_list)
		-- kind of an oxymoron
		adquire_lockless_lock(config, profile_list)

		local snapshots = get_snapshots(profile_list)
		local staged: { [ProfileBase]: any } = {}

		local ctx = {} :: TxContext

		function ctx.get(_, participant)
			return snapshots[participant]
		end
		function ctx.set(_, participant, new_value)
			if new_value == nil then
				error "datastore: ctx:set requires a value"
			end
			staged[participant] = new_value
		end

		if process(ctx) == false then
			return false
		end

		local patches: { TxPatch } = {}

		for _, participant in profile_list do
			local new_value = staged[participant]
			if new_value ~= nil and new_value ~= snapshots[participant] then
				table.insert(patches, make_patch(participant, utils.deep_freeze(new_value)))
			end
		end

		if #patches == 0 then
			return true
		end

		if #patches == 1 then
			-- single key can just write to data and it will be already atomic
			local new_data = patches[1].new_data
			local participant = patches[1].profile
			if participant.kind == "locked" then
				(participant :: Profile):_set_data(new_data);
				(participant :: Profile)._dirty = true
			elseif participant.kind == "lockless" then
				(participant :: LocklessProfile):_queue_update(function()
					return new_data
				end)
			end

			return true
		end

		-- multi key: two-phase commit through the marker
		local id = `{config._hook.job_id()}-{config._counter()}`
		local operation = tx_operation.create(id, config, patches)

		-- Phase 1: every changed participant persists its post-tx data as `pending`.
		local order = utils.sorted(patches, prepare_sort)
		local desired: TxOutcome = "committed"
		local reason = ""
		local expires = config._scheduler.now() + config.tx_ttl
		local store_name = config._datastore.name

		for _, patch in order do
			local pending: types.Pending = {
				tx_id = id,
				store = store_name,
				expires = expires,
				data = patch.new_data,
			}
			local write_ok, prepared = utils.try(patch.prepare, pending)
			if write_ok and prepared == true then
				patch.prepared = true
			else
				desired = "aborted"
				local key = patch.profile.key
				reason = if not write_ok then tostring(prepared) else `lock lost for "{key}"`
				break
			end
		end
		operation.desired = desired

		-- Phase 2: compare-and-set the marker. Whatever it says is the truth;
		-- settle applies it to every participant (in memory) exactly once.
		local outcome = operation:settle()
		if outcome == "committed" then
			return true
		end
		error(`datastore: transaction aborted: {reason}`)
	end)

	unlock_all()
	if not ok then
		error(result)
	end
	return result
end

return tx_handle
