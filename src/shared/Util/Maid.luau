-- Maid: collects connections, instances and cleanup functions, and cleans them all at once.

local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end

function Maid:Give(task)
	table.insert(self._tasks, task)
	return task
end

local function clean(task)
	local kind = typeof(task)
	if kind == "function" then
		task()
	elseif kind == "RBXScriptConnection" then
		task:Disconnect()
	elseif kind == "Instance" then
		task:Destroy()
	elseif kind == "table" then
		if task.Destroy then
			task:Destroy()
		elseif task.Disconnect then
			task:Disconnect()
		end
	end
end

function Maid:Clean()
	local tasks = self._tasks
	self._tasks = {}
	for index = #tasks, 1, -1 do
		clean(tasks[index])
	end
end

Maid.Destroy = Maid.Clean

return Maid
