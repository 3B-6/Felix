--!strict
-- Never run, only type-checked by `lune run check`: uses the public API the way a consumer would,
-- so a change that breaks or weakens the exported types fails the check.

local Felix = require("../src")

local idle = Felix.State.new("Idle")
local run = Felix.State.new("Run")

idle.OnEnter = function(machine: Felix.Machine, ...: any)
	if machine.Details and machine.Details.DebugMode then
		print("entered Idle with", ...)
	end
end

local go: Felix.Transition = Felix.Transition.new({
	From = "Idle",
	Target = "Run",
	Triggers = { "Go" },
	Conditions = {
		function(machine: Felix.Machine): boolean
			return machine.Active
		end,
	},
	Effects = {
		function(machine: Felix.Machine)
			machine:Send("Arrived")
		end,
	},
})
table.insert(idle.Transitions, go)

local machine: Felix.Machine = Felix.new("player", "Idle", { DebugMode = true }, { idle, run })
local noStates: Felix.Machine = Felix.new("empty", "Idle")

machine:Start()
local moved: boolean = machine:Send("Go")
local movedWithData: boolean = machine:Send("Go", 25, "sword")
local current: Felix.State? = machine.Current
local name: string? = if current then current.Name else nil
local states: { Felix.State }? = machine:GetStates()

machine:Stop()
machine:Destroy()

-- Untyped context: `any`, so anything goes
noStates.Context.score = 10

-- Typed context: annotate the machine and states with the context type
type Combat = { Health: number, Hits: { number } }

local alive: Felix.State<Combat> = Felix.State.new("Alive")
local dead: Felix.State<Combat> = Felix.State.new("Dead")

alive.OnEnter = function(combat)
	combat.Context.Health = 100
end

local hit: Felix.Transition<Combat> = Felix.Transition.new({
	From = "Alive",
	Target = "Dead",
	Triggers = { "Hit" },
	Conditions = {
		function(combat, damage: number): boolean
			return combat.Context.Health - damage <= 0
		end,
	},
	Effects = {
		function(combat, damage: number)
			table.insert(combat.Context.Hits, damage)
		end,
	},
})
table.insert(alive.Transitions, hit)

local context: Combat = { Health = 100, Hits = {} }
local player: Felix.Machine<Combat> = Felix.new("Player", "Alive", { Context = context }, { alive, dead })
player:Start()
player:Send("Hit", 30)
local health: number = player.Context.Health

-- Combat features
local fighter: Felix.Machine<Combat> = Felix.new(
	"Fighter",
	"Light",
	{ Context = context, HistorySize = 4, CatchYields = true },
	{ alive, dead }
)

local combo: Felix.State<Combat> = Felix.State.new("Combo")
combo.Initial = "Light"
combo.Tags = { Invulnerable = false }
combo.Resistance = function(m): number
	return if m:GetTimeInState() < 0.2 then 5 else 0
end

local light: Felix.State<Combat> = Felix.State.new("Light")
light.Parent = "Combo"
light.Duration = 0.4
light.Next = "Combo"
light.Resistance = 1
light.OnUpdate = function(m: Felix.Machine<Combat>, dt: number)
	m.Context.Health += dt
end
light.OnEnter = function(m: Felix.Machine<Combat>)
	local scope: Felix.Scope = m:GetScope()
	local cleanup: () -> () = scope:Add(function() end)
	local cancel: () -> () = scope:Delay(0.3, function(amount: number)
		m.Context.Health -= amount
	end, 5)
	cancel()
	cleanup()
end

table.insert(
	fighter.AnyTransitions,
	Felix.Transition.new({ From = "*", Target = "Dead", Triggers = { "Die" }, Priority = math.huge, Except = { "Dead" } })
)

fighter:Update(1 / 60)
local buffered: boolean = fighter:Buffer("Attack", 0.2, "heavy")
fighter:ClearBuffer("Attack")
fighter:ClearBuffer()
local canDodge: boolean, reason: Felix.RejectReason? = fighter:CanSend("Dodge")
local attacking: boolean = fighter:Is("Combo") or fighter:IsAny({ "Light", "Heavy" })
local invulnerable: boolean = fighter:HasTag("Invulnerable")
local tagValue: any = fighter:GetTag("CanMove")
local elapsed: number = fighter:GetTimeInState("Combo")
local history: { string } = fighter:GetHistory()
local previous: Felix.State<Combat>? = fighter.Previous
local clock: number = fighter.Clock
local snapshot: Felix.Snapshot = fighter:Snapshot()
if snapshot.State then
	fighter:ForceState(snapshot.State, snapshot.Time)
end
fighter:Refresh()
fighter.Rejected:Connect(function(trigger: string, why: Felix.RejectReason, ...)
	print(trigger, why, ...)
end)

return {
	moved,
	movedWithData,
	name,
	states,
	noStates,
	health,
	buffered,
	canDodge,
	reason,
	attacking,
	invulnerable,
	tagValue,
	elapsed,
	history,
	previous,
	clock,
}
