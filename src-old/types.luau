--!strict

--[[
	Shared types.
]]

--- A storage handle for one named store. Deliberately not shaped like a
--- Roblox DataStore. All methods throw on failure.
export type StoreHandle = {
	get_async: (key: string) -> any?,
	set_async: (key: string, value: any, user_ids: { number }?) -> (),
	--- `transform` returns the new value, or nil to cancel (nothing written).
	--- Returns the value stored after the call: the new value, or the old one if
	--- cancelled. `transform` must be pure; Roblox may invoke it more than once.
	update_async: (key: string, transform: (old: any?) -> any?, user_ids: { number }?) -> any?,
	--- Optional; only used for best-effort cleanup of transaction markers.
	remove_async: ((key: string) -> ())?,
}

export type Hook = {
	get_job_id: () -> string,
	get_store: (name: string) -> StoreHandle,
}

export type Migration<T = any> = {
	name: string,
	--- Immutable: must return the migrated data (may return the same value if nothing changed).
	apply: (data: T) -> T,
}

export type Lock = {
	id: string,
	expires: number,
	--- true when a transaction holds this lock on a lockless key: taken while
	--- flushing the queue (exact snapshot), released when `pending` is written.
	--- Short-lived (`tx_lock_ttl`). Other lockless writers wait for it instead
	--- of failing.
	tx: boolean?,
}

--- A prepared (phase 1) transaction write. The marker deciding the outcome
--- lives under `tx` in the store named `tx_store`, which may belong to a
--- different Store than the record (cross-store transactions).
export type Pending<T = any> = {
	tx: string,
	tx_store: string,
	--- coordinator clock when prepared; non-owners wait a grace period before
	--- force-aborting a fresh pending
	at: number,
	data: T,
}

--- What is stored under each data key.
export type Record<T = any> = {
	data: T?,
	lock: Lock?,
	pending: Pending<T>?,
	migrations: { string },
}

export type TxOutcome = "committed" | "aborted"

return {}
