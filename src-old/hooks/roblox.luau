--!nocheck
--!nolint UnknownGlobal

local types = require "../types"

--[[
	DataStoreService hook. Only usable inside Roblox.
]]

local roblox = {}

function roblox.new(): types.Hook
	local DataStoreService = game:GetService "DataStoreService"
	local handles: { [string]: types.StoreHandle } = {}

	local self = {} :: types.Hook

	function self.get_store(name: string): types.StoreHandle
		local existing = handles[name]
		if existing then
			return existing
		end
		local datastore = DataStoreService:GetDataStore(name)
		local handle = {} :: types.StoreHandle

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

return roblox
