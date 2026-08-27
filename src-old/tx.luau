--!strict

local runtime = require "./runtime"
local types = require "./types"
local util = require "./util"

--[[
	Transaction coordinator.

	Invariant: once any key record carries `pending { tx = id, tx_store }`, the
	outcome of that transaction is decided solely by the marker stored under
	`id` in the store named `tx_store`, and the marker is only ever written via
	compare-and-set:

		marker = marker or desired

	So the first writer wins. The coordinator tries to write "committed" after
	all participants are prepared (or "aborted" if preparing failed); anyone who
	later finds a dangling `pending` resolves it with fallback "aborted" (after
	a grace period if it does not own the key).

	Participants are abstract (see `Participant`), so one transaction can span
	several stores and mix session-locked and lockless profiles. The marker
	lives in the tx store of the first participant in sort order.
]]

export type TxOutcome = types.TxOutcome
export type PrepareStatus = "ok" | "lock_lost"

-- Profiles are typed loosely here to avoid require cycles.
type ProfileLike = any

type StoreLike = {
	config: { name: string, hook: types.Hook, lock_ttl: number, [any]: any },
	tx_store: types.StoreHandle,
	call: (self: any, fn: () -> any) -> any,
	[any]: any,
}

--- Adapter a profile exposes for the coordinator (`profile:_participant()`).
export type Participant = {
	profile: ProfileLike,
	store: StoreLike,
	sort_key: string,
	lockless: boolean,

	--- In-process mutex.
	lock: () -> (),
	--- Releases the mutex and, if `begin` took a storage lock that `prepare`
	--- never released, that lock too.
	unlock: () -> (),
	is_open: () -> boolean,
	--- Blocks until any earlier transaction on this participant has a known outcome.
	settle_pending: () -> (),
	--- Makes `snapshot` exact. Lockless: flushes the queue and takes a short
	--- transaction lock on the key in one write. Locked: nothing to do. May throw.
	begin: () -> (),
	--- Current value the transform sees.
	snapshot: () -> any,
	--- Single-key fast path: no marker needed.
	set_data: (new: any) -> (),
	--- Phase 1: persist `pending` next to the current data. May throw.
	prepare: (new: any, pending: types.Pending) -> PrepareStatus,
	apply_committed: (new: any, tx: Tx) -> (),
	apply_aborted: (prepared: boolean, tx: Tx) -> (),
}

export type Changed = {
	participant: Participant,
	new: any,
}

export type Tx = {
	id: string,
	desired: TxOutcome,
	outcome: TxOutcome?,
	changed: { Changed },
	prepared: { [Participant]: boolean },
	settle: (self: Tx) -> TxOutcome,
	cleaned: (self: Tx) -> (),
}

type Impl = Tx & {
	_store: StoreLike,
	_marker_store: types.StoreHandle,
	_applied: boolean,
	_resolving: boolean,
	_waiters: { thread },
	_unclean: number,
}

--- Structural view of any profile (locked or lockless) carrying data of type T.
export type ProfileOf<T> = {
	get: (self: any) -> T,
	_participant: (self: any) -> Participant,
	[any]: any,
}

export type TxContext = {
	get: <T>(self: TxContext, profile: ProfileOf<T>) -> T,
	set: <T>(self: TxContext, profile: ProfileOf<T>, new: T) -> (),
}

local Tx = {}
Tx.__index = Tx

local counter = 0

local function tx_store_name(store: StoreLike): string
	return store.config.name .. "/tx"
end

--- Compare-and-set the marker for `tx_id` in `marker_store`: keeps an existing
--- outcome, otherwise stores `fallback`. Returns the outcome now on record.
--- Retries through store:call.
function Tx.resolve_marker(
	store: StoreLike,
	marker_store: types.StoreHandle,
	tx_id: string,
	fallback: TxOutcome
): TxOutcome
	local result = store:call(function()
		return marker_store.update_async(tx_id, function(current: any?)
			if current == "committed" or current == "aborted" then
				return current
			end
			return fallback
		end)
	end)
	if result ~= "committed" and result ~= "aborted" then
		error(`datastore: unexpected tx marker value for {tx_id}: {tostring(result)}`)
	end
	return result :: TxOutcome
end

--- Resolves a `pending` found on a record. With `force = false` a pending
--- younger than `lock_ttl` is left alone (returns nil) so a live coordinator
--- gets the chance to commit; otherwise the marker is CAS-resolved with
--- fallback "aborted".
function Tx.resolve_pending(store: StoreLike, pending: types.Pending, force: boolean): TxOutcome?
	if not force then
		local age = runtime.now() - (pending.at or 0)
		if age < store.config.lock_ttl then
			return nil
		end
	end
	local name = pending.tx_store or tx_store_name(store)
	local marker_store = store.config.hook.get_store(name)
	return Tx.resolve_marker(store, marker_store, pending.tx, "aborted")
end

function Tx.new(store: StoreLike, id: string, changed: { Changed }): Tx
	local self: Impl = setmetatable({
		id = id,
		desired = "aborted",
		outcome = nil,
		changed = changed,
		prepared = {},
		_store = store,
		_marker_store = store.tx_store,
		_applied = false,
		_resolving = false,
		_waiters = {},
		_unclean = #changed,
	}, Tx) :: any
	return self
end

-- Resolves the marker (blocking, retrying with backoff until the storage answers),
-- then applies the outcome to every participant exactly once.
function Tx.settle(self: Impl): TxOutcome
	if self.outcome == nil then
		if self._resolving then
			table.insert(self._waiters, coroutine.running())
			coroutine.yield()
		else
			self._resolving = true
			local backoff = 1
			while self.outcome == nil do
				local ok, result = pcall(Tx.resolve_marker, self._store, self._marker_store, self.id, self.desired)
				if ok then
					self.outcome = result :: TxOutcome
				else
					runtime.wait(backoff)
					backoff = math.min(backoff * 2, 30)
				end
			end
			self._resolving = false
			local waiters = self._waiters
			self._waiters = {}
			for _, waiter in waiters do
				runtime.spawn(waiter)
			end
		end
	end

	local outcome: TxOutcome = self.outcome :: any
	if not self._applied then
		self._applied = true
		for _, entry in self.changed do
			local participant = entry.participant
			if outcome == "committed" then
				participant.apply_committed(entry.new, self)
			else
				participant.apply_aborted(self.prepared[participant] == true, self)
			end
		end
	end
	return outcome
end

-- Called by a participant after it wrote a clean record (no `pending`). Once every
-- participant is clean nothing references the marker and it can be removed.
function Tx.cleaned(self: Impl)
	self._unclean -= 1
	if self._unclean ~= 0 then
		return
	end
	local remove = self._marker_store.remove_async
	if remove == nil then
		return
	end
	local id = self.id
	runtime.spawn(function()
		pcall(remove, id)
	end)
end

local function by_sort_key(a: Participant, b: Participant): boolean
	return a.sort_key < b.sort_key
end

--- Runs `fn(ctx)` over the given profiles (any store, locked or lockless) and
--- commits every `ctx:set` atomically. Returns false when `fn` returns false.
function Tx.run(profiles: { ProfileLike }, fn: (ctx: TxContext) -> boolean?): boolean
	local seen: { [ProfileLike]: Participant } = {}
	local list: { Participant } = {}
	local hook: types.Hook? = nil
	for _, profile in profiles do
		if type(profile) ~= "table" or type(profile._participant) ~= "function" then
			error "datastore: transaction expects profiles"
		end
		if seen[profile] == nil then
			local participant: Participant = profile:_participant()
			seen[profile] = participant
			table.insert(list, participant)
			local profile_hook = participant.store.config.hook
			if hook == nil then
				hook = profile_hook
			elseif hook ~= profile_hook then
				error "datastore: all profiles in a transaction must share the same hook"
			end
		end
	end
	if #list == 0 then
		error "datastore: transaction needs at least one profile"
	end
	-- sorted lock order keeps concurrent transactions deadlock-free
	list = util.sorted(list, by_sort_key)

	for _, participant in list do
		participant.lock()
	end
	local function unlock_all()
		for index = #list, 1, -1 do
			list[index].unlock()
		end
	end

	local ok, result = pcall(function(): boolean
		local snapshots: { [Participant]: any } = {}
		for _, participant in list do
			participant.settle_pending()
			if not participant.is_open() then
				error(`datastore: profile "{participant.profile.key}" is closed`)
			end
			participant.begin()
			snapshots[participant] = participant.snapshot()
		end

		local staged: { [Participant]: any } = {}
		local ctx = {} :: TxContext
		local function participant_of(profile: ProfileLike): Participant
			local participant = seen[profile]
			if participant == nil then
				error "datastore: profile is not part of this transaction"
			end
			return participant
		end
		function ctx.get(_, profile)
			return snapshots[participant_of(profile)]
		end
		function ctx.set(_, profile, new)
			if new == nil then
				error "datastore: ctx:set requires a value"
			end
			staged[participant_of(profile)] = new
		end

		if fn(ctx) == false then
			return false
		end

		local changed: { Changed } = {}
		for _, participant in list do
			local new = staged[participant]
			if new ~= nil and new ~= snapshots[participant] then
				table.insert(changed, { participant = participant, new = util.deep_freeze(new) })
			end
		end

		if #changed == 0 then
			return true
		end
		if #changed == 1 then
			-- single key: a plain write is already atomic
			changed[1].participant.set_data(changed[1].new)
			return true
		end

		local coordinator = list[1].store
		counter += 1
		local id = `{coordinator.server_id}-{counter}`
		local tx = Tx.new(coordinator, id, changed)
		for _, entry in changed do
			entry.participant.profile.unresolved_tx = tx
		end

		-- Phase 1: every changed participant persists its post-tx data as `pending`.
		-- Locked participants go first: a lockless key is held under a short
		-- transaction lock until its pending is written, so keep that window short.
		local order = table.clone(changed)
		table.sort(order, function(a, b)
			if a.participant.lockless ~= b.participant.lockless then
				return not a.participant.lockless
			end
			return a.participant.sort_key < b.participant.sort_key
		end)

		local desired: TxOutcome = "committed"
		local reason = ""
		local at = runtime.now()
		local marker_name = tx_store_name(coordinator)
		for _, entry in order do
			local participant = entry.participant
			local pending: types.Pending = { tx = id, tx_store = marker_name, at = at, data = entry.new }
			local write_ok, status = pcall(participant.prepare, entry.new, pending)
			if write_ok and status == "ok" then
				tx.prepared[participant] = true
			else
				desired = "aborted"
				local key = participant.profile.key
				reason = if not write_ok then tostring(status) else `lock lost for "{key}"`
				break
			end
		end
		tx.desired = desired

		-- Phase 2: compare-and-set the marker. Whatever it says is the truth; settle
		-- applies it to every participant (in memory) exactly once.
		local outcome = tx:settle()
		if outcome == "committed" then
			return true
		end
		error(`datastore: transaction aborted: {reason}`)
	end)

	unlock_all()
	if not ok then
		error(result, 0)
	end
	return result :: boolean
end

return Tx
