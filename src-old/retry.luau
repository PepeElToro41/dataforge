--!strict

local runtime = require "./runtime"

--- Calls `fn` up to `attempts` times, waiting `base * 2^(attempt-1)` seconds
--- between failures. Rethrows the last error.
local function retry<T>(attempts: number, base: number, fn: () -> T): T
	local last_error: any = nil
	for attempt = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		last_error = result
		if attempt < attempts then
			runtime.wait(base * 2 ^ (attempt - 1))
		end
	end
	error(last_error, 0)
end

return retry
