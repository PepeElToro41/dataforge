/// <reference types="@rbxts/types" />

/**
 * Roblox DataStore library with cross-key transactions, session-locked and
 * lockless profiles, migrations and an immutable data model.
 */
declare namespace dataforge {
	/*
		Storage backends
	*/

	/**
	 * A storage handle for one named store. Deliberately not shaped like a
	 * Roblox DataStore. All methods throw on failure.
	 */
	interface DatastoreHandle {
		name: string;

		get_async: (key: string) => unknown;
		set_async: (key: string, value: unknown, user_ids?: number[]) => void;
		/**
		 * Atomic per key. Cancels when `transform` returns `undefined` and
		 * returns the value stored after the call.
		 */
		update_async: (key: string, transform: (old: unknown) => unknown, user_ids?: number[]) => unknown;
		/** Optional; used to delete transaction markers. */
		remove_async?: (key: string) => void;
	}

	/** How a store reaches storage. */
	interface Hook {
		/** Identifies this server. Session locks and transaction ids carry it. */
		job_id: () => string;
		/** Returns the handle for a named store. Called once per store name. */
		get_datastore: (name: string) => DatastoreHandle;
		/**
		 * Non-fatal problems (a hook that threw, a write that could not be
		 * released) are reported here instead of a global `warn`.
		 */
		warn: (message: string) => void;
	}

	/** How the library spawns threads, waits and reads the clock. */
	interface Scheduler {
		spawn: (fn: ((...args: unknown[]) => unknown) | thread, ...args: unknown[]) => thread;
		defer: (fn: ((...args: unknown[]) => unknown) | thread, ...args: unknown[]) => thread;
		wait: (seconds?: number) => number;
		now: () => number;
	}

	type MemoryHookOp = "get_async" | "set_async" | "update_async" | "remove_async" | "*";
	type MemoryHookFailMode = "before" | "after";

	interface MemoryHookOpLogEntry {
		store: string;
		key: string;
		op: string;
	}

	/**
	 * In-memory hook meant for tests. Every handle created from one hook shares
	 * one backend table, so several stores over one hook behave like several
	 * servers. Values are deep-copied in and out.
	 */
	interface MemoryHook extends Hook {
		scheduler: Scheduler;

		/** Raw backend: `data[store][key]`. */
		data: Map<string, Map<string, unknown>>;
		/** Seconds waited through the scheduler before every operation (default `0`). */
		latency: number;
		/** Log of every operation performed. */
		ops: MemoryHookOpLogEntry[];
		/** Every message the library reported through `warn` (nothing is printed). */
		warnings: string[];

		/**
		 * The next matching operation throws. `"before"` throws without touching
		 * the backend; `"after"` performs the write and then throws (unknown
		 * outcome). `op = "*"` matches any operation.
		 */
		fail_next(
			store: string,
			key: string,
			op: MemoryHookOp,
			mode: MemoryHookFailMode,
			message?: string,
		): void;
		/** Drops pending injected failures. */
		clear_failures(): void;
		/** Deep copy of the stored record. */
		dump(store: string, key: string): unknown;
	}

	/**
	 * Virtual-time scheduler for tests. Never yields the real thread: `wait`
	 * suspends the calling coroutine and registers it to resume at
	 * `now + seconds`.
	 */
	interface VirtualScheduler extends Scheduler {
		/**
		 * Advances the clock by `dt` and resumes every due thread in
		 * (resume time, registration order).
		 */
		step: (dt: number) => void;
		/** Runs everything due at the current time. */
		flush: () => void;
		/** Number of queued threads. */
		pending: () => number;
		/** Errors thrown by spawned threads. */
		errors: string[];
	}

	/*
		Configuration
	*/

	interface Migration {
		name: string;
		apply: (data: unknown) => unknown;
	}

	interface Config<T = unknown> {
		name: string;
		template: T;

		migrations?: Migration[];

		/** seconds, default 30 (locked profiles) */
		autosave_interval?: number;
		/** seconds, default autosave_interval (lockless profiles) */
		flush_interval?: number;
		/** seconds, default 60 */
		lock_ttl?: number;
		/** seconds, default lock_ttl + 10 */
		load_timeout?: number;
		/** seconds, default 1 */
		load_poll?: number;
		/** default 5 */
		retry_attempts?: number;
		/** seconds, default 1 */
		retry_base?: number;
	}

	/** `Config<T>` with every optional field filled in. */
	type ResolvedConfig<T = unknown> = Required<Config<T>>;

	interface TransactionConfig {
		/**
		 * seconds, default 60. Grace period others give this transaction's
		 * `pending` before force-resolving it.
		 */
		tx_ttl?: number;
		/**
		 * seconds, default 10. How long a transaction holds a lockless key
		 * between taking its snapshot and writing `pending`.
		 */
		lock_ttl?: number;
		/** default 5 */
		retry_attempts?: number;
		/** seconds, default 1 */
		retry_base?: number;
	}

	/*
		Stored shapes
	*/

	interface Lock {
		id: string;
		expires: number;
		/**
		 * Short-lived lock a transaction takes on a lockless key. Other
		 * lockless writers wait it out instead of failing.
		 */
		tx?: boolean;
	}

	interface Pending<T = unknown> {
		tx_id: string;
		store: string;
		/**
		 * Until when a non-owner leaves this pending alone; after it, the marker
		 * may be force-resolved (fallback "aborted").
		 */
		expires: number;
		data: T;
	}

	/** What is stored under each data key. */
	interface DataRecord<T = unknown> {
		data?: T;
		lock?: Lock;
		pending?: Pending<T>;
		migrations: string[];
	}

	type TxOutcome = "committed" | "aborted";

	/*
		Errors and results
	*/

	interface ErrorBase {
		readonly type: string;
		/** Human readable; `tostring(err)` returns it. */
		readonly message: string;
	}

	/** Storage kept failing after `retry_attempts`. */
	interface RobloxError extends ErrorBase {
		readonly type: "roblox";
		readonly op: "get_async" | "update_async";
		readonly store: string;
		readonly key: string;
		/** The last raw error the storage hook threw. */
		readonly cause: unknown;
	}

	/** `load` / `readquire` gave up after `load_timeout`. */
	interface TimeoutError extends ErrorBase {
		readonly type: "timeout";
		readonly key: string;
		/** The last lock seen on the record (its holder). */
		readonly lock: Lock | undefined;
	}

	/** A write found the session lock is not ours; the profile is closed. */
	interface LockLostError extends ErrorBase {
		readonly type: "lock_lost";
		readonly profile: Profile<any>;
		/** The lock now on the record, `undefined` when it was wiped. */
		readonly lock: Lock | undefined;
	}

	/** The profile was released and not readquired. */
	interface ReleasedError extends ErrorBase {
		readonly type: "released";
		readonly profile: Profile<any>;
	}

	/** Another server holds a live session lock on a lockless key; the profile is closed. */
	interface LocklessLockedError extends ErrorBase {
		readonly type: "lockless_locked";
		readonly profile: LocklessProfile<any>;
		readonly lock: Lock;
	}

	/** The transaction lock a lockless participant held is gone or replaced; the profile is closed. */
	interface TxLockLostError extends ErrorBase {
		readonly type: "tx_lock_lost";
		readonly profile: LocklessProfile<any>;
		/** The transaction lock this profile held. */
		readonly expected: Lock;
		/** The lock now on the record, `undefined` when none. */
		readonly lock: Lock | undefined;
	}

	/** The record was written by a newer server (more migrations than declared). */
	interface OutdatedError extends ErrorBase {
		readonly type: "outdated";
		readonly profile: LocklessProfile<any>;
		readonly record_migrations: string[];
		readonly declared_migrations: string[];
	}

	/** Lockless `get_data` before any fetch / flush. Thrown, never returned. */
	interface NotFetchedError extends ErrorBase {
		readonly type: "not_fetched";
		readonly profile: LocklessProfile<any>;
	}

	/** The profile is closed (or closed while the call waited for it). */
	interface ProfileClosedError extends ErrorBase {
		readonly type: "profile_closed";
		readonly profile: AnyProfile<any>;
		readonly reason: "unloaded" | "lock_lost";
	}

	/** The record's applied migrations do not prefix-match the declared ones. */
	interface MigrationMismatchError extends ErrorBase {
		readonly type: "migration_mismatch";
		readonly key: string;
		/** Set when a name differs: the record's and the declared migration there. */
		readonly index: number | undefined;
		readonly expected: string | undefined;
		readonly actual: string | undefined;
		/** Names the record has applied / this store declares. */
		readonly applied: string[];
		readonly declared: string[];
	}

	/** The transaction aborted. */
	interface TxAbortedError extends ErrorBase {
		readonly type: "tx_aborted";
		readonly id: string;
		/**
		 * The error of the participant that failed phase 1; `undefined` when
		 * the marker was already resolved as aborted by another server.
		 */
		readonly cause: DataforgeError | undefined;
	}

	/** The marker datastore holds something other than "committed" / "aborted". */
	interface TxMarkerInvalidError extends ErrorBase {
		readonly type: "tx_marker_invalid";
		readonly id: string;
		readonly value: unknown;
	}

	interface StoreClosedError extends ErrorBase {
		readonly type: "store_closed";
		readonly store: Store<any>;
	}

	interface AlreadyLoadedError extends ErrorBase {
		readonly type: "already_loaded";
		readonly store: Store<any>;
		readonly key: string;
	}

	/** Every runtime failure the library reports. Narrow on `type`. */
	type DataforgeError =
		| RobloxError
		| TimeoutError
		| LockLostError
		| ReleasedError
		| LocklessLockedError
		| TxLockLostError
		| OutdatedError
		| NotFetchedError
		| ProfileClosedError
		| MigrationMismatchError
		| TxAbortedError
		| TxMarkerInvalidError
		| StoreClosedError
		| AlreadyLoadedError;

	interface Ok<T> {
		readonly success: true;
		readonly value: T;
		/** Returns `value`. */
		unwrap(): T;
	}

	interface Err {
		readonly success: false;
		readonly error: DataforgeError;
		/** Throws `error` (the table itself). */
		unwrap(): never;
	}

	/**
	 * What every fallible call returns. Programmer errors (bad config, misuse
	 * of a transaction) and errors thrown by your own callbacks still throw.
	 */
	type Result<T> = Ok<T> | Err;

	/*
		Profiles
	*/

	/**
	 * The transform passed to `update`. Returns the new data, or
	 * `undefined` / `false` to leave it untouched.
	 */
	type DataDispatcher<T> = (data: T) => T | false | undefined;

	/** Shared shape of both profile kinds. */
	interface ProfileBase<T = unknown> {
		readonly kind: "locked" | "lockless";
		readonly key: string;
		readonly config: ResolvedConfig<T>;
		readonly user_ids: number[];
		readonly open: boolean;
		readonly migrations: string[];

		/**
		 * Current data. A plain accessor: throws a `DataforgeError`
		 * (`profile_closed`, or `not_fetched` for a lockless profile).
		 */
		get_data(): T;
		/** Fails with `profile_closed`, `released`, `roblox`, `lock_lost` (locked) or `lockless_locked`, `outdated`, ... (lockless). */
		save(): Result<void>;
		unload(): void;
		/**
		 * Applies `dispatcher` to the current data. Returning `undefined` or
		 * `false` leaves the data untouched (`Ok(false)`); anything else
		 * becomes the new data and is persisted on the next save (`Ok(true)`).
		 * Fails with `profile_closed` / `released`; an error thrown by the
		 * dispatcher propagates as is.
		 */
		update(dispatcher: DataDispatcher<T>): Result<boolean>;

		on_change(callback: (newData: T, oldData: T | undefined) => void): void;
		on_save(callback: () => void): void;
		/**
		 * Fires at the start of `unload`, while the profile is still open: the
		 * last chance to update before the final write.
		 */
		on_closing(callback: () => void): void;
		/**
		 * Fires once the profile is closed and its final write (if any) is done.
		 * Also fires after `lock_lost`.
		 */
		on_closed(callback: () => void): void;
		on_lock_lost(callback: () => void): void;

		/**
		 * Yields until no operation holds or waits on the profile mutex. Once
		 * this returns, the next update call is guaranteed not to yield.
		 */
		wait_settled(): void;
	}

	/** Session-locked profile. */
	interface Profile<T = unknown> extends ProfileBase<T> {
		readonly kind: "locked";
		readonly last_write: number;
		/**
		 * Whether the profile currently holds its session lock. True after
		 * `load`; `release` clears it, `readquire` takes it again. While
		 * released, `update` / `save` fail with `released` and the profile
		 * cannot join a transaction.
		 */
		readonly is_locked: boolean;

		/** Yields until the closed profile finished its final write. Throws if still open. */
		wait_closed(): void;

		/**
		 * Writes the data and gives the session lock back, keeping the profile
		 * open so another server may take the key. No-op when already released.
		 * Fails with `profile_closed`, `roblox` or `lock_lost`.
		 */
		release(): Result<void>;
		/**
		 * Takes the session lock again (waits like `load` does) and adopts the
		 * stored record as the current data. No-op when already locked. Fails
		 * with `timeout`, `profile_closed`, `roblox`, `migration_mismatch`.
		 */
		readquire(): Result<void>;
	}

	/** Profile without a session lock; updates are queued and folded into storage on save. */
	interface LocklessProfile<T = unknown> extends ProfileBase<T> {
		readonly kind: "lockless";
		readonly fetched: boolean;

		readonly queued_updates: DataDispatcher<T>[];
		readonly dirty_pending: boolean;

		/**
		 * Reads the stored record into the local data: migrations are applied,
		 * then the queued updates replayed on top. Marks the profile fetched.
		 * Yields. Fails (keeping the queue) with `lockless_locked` if a session
		 * lock is on the record, `roblox`, `migration_mismatch`, `profile_closed`.
		 */
		fetch(): Result<T>;
	}

	/** Either profile kind; narrow on `kind`. */
	type AnyProfile<T = unknown> = Profile<T> | LocklessProfile<T>;

	/**
	 * Read-only snapshot of a key. Not a `ProfileBase`: it cannot write, hold a
	 * lock or join a transaction. Returned by `store.peek`.
	 */
	interface PeekProfile<T = unknown> {
		readonly kind: "peek";
		readonly key: string;

		/** Lock currently on the record (session or transaction), `undefined` when free. */
		readonly lock: Lock | undefined;
		/** Transaction marker on the record, if any. Left as stored, never resolved. */
		readonly pending: Pending<T> | undefined;
		/** Migration names after the in-memory migrations of the last read. */
		readonly migrations: string[];

		get_data(): T;
		/**
		 * Calls `GetAsync` again and replaces `lock`, `pending`, `migrations`
		 * and the data. Yields. Fails with `roblox` or `migration_mismatch`,
		 * keeping the previous snapshot.
		 */
		refresh(): Result<T>;
	}

	/*
		Transactions
	*/

	interface TxContext {
		get<T>(profile: ProfileBase<T>): T;
		set<T>(profile: ProfileBase<T>, newData: T): void;
	}

	/*
		Store
	*/

	interface Store<T = unknown> {
		readonly closed: boolean;
		readonly config: ResolvedConfig<T>;

		readonly profiles: ReadonlyMap<string, Profile<T>>;
		readonly lockless_profiles: ReadonlyMap<string, LocklessProfile<T>>;

		/**
		 * Takes the session lock for `key` and loads it. Yields. Fails with
		 * `store_closed`, `already_loaded`, `timeout`, `roblox`,
		 * `migration_mismatch` or `tx_marker_invalid`.
		 */
		load(key: string, user_ids: number[]): Result<Profile<T>>;
		/**
		 * Returns the profile for `key`, waiting for it to load or loading it
		 * if nobody has yet. Waiters get the same result as the load.
		 */
		wait_loaded(key: string, user_ids: number[]): Result<Profile<T>>;
		get_loaded(key: string): Profile<T> | undefined;

		/**
		 * Returns the lockless profile for `key`, creating it if needed. Never
		 * yields: a lockless profile does no storage work until `fetch`.
		 * Throws a `store_closed` error on a closed store.
		 */
		get_lockless(key: string, user_ids: number[]): LocklessProfile<T>;

		/**
		 * Read-only snapshot of `key` via `GetAsync`: the current data and lock.
		 * Yields. The result is not tracked by the store, takes no lock and
		 * cannot join a transaction. Fails with `store_closed`, `roblox` or
		 * `migration_mismatch`.
		 */
		peek(key: string): Result<PeekProfile<T>>;

		/**
		 * Atomically updates profiles of this store (locked or lockless).
		 * `transform` gets their data in order and returns the new data in the
		 * same order, or `false` to cancel. `Ok(false)` when cancelled,
		 * `Ok(true)` when committed; fails like `dataforge.transaction`, plus
		 * `store_closed`.
		 */
		transaction(
			profiles: ProfileBase<T>[],
			transform: (data: T[]) => T[] | false,
			config?: TransactionConfig,
		): Result<boolean>;

		on_change(callback: (profile: AnyProfile<T>, newData: T, oldData: T | undefined) => void): void;
		on_save(callback: (profile: AnyProfile<T>) => void): void;
		on_closing(callback: (profile: AnyProfile<T>) => void): void;
		on_closed(callback: (profile: AnyProfile<T>) => void): void;
		on_lock_lost(callback: (profile: AnyProfile<T>) => void): void;

		/**
		 * Unloads every profile (locked and lockless) concurrently and waits for
		 * all of them. Loads and transactions are rejected from the first line on.
		 */
		close(): void;
	}

	/*
		Module
	*/

	/** Creates a store over the datastore named `config.name`. Throws if `name` or `template` is missing. */
	function create_store<T>(config: Config<T>): Store<T>;

	/**
	 * Atomically updates any set of profiles, across stores and mixing locked
	 * and lockless ones. `process` reads with `ctx.get(profile)` and stages
	 * writes with `ctx.set(profile, newData)`; return `false` to cancel.
	 *
	 * `Ok(false)` when cancelled, `Ok(true)` when committed. Fails with
	 * `tx_aborted` (see its `cause`), `profile_closed`, `released`, or what
	 * flushing a lockless participant raised. Misuse and errors thrown by
	 * `process` throw. `config` defaults its retry settings to the first
	 * profile's.
	 */
	function transaction(
		profiles: ProfileBase<any>[],
		process: (ctx: TxContext) => boolean | undefined,
		config?: TransactionConfig,
	): Result<boolean>;

	namespace hooks {
		namespace memory {
			function create(scheduler: Scheduler): MemoryHook;
		}
		namespace roblox {
			/** Adapts `DataStoreService`. Default inside Roblox. */
			function create(): Hook;
		}
	}

	namespace schedulers {
		namespace virtual {
			function create(): VirtualScheduler;
		}
		namespace roblox {
			/** Wraps the `task` library. Default inside Roblox. */
			function create(): Scheduler;
		}
	}
}

export = dataforge;
