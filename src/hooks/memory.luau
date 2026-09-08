--!strict

local types = require "../types"
local utils = require "../utils"

--[[
	In-memory hook. Meant for tests (the library's own and yours).

	- Every store handle created from the same hook shares one backend table, so
	  several `create_store` instances over one hook behave like several servers.
	- Values are deep-copied on the way in and out (no aliasing with the backend).
	- `latency` (seconds) is waited through the runtime before every operation, so
	  op interleavings are controllable under the virtual scheduler.
	- `fail_next(store, key, op, mode)`: the next matching operation throws.
	  "before" throws without touching the backend; "after" performs the write and
	  then throws (simulates an unknown outcome / dying mid-call).
]]

export type Op = "get_async" | "set_async" | "update_async" | "remove_async" | "*"
export type FailMode = "before" | "after"

export type OpLogEntry = { store: string, key: string, op: string }

export type MemoryHook = types.Hook & {
	scheduler: types.Scheduler,

	data: { [string]: { [string]: any } },
	latency: number,
	ops: { OpLogEntry },
	--- every message the library reported through `warn` (nothing is printed)
	warnings: { string },
	fail_next: (self: MemoryHook, store: string, key: string, op: Op, mode: FailMode, message: string?) -> (),
	dump: (self: MemoryHook, store: string, key: string) -> any?,
	clear_failures: (self: MemoryHook) -> (),
}

type Failure = {
	store: string,
	key: string,
	op: Op,
	mode: FailMode,
	message: string,
}

local memory = {}

function memory.create(scheduler: types.Scheduler): MemoryHook
	local handles: { [string]: types.DatastoreHandle } = {}
	local failures: { Failure } = {}

	local self = {} :: MemoryHook

	self.data = {}
	self.latency = 0
	self.ops = {}
	self.warnings = {}
	self.scheduler = scheduler

	function self.warn(message: string)
		table.insert(self.warnings, message)
	end

	local function bucket(store: string): { [string]: any }
		local existing = self.data[store]
		if existing == nil then
			existing = {}
			self.data[store] = existing
		end
		return existing
	end

	local function take_failure(store: string, key: string, op: string, mode: FailMode): Failure?
		for index, failure in failures do
			local matches = failure.store == store
				and (failure.key == "*" or failure.key == key)
				and (failure.op == "*" or failure.op == op)
				and failure.mode == mode
			if matches then
				table.remove(failures, index)
				return failure
			end
		end
		return nil
	end

	local function begin(store: string, key: string, op: string)
		if self.latency > 0 then
			scheduler.wait(self.latency)
		end
		table.insert(self.ops, { store = store, key = key, op = op })
		local failure = take_failure(store, key, op, "before")
		if failure then
			error(failure.message, 0)
		end
	end

	local function finish(store: string, key: string, op: string)
		local failure = take_failure(store, key, op, "after")
		if failure then
			error(failure.message, 0)
		end
	end

	-- one id per hook instance: locks are owned by job id, so it must be stable
	local job_id = utils.uuid()
	function self.job_id()
		return job_id
	end

	function self.get_datastore(name: string): types.DatastoreHandle
		local existing = handles[name]
		if existing then
			return existing
		end
		local values = bucket(name)
		local handle = {} :: types.DatastoreHandle
		handle.name = name

		function handle.get_async(key: string): any?
			begin(name, key, "get_async")
			local value = utils.deep_copy(values[key])
			finish(name, key, "get_async")
			return value
		end

		function handle.set_async(key: string, value: any, _user_ids: { number }?)
			begin(name, key, "set_async")
			values[key] = utils.deep_copy(value)
			finish(name, key, "set_async")
		end

		function handle.update_async(key: string, transform: (old: any?) -> any?, _user_ids: { number }?): any?
			begin(name, key, "update_async")
			local old = utils.deep_copy(values[key])
			local new = transform(old)
			local result = old
			if new ~= nil then
				values[key] = utils.deep_copy(new)
				result = new
			end
			finish(name, key, "update_async")
			return result
		end

		function handle.remove_async(key: string)
			begin(name, key, "remove_async")
			values[key] = nil
			finish(name, key, "remove_async")
		end

		handles[name] = handle
		return handle
	end

	function self.fail_next(_, store, key, op, mode, message)
		table.insert(failures, {
			store = store,
			key = key,
			op = op,
			mode = mode,
			message = message or `memory hook: injected failure ({mode} {op} {store}/{key})`,
		})
	end
	function self.clear_failures()
		table.clear(failures)
	end

	function self.dump(_, store, key)
		return utils.deep_copy(bucket(store)[key])
	end

	return self
end

return memory
