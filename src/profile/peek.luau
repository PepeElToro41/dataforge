local common = require "./common"
local result = require "../result"
local types = require "../types"
local utils = require "../utils"

type DataRecord = types.DataRecord
export type PeekProfile<T = any> = types.PeekProfile<T>

export type PeekOptions = {
	key: string,
	_datastore: types.DatastoreHandle,
	_config: types.ResolvedConfig,
}

local peek_profile = {}
peek_profile.__index = peek_profile

--- Reads the record with `GetAsync` and adopts it: `lock` and `pending` are
--- taken as stored, the data gets the declared migrations applied in memory
--- (nothing is written). A missing key resolves to the template. Throws
--- `roblox` or `migration_mismatch`.
local function read(self: PeekProfile): any
	local config = self._config
	local datastore = self._datastore

	local record = utils.get_async(config, datastore, self.key) :: DataRecord?

	self.lock = if record then record.lock else nil
	self.pending = if record then record.pending else nil

	local data: any
	local migrations: { string }
	if record == nil or record.data == nil then
		data = utils.deep_copy(config.template)
		migrations = common.all_migration_names(config.migrations)
	else
		local migrated = common.apply_migrations(self.key, record.data, record.migrations or {}, config.migrations)
		if not migrated.success then
			error(migrated.err, 0)
		end
		data = migrated.result
		migrations = migrated.new_migrations
	end

	self.migrations = migrations
	self._data = utils.deep_freeze(data)
	return self._data
end

function peek_profile.get_data(self: PeekProfile)
	return self._data
end

--- Calls `get_async` again and replaces the snapshot. Yields. Fails with
--- `roblox` or `migration_mismatch`, leaving the previous snapshot in place.
function peek_profile.refresh(self: PeekProfile): types.Result<any>
	return result.capture(read, self)
end

--- Takes the first snapshot right away (yields). The profile has no mutex, no
--- loops and no hooks: it is a plain value that can be refreshed. Fails with
--- `roblox` or `migration_mismatch`.
function peek_profile.create(options: PeekOptions): types.Result<PeekProfile>
	local self = {} :: PeekProfile
	self.kind = "peek"
	self.key = options.key
	self._datastore = options._datastore
	self._config = options._config
	self.lock = nil
	self.pending = nil
	self.migrations = {}
	self._data = nil :: any

	local profile = setmetatable(self, peek_profile) :: any
	local first = result.capture(read, profile)
	if not first.success then
		return first
	end
	return result.ok(profile)
end

return {
	create = peek_profile.create,
}
