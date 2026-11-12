--!strict

local _t = require("./types")

--[=[
	@class Transition

	A move from one [State] to another, fired by a trigger. Insert it into the `Transitions` list of the state it leaves.

	```lua
	table.insert(locked.Transitions, Felix.Transition.new({
		From = "Locked",
		Target = "Open",
		Triggers = { "Unlock" },
		Conditions = { function(machine) return machine.Context.HasKey end },
		Effects = { function(machine) playSound("Click") end },
	}))
	```
]=]

--[=[
	@prop From string
	@within Transition
	The state this transition leaves. It must match the state whose `Transitions` list it's in ([Machine:Start]
	checks), or be `"*"` for transitions in [Machine.AnyTransitions].
]=]

--[=[
	@prop Target string
	@within Transition
	The name of the state to enter.
]=]

--[=[
	@prop Triggers { string }
	@within Transition
	The trigger names that fire this transition.
]=]

--[=[
	@prop Conditions { Condition }
	@within Transition
	Guards. All must return `true` for the transition to fire.
]=]

--[=[
	@prop Effects { Effect }
	@within Transition
	Actions, run in order after the old state exits and before the new state enters.
]=]

--[=[
	@prop Priority number?
	@within Transition
	How hard this transition interrupts. It only fires if `Priority` is at least the current state's
	[State.Resistance]. Defaults to `0`. Use `math.huge` for transitions nothing should block, like dying.
]=]

--[=[
	@prop Except { string }?
	@within Transition
	For transitions in [Machine.AnyTransitions]: states it doesn't fire from. A state's children are excluded too.
]=]

local Transition = {}
Transition.__index = Transition

--[=[
	@within Transition
	@param params { From: string, Target: string, Triggers: { string }, Conditions: { Condition }?, Effects: { Effect }?, Priority: number?, Except: { string }? }
	@return Transition
]=]
function Transition.new(params: _t.Transition): _t.Transition
	local self = setmetatable({
		From = params.From,
		Target = params.Target,
		Triggers = params.Triggers,
		Effects = params.Effects or {},
		Conditions = params.Conditions or {},
		Priority = params.Priority,
		Except = params.Except,
	}, Transition)

	return self :: any
end

return Transition
