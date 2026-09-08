--!nocheck
--!nolint UnknownGlobal

local types = require "../types"
local utils = require "../utils"

--[[
	DataStoreService hook. Only usable inside Roblox.
]]

local roblox_hook = {}

function roblox_hook.create(): types.Hook
	local DataStoreService = game:GetService "DataStoreService"
	local handles: { [string]: types.DatastoreHandle } = {}

	local self = {} :: types.Hook

	self.warn = warn

	-- `game.JobId` is an empty string in Studio, so every Studio session would
	-- share the same lock owner and transaction id prefix. Generate a random
	-- one once per hook instead; locks are owned by job id, so it must be stable.
	local job_id: string = game.JobId
	if job_id == "" then
		job_id = `studio-{utils.uuid()}`
	end

	function self.job_id()
		return job_id
	end

	function self.get_datastore(name: string): types.DatastoreHandle
		local existing = handles[name]
		if existing then
			return existing
		end
		local datastore = DataStoreService:GetDataStore(name)
		local handle = {} :: types.DatastoreHandle
		handle.name = name

		function handle.get_async(key: string): any?
			return (datastore:GetAsync(key))
		end

		function handle.set_async(key: string, value: any, user_ids: { number }?)
			datastore:SetAsync(key, value, user_ids)
		end

		function handle.update_async(key: string, transform: (old: any?) -> any?, user_ids: { number }?): any?
			-- Capture the result inside the callback so semantics do not depend on
			-- what UpdateAsync returns when the callback cancels.
			local result: any = nil
			datastore:UpdateAsync(key, function(old: any?)
				local new = transform(old)
				if new == nil then
					result = old
					return nil
				end
				result = new
				return new, user_ids
			end)
			return result
		end

		function handle.remove_async(key: string)
			datastore:RemoveAsync(key)
		end

		handles[name] = handle
		return handle
	end

	return self
end

return roblox_hook
