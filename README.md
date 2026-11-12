# Felix

A small, fast, fully typed finite state machine for Roblox and Luau.

**[Felix Documentation](https://3b-6.github.io/Felix)**

- **States** with `OnEnter` / `OnExit` callbacks
- **Transitions** fired by named triggers, with optional **Conditions** (guards) and **Effects** (actions)
- **Event data** sent with triggers, and a shared **Context** table, both available to every callback
- Predictable ordering: **Exit → Effects → Enter**
- Safe re-entrancy: sending a trigger from inside a callback is queued until the current transition finishes
- Strict-mode types for everything, exported from the package

Built for combat, all optional:

- **Scopes** that clean up hitboxes, connections and timers when a state is left, however it's left
- **Timed states** (`Duration` / `Next`), `OnUpdate`, and time in state, driven by `machine:Update(dt)`
- **Any-state transitions** for interrupts like stuns and death
- **Priority and Resistance** for armor, uncancellable frames and cancel windows
- **Input buffering** with `machine:Buffer(trigger, window)`
- **Hierarchical states**, **tags**, history, `CanSend`, a `Rejected` signal, and `Snapshot` / `ForceState` for networking

## Installation

With [Wally](https://wally.run), add Felix to your `wally.toml`:

```toml
[dependencies]
Felix = "3b-6/felix@0.1.0"
```

Then run `wally install` and require it:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Felix = require(ReplicatedStorage.Packages.Felix)
```

Felix has no dependencies and works anywhere Luau runs, including on the client, on the server, and in [Lune](https://lune-org.github.io/docs).

## Quick start

A character that can idle, walk and jump:

```lua
--!strict
local Felix = require(ReplicatedStorage.Packages.Felix)

-- 1. Create the states
local idle = Felix.State.new("Idle")
local walk = Felix.State.new("Walk")
local jump = Felix.State.new("Jump")

idle.OnEnter = function()
	print("Standing still")
end

jump.OnEnter = function()
	print("Jumping!")
end

jump.OnExit = function()
	print("Landed")
end

-- 2. Connect them with transitions. A transition goes in the Transitions list of the state it leaves.
table.insert(idle.Transitions, Felix.Transition.new({
	From = "Idle",
	Target = "Walk",
	Triggers = { "Move" },
}))

table.insert(walk.Transitions, Felix.Transition.new({
	From = "Walk",
	Target = "Idle",
	Triggers = { "StopMoving" },
}))

-- One transition can listen for several triggers
for _, state in { idle, walk } do
	table.insert(state.Transitions, Felix.Transition.new({
		From = state.Name,
		Target = "Jump",
		Triggers = { "Jump", "DoubleTap" },
	}))
end

table.insert(jump.Transitions, Felix.Transition.new({
	From = "Jump",
	Target = "Idle",
	Triggers = { "Land" },
}))

-- 3. Create the machine: an ID, the name of the starting state, options, and the states
local character = Felix.new("Character", "Idle", nil, { idle, walk, jump })

-- 4. Start it and send triggers
character:Start()          --> Standing still
character:Send("Move")     -- Idle -> Walk
character:Send("Jump")     --> Jumping!
character:Send("Move")     -- ignored: Jump has no "Move" transition
character:Send("Land")     --> Landed, Standing still

print(character.Current and character.Current.Name) --> Idle
```

## Concepts

### States

```lua
local state = Felix.State.new("Name")
```

| Field | Type | Description |
|---|---|---|
| `Name` | `string` | The state's name. Transitions target states by this name, so it must be unique within a machine. |
| `Transitions` | `{ Transition }` | The transitions that can leave this state. |
| `OnEnter` | `((Machine, ...any) -> ())?` | Called when the machine enters this state. |
| `OnExit` | `((Machine, ...any) -> ())?` | Called when the machine leaves this state. |

Like every callback, `OnEnter` and `OnExit` receive the machine, followed by any [event data](#event-data) sent with the trigger.

### Transitions

```lua
Felix.Transition.new({
	From = "Locked",
	Target = "Open",
	Triggers = { "Unlock" },
	Conditions = { function(machine, ...) return hasKey end },  -- optional
	Effects = { function(machine, ...) playSound("click") end }, -- optional
})
```

| Field | Type | Description |
|---|---|---|
| `From` | `string` | The state this transition leaves. Must match the state whose `Transitions` list it's in (`Start()` checks), or be `"*"` in `machine.AnyTransitions`. |
| `Target` | `string` | The name of the state to enter. |
| `Triggers` | `{ string }` | The trigger names that fire this transition. |
| `Conditions` | `{ (Machine, ...any) -> boolean }?` | All must return `true` for the transition to fire. Also called guards. |
| `Effects` | `{ (Machine, ...any) -> () }?` | Run in order during the transition, after the old state exits and before the new state enters. Also called actions. |

When a trigger is sent, the current state checks its transitions **in the order they were inserted** and fires the first one that listens for that trigger and whose conditions all pass. If none match, the trigger is ignored.

```lua
-- A door that only opens with a key, and stays locked otherwise
local hasKey = false

table.insert(locked.Transitions, Felix.Transition.new({
	From = "Locked",
	Target = "Open",
	Triggers = { "Use" },
	Conditions = {
		function()
			return hasKey
		end,
	},
}))

door:Send("Use") -- false: condition failed, still Locked
hasKey = true
door:Send("Use") -- true: now Open
```

### The machine

```lua
local machine = Felix.new(id, defaultState, details?, states?)
```

| Argument | Type | Description |
|---|---|---|
| `id` | `any` | Any value that identifies the machine. Used in error messages. |
| `defaultState` | `string` | The name of the state entered by `Start()`. |
| `details` | `Details?` | Options: `Context`, the machine's [context](#context) table, and `DebugMode`, which prints every transition and how long each callback took. |
| `states` | `{ State }?` | The machine's states. |

| Method / field | Description |
|---|---|
| `machine:Start()` | Enters the default state. Calling it on a running machine exits the current state and starts over. |
| `machine:Send(trigger, ...): boolean` | Sends a trigger, with optional [event data](#event-data). Returns `true` if the machine transitioned. |
| `machine:Stop()` | Exits the current state and stops. Triggers sent while stopped are ignored. Call `Start()` to run again. |
| `machine:Destroy()` | Stops the machine and releases its states and details. |
| `machine:GetStates()` | Returns the machine's states. |
| `machine.Context` | The machine's [context](#context) table. |
| `machine.Current` | The current `State`, or `nil` when the machine isn't running. |
| `machine.Active` | Whether the machine is running. |
| `machine.StateChanged` | A signal fired with `(newState, oldState, ...eventData)` whenever the state changes. See [Listening for state changes](#listening-for-state-changes). |

### Event data

Anything passed to `Send` after the trigger name is event data. It's passed, after the machine, to every callback the trigger runs: the Conditions, the old state's `OnExit`, the Effects, and the new state's `OnEnter`.

```lua
table.insert(alive.Transitions, Felix.Transition.new({
	From = "Alive",
	Target = "Dead",
	Triggers = { "Hit" },
	Conditions = {
		function(machine, damage)
			return damage >= machine.Context.Health
		end,
	},
}))

dead.OnEnter = function(machine, damage, attacker)
	print(`Killed by {attacker} for {damage} damage`)
end

player:Send("Hit", 25, "Zombie") -- not enough damage: stays Alive
player:Send("Hit", 150, "Boss")  --> Killed by Boss for 150 damage
```

`Start()` and `Stop()` pass no event data: the default state's `OnEnter` and the last state's `OnExit` receive only the machine.

### Context

Every machine has a `Context` table for data its callbacks share, such as health, ammo or a target. Pass the starting table as `Context` in `details`, or leave it out to start with an empty table.

```lua
local player = Felix.new("Player", "Alive", { Context = { Health = 100, Ammo = 30 } }, { alive, dead })

table.insert(alive.Transitions, Felix.Transition.new({
	From = "Alive",
	Target = "Alive",
	Triggers = { "Shoot" },
	Conditions = {
		function(machine)
			return machine.Context.Ammo > 0
		end,
	},
	Effects = {
		function(machine)
			machine.Context.Ammo -= 1
		end,
	},
}))

player:Send("Shoot")
print(player.Context.Ammo) --> 29
```

`machine.Context` is the same table you passed in, so changes made from outside the machine are visible to its callbacks, and the other way round. See [Typed context](#typed-context) to type-check it.

### Listening for state changes

`machine.StateChanged` is a signal that fires whenever `machine.Current` changes. Handlers receive the new state, the old state, then any [event data](#event-data) passed to `Send`.

```lua
local connection = player.StateChanged:Connect(function(newState, oldState, damage, attacker)
	print(oldState and oldState.Name, "->", newState and newState.Name, damage, attacker)
end)

player:Start()                  --> nil -> Alive
player:Send("Hit", 150, "Boss") --> Alive -> Dead 150 Boss
player:Stop()                   --> Dead -> nil

connection:Disconnect()
```

- It fires after the new state's `OnEnter`, so `machine.Current` is already the new state.
- On `Start()` the old state is `nil`, and on `Stop()` the new state is `nil`. Neither passes event data.
- A self-transition fires it too, with the same state as both arguments.
- A `Send` made from a handler is [queued](#sending-triggers-from-callbacks) like one made from any other callback.
- `Destroy()` disconnects every handler.

Handlers run on their own thread (with `task.spawn` on Roblox, plain coroutines elsewhere). If a handler yields, the machine may have moved on by the time it resumes, so use the `newState` argument rather than reading `machine.Current` after a yield.

## Behavior in detail

### Transition order

Every transition runs in the same order:

1. The current state's `OnExit`
2. The transition's `Effects`, in order
3. `machine.Current` is set to the new state
4. The new state's `OnEnter`
5. `machine.StateChanged` fires

A transition from a state to itself (`Target` equal to its own name) runs the full exit and enter.

### Sending triggers from callbacks

You can call `Send` from inside `OnEnter`, `OnExit`, an Effect or a Condition. The trigger, and any event data with it, is **queued** and runs after the current transition has fully finished, so callbacks never see a half-finished transition. A queued `Send` returns `false`, because nothing has transitioned yet when it returns.

```lua
loading.OnEnter = function(machine)
	loadAssets()
	machine:Send("Loaded") -- runs after Loading has been fully entered
end

local game = Felix.new("Game", "Loading", nil, { loading, menu })
game:Start() -- Loading -> Menu
```

If a callback yields (for example with `task.wait()`), the transition isn't finished until it resumes, so any triggers sent in the meantime are queued too. To wait inside a state, use [`machine:GetScope():Delay()`](https://3b-6.github.io/Felix/api/Scope#Delay) instead; set `CatchYields = true` in the details (on in `DebugMode`) to make an accidental yield an error.

`Stop()` and `Destroy()` called from inside a callback also wait until the transition finishes. They then discard any queued triggers.

### Errors

- **`Start()` checks the setup.** It throws before entering anything if the default state doesn't exist, two states share a name, a transition's `Target` isn't one of the machine's states or its `From` doesn't match the state it's in, or a `Parent`, `Initial`, `Next` or `Except` names a state that doesn't exist. Typos fail at setup instead of mid-game.
- **Errors in callbacks** are rethrown from the `Send` (or `Start`) that ran them. The machine stays usable afterwards. If the error happened partway through a transition, `machine.Current` is whatever state the machine had reached: still the old state if an `OnExit` or Effect threw, or the new state if its `OnEnter` threw.

## Combat

Everything below is covered in depth, with examples, in the [Combat guide](https://3b-6.github.io/Felix/docs/combat).

```lua
local idle = Felix.State.new("Idle")
local swing = Felix.State.new("Swing")
local recovery = Felix.State.new("Recovery")
local stunned = Felix.State.new("Stunned")

swing.Duration = 0.3              -- moves to Next on its own, driven by Update
swing.Next = "Recovery"
swing.Resistance = 5              -- light hits (Priority below 5) don't interrupt it
swing.Tags = { CanMove = false }

recovery.Duration = 0.2
recovery.Next = "Idle"

swing.OnEnter = function(machine)
	local scope = machine:GetScope()           -- cleaned up when Swing is left, however it's left
	local hitbox = scope:Add(Hitbox.new())     -- destroyed on exit
	scope:Delay(0.1, function()                -- machine-time timer, cancelled on exit
		hitbox:Enable()
	end)
end

table.insert(idle.Transitions, Felix.Transition.new({ From = "Idle", Target = "Swing", Triggers = { "Attack" } }))
table.insert(stunned.Transitions, Felix.Transition.new({ From = "Stunned", Target = "Idle", Triggers = { "Recover" } }))

local fighter = Felix.new("Fighter", "Idle", nil, { idle, swing, recovery, stunned })

-- Interrupts that work from any state
table.insert(fighter.AnyTransitions, Felix.Transition.new({
	From = "*",
	Target = "Stunned",
	Triggers = { "Stun" },
	Priority = 10,
	Except = { "Stunned" },
}))

fighter:Start()
RunService.Heartbeat:Connect(function(dt)
	fighter:Update(dt)
end)

fighter:Buffer("Attack", 0.2)  -- input buffering: fires now, or as soon as it can within 0.2s
fighter:CanSend("Attack")      -- true/false, plus a reason
fighter:HasTag("CanMove")      -- ask what the state means instead of checking names
fighter:Snapshot()             -- { State = "Swing", Time = 0.12 }, apply with ForceState
```

| Feature | API |
|---|---|
| Per-state cleanup | `machine:GetScope()`, `scope:Add(item)`, `scope:Delay(seconds, fn, ...)` |
| Time | `machine:Update(dt)`, `machine.Clock`, `machine:GetTimeInState(name?)`, `State.OnUpdate(machine, dt)` |
| Timed states | `State.Duration`, `State.Next` |
| Any-state transitions | `machine.AnyTransitions`, `Transition.Except` |
| Interrupt rules | `Transition.Priority`, `State.Resistance` (number or `function(machine) -> number`) |
| Input buffering | `machine:Buffer(trigger, window, ...)`, `machine:ClearBuffer(trigger?)` |
| Hierarchy | `State.Parent`, `State.Initial`, `machine:Is(name)`, `machine:IsAny(names)` |
| Tags | `State.Tags`, `machine:HasTag(tag)`, `machine:GetTag(tag)` |
| Introspection | `machine:CanSend(trigger, ...)`, `machine.Rejected`, `machine.Previous`, `machine:GetHistory()` |
| Networking | `machine:Snapshot()`, `machine:ForceState(name, elapsed?)` |
| Runtime changes | `machine:Refresh()` |

## Types

Felix is written in `--!strict` and exports its types from the package:

```lua
local Felix = require(ReplicatedStorage.Packages.Felix)

local machine: Felix.Machine = Felix.new("Door", "Closed")
local state: Felix.State? = machine.Current

local canOpen: Felix.Condition = function(machine: Felix.Machine): boolean
	return machine.Active
end
```

| Type | Description |
|---|---|
| `Felix.Machine<C>` | A machine created by `Felix.new` |
| `Felix.State<C>` | A state created by `Felix.State.new` |
| `Felix.Transition<C>` | A transition, and the table passed to `Felix.Transition.new` |
| `Felix.Details<C>` | The options table passed to `Felix.new` |
| `Felix.Callback<C>` | `(Machine<C>, ...any) -> ()`, the type of `OnEnter` and `OnExit` |
| `Felix.Condition<C>` | `(Machine<C>, ...any) -> boolean` |
| `Felix.Effect<C>` | `(Machine<C>, ...any) -> ()` |
| `Felix.Trigger` | A trigger name (`string`) |
| `Felix.StateName` | A state name (`string`) |

`C` is the type of the machine's context. It's optional and defaults to `any`, so `Felix.Machine` means `Felix.Machine<any>`.

### Typed context

By default `machine.Context` is `any`. To have it type-checked, write a type for it and add it to your annotations:

```lua
type Combat = { Health: number, Hits: { number } }

local alive: Felix.State<Combat> = Felix.State.new("Alive")
local dead: Felix.State<Combat> = Felix.State.new("Dead")

alive.OnEnter = function(machine)
	machine.Context.Health = 100 -- checked: Health is a number
end

local hit: Felix.Transition<Combat> = Felix.Transition.new({
	From = "Alive",
	Target = "Dead",
	Triggers = { "Hit" },
	Effects = {
		function(machine, damage: number)
			table.insert(machine.Context.Hits, damage)
		end,
	},
})
table.insert(alive.Transitions, hit)

local context: Combat = { Health = 100, Hits = {} }
local player: Felix.Machine<Combat> = Felix.new("Player", "Alive", { Context = context }, { alive, dead })

player.Context.Helth = 50 -- type error: Combat has no field "Helth"
```

Event data isn't checked, since it can be anything per trigger. Annotate it in the callback instead, like `damage: number` above.

Fields starting with an underscore (`_Queue`, `_Enter`, …) are internal and may change between versions.

## License

MIT, see [LICENSE](LICENSE).
