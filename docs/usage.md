---
sidebar_position: 2
---

# Usage

## States

```lua
local state = Felix.State.new("Name")
```

A [State](/api/State) has a `Name`, a list of `Transitions` that can leave it, and optional `OnEnter` and `OnExit` callbacks. Names must be unique within a machine, because transitions target states by name.

Like every callback, `OnEnter` and `OnExit` receive the machine, followed by any [event data](#event-data) sent with the trigger.

## Transitions

```lua
Felix.Transition.new({
	From = "Locked",
	Target = "Open",
	Triggers = { "Unlock" },
	Conditions = { function(machine, ...) return hasKey end },  -- optional
	Effects = { function(machine, ...) playSound("click") end }, -- optional
})
```

A [Transition](/api/Transition) goes in the `Transitions` list of the state it leaves, and its `From` must match that state (`Start()` checks).

When a trigger is sent, the current state checks its transitions **in the order they were inserted** and fires the first one that listens for that trigger and whose Conditions all pass. If none match, the trigger is ignored.

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

## The machine

```lua
local machine = Felix.new(id, defaultState, details?, states?)
machine:Start()
machine:Send("Trigger")
machine:Stop()
```

`id` is any value that identifies the machine in error messages. `details` takes the machine's `Context` and a `DebugMode` flag that prints every transition and how long each callback took. See [Felix.new](/api/Felix#new) and [Machine](/api/Machine) for everything a machine has.

## Event data

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

## Context

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

`machine.Context` is the same table you passed in, so changes made from outside the machine are visible to its callbacks, and the other way round.

## Listening for state changes

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

## Transition order

Every transition runs in the same order:

1. The current state's `OnExit`
2. The transition's `Effects`, in order
3. `machine.Current` is set to the new state
4. The new state's `OnEnter`
5. `machine.StateChanged` fires

A transition from a state to itself (`Target` equal to its own name) runs the full exit and enter.

## Sending triggers from callbacks

You can call `Send` from inside `OnEnter`, `OnExit`, an Effect or a Condition. The trigger, and any event data with it, is **queued** and runs after the current transition has fully finished, so callbacks never see a half-finished transition. A queued `Send` returns `false`, because nothing has transitioned yet when it returns.

```lua
loading.OnEnter = function(machine)
	loadAssets()
	machine:Send("Loaded") -- runs after Loading has been fully entered
end

local game = Felix.new("Game", "Loading", nil, { loading, menu })
game:Start() -- Loading -> Menu
```

If a callback yields (for example with `task.wait()`), the transition isn't finished until it resumes, so any triggers sent in the meantime are queued too. To wait inside a state, use [`machine:GetScope():Delay()`](/api/Scope#Delay) instead; set `CatchYields = true` in the details (on in `DebugMode`) to make an accidental yield an error.

`Stop()` and `Destroy()` called from inside a callback also wait until the transition finishes. They then discard any queued triggers.

## Errors

- **`Start()` checks the setup.** It throws before entering anything if the default state doesn't exist, two states share a name, a transition's `Target` isn't one of the machine's states or its `From` doesn't match the state it's in, or a `Parent`, `Initial`, `Next` or `Except` names a state that doesn't exist. Typos fail at setup instead of mid-game.
- **Errors in callbacks** are rethrown from the `Send` (or `Start`) that ran them. The machine stays usable afterwards. If the error happened partway through a transition, `machine.Current` is whatever state the machine had reached: still the old state if an `OnExit` or Effect threw, or the new state if its `OnEnter` threw.

For durations, timers, cleanup scopes, interrupts, input buffering, hierarchical states and more, see [Combat](combat).

## Types

Felix is written in `--!strict` and exports its types from the package: `Felix.Machine<C>`, `Felix.State<C>`, `Felix.Transition<C>`, `Felix.Details<C>`, `Felix.Callback<C>`, `Felix.Condition<C>`, `Felix.Effect<C>`, `Felix.UpdateCallback<C>`, `Felix.Resistance<C>`, `Felix.Scope`, `Felix.Snapshot`, `Felix.RejectReason`, `Felix.Trigger` and `Felix.StateName`.

`C` is the type of the machine's context. It's optional and defaults to `any`.

### Typed context

To have `machine.Context` type-checked, write a type for it and add it to your annotations:

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
