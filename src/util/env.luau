--!nocheck
--# selene: allow(undefined_variable) -- `task` is only touched after checking it exists
-- Thread helpers that use Roblox's `task` library when it exists and fall back to plain coroutines,
-- so Felix runs anywhere Luau does (Roblox, Lune, the standalone VM).

local hasTask = typeof(task) == "table"

local Env = {}

-- Runs `thread` (or a function, on a new thread) immediately with `...`.
function Env.spawn(thread, ...)
	if hasTask then
		return task.spawn(thread, ...)
	end

	if type(thread) == "function" then
		thread = coroutine.create(thread)
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		-- Match task.spawn: report the error without unwinding the caller
		print(err)
	end
	return thread
end

-- Stops `thread`, also unscheduling it if it's waiting on task.wait/task.delay.
function Env.cancel(thread)
	if hasTask then
		task.cancel(thread)
	else
		coroutine.close(thread)
	end
end

return Env
