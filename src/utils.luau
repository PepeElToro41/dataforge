local types = require "./types"

export type Counter = types.Counter

local utils = {}

--- Recursively freezes a table (and nested tables). Non-table values are returned as-is.
function utils.deep_freeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local tbl = value :: any
	if table.isfrozen(tbl) then
		return value
	end
	for _, child in tbl do
		if type(child) == "table" then
			utils.deep_freeze(child)
		end
	end
	table.freeze(tbl :: {})
	return value
end

--- Recursively copies a table. The copy is not frozen.
function utils.deep_copy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = utils.deep_copy(child)
	end
	return copy :: any
end

--- Returns true when both tables have exactly the same set of keys.
function utils.same_key_set(a: { [any]: any }, b: { [any]: any }): boolean
	for key in a do
		if b[key] == nil then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

--- pcall that always yields exactly (ok, err_or_first_result), even when `fn` returns nothing.
function utils.try(fn: (...any) -> ...any, ...: any): (boolean, any)
	local results = { pcall(fn, ...) }
	return results[1], results[2]
end

--- Shallow copy of an array sorted with the provided comparator.
function utils.sorted<T>(list: { T }, less: (T, T) -> boolean): { T }
	local copy = table.clone(list)
	table.sort(copy, less)
	return copy
end

local HEX = "0123456789abcdef"

--- Random 16-char hex id. Collisions are astronomically unlikely, Alternative to httpservice.
function utils.uuid(): string
	local chars = table.create(16)
	for index = 1, 16 do
		local nibble = math.random(1, 16)
		chars[index] = string.sub(HEX, nibble, nibble)
	end
	return table.concat(chars)
end

function utils.retry<T>(config: types.RetryConfig, callback: () -> T): T
	local last_error: any = nil
	local attempts = config.retry_attempts
	local base = config.retry_base

	for attempt = 1, attempts do
		local ok, result = pcall(callback)
		if ok then
			return result
		end
		last_error = result
		if attempt < attempts then
			config._scheduler.wait(base * 2 ^ (attempt - 1))
		end
	end
	error(last_error, 0)
end

function utils.counter(): Counter
	local count = 0
	return function()
		local current = count
		count += 1
		return current
	end
end

return utils
