local errors = require "@self/errors"
local result = require "@self/result"
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
export type Migration = types.Migration
export type DataDispatcher<T = any> = types.DataDispatcher<T>

local dataforge = {}

function dataforge.create_store<T>(config: Config<T>): Store<T>
	return store.create(config)
end

--- Atomically updates any set of profiles, across stores and mixing locked and
--- lockless ones. Ok(false) when `process` returns false, Ok(true) when
--- committed. Fails with `tx_aborted` (see its `cause`), `profile_closed`,
--- `released`, or what flushing a lockless participant raised.
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

--- Whether `value` is a dataforge `Error` table (what a failed Result carries
--- and what the library throws internally). Lets a wrapper around library calls
--- tell a library error from any other thrown value.
dataforge.is_error = errors.is

--- The `Result` helpers (`ok`, `err`, `is`, `of`, `capture`), so a game can
--- build library-shaped results in its own wrappers. `result.err` only accepts
--- an `Error`, so a malformed result cannot be fabricated with it.
dataforge.result = result

dataforge.hooks = {
	memory = memory_hook,
	roblox = roblox_hook,
}

dataforge.schedulers = {
	virtual = virtual_scheduler,
	roblox = roblox_scheduler,
}

return dataforge
