local store = require "@self/store"
local tx = require "@self/tx/handle"
local types = require "@self/types"

local memory_hook = require "@self/hooks/memory"
local roblox_hook = require "@self/hooks/roblox"

local virtual_scheduler = require "@self/schedulers/virtual"
local roblox_scheduler = require "@self/schedulers/roblox"

type Array<T> = { T }

export type Store<T = any> = store.Store<T>
export type Config<T = any> = types.Config<T>
export type TransactionConfig = types.TransactionConfig
export type TxContext = types.TxContext
export type Profile<T = any> = types.Profile<T>
export type LocklessProfile<T = any> = types.LocklessProfile<T>
export type ProfileBase<T = any> = types.ProfileBase<T>
export type PeekProfile<T = any> = types.PeekProfile<T>
export type Result<T> = types.Result<T>
export type Error = types.Error

local dataforge = {}

function dataforge.create_store<T>(config: Config<T>): Store<T>
	return store.create(config)
end

--- Atomically updates any set of profiles, across stores and mixing locked and
--- lockless ones. Ok(false) when `process` returns false, Ok(true) when
--- committed. Fails with `tx_aborted` (see its `cause`), `profile_closed`,
--- `not_locked`, or what flushing a lockless participant raised.
function dataforge.transaction(
	profiles: Array<ProfileBase>,
	process: (ctx: TxContext) -> boolean?,
	config: TransactionConfig?
): Result<boolean>
	local first = profiles[1]
	local defaults: TransactionConfig? = if first
		then {
			_hook = first.config._hook,
			_scheduler = first.config._scheduler,
			retry_attempts = first.config.retry_attempts,
			retry_base = first.config.retry_base,
		}
		else nil

	return tx.run(tx.resolve_config(config, defaults), profiles, process)
end

dataforge.hooks = {
	memory = memory_hook,
	roblox = roblox_hook,
}

dataforge.schedulers = {
	virtual = virtual_scheduler,
	roblox = roblox_scheduler,
}

return dataforge
