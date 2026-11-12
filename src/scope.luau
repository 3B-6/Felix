--!strict

local _t = require("./types")
local Env = require("./util/env")

--[=[
	@class Scope

	Cleanup for one stay in a [State]. Everything added to a scope is cleaned up when the machine leaves that
	state, however it leaves: a normal transition, an interrupt, a timeout, [Machine:ForceState] or [Machine:Stop].

	Get the scope of the state whose callback is running with [Machine:GetScope].

	```lua
	attack.OnEnter = function(machine)
		local scope = machine:GetScope()
		scope:Add(hitbox)                       -- hitbox:Destroy() on exit
		scope:Add(track.Stopped:Connect(onEnd)) -- disconnected on exit
		scope:Delay(0.3, function()             -- never runs if the attack is interrupted first
			machine:Send("Recovered")
		end)
	end
	```
]=]

--[=[
	@prop Active boolean
	@within Scope
	@readonly
	`true` until the state is left and the scope is cleaned up. A scope is never reused: entering the state
	again gives it a new one.
]=]

local Scope = {}
Scope.__index = Scope

local function CleanItem(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "thread" then
		Env.cancel(item)
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "table" then
		local method: any = item.Destroy or item.Disconnect or item.destroy or item.disconnect
		method(item)
	end
end

local function IsCleanable(item: any): boolean
	local kind = typeof(item)
	if kind == "function" or kind == "thread" or kind == "RBXScriptConnection" or kind == "Instance" then
		return true
	end
	if kind == "table" then
		return typeof(item.Destroy or item.Disconnect or item.destroy or item.disconnect) == "function"
	end
	return false
end

function Scope.new(machine: _t.MachineClass, state: _t.State): _t.Scope
	local self = setmetatable({
		Active = true,
		_Machine = machine,
		_State = state,
		_Items = {},
		-- Set of this scope's pending timers; the machine's list is what fires them
		_Timers = {},
	}, Scope)

	return self :: any
end

--[=[
	@method Add
	@within Scope
	@param item T -- A function, thread, Instance, RBXScriptConnection, or a table with a `Destroy` or `Disconnect` method
	@return T -- The same item, so it can be added inline

	Cleans `item` up when the state is left: functions are called, threads cancelled, Instances destroyed,
	connections disconnected, and tables have their `Destroy` (or `Disconnect`) method called.
	Items are cleaned in reverse order of adding. Adding to a scope that was already cleaned cleans the item immediately.

	```lua
	local hitbox = machine:GetScope():Add(Hitbox.new(character))
	```
]=]
function Scope.Add<T>(self: _t.Scope, item: T): T
	if not IsCleanable(item) then
		error(`Scope:Add can't clean up a {typeof(item)}.`, 2)
	end

	if self.Active then
		table.insert((self :: any)._Items, item)
	else
		CleanItem(item)
	end

	return item
end

--[=[
	@method Delay
	@within Scope
	@param seconds number -- Machine time to wait, advanced by [Machine:Update]
	@param callback (...any) -> () -- Called with `...`
	@param ... any
	@return () -> () -- Cancels the timer

	Calls `callback` after `seconds` of machine time, unless the state is left first. Timers are driven by
	[Machine:Update], so they never fire without it, and fire at the earliest on the next `Update`.

	```lua
	-- Open the cancel window 0.25s into the attack
	machine:GetScope():Delay(0.25, function()
		machine.Context.CanCancel = true
	end)
	```
]=]
function Scope.Delay(self: _t.Scope, seconds: number, callback: (...any) -> (), ...: any): () -> ()
	local raw = self :: any
	local machine = raw._Machine
	machine._TimerOrder += 1

	local timer: _t.Timer = {
		Due = machine.Clock + seconds,
		Order = machine._TimerOrder,
		Callback = callback,
		Args = table.pack(...),
		Scope = self,
		Cancelled = not self.Active,
	}

	if self.Active then
		raw._Timers[timer] = true
		table.insert(machine._Timers, timer)
	end

	return function()
		timer.Cancelled = true
		raw._Timers[timer] = nil
	end
end

-- Cancels the scope's timers and cleans its items, newest first. Every item is cleaned even if one errors;
-- the first error is rethrown afterwards.
function Scope._Clean(self: _t.Scope)
	local raw = self :: any
	if not self.Active then
		return
	end
	self.Active = false

	for timer in raw._Timers do
		timer.Cancelled = true
	end
	table.clear(raw._Timers)

	local items = raw._Items
	local first_error = nil
	for i = #items, 1, -1 do
		local ok, err = pcall(CleanItem, items[i])
		if not ok and first_error == nil then
			first_error = err
		end
	end
	table.clear(items)

	if first_error ~= nil then
		error(first_error, 0)
	end
end

return Scope
