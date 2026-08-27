local types = require "../types"

export type TxOperation = types.TxOperation
type ResolvedTransactionConfig = types.ResolvedTransactionConfig
type TxOutcome = types.TxOutcome

local tx_operation = {}
tx_operation.__index = tx_operation

--- Compare-and-set the marker for this operation: keeps an existing outcome,
--- otherwise stores `desired`. Retries through the config's retry policy.
local function resolve_marker(self: TxOperation): TxOutcome
	local config = self.config
	local datastore = config._datastore
	local id = self.id
	local desired = self.desired

	local result = datastore.update_async(id, function(current: any?)
		if current == "committed" or current == "aborted" then
			return current
		end
		return desired
	end)

	if result ~= "committed" and result ~= "aborted" then
		error(`datastore: unexpected tx marker value for {id}: {tostring(result)}`)
	end
	return result :: TxOutcome
end

--- Resolves the marker (blocking, retrying with backoff until the storage
--- answers), then applies the outcome to every patch exactly once. Safe to call
--- from several coroutines: later callers wait for the first resolution.
function tx_operation.settle(self: TxOperation): TxOutcome
	local scheduler = self.config._scheduler

	if self.outcome == nil then
		if self._resolving then
			table.insert(self._waiters, coroutine.running())
			coroutine.yield()
		else
			self._resolving = true
			local backoff = 1
			while self.outcome == nil do
				local ok, result = pcall(resolve_marker, self)
				if ok then
					self.outcome = result :: TxOutcome
				else
					scheduler.wait(backoff)
					backoff = math.min(backoff * 2, 30)
				end
			end
			self._resolving = false

			local waiters = self._waiters
			self._waiters = {}
			for _, waiter in waiters do
				scheduler.spawn(waiter)
			end
		end
	end

	local outcome: TxOutcome = self.outcome :: any
	if not self._applied then
		self._applied = true
		local committed = outcome == "committed"
		for _, patch in self.patches do
			if committed then
				patch.commit(self)
			else
				patch.abort(self)
			end
		end
	end
	return outcome
end

--- Called by a participant after it wrote a clean record (no `pending`). Once
--- every participant is clean nothing references the marker and it can go.
function tx_operation.cleaned(self: TxOperation)
	self._unclean -= 1
	if self._unclean > 0 then
		return
	end

	local remove = self.config._datastore.remove_async
	if remove == nil then
		return
	end

	local id = self.id
	self.config._scheduler.spawn(function()
		pcall(remove, id)
	end)
end

--- The outcome marker lives in `config._datastore` under `id`.
function tx_operation.create(id: string, config: ResolvedTransactionConfig, patches: { types.TxPatch }): TxOperation
	local self = {} :: TxOperation

	self.id = id
	self.config = config
	self.desired = "aborted"
	self.outcome = nil
	self.patches = patches

	self._resolving = false
	self._applied = false
	self._waiters = {}
	self._unclean = #patches

	return setmetatable(self, tx_operation) :: any
end

return {
	create = tx_operation.create,
}
