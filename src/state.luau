--!strict

local _t = require("./types")

--[=[
	@class State

	A state a [Machine] can be in. Created with `Felix.State.new(name)`.

	```lua
	local jump = Felix.State.new("Jump")

	jump.OnEnter = function(machine)
		print("Jumping!")
	end
	```
]=]

--[=[
	@prop Name string
	@within State
	The state's name. Transitions target states by this name, so it must be unique within a machine.
]=]

--[=[
	@prop Transitions { Transition }
	@within State
	The transitions that can leave this state, checked in order when a trigger is sent. Add to it with `table.insert`.
]=]

--[=[
	@prop OnEnter Callback?
	@within State
	Called with the machine and any event data when the machine enters this state.
]=]

--[=[
	@prop OnExit Callback?
	@within State
	Called with the machine and any event data when the machine leaves this state.
]=]

--[=[
	@prop OnUpdate UpdateCallback?
	@within State
	Called with the machine and `dt` on every [Machine:Update] while the machine is in this state (or in one of
	its children). Parents run before children.
]=]

--[=[
	@prop Parent string?
	@within State
	The name of this state's parent, for hierarchical machines. While a child is active its parents are too:
	[Machine:Is] matches them, their transitions, [State.Tags] and [State.Resistance] apply, and they're only
	exited when a transition leaves them.

	```lua
	local combat = Felix.State.new("Combat")
	local light = Felix.State.new("Light")
	light.Parent = "Combat"
	```
]=]

--[=[
	@prop Initial string?
	@within State
	The child entered automatically when this state is entered, so a transition can target a parent.
]=]

--[=[
	@prop Duration number?
	@within State
	Seconds of machine time after which the machine moves to [State.Next] on its own. Driven by [Machine:Update].
	The move ignores Conditions and [State.Resistance]: it's the state ending, not an interrupt.

	```lua
	windup.Duration = 0.15
	windup.Next = "Active"
	```
]=]

--[=[
	@prop Next string?
	@within State
	The state entered when [State.Duration] runs out. Required when `Duration` is set.
]=]

--[=[
	@prop Resistance Resistance?
	@within State
	The minimum [Transition.Priority] needed to leave this state, or a function returning it. Defaults to the
	nearest parent's Resistance, or `0`. A function is re-evaluated on every Send, which makes cancel windows easy:

	```lua
	-- Uncancellable for the first 0.25s, then anything goes
	heavy.Resistance = function(machine)
		return if machine:GetTimeInState() < 0.25 then 10 else 0
	end
	```

	Timeouts ([State.Duration]), [Machine:ForceState] and [Machine:Stop] ignore it.
]=]

--[=[
	@prop Tags { [string]: any }?
	@within State
	Values that describe the state, read with [Machine:HasTag] and [Machine:GetTag]. A child's tag overrides its parent's.

	```lua
	dodge.Tags = { Invulnerable = true, CanMove = false }
	```
]=]

local State = {}
State.__index = State

function State._Enter(self: _t.State, machine: _t.MachineClass, ...: any): _t.Delta
	local start_time = os.clock()

	if self.OnEnter then
		self.OnEnter(machine, ...)
	end

	return os.clock() - start_time
end

function State._Exit(self: _t.State, machine: _t.MachineClass, ...: any): _t.Delta
	local start_time = os.clock()

	if self.OnExit then
		self.OnExit(machine, ...)
	end

	return os.clock() - start_time
end

--[=[
	@method Trigger
	@within State
	@param trigger string
	@param machine Machine
	@param ... any -- Event data, passed to each Condition
	@return Transition? -- The first transition listening for `trigger` whose Conditions all pass

	Finds the transition in this state's own `Transitions` that a trigger would fire, without running it.
	It doesn't look at parents, the machine's `AnyTransitions` or [State.Resistance]; use [Machine:CanSend] for that.
]=]
function State.Trigger(self: _t.State, request: _t.Trigger, machine: _t.MachineClass, ...: any): _t.Transition?
	for _, transition in self.Transitions do
		if not table.find(transition.Triggers, request) then
			continue
		end

		local passed = true
		local conditions = transition.Conditions
		if conditions then
			for _, condition in conditions do
				if not condition(machine, ...) then
					passed = false
					break
				end
			end
		end

		if passed then
			return transition
		end
	end

	return nil
end

--[=[
	@within State
	@param name string -- The state's name, unique within its machine
	@return State
]=]
function State.new(name: _t.StateName): _t.State
	local self = setmetatable({
		Name = name,
		Transitions = {},
	}, State)

	-- Methods come from the metatable, which the checker can't match against _t.State on its own
	return self :: any
end

return State
