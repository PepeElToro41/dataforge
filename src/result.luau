--!strict

local errors = require "./errors"
local types = require "./types"
local utils = require "./utils"

--[[
	`Result<T>`: what every fallible library call returns instead of throwing.

	Internally the library keeps throwing, but it throws `Error` tables (see
	`errors.luau`). `result.capture` at each public entry point turns an
	`Error` into `Err`; anything else (a string thrown by a user callback, an
	internal invariant) is rethrown untouched.
]]

export type Result<T> = types.Result<T>
export type Error = types.Error

local result_mt = {}
result_mt.__index = result_mt

function result_mt.unwrap(self: any): any
	if self.success then
		return self.value
	end
	error(self.error, 0)
end

local result = {}

function result.ok<T>(value: T): Result<T>
	return setmetatable({ success = true, value = value }, result_mt) :: any
end

function result.err(err: Error): Result<any>
	assert(errors.is(err), "result.err expects an Error table")
	return setmetatable({ success = false, error = err }, result_mt) :: any
end

function result.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == result_mt
end

--- Turns a `pcall` outcome into a Result: `Ok(value)` on success, `Err` when
--- the thrown value is an `Error` table, rethrown raw otherwise.
function result.of<T>(ok: boolean, value: any): Result<T>
	if ok then
		return result.ok(value)
	end
	if errors.is(value) then
		return result.err(value)
	end
	error(value, 0)
end

--- `pcall(fn, ...)` folded through `result.of`.
function result.capture<T>(fn: (...any) -> T, ...: any): Result<T>
	return result.of(utils.try(fn, ...))
end

return result
