local types = require "../types"

export type RobloxScheduler = types.Scheduler

local roblox_scheduler = {}

function roblox_scheduler.create()
	return {
		spawn = task.spawn,
		defer = task.defer,
		wait = task.wait,
		now = function()
			return DateTime.now().UnixTimestampMillis / 1000
		end,
	}
end

return roblox_scheduler
