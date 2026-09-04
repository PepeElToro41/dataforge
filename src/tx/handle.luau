--[[
	Transaction functions. No object: everything takes a
	`ResolvedTransactionConfig` (hook, scheduler, marker datastore, ttls) so
	profiles and the top-level module share one config without a handle class.

	This module must not require the profile modules: they require it to resolve
	foreign `pending` entries.
]]

local errors = require "../errors"
local result = require "../result"
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
type Error = types.Error
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
	local outcome = utils.update_async(config, datastore, id, function(current: any?)
		if current == "committed" or current == "aborted" then
			return current
		end
		return fallback
	end)

	if outcome ~= "committed" and outcome ~= "aborted" then
		error(errors.tx_marker_invalid(id, outcome), 0)
	end
	return outcome :: TxOutcome
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

--- Locks every profile mutex in order, appending each one taken to `locked`
--- so a rejection midway (a mutex closed while waiting) leaves an exact list
--- for `unlock_all`.
local function lock_all(profiles: Array<ProfileBase>, locked: Array<ProfileBase>)
	for _, participant in profiles do
		participant._mutex:lock()
		table.insert(locked, participant)
	end
end

--- Releases the mutexes in reverse and, for a lockless profile still holding
--- its storage transaction lock (the transaction ended before writing
--- `pending`), gives the key back.
local function unlock_all(locked: Array<ProfileBase>)
	for index = #locked, 1, -1 do
		local participant = locked[index]
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

local function assert_open_profiles(profiles: Array<ProfileBase>)
	for _, participant in profiles do
		if not participant.open then
			error(errors.closed(participant), 0)
		end
		if participant.kind == "locked" and not (participant :: Profile).is_locked then
			error(errors.not_locked(participant), 0)
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
		local written, lock = participant:_write_record { release = false, pending = pending }
		if not written then
			error(errors.lock_lost(participant, lock), 0)
		end
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
		-- releases the transaction lock taken in `adquire_lockless_lock`; throws
		-- `tx_lock_lost` (nothing written) if that lock is gone or someone
		-- else's by now
		participant:_write_queued {
			pending = pending,
			old_tx_lock = participant._tx_lock,
		}
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
--- and commits every `ctx:set` atomically. Ok(false) when `process` returns
--- false, Ok(true) when committed. Fails with `tx_aborted` (its `cause` says
--- why phase 1 gave up), `profile_closed`, `not_locked`, or what flushing a
--- lockless participant raised (`profile_locked`, `outdated`, `roblox`, ...).
--- Argument misuse throws; an error thrown by `process` propagates as is.
function tx_handle.run(
	config: ResolvedTransactionConfig,
	profiles: Array<ProfileBase>,
	process: (ctx: TxContext) -> boolean?
): types.Result<boolean>
	local seen: { [ProfileBase]: boolean } = {}
	local profile_list: Array<ProfileBase> = {}

	for _, profile in profiles do
		if not is_profile(profile) then
			error "datastore: transaction expects profiles"
		end
		if seen[profile] then
			error "datastore: a profile was provided twice in a transaction"
		end
		if profile.config._hook ~= config._hook then
			error "datastore: all profiles in a transaction must share the transaction's hook"
		end
		if not profile.open then
			return result.err(errors.closed(profile))
		end
		if profile.kind == "locked" and not (profile :: Profile).is_locked then
			return result.err(errors.not_locked(profile))
		end

		seen[profile] = true
		table.insert(profile_list, profile)
	end

	if #profile_list == 0 then
		error "datastore: transactions need at least one profile"
	end
	profile_list = utils.sorted(profile_list, profile_sort)

	local locked: Array<ProfileBase> = {}

	local ok, value = utils.try(function()
		-- inside the protected region: a mutex closed while waiting rejects the
		-- lock, and the ones already taken must still be given back
		lock_all(profile_list, locked)
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
		-- why phase 1 gave up: a library error (reported as the abort's cause)
		-- or a raw one (an internal invariant; rethrown as is after settling)
		local cause: Error? = nil
		local raw: any = nil
		local expires = config._scheduler.now() + config.tx_ttl
		local store_name = config._datastore.name

		for _, patch in order do
			local pending: types.Pending = {
				tx_id = id,
				store = store_name,
				expires = expires,
				data = patch.new_data,
			}
			local write_ok, err = utils.try(patch.prepare, pending)
			if write_ok then
				patch.prepared = true
			else
				desired = "aborted"
				if errors.is(err) then
					cause = err
				else
					raw = err
				end
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
		if raw ~= nil then
			error(raw, 0)
		end
		-- no cause: every prepare went through but the marker was already
		-- resolved as aborted by another server (the pending's grace expired)
		error(errors.tx_aborted(id, cause), 0)
	end)

	unlock_all(locked)
	return result.of(ok, value)
end

return tx_handle
