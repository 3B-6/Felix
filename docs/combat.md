---
sidebar_position: 3
---

# Combat

Felix has a set of features for combat systems, where states are short, timed, interruptible, and full of
things that have to be cleaned up. They're all optional: a machine that doesn't use them behaves exactly as described in [Usage](usage).

## Driving the machine with Update

Anything time-based (durations, delays, input buffer windows, time in state) uses **machine time**, which only
moves when you call [`Update`](/api/Machine#Update):

```lua
RunService.Heartbeat:Connect(function(dt)
	fighter:Update(dt)
end)
```

Each `Update` advances [`machine.Clock`](/api/Machine#Clock) by `dt`, then, in order:

1. fires due [`Scope:Delay`](/api/Scope#Delay) timers
2. moves on from states whose `Duration` ran out
3. calls each active state's `OnUpdate(machine, dt)`, parents first
4. retries buffered triggers

Because time only comes from `Update`, a machine is deterministic: the same `dt`s and triggers always give the same result, which makes combat code easy to test and to reproduce on the server.

## Timed states

Attacks are usually phases. Give a state a `Duration` and a `Next`, and it moves on by itself:

```lua
local windup = Felix.State.new("Windup")
windup.Duration = 0.15
windup.Next = "Swing"

local swing = Felix.State.new("Swing")
swing.Duration = 0.1
swing.Next = "Recovery"
```

A timeout ignores Conditions and `Resistance`: it's the state ending, not something interrupting it.

For anything time-dependent, use [`GetTimeInState`](/api/Machine#GetTimeInState) in a Condition:

```lua
Conditions = {
	function(machine)
		return machine:GetTimeInState() >= 0.2 -- combo window opens 0.2s in
	end,
}
```

## Cleaning up with scopes

Combat states create things: hitboxes, sounds, animation connections, timers. When the state is interrupted, all of it has to go. Every stay in a state has a [Scope](/api/Scope), and everything added to it is cleaned up when the state is left, however it's left:

```lua
swing.OnEnter = function(machine)
	local scope = machine:GetScope()

	local hitbox = scope:Add(Hitbox.new(character)) -- hitbox:Destroy() on exit
	scope:Add(hitbox.Touched:Connect(onHit))         -- disconnected on exit
	scope:Add(function()                             -- called on exit
		track:Stop()
	end)

	scope:Delay(0.05, function()  -- never fires if the swing is interrupted first
		hitbox:Enable()
	end)
end
```

`Add` takes functions, threads, Instances, connections, and tables with a `Destroy` or `Disconnect` method.
Inside `OnEnter`, `OnExit`, `OnUpdate` and `Delay` callbacks, `machine:GetScope()` is the scope of the state the callback belongs to.

:::caution Don't yield in callbacks
If a callback yields (`task.wait()`), the transition isn't finished until it resumes, and every trigger sent in the meantime is queued, so inputs pile up and then fire all at once. Use `scope:Delay` instead.
Set `CatchYields = true` in the machine's details (it's on in `DebugMode`) to turn an accidental yield into an error.
:::

## Interrupts from any state

Getting hit, stunned or killed can happen in almost every state. Instead of adding the same transition to each one, put it in [`machine.AnyTransitions`](/api/Machine#AnyTransitions):

```lua
table.insert(fighter.AnyTransitions, Felix.Transition.new({
	From = "*",
	Target = "Stunned",
	Triggers = { "Stun" },
	Except = { "Dead" },
}))
```

They're checked after the current state's own transitions (and its parents'), so a state can handle a trigger its own way. For example, `Blocking` can turn `Hit` into `BlockStun`.

## Priority and Resistance

Not everything can interrupt everything. A transition's `Priority` must be at least the current state's `Resistance` to fire (both default to `0`):

```lua
heavy.Resistance = 5 -- armored: light hits don't interrupt

Felix.Transition.new({ From = "*", Target = "HitReact", Triggers = { "Hit" }, Priority = 1 })
Felix.Transition.new({ From = "*", Target = "Staggered", Triggers = { "Stagger" }, Priority = 10 })
Felix.Transition.new({ From = "*", Target = "Dead", Triggers = { "Die" }, Priority = math.huge })
```

`Resistance` can be a function, re-evaluated on every trigger, which makes **cancel windows** one line:

```lua
-- Can't be cancelled for the first 0.25s, then anything goes
heavy.Resistance = function(machine)
	return if machine:GetTimeInState() < 0.25 then 10 else 0
end
```

## Input buffering

Players press attack slightly before the current attack ends. With `Send`, that press is lost. With
[`Buffer`](/api/Machine#Buffer), it's kept for a window and retried after every transition and every `Update`:

```lua
fighter:Buffer("Attack", 0.2) -- fires now if it can, otherwise within the next 0.2s if it becomes possible
```

Buffering a trigger that's already buffered replaces it, so mashing buffers one press. `ClearBuffer` drops them, and `Stop` clears the buffer.

## Hierarchical states

Set a state's `Parent` to group states. While a child is active, its parents are too:

```lua
local attacking = Felix.State.new("Attacking")
attacking.Initial = "Light1"          -- targeting Attacking enters Light1
attacking.Tags = { CanMove = false }

local light1 = Felix.State.new("Light1")
light1.Parent = "Attacking"

local light2 = Felix.State.new("Light2")
light2.Parent = "Attacking"
```

- A parent's transitions, `Tags` and `Resistance` apply to its children (a child's own win).
- Moving between children of the same parent doesn't exit the parent, so its scope survives the whole combo.
- `machine:Is("Attacking")` is true in `Light1` and `Light2`.
- `machine.Current` is the innermost active state.

## Tags

Instead of asking "is the fighter in Dodge, or Roll, or Parry?", ask what the state means:

```lua
dodge.Tags = { Invulnerable = true, CanMove = false }

if not target:HasTag("Invulnerable") then
	target:Send("Hit", damage)
end
```

## Asking before sending

[`CanSend`](/api/Machine#CanSend) checks a trigger without firing it, for UI and AI. [`Rejected`](/api/Machine#Rejected) fires whenever a `Send` doesn't transition. Both give a reason: `"NoTransition"`, `"Conditions"`, `"Resisted"` or `"Inactive"`.

```lua
local canDodge, reason = fighter:CanSend("Dodge")

fighter.Rejected:Connect(function(trigger, reason)
	print(trigger, "rejected:", reason) -- "Parry rejected: Resisted"
end)
```

`CanSend` runs the Conditions, so keep them free of side effects.

## History

[`machine.Previous`](/api/Machine#Previous) is the state before the last transition, and [`GetHistory()`](/api/Machine#GetHistory) returns the last few state names, oldest first (8 by default, set with `HistorySize`).

## Networking

[`Snapshot()`](/api/Machine#Snapshot) returns `{ State, Time }` as plain data, and [`ForceState(name, elapsed)`](/api/Machine#ForceState) moves straight to a state with the given time already elapsed, skipping Conditions, Effects and Resistance. Together they let a server correct a client:

```lua
-- Server
remote:FireClient(player, fighter:Snapshot())

-- Client
remote.OnClientEvent:Connect(function(snapshot)
	if snapshot.State and not fighter:Is(snapshot.State) then
		fighter:ForceState(snapshot.State, snapshot.Time)
	end
end)
```

`Context` isn't part of the snapshot; replicate the values you need yourself.

## Changing transitions at runtime

Inserting a transition or state after `Start` is picked up automatically. After replacing or removing one, or changing a transition's `Triggers`, call [`machine:Refresh()`](/api/Machine#Refresh).
