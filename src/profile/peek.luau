local common = require "./common"
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
--- (nothing is written). A missing key resolves to the template.
local function read(self: PeekProfile): any
	local config = self._config
	local datastore = self._datastore

	local record = utils.retry(config, function()
		return datastore.get_async(self.key)
	end) :: DataRecord?

	self.lock = if record then record.lock else nil
	self.pending = if record then record.pending else nil

	local data: any
	local migrations: { string }
	if record == nil or record.data == nil then
		data = utils.deep_copy(config.template)
		migrations = common.all_migration_names(config.migrations)
	else
		local result = common.apply_migrations(record.data, record.migrations or {}, config.migrations)
		if not result.success then
			error(`datastore: failed to apply migrations for "{self.key}": {result.err}`)
		end
		data = result.result
		migrations = result.new_migrations
	end

	self.migrations = migrations
	self._data = utils.deep_freeze(data)
	return self._data
end

function peek_profile.get_data(self: PeekProfile)
	return self._data
end

--- Calls `get_async` again and replaces the snapshot. Yields.
function peek_profile.refresh(self: PeekProfile)
	return read(self)
end

--- Takes the first snapshot right away (yields). The profile has no mutex, no
--- loops and no hooks: it is a plain value that can be refreshed.
function peek_profile.create(options: PeekOptions): PeekProfile
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
	read(profile)
	return profile
end

return {
	create = peek_profile.create,
}
