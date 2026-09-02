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

		/** Current data. Throws if the profile is closed or (lockless) not fetched. */
		get_data(): T;
		save(): void;
		unload(): void;
		/**
		 * Applies `dispatcher` to the current data. Returning `undefined` or
		 * `false` leaves the data untouched (returns `false`); anything else
		 * becomes the new data and is persisted on the next save.
		 */
		update(dispatcher: DataDispatcher<T>): boolean;

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
		 * released, `update` / `save` throw and the profile cannot join a
		 * transaction.
		 */
		readonly is_locked: boolean;

		/** Yields until the closed profile finished its final write. Throws if still open. */
		wait_closed(): void;

		/**
		 * Writes the data and gives the session lock back, keeping the profile
		 * open so another server may take the key. No-op when already released.
		 */
		release(): void;
		/**
		 * Takes the session lock again (waits like `load` does) and adopts the
		 * stored record as the current data. No-op when already locked.
		 */
		readquire(): void;
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
		 * Yields. Throws (keeping the queue) if a session lock is on the record.
		 */
		fetch(): T;
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
		/** Calls `GetAsync` again and replaces `lock`, `pending`, `migrations` and the data. Yields. */
		refresh(): T;
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

		/** Takes the session lock for `key` and loads it. Yields. Throws when already loaded. */
		load(key: string, user_ids: number[]): Profile<T>;
		/** Returns the profile for `key`, waiting for it to load or loading it if nobody has yet. */
		wait_loaded(key: string, user_ids: number[]): Profile<T>;
		get_loaded(key: string): Profile<T> | undefined;

		/**
		 * Returns the lockless profile for `key`, creating it if needed. Never
		 * yields: a lockless profile does no storage work until `fetch`.
		 */
		get_lockless(key: string, user_ids: number[]): LocklessProfile<T>;

		/**
		 * Read-only snapshot of `key` via `GetAsync`: the current data and lock.
		 * Yields. The result is not tracked by the store, takes no lock and
		 * cannot join a transaction.
		 */
		peek(key: string): PeekProfile<T>;

		/**
		 * Atomically updates profiles of this store (locked or lockless).
		 * `transform` gets their data in order and returns the new data in the
		 * same order, or `false` to cancel. Returns `false` when cancelled,
		 * `true` when committed; throws when aborted.
		 */
		transaction(
			profiles: ProfileBase<T>[],
			transform: (data: T[]) => T[] | false,
			config?: TransactionConfig,
		): boolean;

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
	 * Returns `false` when cancelled, `true` when committed. Throws when aborted.
	 * `config` defaults its retry settings to the first profile's.
	 */
	function transaction(
		profiles: ProfileBase<any>[],
		process: (ctx: TxContext) => boolean | undefined,
		config?: TransactionConfig,
	): boolean;

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
