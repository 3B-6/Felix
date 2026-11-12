--!nocheck
-- Loads a Rojo-built place in Lune and gives Roblox-style `require(ModuleScript)`
-- so Instance-based packages (like Arch from Wally) can run outside Studio.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Loader = {}

function Loader.build(projectPath: string, outPath: string)
	local result = process.exec("rojo", { "build", projectPath, "-o", outPath })
	if not result.ok then
		error(`rojo build failed:\n{result.stderr}`)
	end
end

-- Lune has no frame loop, so RunService events are emulated with task.wait()
local function createFrameEvent()
	local event = {}

	function event:Connect(fn)
		local connection = { Connected = true }
		connection.Disconnect = function()
			connection.Connected = false
		end

		task.spawn(function()
			while connection.Connected do
				local dt = task.wait()
				if connection.Connected then
					fn(dt)
				end
			end
		end)

		return connection
	end

	function event:Once(fn)
		local connection
		connection = event:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end

	function event:Wait()
		return task.wait()
	end

	return event
end

local function createGame(dataModel)
	local runService = {
		Heartbeat = createFrameEvent(),
		Stepped = createFrameEvent(),
		RenderStepped = createFrameEvent(),
		PostSimulation = createFrameEvent(),
		PreSimulation = createFrameEvent(),
	}
	function runService:IsStudio()
		return false
	end
	function runService:IsServer()
		return true
	end
	function runService:IsClient()
		return false
	end

	local proxy = {}

	function proxy:GetService(name: string)
		if name == "RunService" then
			return runService
		end
		return dataModel:GetService(name)
	end

	function proxy.Destroy(instance)
		instance:Destroy()
	end

	return setmetatable(proxy, {
		__index = function(_, key)
			return dataModel[key]
		end,
	})
end

function Loader.loadPlace(placePath: string)
	local dataModel = roblox.deserializePlace(fs.readFile(placePath))
	local game = createGame(dataModel)
	local workspace = dataModel:GetService("Workspace")

	local cache = {}
	local loading = {}
	local warningsMuted = false

	local env = {
		game = game,
		workspace = workspace,
		task = task,
		tick = os.clock,
		warn = function(...)
			if not warningsMuted then
				local parts = table.pack(...)
				for i = 1, parts.n do
					parts[i] = tostring(parts[i])
				end
				stdio.ewrite(stdio.color("yellow") .. table.concat(parts, " ") .. stdio.color("reset") .. "\n")
			end
		end,
	}

	-- Roblox datatypes (Instance, Enum, Vector3, ...)
	for name, value in roblox do
		if string.match(name, "^%u") then
			env[name] = value
		end
	end

	local function requireModule(module)
		if typeof(module) ~= "Instance" or not module:IsA("ModuleScript") then
			error(`Attempted to require a non-ModuleScript: {tostring(module)}`, 2)
		end

		local key = module:GetFullName()
		local cached = cache[key]
		if cached ~= nil then
			return cached.value
		end
		if loading[key] then
			error(`Cyclic require detected: {key}`, 2)
		end
		loading[key] = true

		-- luau.load copies the environment table, so it must be flat (no __index)
		local moduleEnv = table.clone(env)
		moduleEnv.script = module
		moduleEnv.require = requireModule
		local chunk = luau.load(module.Source, {
			debugName = key,
			environment = moduleEnv,
		})

		local results = table.pack(chunk())
		if results.n ~= 1 then
			error(`Module {key} did not return exactly one value`)
		end

		local value = results[1]
		cache[key] = { value = value }
		loading[key] = nil
		return value
	end

	env.require = requireModule

	return {
		game = game,
		require = requireModule,
		setWarningsMuted = function(muted: boolean)
			warningsMuted = muted
		end,
	}
end

return Loader
