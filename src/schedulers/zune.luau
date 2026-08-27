local types = require "../types"

export type RobloxScheduler = types.Scheduler

local zune_scheduler = {}

function zune_scheduler.create()
	return {
		spawn = zune.task.spawn,
		defer = zune.task.defer,
		wait = zune.task.wait,
		now = function()
			return zune.time.timestampMillis() / 1000
		end,
	}
end

return zune_scheduler
