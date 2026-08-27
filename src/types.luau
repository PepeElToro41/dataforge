type Array<T> = { T }

export type Counter = () -> number

--- Returns the new data, or nil / false to leave it untouched.
export type DataDispatcher<T> = (T) -> (T | false)?

--- A storage handle for one named store. Deliberately not shaped like a
--- Roblox DataStore. All methods throw on failure.
export type DatastoreHandle = {
	name: string,

	get_async: (key: string) -> any?,
	set_async: (key: string, value: any, user_ids: { number }?) -> (),
	update_async: (key: string, transform: (old: any?) -> any?, user_ids: { number }?) -> any?,
	remove_async: ((key: string) -> ())?,
}

export type Hook = {
	job_id: () -> string,
	get_datastore: (name: string) -> DatastoreHandle,
	--- Non-fatal problems (a hook that threw, a write that could not be
	--- released) are reported here instead of a global `warn`.
	warn: (message: string) -> (),
}

export type Scheduler = {
	spawn: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	defer: (fn: ((...any) -> ...any) | thread, ...any) -> thread,
	wait: (seconds: number?) -> number,
	now: () -> number,
}

export type Migration = {
	name: string,
	apply: (data: unknown) -> unknown,
}

export type Config<T = any> = {
	name: string,
	template: T,

	_hook: Hook?,
	_scheduler: Scheduler?,

	migrations: Array<Migration>?,

	--- seconds, default 30 (locked profiles)
	autosave_interval: number?,
	-- seconds, default autosave_interval (lockless profiles)
	flush_interval: number?,
	--- seconds, default 60
	lock_ttl: number?,
	--- seconds, default lock_ttl + 10
	load_timeout: number?,
	--- seconds, default 1
	load_poll: number?,
	--- default 5
	retry_attempts: number?, -- default 5
	--- seconds, default 1
	retry_base: number?,
}

--- Options shared by the retry helper. Both `ResolvedConfig` and
--- `ResolvedTransactionConfig` satisfy it.
export type RetryConfig = {
	_scheduler: Scheduler,
	retry_attempts: number,
	retry_base: number,
}

export type ResolvedConfig<T = any> = RetryConfig & {
	name: string,
	template: T,

	_hook: Hook,
	_scheduler: Scheduler,

	migrations: Array<Migration>,

	autosave_interval: number,
	flush_interval: number,
	lock_ttl: number,
	load_timeout: number,
	load_poll: number,
}

export type TransactionConfig = {
	_hook: Hook?,
	_scheduler: Scheduler?,
	_datastore: DatastoreHandle?,

	--- seconds, default 60. Grace period others give this transaction's `pending`
	--- before force-resolving it (stamped on the pending as `expires`).
	tx_ttl: number?,
	--- seconds, default 10. How long a transaction holds a lockless key between
	--- taking its snapshot and writing `pending`.
	lock_ttl: number?,
	--- default 5
	retry_attempts: number?,
	--- seconds, default 1
	retry_base: number?,
}

export type ResolvedTransactionConfig = RetryConfig & {
	_hook: Hook,
	_scheduler: Scheduler,
	--- Global marker datastore, resolved once via `tx_handle.get_tx_store`.
	_datastore: DatastoreHandle,
	--- Per-process transaction id counter (ids are `{job_id}-{n}`).
	_counter: Counter,

	tx_ttl: number,
	lock_ttl: number,
}

export type Lock = {
	id: string,
	expires: number,
	--- Short-lived lock a transaction takes on a lockless key (see `lock_ttl`
	--- in `TransactionConfig`). Other lockless writers wait it out instead of failing.
	tx: boolean?,
}

export type Pending<T = any> = {
	tx_id: string,
	store: string,
	--- Until when a non-owner leaves this pending alone; after it, the marker
	--- may be force-resolved (fallback "aborted").
	expires: number,
	data: T,
}

--- What is stored under each data key.
export type DataRecord<T = any> = {
	data: T?,
	lock: Lock?,
	pending: Pending<T>?,
	migrations: { string },
}

--- FIFO mutex for coroutines. See `mutex.luau`.
export type Mutex = {
	_locked: boolean,
	_closed: string?,
	_waiters: { thread },
	_settlers: { thread },

	scheduler: Scheduler,

	wait_settled: (self: Mutex) -> (),
	lock: (self: Mutex) -> (),
	unlock: (self: Mutex) -> (),
	close: (self: Mutex, reason: string) -> (),
	is_locked: (self: Mutex) -> boolean,
	is_closed: (self: Mutex) -> boolean,
	with: (self: Mutex, fn: () -> ...any) -> any,
}

export type TxOutcome = "committed" | "aborted"

--- One participant's share of a multi-key transaction. Built by `tx_handle.run`
--- per profile kind; the operation drives it through prepare / commit / abort.
export type TxPatch = {
	--- A `ProfileBase`. Typed `any` on purpose: `ProfileBase<T>` refers back to
	--- `TxOperation`, and Luau rejects a generic type used with different
	--- parameters inside one recursive group.
	profile: any,
	new_data: any,
	--- Set once `prepare` succeeded (the record carries `pending`).
	prepared: boolean,

	--- Phase 1: persist `pending` next to the current data. Returns false when
	--- the profile no longer owns its lock. May throw.
	prepare: (pending: Pending) -> boolean,
	--- Applies the outcome in memory. Called exactly once by the operation.
	commit: (operation: TxOperation) -> (),
	abort: (operation: TxOperation) -> (),
}

export type TxContext = {
	get: <T>(self: TxContext, profile: ProfileBase<T>) -> T,
	set: <T>(self: TxContext, profile: ProfileBase<T>, new: T) -> (),
}

--- in-flight multi-key transaction.
export type TxOperation = {
	_resolving: boolean,
	_applied: boolean,
	_waiters: { thread },
	_unclean: number,

	id: string,
	config: ResolvedTransactionConfig,
	desired: TxOutcome,
	outcome: TxOutcome?,

	patches: { TxPatch },

	--- Resolves the marker (blocking) and applies the outcome to every patch once.
	settle: (self: TxOperation) -> TxOutcome,
	--- A participant wrote a clean record; once all did, the marker is removed.
	cleaned: (self: TxOperation) -> (),
}

--[[
	Profiles
]]

export type HooksList<T... = ()> = {
	type: string,
	hooks: Array<(T...) -> ()>,
}

export type ProfileBase<T = any> = {
	kind: "locked" | "lockless",
	key: string,
	config: ResolvedConfig<T>,
	user_ids: Array<number>,
	datastore: DatastoreHandle,
	open: boolean,
	migrations: Array<string>,

	--- frozen; nil until loaded (locked) / fetched (lockless). Read through `get_data()`.
	_data: T?,
	_mutex: Mutex,
	--- Operations waiting for this profile to write a record without `pending`.
	_cleanup_txs: Array<TxOperation>,

	--- Current data. Throws if the profile is closed or (lockless) not fetched.
	get_data: (self: ProfileBase<T>) -> T,
	save: (self: ProfileBase<T>) -> (),
	unload: (self: ProfileBase<T>) -> (),
	update: (self: ProfileBase<T>, (T) -> T | false) -> boolean,

	on_change: (self: ProfileBase<T>, callback: (new: T, old: T?) -> ()) -> (),
	on_save: (self: ProfileBase<T>, callback: () -> ()) -> (),
	--- Fires at the start of `unload`, while the profile is still open: the
	--- last chance to update before the final write.
	on_closing: (self: ProfileBase<T>, callback: () -> ()) -> (),
	--- Fires once the profile is closed and its final write (if any) is done.
	--- Also fires after `lock_lost`.
	on_closed: (self: ProfileBase<T>, callback: () -> ()) -> (),
	on_lock_lost: (self: ProfileBase<T>, callback: () -> ()) -> (),

	--- Yields until no operation holds or waits on the profile mutex. Once this
	--- returns, the next update call is guaranteed not to yield (nothing is
	--- queued ahead of it).
	wait_settled: (self: ProfileBase<T>) -> (),

	-- internal, used by transactions
	_set_data: (self: ProfileBase<T>, data: T) -> (),
}

--- Session-locked profile.
export type Profile<T = any> = ProfileBase<T> & {
	kind: "locked",
	last_write: number,
	--- Whether the profile currently holds its session lock. True after `load`;
	--- `release` clears it, `readquire` takes it again. While released,
	--- `update` / `save` throw and the profile cannot join a transaction.
	is_locked: boolean,

	_dirty: boolean,
	_hooks: {
		change: HooksList<T, T?>,
		lock_lost: HooksList<()>,
		save: HooksList<()>,
		closing: HooksList<()>,
		closed: HooksList<()>,
	},

	wait_closed: (self: Profile<T>) -> (),

	--- Writes the data and gives the session lock back, keeping the profile
	--- open so another server may take the key. No-op when already released.
	release: (self: Profile<T>) -> (),
	--- Takes the session lock again (waits like `load` does) and adopts the
	--- stored record as the current data. No-op when already locked.
	readquire: (self: Profile<T>) -> (),

	-- internal, used by transactions. Returns false when the lock is gone.
	_write_record: (self: Profile<T>, options: ProfileWriteOptions) -> boolean,
}

export type ProfileWriteOptions = {
	release: boolean,
	pending: Pending?,
}

--- Profile without a session lock; updates are queued and folded into storage on save.
export type LocklessProfile<T = any> = ProfileBase<T> & {
	kind: "lockless",
	fetched: boolean,

	queued_updates: Array<DataDispatcher<T>>,
	dirty_pending: boolean,
	--- The transaction lock this profile believes storage holds (taken by
	--- `_write_queued { tx_lock = lock }`, cleared by a write passing it as
	--- `old_tx_lock`). nil when no lock is held.
	_tx_lock: Lock?,
	--- Outcomes of transactions whose `pending` this profile has seen on its record.
	_known_outcomes: { [string]: TxOutcome },

	_hooks: {
		change: Array<(new: T, old: T?) -> ()>,
		save: Array<() -> ()>,
		closing: Array<() -> ()>,
		closed: Array<() -> ()>,
		--- A session lock showed up on the record (a locked profile owns the key
		--- now); the profile closes.
		lock_lost: Array<() -> ()>,
	},

	fetch: (self: LocklessProfile<T>) -> T,

	-- internal, used by transactions
	_write_queued: (self: LocklessProfile<T>, options: LocklessWriteOptions) -> (),
	_queue_update: (self: LocklessProfile<T>, dispatcher: DataDispatcher<T>) -> boolean,
}

export type LocklessWriteOptions = {
	--- Leave this transaction lock on the record with this write (built by the
	--- transaction from its own config).
	tx_lock: Lock?,
	--- The transaction lock expected on the record. The write only goes through
	--- (replacing that lock) when the stored lock has the same id; if the lock
	--- is gone or is a different one, nothing is written and the call fails
	--- with "lock_lost". Without it, any lock on the record blocks the write.
	old_tx_lock: Lock?,
	--- Persist `pending` with this write.
	pending: Pending?,
}

--- What a store hands to `profile.load` / `lockless_profile.create`.
export type LoadOptions = {
	key: string,
	datastore: DatastoreHandle,
	config: ResolvedConfig,
	user_ids: Array<number>,
}

export type MigrationsResult = {
	applied: boolean,
	success: boolean,
	err: any,
	result: any,
	new_migrations: { string },
}

return nil
