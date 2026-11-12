--!strict

-- `C` is the type of the machine's Context table. It defaults to `any`, so code that doesn't
-- care about typing its context can leave it off (e.g. `Machine` instead of `Machine<MyContext>`).

export type StateName = string
export type Default = string
export type Delta = number
export type MachineID = any
export type ErrorMessage = string

export type Trigger = string

--[=[
	@type Callback (machine: Machine, ...any) -> ()
	@within Felix
	The type of [State.OnEnter] and [State.OnExit]. Receives the machine, then any event data.
]=]

--[=[
	@type Effect (machine: Machine, ...any) -> ()
	@within Felix
	A transition action. Receives the machine, then any event data.
]=]

--[=[
	@type Condition (machine: Machine, ...any) -> boolean
	@within Felix
	A transition guard. Receives the machine, then any event data, and returns whether the transition may fire.
]=]

--[=[
	@interface Details
	@within Felix
	.Context C? -- The machine's starting context table. Defaults to `{}`.
	.DebugMode boolean? -- Prints every transition, rejected trigger, and how long each callback took
	.HistorySize number? -- How many state names [Machine:GetHistory] keeps. Defaults to 8; 0 turns it off.
	.CatchYields boolean? -- Errors when a callback yields, instead of holding the machine until it resumes. On in DebugMode. See [Machine:Send].

	The options table passed to [Felix.new].
]=]

--[=[
	@type Trigger string
	@within Felix
	A trigger name.
]=]

--[=[
	@type StateName string
	@within Felix
	A state name.
]=]

-- Every callback receives the machine, then any event data passed to Send after the trigger name.
export type Callback<C = any> = (machine: MachineClass<C>, ...any) -> ()
export type Effect<C = any> = (machine: MachineClass<C>, ...any) -> ()
export type Condition<C = any> = (machine: MachineClass<C>, ...any) -> boolean

--[=[
	@type UpdateCallback (machine: Machine, dt: number) -> ()
	@within Felix
	The type of [State.OnUpdate]. Receives the machine and the `dt` passed to [Machine:Update].
]=]
export type UpdateCallback<C = any> = (machine: MachineClass<C>, dt: number) -> ()

--[=[
	@type Resistance number | (machine: Machine) -> number
	@within Felix
	The type of [State.Resistance]: a number, or a function that returns one, so it can change over time.
]=]
export type Resistance<C = any> = number | (machine: MachineClass<C>) -> number

--[=[
	@type RejectReason "NoTransition" | "Conditions" | "Resisted" | "Inactive"
	@within Felix
	Why a trigger didn't fire a transition, as passed to [Machine.Rejected] and returned by [Machine:CanSend]:

	- `"NoTransition"`: nothing in the current state, its parents or the machine's `AnyTransitions` listens for the trigger
	- `"Conditions"`: something listens, but its Conditions failed
	- `"Resisted"`: something listens, but its `Priority` is below the current state's `Resistance`
	- `"Inactive"`: the machine isn't running
]=]
export type RejectReason = "NoTransition" | "Conditions" | "Resisted" | "Inactive"

--[=[
	@interface Snapshot
	@within Felix
	.State string? -- The current state's name, or `nil` when the machine isn't running
	.Time number -- How long the machine has been in it, in machine time

	Returned by [Machine:Snapshot]. Plain data, so it can be sent through a RemoteEvent and applied with
	[Machine:ForceState].
]=]
export type Snapshot = {
	State: StateName?,
	Time: number,
}

export type Transition<C = any> = {
	From: string,
	Target: string,
	Triggers: { Trigger },
	Effects: { Effect<C> }?,
	Conditions: { Condition<C> }?,
	Priority: number?,
	Except: { StateName }?,
}

export type State<C = any> = {
	_Enter: (self: State<C>, machine: MachineClass<C>, ...any) -> Delta,
	_Exit: (self: State<C>, machine: MachineClass<C>, ...any) -> Delta,

	Name: string,
	Trigger: (self: State<C>, Trigger, MachineClass<C>, ...any) -> Transition<C>?,
	Transitions: { Transition<C> },

	OnEnter: Callback<C>?,
	OnExit: Callback<C>?,
	OnUpdate: UpdateCallback<C>?,

	Parent: StateName?,
	Initial: StateName?,
	Duration: number?,
	Next: StateName?,
	Resistance: Resistance<C>?,
	Tags: { [string]: any }?,
}

export type Details<C = any> = {
	DebugMode: boolean?,
	Context: C?,
	HistorySize: number?,
	CatchYields: boolean?,
}

--[=[
	@interface Connection
	@within Felix
	.Disconnect (self: Connection) -> () -- Stops the handler from being called

	Returned by `Signal:Connect`.
]=]
export type Connection = {
	Disconnect: (self: Connection) -> (),
}

-- Shape of util/signal, which is untyped
export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

-- A Send made mid-transition: table.pack(trigger, ...event data)
export type QueuedSend = { n: number, [number]: any }

-- A Scope:Delay waiting for its machine's clock
export type Timer = {
	Due: number,
	Order: number,
	Callback: (...any) -> (),
	Args: { n: number, [number]: any },
	Scope: Scope,
	Cancelled: boolean,
}

-- A trigger kept by Machine:Buffer until it fires or Expires
export type BufferedSend = {
	Trigger: Trigger,
	Expires: number,
	Args: { n: number, [number]: any },
}

export type Scope = {
	Active: boolean,

	Add: <T>(self: Scope, item: T) -> T,
	Delay: (self: Scope, seconds: number, callback: (...any) -> (), ...any) -> () -> (),
	_Clean: (self: Scope) -> (),
}

export type MachineClass<C = any> = {
	Active: boolean,
	ID: MachineID,
	Default: Default,
	Current: State<C>?,
	Previous: State<C>?,
	Details: Details<C>?,
	States: { State<C> }?,
	AnyTransitions: { Transition<C> },
	Context: C,
	Clock: number,

	-- Fires (new state, old state, ...event data) whenever Current changes
	StateChanged: Signal<(State<C>?, State<C>?, ...any)>,
	-- Fires (trigger, reason, ...event data) when a Send doesn't transition
	Rejected: Signal<(Trigger, RejectReason, ...any)>,

	-- Internal: re-entrancy guard, Sends queued by callbacks (trigger + event data, packed),
	-- and a Stop/Destroy deferred until the transition ends
	_Transitioning: boolean,
	_Queue: { QueuedSend },
	_Pending: ("Stop" | "Destroy")?,

	-- Internal: the active states from outermost parent to Current, when each was entered, their scopes,
	-- and the state whose callback is running (for GetScope)
	_Active: { State<C> },
	_Entered: { [State<C>]: number },
	_Scopes: { [State<C>]: Scope },
	_Running: State<C>?,

	-- Internal: name -> state, and trigger -> transitions for each Transitions list (with the list length
	-- it was built at, so inserts are picked up)
	_Map: { [StateName]: State<C> },
	_Index: { [{ Transition<C> }]: { [Trigger]: { Transition<C> } } },
	_Counts: { [{ Transition<C> }]: number },

	-- Internal: pending Scope:Delay timers, and triggers held by Buffer (retried when _BufferDirty)
	_History: { StateName },
	_HistoryCount: number,
	_Timers: { Timer },
	_TimerOrder: number,
	_Buffer: { BufferedSend },
	_BufferDirty: boolean,

	Send: (self: MachineClass<C>, Trigger, ...any) -> boolean,
	Buffer: (self: MachineClass<C>, Trigger, window: number, ...any) -> boolean,
	ClearBuffer: (self: MachineClass<C>, Trigger?) -> (),
	CanSend: (self: MachineClass<C>, Trigger, ...any) -> (boolean, RejectReason?),
	Update: (self: MachineClass<C>, dt: number) -> (),
	Start: (self: MachineClass<C>) -> (),
	Stop: (self: MachineClass<C>) -> (),
	Destroy: (self: MachineClass<C>) -> (),
	Refresh: (self: MachineClass<C>) -> (),
	ForceState: (self: MachineClass<C>, StateName, elapsed: number?) -> (),
	Snapshot: (self: MachineClass<C>) -> Snapshot,

	Is: (self: MachineClass<C>, StateName) -> boolean,
	IsAny: (self: MachineClass<C>, { StateName }) -> boolean,
	HasTag: (self: MachineClass<C>, string) -> boolean,
	GetTag: (self: MachineClass<C>, string) -> any,
	GetScope: (self: MachineClass<C>, StateName?) -> Scope,
	GetTimeInState: (self: MachineClass<C>, StateName?) -> number,
	GetHistory: (self: MachineClass<C>) -> { StateName },
	GetStates: (self: MachineClass<C>) -> { State<C> }?,
}

return nil
