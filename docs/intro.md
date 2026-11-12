---
sidebar_position: 1
---

# Getting Started

Felix is a small, fast, fully typed finite state machine for Roblox and Luau.

- **States** with `OnEnter` / `OnExit` callbacks
- **Transitions** fired by named triggers, with optional **Conditions** (guards) and **Effects** (actions)
- **Event data** sent with triggers, and a shared **Context** table, both available to every callback
- Predictable ordering: **Exit → Effects → Enter**
- Safe re-entrancy: sending a trigger from inside a callback is queued until the current transition finishes
- Strict-mode types for everything, exported from the package

Built for combat, all optional (see the [Combat guide](./combat)):

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

Felix has no dependencies and works anywhere Luau runs: on the client, on the server, and in [Lune](https://lune-org.github.io/docs).

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

Next, read the [Usage guide](./usage), the [Combat guide](./combat), or jump to the [API reference](/api/Felix).
