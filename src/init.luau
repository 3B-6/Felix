--!strict
local _t = require("@self/types")
local Signal = require("@self/util/signal")
local Env = require("@self/util/env")
local Scope = require("@self/scope")

-- Public types, used as Felix.Machine, Felix.State, etc. `C` is the Context type and defaults to `any`.
export type Machine<C = any> = _t.MachineClass<C>
export type State<C = any> = _t.State<C>
export type Transition<C = any> = _t.Transition<C>
export type Details<C = any> = _t.Details<C>
export type Callback<C = any> = _t.Callback<C>
export type UpdateCallback<C = any> = _t.UpdateCallback<C>
export type Effect<C = any> = _t.Effect<C>
export type Condition<C = any> = _t.Condition<C>
export type Resistance<C = any> = _t.Resistance<C>
export type Scope = _t.Scope
export type Snapshot = _t.Snapshot
export type RejectReason = _t.RejectReason
export type Trigger = _t.Trigger
export type StateName = _t.StateName
export type Connection = _t.Connection

--[=[
	@class Felix

	The package. Creates machines, and holds the [State] and [Transition] constructors.

	```lua
	local Felix = require(ReplicatedStorage.Packages.Felix)

	local door = Felix.new("Door", "Closed", nil, { closed, open })
	```
]=]

--[=[
	@class Machine

	A state machine, created by [Felix.new]. It holds a list of [State]s, is in at most one of them at a time
	(plus that state's parents, see [State.Parent]), and moves between them when you [Machine:Send] a trigger
	that one of the current state's [Transition]s listens for.

	`C` is the type of the machine's [Machine.Context]. It defaults to `any`.

	Fields starting with an underscore (`_Queue`, `_Transitioning`, …) are internal and may change between versions.
]=]

--[=[
	@prop Current State?
	@within Machine
	@readonly
	The state the machine is in, or `nil` when it isn't running. In a hierarchical machine this is the innermost
	active state; use [Machine:Is] to also match its parents.
]=]

--[=[
	@prop Previous State?
	@within Machine
	@readonly
	The state the machine was in before the last transition, or `nil` right after [Machine:Start].
]=]

--[=[
	@prop Active boolean
	@within Machine
	@readonly
	Whether the machine is running: `true` between [Machine:Start] and [Machine:Stop].
]=]

--[=[
	@prop Context C
	@within Machine
	A table shared by every callback, for data like health, ammo or a target. It's the same table passed as
	`Context` in [Felix.Details], or an empty table if none was passed.
]=]

--[=[
	@prop Clock number
	@within Machine
	@readonly
	Machine time in seconds: the sum of every `dt` passed to [Machine:Update]. [State.Duration], [Scope:Delay],
	[Machine:Buffer] windows and [Machine:GetTimeInState] all use it.
]=]

--[=[
	@prop AnyTransitions { Transition }
	@within Machine
	Transitions that can fire from any state, for interrupts like getting stunned or dying. They're checked after
	the current state's own transitions and its parents', so a state can handle a trigger its own way.
	Their `From` must be `"*"`, and their `Except` lists states they don't fire from.

	```lua
	table.insert(fighter.AnyTransitions, Felix.Transition.new({
		From = "*",
		Target = "Dead",
		Triggers = { "Die" },
		Priority = math.huge,
		Except = { "Dead" },
	}))
	```
]=]

--[=[
	@prop ID any
	@within Machine
	@readonly
	The `id` passed to [Felix.new]. Used in error messages.
]=]

--[=[
	@prop Default string
	@within Machine
	@readonly
	The name of the state entered by [Machine:Start].
]=]

--[=[
	@prop StateChanged Signal
	@within Machine
	@readonly
	Fires with `(newState, oldState, ...)` whenever [Machine.Current] changes: after a state's `OnEnter` runs,
	and after `OnExit` when the machine stops. `...` is the event data passed to [Machine:Send].
	`newState` is `nil` on [Machine:Stop], and `oldState` is `nil` on [Machine:Start]; neither has event data.

	A [Machine:Send] made from a handler is queued like one made from any other callback.

	Handlers run on their own thread. If a handler yields, the machine may have moved on by the time it resumes,
	so use the `newState` argument rather than reading [Machine.Current] after a yield.

	```lua
	local connection = machine.StateChanged:Connect(function(newState, oldState, ...)
		print(oldState and oldState.Name, "->", newState and newState.Name, ...)
	end)

	connection:Disconnect()
	```
]=]

--[=[
	@prop Rejected Signal
	@within Machine
	@readonly
	Fires with `(trigger, reason, ...)` when a [Machine:Send] doesn't transition. `reason` is a [Felix.RejectReason].
	Triggers retried by [Machine:Buffer] don't fire it.

	```lua
	fighter.Rejected:Connect(function(trigger, reason)
		warn(`{trigger} rejected: {reason}`) --> Parry rejected: Resisted
	end)
	```
]=]

--[=[
	@prop State State
	@within Felix
	The [State] constructor: `Felix.State.new(name)`.
]=]

--[=[
	@prop Transition Transition
	@within Felix
	The [Transition] constructor: `Felix.Transition.new(params)`.
]=]

local FelixMachine = {}
FelixMachine.__index = FelixMachine

FelixMachine.State = require("@self/state")
FelixMachine.Transition = require("@self/transition")

local DEFAULT_HISTORY_SIZE = 8
-- Timeouts into states with a zero Duration chain within one Update; this stops a loop of them
local MAX_TIMEOUTS_PER_UPDATE = 64
-- Clock is a sum of dts, so 0.05 * 4 can come out as 0.19999…; times this close count as reached,
-- so a 0.2s state doesn't end a frame late
local TIME_EPSILON = 1e-9

type MachineClass = _t.MachineClass
type StateT = _t.State
type TransitionT = _t.Transition

--------------------------------------------------------------------------------
-- Running callbacks
--
-- With CatchYields (or DebugMode), transitions run on a cached runner thread so a callback that yields can be
-- caught: if the thread comes back suspended instead of finished, a callback yielded, and the machine would
-- otherwise stay locked until it resumed.
--------------------------------------------------------------------------------

local DONE = table.freeze({})
local free_runner: thread? = nil
local result_ok = false
local result_value: any = nil

local function Call(fn: (...any) -> any, ...: any)
	result_ok, result_value = pcall(fn, ...)
end

local function RunnerBody(...: any)
	Call(...)
	while true do
		Call(coroutine.yield(DONE))
	end
end

local function Execute(machine: MachineClass, fn: (...any) -> any, ...: any): (boolean, any)
	-- A coroutine resume costs far more than a pcall, so yields are only caught when asked for
	local details = machine.Details
	if not (details and (details.CatchYields or details.DebugMode)) then
		return pcall(fn, ...)
	end

	local runner = free_runner or coroutine.create(RunnerBody)
	free_runner = nil

	local resumed, signal = coroutine.resume(runner, fn, ...)
	if resumed and signal == DONE then
		free_runner = runner
		local ok, value = result_ok, result_value
		result_value = nil
		return ok, value
	end

	-- A callback yielded. Stop it where it is, as if it had errored there.
	if coroutine.status(runner) == "suspended" then
		Env.cancel(runner)
	end

	return false,
		`Machine: [{machine.ID}] A callback yielded during a transition. Use machine:GetScope():Delay() to wait instead.`
end

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

local function FindState(machine: MachineClass, name: _t.StateName): StateT?
	local state = machine._Map[name]
	if state then
		return state
	end

	-- States added after Start
	local states = machine.States
	if not states then
		return nil
	end

	for _, candidate in states do
		if candidate.Name == name then
			machine._Map[name] = candidate
			return candidate
		end
	end

	return nil
end

local function ParentOf(machine: MachineClass, state: StateT): StateT?
	local name = state.Parent
	return if name then FindState(machine, name) else nil
end

-- trigger -> transitions, in list order. Rebuilt when the list's length changes, so inserts after Start count.
local function GetIndex(machine: MachineClass, list: { TransitionT }): { [_t.Trigger]: { TransitionT } }
	local index = machine._Index[list]
	if index and machine._Counts[list] == #list then
		return index
	end

	local fresh = {}
	for _, transition in list do
		for _, trigger in transition.Triggers do
			local bucket = fresh[trigger]
			if not bucket then
				bucket = {}
				fresh[trigger] = bucket
			end
			if bucket[#bucket] ~= transition then
				table.insert(bucket, transition)
			end
		end
	end

	machine._Index[list] = fresh
	machine._Counts[list] = #list
	return fresh
end

local function IsAny(machine: MachineClass, names: { _t.StateName }): boolean
	for _, state in machine._Active do
		if table.find(names, state.Name) then
			return true
		end
	end
	return false
end

-- The innermost active state's Resistance wins
local function GetResistance(machine: MachineClass): number
	local active = machine._Active
	for i = #active, 1, -1 do
		local resistance = active[i].Resistance
		if resistance ~= nil then
			if type(resistance) == "function" then
				return resistance(machine)
			end
			return resistance
		end
	end
	return 0
end

local function DebugEnabled(machine: MachineClass): boolean
	local details = machine.Details
	return details ~= nil and details.DebugMode == true
end

local function DebugPrint(machine: MachineClass, message: string)
	print(`[Felix:{machine.ID}] {message}`)
end

local function Ms(seconds: number): string
	return string.format("%.3f ms", seconds * 1000)
end

--------------------------------------------------------------------------------
-- Choosing a transition
--------------------------------------------------------------------------------

-- Finds the first candidate that fires, carrying the best rejection reason so far and the (lazily computed)
-- current Resistance across calls.
local function Pick(
	machine: MachineClass,
	candidates: { TransitionT },
	check_except: boolean,
	reason: _t.RejectReason,
	resistance: number?,
	...: any
): (TransitionT?, _t.RejectReason, number?)
	for _, transition in candidates do
		local except = transition.Except
		if check_except and except and IsAny(machine, except) then
			continue
		end

		local required: number
		if resistance then
			required = resistance
		else
			required = GetResistance(machine)
			resistance = required
		end
		if (transition.Priority or 0) < required then
			reason = "Resisted"
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
			return transition, reason, resistance
		end

		if reason ~= "Resisted" then
			reason = "Conditions"
		end
	end

	return nil, reason, resistance
end

-- The transition `request` would fire: the current state's own first, then its parents', then AnyTransitions.
local function Select(machine: MachineClass, request: _t.Trigger, ...: any): (TransitionT?, _t.RejectReason?)
	local active = machine._Active
	local reason: _t.RejectReason = "NoTransition"
	local resistance: number? = nil
	local found: TransitionT? = nil

	for i = #active, 1, -1 do
		local candidates = GetIndex(machine, active[i].Transitions)[request]
		if candidates then
			found, reason, resistance = Pick(machine, candidates, false, reason, resistance, ...)
			if found then
				return found, nil
			end
		end
	end

	local any = machine.AnyTransitions
	if #any > 0 then
		local candidates = GetIndex(machine, any)[request]
		if candidates then
			found, reason, resistance = Pick(machine, candidates, true, reason, resistance, ...)
			if found then
				return found, nil
			end
		end
	end

	return nil, reason
end

--------------------------------------------------------------------------------
-- Entering and exiting
--------------------------------------------------------------------------------

local function CleanScope(machine: MachineClass, state: StateT)
	local scope = machine._Scopes[state]
	if scope then
		machine._Scopes[state] = nil
		scope:_Clean()
	end
end

-- Exits active states from the innermost out, stopping at `stop` (which stays active). nil exits everything.
local function ExitTo(machine: MachineClass, debug_mode: boolean, stop: StateT?, ...: any)
	local active = machine._Active

	for i = #active, 1, -1 do
		local state = active[i]
		if state == stop then
			break
		end

		machine._Running = state
		if debug_mode then
			DebugPrint(machine, `Exit {state.Name} ({Ms(state:_Exit(machine, ...))})`)
		else
			local on_exit = state.OnExit
			if on_exit then
				on_exit(machine, ...)
			end
		end
		machine._Running = nil

		active[i] = nil
		machine._Entered[state] = nil
		if machine._Scopes[state] then
			CleanScope(machine, state)
		end
	end
end

local function EnterOne(machine: MachineClass, debug_mode: boolean, state: StateT, ...: any)
	local active = machine._Active
	active[#active + 1] = state
	machine._Entered[state] = machine.Clock
	-- Set before entering so a Send() from inside OnEnter starts from this state
	machine.Current = state

	machine._Running = state
	if debug_mode then
		DebugPrint(machine, `Enter {state.Name} ({Ms(state:_Enter(machine, ...))})`)
	else
		local on_enter = state.OnEnter
		if on_enter then
			on_enter(machine, ...)
		end
	end
	machine._Running = nil
end

-- Enters every state between `from` (already active, or nil) and `target`, outermost first,
-- then follows Initial children down.
local function EnterTarget(machine: MachineClass, debug_mode: boolean, from: StateT?, target: StateT, ...: any)
	if target.Parent == nil then
		EnterOne(machine, debug_mode, target, ...)
	else
		local path = {}
		local state: StateT? = target
		while state and state ~= from do
			table.insert(path, state)
			state = ParentOf(machine, state)
		end
		for i = #path, 1, -1 do
			EnterOne(machine, debug_mode, path[i], ...)
		end
	end

	local initial = target.Initial
	while initial do
		local child = FindState(machine, initial)
		if not child then
			error(`Machine: [{machine.ID}] Initial State "{initial}" Doesn't Exist.`)
		end
		EnterOne(machine, debug_mode, child, ...)
		initial = child.Initial
	end
end

-- Bookkeeping after Current changed
local function Finish(machine: MachineClass, debug_mode: boolean, old: StateT?, ...: any)
	local current = machine.Current
	machine.Previous = old

	-- History is a ring buffer: _HistoryCount is the total ever recorded, so the newest is at Count % size
	local details = machine.Details
	local history_size = (details and details.HistorySize) or DEFAULT_HISTORY_SIZE
	if history_size > 0 and current then
		local count = machine._HistoryCount + 1
		machine._HistoryCount = count
		machine._History[(count - 1) % history_size + 1] = current.Name
	end

	if #machine._Buffer > 0 then
		machine._BufferDirty = true
	end

	if debug_mode then
		DebugPrint(machine, `{if old then old.Name else "nil"} -> {if current then current.Name else "nil"}`)
	end

	machine.StateChanged:Fire(current, old, ...)
end

-- Exit -> Effects -> Enter. Only the states that differ are exited and entered: moving between two children of
-- the same parent leaves the parent active. A transition to the current state (or one of its parents) exits and
-- re-enters it.
local function EnterTransition(machine: MachineClass, target: StateT, transition: TransitionT?, ...: any)
	local old = machine.Current
	local debug_mode = DebugEnabled(machine)

	-- The deepest active state that's a strict parent of target
	local shared = if target.Parent then ParentOf(machine, target) else nil
	while shared and machine._Entered[shared] == nil do
		shared = ParentOf(machine, shared)
	end

	ExitTo(machine, debug_mode, shared, ...)

	local effects = transition and transition.Effects
	if effects then
		for _, effect in effects do
			effect(machine, ...)
		end
	end

	EnterTarget(machine, debug_mode, shared, target, ...)
	Finish(machine, debug_mode, old, ...)
end

local function TargetOf(machine: MachineClass, name: _t.StateName): StateT
	local state = FindState(machine, name)
	if not state then
		error(`Machine: [{machine.ID}] Transition Target "{name}" Doesn't Exist.`)
	end
	return state
end

-- After a callback errors mid-transition, Current is whatever state was reached. Make the active chain match it
-- again (Current and its parents, without running OnEnter), so the machine stays usable.
local function Resync(machine: MachineClass)
	local current = machine.Current
	if not machine.Active or not current or machine._Entered[current] ~= nil then
		return
	end

	local chain = {}
	local state: StateT? = current
	while state do
		table.insert(chain, 1, state)
		state = ParentOf(machine, state)
	end

	for _, active in machine._Active do
		if not table.find(chain, active) then
			machine._Entered[active] = nil
			pcall(CleanScope, machine, active)
		end
	end

	for _, link in chain do
		if machine._Entered[link] == nil then
			machine._Entered[link] = machine.Clock
		end
	end
	machine._Active = chain
end

-- Cleans up everything left from a previous run, for Start and Stop
local function Reset(machine: MachineClass)
	for _, scope in machine._Scopes do
		pcall(scope._Clean, scope)
	end
	table.clear(machine._Scopes)
	table.clear(machine._Active)
	table.clear(machine._Entered)
	table.clear(machine._Timers)
end

--------------------------------------------------------------------------------
-- Locked operations. Each runs through Run, which queues Sends made by callbacks.
--------------------------------------------------------------------------------

local function Reject(machine: MachineClass, request: _t.Trigger, reason: _t.RejectReason, ...: any)
	if DebugEnabled(machine) then
		local current = machine.Current
		DebugPrint(machine, `"{request}" rejected in {if current then current.Name else "nil"}: {reason}`)
	end
	machine.Rejected:Fire(request, reason, ...)
end

-- Runs one transition for `request` from the current state. Returns whether it transitioned.
local function Process(machine: MachineClass, request: _t.Trigger, ...: any): boolean
	if not machine.Active or not machine.Current then
		return false
	end

	local transition, reason = Select(machine, request, ...)
	if not transition then
		Reject(machine, request, reason or "NoTransition", ...)
		return false
	end

	EnterTransition(machine, TargetOf(machine, transition.Target), transition, ...)
	return true
end

local function StoreBuffered(machine: MachineClass, entry: _t.BufferedSend)
	local buffer = machine._Buffer
	-- Mashing a button keeps one buffered press, the latest
	for i, existing in buffer do
		if existing.Trigger == entry.Trigger then
			table.remove(buffer, i)
			break
		end
	end
	table.insert(buffer, entry)
end

local function SendBuffered(machine: MachineClass, entry: _t.BufferedSend): boolean
	local args = entry.Args
	local transition = Select(machine, entry.Trigger, table.unpack(args, 1, args.n))
	if not transition then
		return false
	end

	EnterTransition(machine, TargetOf(machine, transition.Target), transition, table.unpack(args, 1, args.n))
	return true
end

local function BufferNow(machine: MachineClass, entry: _t.BufferedSend): boolean
	if SendBuffered(machine, entry) then
		return true
	end
	StoreBuffered(machine, entry)
	return false
end

-- Retries buffered triggers in the order they were buffered, dropping expired ones. Fires at most one;
-- its transition marks the buffer dirty again so the rest get another go from the new state.
local function TryBuffer(machine: MachineClass): boolean
	if not machine.Current then
		return false
	end

	local buffer = machine._Buffer
	local clock = machine.Clock
	local i = 1
	while i <= #buffer do
		local entry = buffer[i]
		if entry.Expires + TIME_EPSILON < clock then
			table.remove(buffer, i)
		else
			local args = entry.Args
			local transition = Select(machine, entry.Trigger, table.unpack(args, 1, args.n))
			if transition then
				table.remove(buffer, i)
				EnterTransition(
					machine,
					TargetOf(machine, transition.Target),
					transition,
					table.unpack(args, 1, args.n)
				)
				return true
			end
			i += 1
		end
	end

	return false
end

local function FireTimers(machine: MachineClass)
	local timers = machine._Timers
	if #timers == 0 then
		return
	end

	-- Take out the due timers (and drop cancelled ones), keeping the rest in order
	local clock = machine.Clock
	local due: { _t.Timer } = {}
	local kept = 0
	for _, timer in timers do
		if timer.Cancelled then
			continue
		elseif timer.Due <= clock + TIME_EPSILON then
			table.insert(due, timer)
		else
			kept += 1
			timers[kept] = timer
		end
	end
	for i = #timers, kept + 1, -1 do
		timers[i] = nil
	end

	if #due > 1 then
		table.sort(due, function(a: _t.Timer, b: _t.Timer): boolean
			if a.Due ~= b.Due then
				return a.Due < b.Due
			end
			return a.Order < b.Order
		end)
	end

	for _, timer in due do
		if timer.Cancelled or machine._Pending then
			continue
		end
		timer.Cancelled = true

		local scope = timer.Scope :: any
		scope._Timers[timer] = nil

		machine._Running = scope._State
		timer.Callback(table.unpack(timer.Args, 1, timer.Args.n))
		machine._Running = nil
	end
end

local function CheckTimeouts(machine: MachineClass)
	for _ = 1, MAX_TIMEOUTS_PER_UPDATE do
		if not machine.Active or machine._Pending then
			return
		end

		local expired: StateT? = nil
		local clock = machine.Clock
		for _, state in machine._Active do
			local duration = state.Duration
			if duration and clock - (machine._Entered[state] or clock) + TIME_EPSILON >= duration then
				expired = state
				break
			end
		end

		if not expired then
			return
		end

		if DebugEnabled(machine) then
			DebugPrint(machine, `{expired.Name} timed out`)
		end

		EnterTransition(machine, TargetOf(machine, expired.Next :: string))
	end
end

local function Tick(machine: MachineClass, dt: number)
	FireTimers(machine)
	CheckTimeouts(machine)

	if not machine.Active or machine._Pending then
		return
	end

	-- Sends from OnUpdate are queued, so the active states can't change during this loop
	for _, state in machine._Active do
		local on_update = state.OnUpdate
		if on_update then
			machine._Running = state
			on_update(machine, dt)
			machine._Running = nil
		end
	end

	-- Time passed, so Conditions like "0.2s into the state" may pass now
	if #machine._Buffer > 0 then
		machine._BufferDirty = true
	end
end

local function Force(machine: MachineClass, target: StateT, elapsed: number)
	if machine._Entered[target] == nil then
		EnterTransition(machine, target, nil)
	end

	-- Backdate the target and everything inside it
	local since = machine.Clock - elapsed
	local inside = false
	for _, state in machine._Active do
		if state == target then
			inside = true
		end
		if inside then
			machine._Entered[state] = since
		end
	end
end

local function EnterDefault(machine: MachineClass, state: StateT)
	local debug_mode = DebugEnabled(machine)
	EnterTarget(machine, debug_mode, nil, state)
	Finish(machine, debug_mode, nil)
end

local function ExitAll(machine: MachineClass, old: StateT?)
	ExitTo(machine, DebugEnabled(machine), nil)
	Reset(machine)
	machine.Previous = old
	machine.StateChanged:Fire(nil, old)
end

-- Ends a locked run: drains Sends queued by callbacks and retries buffered triggers, then runs any Stop/Destroy
-- requested mid-transition, then rethrows if a callback errored. `ok`/`result` come from the run that held the lock.
local function Unlock(machine: MachineClass, ok: boolean, result: any): any
	local queue = machine._Queue
	while ok and machine.Active and not machine._Pending do
		local step_ok, err
		if #queue > 0 then
			local entry = table.remove(queue, 1) :: _t.QueuedSend
			step_ok, err = Execute(machine, Process, machine, table.unpack(entry, 1, entry.n))
		elseif machine._BufferDirty then
			machine._BufferDirty = false
			step_ok, err = Execute(machine, TryBuffer, machine)
		else
			break
		end

		machine._Running = nil
		if not step_ok then
			ok, result = false, err
		end
	end

	if not ok then
		Resync(machine)
	end

	table.clear(queue)
	machine._BufferDirty = false
	machine._Transitioning = false

	local pending = machine._Pending
	machine._Pending = nil
	if pending == "Destroy" then
		machine:Destroy()
	elseif pending == "Stop" then
		machine:Stop()
	end

	if not ok then
		error(result, 0)
	end

	return result
end

local function Run(machine: MachineClass, fn: (...any) -> any, ...: any): any
	-- The runner catches errors and yields so a callback can't leave the machine locked
	machine._Transitioning = true
	local details = machine.Details
	local ok, result
	if details and (details.CatchYields or details.DebugMode) then
		ok, result = Execute(machine, fn, machine, ...)
	else
		ok, result = pcall(fn, machine, ...)
	end
	machine._Running = nil

	-- Fast path: nothing was queued, deferred or buffered during the run
	if ok and #machine._Queue == 0 and not machine._Pending and not machine._BufferDirty then
		machine._Transitioning = false
		return result
	end

	return Unlock(machine, ok, result)
end

-- Rebuilds the name lookup and checks the machine's states and transitions, so typos fail at Start.
local function Validate(machine: MachineClass): StateT
	local map = machine._Map
	table.clear(map)
	table.clear(machine._Index)
	table.clear(machine._Counts)

	local id = machine.ID
	local states = machine.States or {}

	for _, state in states do
		if map[state.Name] then
			error(`Machine: [{id}] Has two States named "{state.Name}".`, 3)
		end
		map[state.Name] = state
	end

	local start_state = map[machine.Default]
	if not start_state then
		error(`Default State not Defined.`, 3)
	end

	local function exists(name: _t.StateName?): boolean
		return name ~= nil and map[name] ~= nil
	end

	for _, state in states do
		local name = state.Name

		for _, transition in state.Transitions do
			if not exists(transition.Target) then
				error(
					`Machine: [{id}] State "{name}" has a Transition to "{transition.Target}", which Doesn't Exist.`,
					3
				)
			end
			if transition.From ~= name then
				error(
					`Machine: [{id}] State "{name}" has a Transition From "{transition.From}". It must be From "{name}".`,
					3
				)
			end
		end

		if state.Parent ~= nil then
			if not exists(state.Parent) then
				error(`Machine: [{id}] State "{name}" has Parent "{state.Parent}", which Doesn't Exist.`, 3)
			end

			-- Walking up more times than there are states means a loop
			local ancestor: StateT? = state
			for _ = 1, #states + 1 do
				ancestor = if ancestor and ancestor.Parent then map[ancestor.Parent] else nil
				if not ancestor then
					break
				end
				if ancestor == state then
					error(`Machine: [{id}] State "{name}" is its own Parent.`, 3)
				end
			end
		end

		if state.Initial ~= nil then
			local child = map[state.Initial]
			if not child or child.Parent ~= name then
				error(
					`Machine: [{id}] State "{name}" has Initial "{state.Initial}", which isn't one of its children.`,
					3
				)
			end
		end

		if state.Duration ~= nil and state.Next == nil then
			error(`Machine: [{id}] State "{name}" has a Duration but no Next.`, 3)
		end
		if state.Next ~= nil and not exists(state.Next) then
			error(`Machine: [{id}] State "{name}" has Next "{state.Next}", which Doesn't Exist.`, 3)
		end
	end

	for _, transition in machine.AnyTransitions do
		if not exists(transition.Target) then
			error(`Machine: [{id}] AnyTransitions has a Transition to "{transition.Target}", which Doesn't Exist.`, 3)
		end
		if transition.From ~= "*" then
			error(`Machine: [{id}] AnyTransitions has a Transition From "{transition.From}". It must be From "*".`, 3)
		end
		for _, except in transition.Except or {} do
			if not exists(except) then
				error(`Machine: [{id}] AnyTransitions has a Transition Except "{except}", which Doesn't Exist.`, 3)
			end
		end
	end

	return start_state
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[=[
	@method Send
	@within Machine
	@param trigger string -- The trigger name
	@param ... any -- Event data, passed after the machine to the Conditions, the old state's `OnExit`, the Effects and the new state's `OnEnter`
	@return boolean -- `true` if the machine transitioned

	Sends a trigger. The machine looks for a transition listening for `trigger` in the current state's
	`Transitions` (in the order they were inserted), then in each parent's, then in [Machine.AnyTransitions].
	The first one whose `Priority` meets the current [State.Resistance] and whose Conditions all pass fires.
	If none does, nothing happens, [Machine.Rejected] fires, and `Send` returns `false`.

	A `Send` made from inside a callback is queued and runs after the current transition has fully finished,
	so it returns `false`. Errors thrown by callbacks are rethrown from `Send`.

	If a callback yields (for example with `task.wait()`), the transition isn't finished until it resumes, so
	every `Send` in the meantime is queued. That's rarely what you want in combat: use [Scope:Delay] to wait
	instead. Set `CatchYields` (or `DebugMode`) in [Felix.Details] to turn a yield into an error, which stops the
	callback where it yielded.

	```lua
	player:Send("Hit", 25, "Zombie")
	```
]=]
function FelixMachine.Send(self: MachineClass, request: _t.Trigger, ...: any): boolean
	if not self.Active or not self.Current then
		Reject(self, request, "Inactive", ...)
		return false
	end

	if self._Transitioning then
		table.insert(self._Queue, table.pack(request, ...))
		return false
	end

	return Run(self, Process, request, ...)
end

--[=[
	@method Buffer
	@within Machine
	@param trigger string
	@param window number -- How long to keep retrying, in machine time
	@param ... any -- Event data, passed as with [Machine:Send]
	@return boolean -- `true` if it transitioned right away

	Like [Machine:Send], but if the trigger can't fire now it's kept for `window` seconds and retried after every
	transition and every [Machine:Update], until it fires or expires. For input buffering: an attack pressed just
	before the current one ends still comes out.

	Buffering a trigger that's already buffered replaces it, so mashing a button buffers one press.

	```lua
	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			fighter:Buffer("Attack", 0.2)
		end
	end)
	```
]=]
function FelixMachine.Buffer(self: MachineClass, request: _t.Trigger, window: number, ...: any): boolean
	if not self.Active or not self.Current then
		return false
	end

	local entry: _t.BufferedSend = {
		Trigger = request,
		Expires = self.Clock + window,
		Args = table.pack(...),
	}

	if self._Transitioning then
		StoreBuffered(self, entry)
		self._BufferDirty = true
		return false
	end

	return Run(self, BufferNow, entry)
end

--[=[
	@method ClearBuffer
	@within Machine
	@param trigger string? -- Only clear this trigger. Clears everything when omitted.

	Drops buffered triggers. [Machine:Stop] clears the buffer too.
]=]
function FelixMachine.ClearBuffer(self: MachineClass, request: _t.Trigger?): ()
	if request == nil then
		table.clear(self._Buffer)
		return
	end

	local buffer = self._Buffer
	for i = #buffer, 1, -1 do
		if buffer[i].Trigger == request then
			table.remove(buffer, i)
		end
	end
end

--[=[
	@method CanSend
	@within Machine
	@param trigger string
	@param ... any -- Event data, passed to the Conditions
	@return boolean -- Whether [Machine:Send] would transition right now
	@return RejectReason? -- Why not, when it wouldn't

	Checks a trigger without sending it, for UI and AI ("can I dodge right now?"). It runs the Conditions, so keep
	them free of side effects.

	```lua
	local canDodge, reason = fighter:CanSend("Dodge")
	```
]=]
function FelixMachine.CanSend(self: MachineClass, request: _t.Trigger, ...: any): (boolean, _t.RejectReason?)
	if not self.Active or not self.Current then
		return false, "Inactive"
	end

	local transition, reason = Select(self, request, ...)
	return transition ~= nil, reason
end

--[=[
	@method Update
	@within Machine
	@param dt number -- Seconds since the last Update

	Advances machine time by `dt`, then, in order: fires due [Scope:Delay] timers, moves on from states whose
	[State.Duration] ran out, calls each active state's [State.OnUpdate], and retries buffered triggers.
	Call it every frame:

	```lua
	RunService.Heartbeat:Connect(function(dt)
		fighter:Update(dt)
	end)
	```

	Nothing time-based happens without it. Machines that don't use time don't need it.

	@error "Can't Update during a transition." -- Called from inside a callback
]=]
function FelixMachine.Update(self: MachineClass, dt: number): ()
	if self._Transitioning then
		error(`Machine: [{self.ID}] Can't Update during a transition.`, 2)
	end

	if not self.Active then
		return
	end

	self.Clock += dt
	Run(self, Tick, dt)
end

--[=[
	@method Start
	@within Machine

	Enters the default state (and its parents, and its [State.Initial] children). Calling it on a running machine
	exits the current state and starts over.

	Before entering anything, `Start` checks the machine's setup, so typos fail at setup instead of mid-game: state
	names are unique, the default state exists, every transition's `Target` names one of the machine's states and
	its `From` matches the state it's in, and every `Parent`, `Initial`, `Next` and `Except` names a real state.

	@error "Default State not Defined." -- The default state isn't one of the machine's states
	@error "... has a Transition to ..., which Doesn't Exist." -- A transition targets a state the machine doesn't have
	@error "Can't Start during a transition." -- Called from inside a callback
]=]
function FelixMachine.Start(self: MachineClass): ()
	if self._Transitioning then
		error(`Machine: [{self.ID}] Can't Start during a transition.`, 2)
	end

	local start_state = Validate(self)

	if self.Active then
		self:Stop()
	end

	Reset(self)
	self.Active = true
	self.Current = nil
	self.Previous = nil
	table.clear(self._History)
	self._HistoryCount = 0

	Run(self, EnterDefault, start_state)
end

--[=[
	@method Stop
	@within Machine

	Exits the current state (and its parents) and stops the machine, cleaning up every [Scope] and clearing
	buffered triggers. Triggers sent while stopped are ignored. Call [Machine:Start] to run it again.

	Called from inside a callback, it waits until the current transition finishes, then discards any queued triggers.
]=]
function FelixMachine.Stop(self: MachineClass): ()
	if self._Transitioning then
		if not self._Pending then
			self._Pending = "Stop"
		end
		return
	end

	if not self.Active then
		return
	end

	local current_state = self.Current
	self.Active = false
	self.Current = nil
	table.clear(self._Buffer)
	self._BufferDirty = false

	if #self._Active > 0 then
		Run(self, ExitAll, current_state)
	end
end

--[=[
	@method Destroy
	@within Machine

	Stops the machine and releases its states and details. Like [Machine:Stop], it waits for the current
	transition to finish when called from inside a callback.
]=]
function FelixMachine.Destroy(self: MachineClass): ()
	if self._Transitioning then
		self._Pending = "Destroy"
		return
	end

	-- Stop execution and exit the active state, if any
	self:Stop()
	self.StateChanged:DisconnectAll()
	self.Rejected:DisconnectAll()

	-- Release stored tables to allow GC
	self.States = nil
	self.Details = nil
	self.ID = nil
	table.clear(self._Map)
	table.clear(self._Index)
	table.clear(self._Counts)
	table.clear(self.AnyTransitions)
end

--[=[
	@method ForceState
	@within Machine
	@param name string -- The state to move to
	@param elapsed number? -- How long the machine has already been in it. Defaults to `0`.

	Moves straight to a state, skipping Conditions, Effects and [State.Resistance] (exits and enters still run).
	If the machine is already in that state, only its time is changed. For applying a server's [Machine:Snapshot]
	on a client, or resetting a fighter at round start. [Scope:Delay] timers aren't shifted by `elapsed`.

	```lua
	-- Client: snap to the server's state when prediction was wrong
	remote.OnClientEvent:Connect(function(snapshot)
		if snapshot.State and not fighter:Is(snapshot.State) then
			fighter:ForceState(snapshot.State, snapshot.Time)
		end
	end)
	```

	@error "Isn't Active." -- The machine isn't running
	@error "Can't ForceState during a transition." -- Called from inside a callback
]=]
function FelixMachine.ForceState(self: MachineClass, name: _t.StateName, elapsed: number?): ()
	if self._Transitioning then
		error(`Machine: [{self.ID}] Can't ForceState during a transition.`, 2)
	end
	if not self.Active then
		error(`Machine: [{self.ID}] Isn't Active.`, 2)
	end

	local target = FindState(self, name)
	if not target then
		error(`Machine: [{self.ID}] State "{name}" Doesn't Exist.`, 2)
	end

	Run(self, Force, target, elapsed or 0)
end

--[=[
	@method Snapshot
	@within Machine
	@return Snapshot

	The current state's name and how long the machine has been in it, as plain data to send to clients.
	Apply it with [Machine:ForceState]. [Machine.Context] isn't included.
]=]
function FelixMachine.Snapshot(self: MachineClass): _t.Snapshot
	local current = self.Current
	return {
		State = if current then current.Name else nil,
		Time = self:GetTimeInState(),
	}
end

--[=[
	@method Is
	@within Machine
	@param name string
	@return boolean -- Whether the machine is in `name`, or in a child of it

	```lua
	if fighter:Is("Attacking") then -- true in Attacking's children too
	```
]=]
function FelixMachine.Is(self: MachineClass, name: _t.StateName): boolean
	for _, state in self._Active do
		if state.Name == name then
			return true
		end
	end
	return false
end

--[=[
	@method IsAny
	@within Machine
	@param names { string }
	@return boolean -- Whether [Machine:Is] is true for any of `names`
]=]
function FelixMachine.IsAny(self: MachineClass, names: { _t.StateName }): boolean
	return IsAny(self, names)
end

--[=[
	@method GetTag
	@within Machine
	@param tag string
	@return any -- The tag's value in the innermost active state that sets it, or `nil`

	Reads [State.Tags]. A child's value overrides its parent's.
]=]
function FelixMachine.GetTag(self: MachineClass, tag: string): any
	local active = self._Active
	for i = #active, 1, -1 do
		local tags = active[i].Tags
		if tags then
			local value = tags[tag]
			if value ~= nil then
				return value
			end
		end
	end
	return nil
end

--[=[
	@method HasTag
	@within Machine
	@param tag string
	@return boolean -- Whether [Machine:GetTag] is truthy

	Lets damage, movement and UI code ask about the state instead of checking state names:

	```lua
	if not target:HasTag("Invulnerable") then
		target:Send("Hit", damage)
	end
	```
]=]
function FelixMachine.HasTag(self: MachineClass, tag: string): boolean
	return not not self:GetTag(tag)
end

--[=[
	@method GetScope
	@within Machine
	@param name string? -- An active state. Defaults to the state whose callback is running, or [Machine.Current].
	@return Scope

	The [Scope] for the current stay in a state: everything added to it is cleaned up when the machine leaves
	that state. Inside `OnEnter`, `OnExit`, `OnUpdate` and [Scope:Delay] callbacks, `machine:GetScope()` is the
	scope of the state the callback belongs to.

	@error "... isn't active." -- The state isn't active (for example, from inside an Effect, between states)
]=]
function FelixMachine.GetScope(self: MachineClass, name: _t.StateName?): _t.Scope
	local state = if name then FindState(self, name) else (self._Running or self.Current)
	if not state or self._Entered[state] == nil then
		local shown = name or (if state then state.Name else "nil")
		error(`Machine: [{self.ID}] GetScope: State "{shown}" isn't active.`, 2)
	end

	local scope = self._Scopes[state]
	if not scope then
		scope = Scope.new(self, state)
		self._Scopes[state] = scope
	end
	return scope
end

--[=[
	@method GetTimeInState
	@within Machine
	@param name string? -- An active state. Defaults to [Machine.Current].
	@return number -- Machine time since the state was entered, or `0` if it isn't active

	```lua
	-- A Condition: only cancel into a dodge after the attack's first 0.2s
	function(machine)
		return machine:GetTimeInState() >= 0.2
	end
	```
]=]
function FelixMachine.GetTimeInState(self: MachineClass, name: _t.StateName?): number
	local state = if name then FindState(self, name) else self.Current
	local entered = state and self._Entered[state]
	return if entered then self.Clock - entered else 0
end

--[=[
	@method GetHistory
	@within Machine
	@return { string } -- State names, oldest first, ending with [Machine.Current]

	The names of the last states the machine was in. Keeps [Felix.Details] `HistorySize` entries (8 by default).
	Cleared by [Machine:Start]. Returns a new table each call.

	```lua
	-- Back to whatever stance we were in before getting hit
	local history = fighter:GetHistory()
	local before = history[#history - 1]
	```
]=]
function FelixMachine.GetHistory(self: MachineClass): { _t.StateName }
	local details = self.Details
	local size = (details and details.HistorySize) or DEFAULT_HISTORY_SIZE
	local count = self._HistoryCount
	local history = self._History
	local result = {}

	if size <= 0 then
		return result
	end

	for n = math.max(count - size + 1, 1), count do
		table.insert(result, history[(n - 1) % size + 1])
	end

	return result
end

--[=[
	@method Refresh
	@within Machine

	Rebuilds the machine's lookup tables. Inserting transitions or states after [Machine:Start] is picked up
	automatically; call this after replacing or removing them, or after changing a transition's `Triggers`.
]=]
function FelixMachine.Refresh(self: MachineClass): ()
	table.clear(self._Map)
	table.clear(self._Index)
	table.clear(self._Counts)
end

--[=[
	@method GetStates
	@within Machine
	@return { State }? -- The machine's states, or `nil` if it has none or was destroyed
]=]
function FelixMachine.GetStates(self: MachineClass): { StateT }?
	return self.States
end

--[=[
	@within Felix
	@param id any -- Any value that identifies the machine. Used in error messages.
	@param default string -- The name of the state entered by [Machine:Start]
	@param details Details? -- Options: the machine's `Context`, `DebugMode`, `HistorySize` and `CatchYields`
	@param states { State }? -- The machine's states
	@return Machine

	Creates a machine. It doesn't enter any state until [Machine:Start] is called.

	```lua
	local player = Felix.new("Player", "Alive", { Context = { Health = 100 } }, { alive, dead })
	player:Start()
	```

	For a typed context, annotate the result: `local machine: Felix.Machine<MyContext> = Felix.new(...)`
]=]
function FelixMachine.new(id: _t.MachineID, default: _t.Default, details: _t.Details?, states: { StateT }?): MachineClass
	local self = setmetatable({
		ID = id,
		Default = default,
		Current = nil,
		Previous = nil,
		Details = details,
		States = states,
		AnyTransitions = {},
		Active = false,
		Context = if details and details.Context ~= nil then details.Context else {},
		Clock = 0,
		StateChanged = Signal.new(),
		Rejected = Signal.new(),

		_Transitioning = false,
		_Queue = {},
		_Pending = nil,

		_Active = {},
		_Entered = {},
		_Scopes = {},
		_Running = nil,

		_Map = {},
		_Index = {},
		_Counts = {},

		_History = {},
		_HistoryCount = 0,

		_Timers = {},
		_TimerOrder = 0,
		_Buffer = {},
		_BufferDirty = false,
	}, FelixMachine)

	-- Methods come from the metatable, which the checker can't match against _t.MachineClass on its own
	return self :: any
end

return FelixMachine
