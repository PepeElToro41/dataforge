--!strict

local Scheduler = require "@self/scheduler"
local Store = require "@self/store"
local Tx = require "@self/tx"
local memory = require "@self/hooks/memory"
local roblox = require "@self/hooks/roblox"
local runtime = require "@self/runtime"
local types = require "@self/types"
local util = require "@self/util"

export type Hook = types.Hook
export type StoreHandle = types.StoreHandle
export type Migration<T = any> = types.Migration<T>
export type Record<T = any> = types.Record<T>

export type Config<T = any> = Store.Config<T>
export type Store<T = any> = Store.Store<T>
export type Profile<T = any> = Store.Profile<T>
export type LocklessProfile<T = any> = Store.LocklessProfile<T>
export type AnyProfile<T = any> = Store.AnyProfile<T>

export type TxContext = Tx.TxContext

export type Scheduler = Scheduler.Scheduler
export type MemoryHook = memory.MemoryHook

local datastore = {}

--- Creates a store keyed by arbitrary strings. `store:load(key)` returns a
--- session-locked Profile, `store:load_lockless(key)` a LocklessProfile.
function datastore.create_store<T>(config: Config<T>): Store<T>
	return Store.new(config)
end

--- Atomically updates any set of profiles, across stores and mixing locked and
--- lockless ones. `fn` reads with `ctx:get(profile)` and stages writes with
--- `ctx:set(profile, new)`; return false to cancel (nothing is written).
--- Returns false when cancelled, true when committed; throws when aborted.
function datastore.transaction(profiles: { AnyProfile }, fn: (ctx: TxContext) -> boolean?): boolean
	return Tx.run(profiles, fn)
end

--- Whether a raw stored record is held by a transaction lock (as opposed to a
--- session lock held by a locked profile).
datastore.is_tx_lock = util.is_tx_lock

datastore.hooks = {
	memory = memory.new,
	roblox = roblox.new,
}

datastore.runtime = runtime
datastore.scheduler = Scheduler

return datastore
