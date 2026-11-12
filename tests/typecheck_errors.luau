--!strict
-- Never run, only type-checked by `lune run check`: every line marked `-- error` must produce a
-- type error, so a change that silently loosens the public types (e.g. to `any`) fails the check.

local Felix = require("../src")

local machine = Felix.new("player", "Idle")
local state = Felix.State.new("Idle")

machine:Send(5) -- error
machine:Snd("Go") -- error
local _moved: number = machine:Send("Go") -- error
Felix.State.new(1) -- error
state.Nme = "Idle" -- error
Felix.Transition.new({ Target = "Run" }) -- error
Felix.new("player") -- error
local _current: Felix.State = machine.Current -- error
state.OnEnter = function(_details: Felix.Details?) end -- error

type Combat = { Health: number }
local combat: Felix.Machine<Combat> = Felix.new("Player", "Alive", { Context = { Health = 100 } })
local combatState: Felix.State<Combat> = Felix.State.new("Alive")
local _health: string = combat.Context.Health -- error
combat.Context.Helth = 1 -- error
combatState.OnExit = function(m) m.Context.Helth = 2 end -- error

combatState.Duration = "long" -- error
combatState.Parent = 5 -- error
combatState.Resistance = "high" -- error
combatState.OnUpdate = function(m, dt: string) end -- error
combat:Update("1") -- error
combat:Buffer("Attack") -- error
local _reason: number = select(2, combat:CanSend("Dodge")) -- error
combat:ForceState(1) -- error
local _scope: number = combat:GetScope() -- error
Felix.Transition.new({ From = "*", Target = "Dead", Triggers = { "Die" }, Priority = "max" }) -- error

return nil
