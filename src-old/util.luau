--!strict

local util = {}

--- Recursively freezes a table (and nested tables). Non-table values are returned as-is.
function util.deep_freeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local tbl = value :: any
	if table.isfrozen(tbl) then
		return value
	end
	for _, child in tbl do
		if type(child) == "table" then
			util.deep_freeze(child)
		end
	end
	table.freeze(tbl)
	return value
end

--- Recursively copies a table. The copy is not frozen.
function util.deep_copy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = util.deep_copy(child)
	end
	return copy :: any
end

--- Returns true when both tables have exactly the same set of keys.
function util.same_key_set(a: { [any]: any }, b: { [any]: any }): boolean
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

local HEX = "0123456789abcdef"

--- Random 16-char hex id. Collisions are astronomically unlikely; used for server ids.
function util.uid(): string
	local chars = table.create(16)
	for index = 1, 16 do
		local nibble = math.random(1, 16)
		chars[index] = string.sub(HEX, nibble, nibble)
	end
	return table.concat(chars)
end

--- pcall that always yields exactly (ok, err_or_first_result), even when `fn` returns nothing.
function util.try(fn: (...any) -> ...any, ...: any): (boolean, any)
	local results = table.pack(pcall(fn, ...))
	return results[1], results[2]
end

--- Shallow copy of an array sorted with the provided comparator.
function util.sorted<T>(list: { T }, less: (T, T) -> boolean): { T }
	local copy = table.clone(list)
	table.sort(copy, less)
	return copy
end

--- Id a transaction locks a lockless key with. Distinct from the server id so
--- a locked profile on the same server never mistakes it for its own lock.
function util.tx_lock_id(server_id: string): string
	return server_id .. ":tx"
end

--- Whether a stored record carries a transaction lock (see `types.Lock.tx`),
--- as opposed to a session lock held by a locked profile.
function util.is_tx_lock(record: any): boolean
	return type(record) == "table" and type(record.lock) == "table" and record.lock.tx == true
end

--- Applies every migration in `migrations` whose name is not in `applied`
--- (in declaration order). Pure: returns the migrated data, the new applied
--- list and whether anything ran. Safe to call inside an update transform.
function util.migrate<T>(
	migrations: { { name: string, apply: (data: T) -> T } },
	data: T,
	applied: { string }?
): (T, { string }, boolean)
	local names: { string } = if applied then table.clone(applied) else {}
	local changed = false
	for _, migration in migrations do
		if table.find(names, migration.name) == nil then
			data = migration.apply(data)
			if data == nil then
				error(`datastore: migration "{migration.name}" returned nil`)
			end
			table.insert(names, migration.name)
			changed = true
		end
	end
	return data, names, changed
end

return util
