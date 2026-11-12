--!nocheck
-- Felix-only features aimed at combat: scopes, timers, hierarchy, interrupts, buffering, tags, snapshots.

return function(t, libs)
	local describe, it, expect = t.describe, t.it, t.expect

	local Felix
	for _, lib in libs do
		if lib.name == "Felix" then
			Felix = lib.module
		end
	end

	-- Builds a machine from { Name = { Parent?, Initial?, Duration?, Next?, Resistance?, Tags?, on = { Trigger = "Target" | { Target, ... } } } }.
	-- Every enter/exit is recorded in `trace`.
	local function build(default: string, spec, details)
		local trace = {}
		local states = {}
		for name, def in spec do
			local state = Felix.State.new(name)
			state.Parent = def.Parent
			state.Initial = def.Initial
			state.Duration = def.Duration
			state.Next = def.Next
			state.Resistance = def.Resistance
			state.Tags = def.Tags
			state.OnUpdate = def.OnUpdate
			state.OnEnter = function(m, ...)
				table.insert(trace, `enter:{name}`)
				if def.OnEnter then
					def.OnEnter(m, ...)
				end
			end
			state.OnExit = function(m, ...)
				table.insert(trace, `exit:{name}`)
				if def.OnExit then
					def.OnExit(m, ...)
				end
			end
			for trigger, target in def.on or {} do
				local params = if type(target) == "string" then { Target = target } else target
				params.From = name
				params.Triggers = { trigger }
				table.insert(state.Transitions, Felix.Transition.new(params))
			end
			table.insert(states, state)
		end
		local machine = Felix.new("test", default, details, states)
		return machine, trace
	end

	describe("Scope", function()
		it("cleans up added items when the state is left, newest first", function()
			local cleaned = {}
			local m = build("A", {
				A = {
					on = { Go = "B" },
					OnEnter = function(machine)
						local scope = machine:GetScope()
						scope:Add(function()
							table.insert(cleaned, "fn")
						end)
						scope:Add({
							Destroy = function()
								table.insert(cleaned, "Destroy")
							end,
						})
						scope:Add({
							Disconnect = function()
								table.insert(cleaned, "Disconnect")
							end,
						})
					end,
				},
				B = {},
			})
			m:Start()
			expect(cleaned).toEqual({})
			m:Send("Go")
			expect(cleaned).toEqual({ "Disconnect", "Destroy", "fn" })
		end)

		it("gives each callback its own state's scope, and lets OnExit still use it", function()
			local exitScopeActive
			local m = build("A", {
				A = {
					on = { Go = "B" },
					OnExit = function(machine)
						exitScopeActive = machine:GetScope().Active
					end,
				},
				B = {},
			})
			m:Start()
			local scope = m:GetScope()
			m:Send("Go")
			expect(exitScopeActive).toBe(true)
			expect(scope.Active).toBe(false)
		end)

		it("cleans an item added to an already-cleaned scope immediately", function()
			local m = build("A", { A = { on = { Go = "B" } }, B = {} })
			m:Start()
			local scope = m:GetScope()
			m:Send("Go")
			local ran = false
			scope:Add(function()
				ran = true
			end)
			expect(ran).toBe(true)
		end)

		it("rejects items it can't clean", function()
			local m = build("A", { A = {} })
			m:Start()
			expect(function()
				m:GetScope():Add(5)
			end).toThrow("can't clean up a number")
		end)

		it("errors when asked for the scope of an inactive state, like from inside an Effect", function()
			local m = build("A", {
				A = {
					on = {
						Go = {
							Target = "B",
							Effects = {
								function(machine)
									machine:GetScope()
								end,
							},
						},
					},
				},
				B = {},
			})
			m:Start()
			expect(function()
				m:Send("Go")
			end).toThrow("isn't active")
		end)

		it("cleans every item even if one errors, then rethrows", function()
			local cleaned = false
			local m = build("A", {
				A = {
					on = { Go = "B" },
					OnEnter = function(machine)
						local scope = machine:GetScope()
						scope:Add(function()
							cleaned = true
						end)
						scope:Add(function()
							error("cleanup failed")
						end)
					end,
				},
				B = {},
			})
			m:Start()
			expect(function()
				m:Send("Go")
			end).toThrow("cleanup failed")
			expect(cleaned).toBe(true)
		end)
	end)

	describe("Timers", function()
		it("fires a Delay once its time has passed on Update", function()
			local fired = 0
			local m = build("A", {
				A = {
					OnEnter = function(machine)
						machine:GetScope():Delay(0.3, function(amount)
							fired += amount
						end, 2)
					end,
				},
			})
			m:Start()
			m:Update(0.2)
			expect(fired).toBe(0)
			m:Update(0.1)
			expect(fired).toBe(2)
			m:Update(1)
			expect(fired).toBe(2)
		end)

		it("cancels a Delay when its state is left first", function()
			local fired = false
			local m = build("Attack", {
				Attack = {
					on = { Hit = "Stunned" },
					OnEnter = function(machine)
						machine:GetScope():Delay(0.3, function()
							fired = true
						end)
					end,
				},
				Stunned = {},
			})
			m:Start()
			m:Update(0.1)
			m:Send("Hit")
			m:Update(1)
			expect(fired).toBe(false)
		end)

		it("cancels a Delay with the function it returns", function()
			local fired = false
			local m = build("A", { A = {} })
			m:Start()
			local cancel = m:GetScope():Delay(0.1, function()
				fired = true
			end)
			cancel()
			m:Update(1)
			expect(fired).toBe(false)
		end)

		it("fires due timers in time order, and queues Sends they make", function()
			local order = {}
			local m, trace = build("A", {
				A = {
					on = { Go = "B" },
					OnEnter = function(machine)
						local scope = machine:GetScope()
						scope:Delay(0.2, function()
							table.insert(order, "late")
						end)
						scope:Delay(0.1, function()
							table.insert(order, "early")
							machine:Send("Go")
						end)
					end,
				},
				B = {},
			})
			m:Start()
			m:Update(0.5)
			-- Both were due in the same Update, so both fire, then the queued Go runs
			expect(order).toEqual({ "early", "late" })
			expect(trace).toEqual({ "enter:A", "exit:A", "enter:B" })
		end)

		it("moves to Next when a state's Duration runs out", function()
			local m, trace = build("Windup", {
				Windup = { Duration = 0.1, Next = "Active" },
				Active = { Duration = 0.2, Next = "Recovery" },
				Recovery = {},
			})
			m:Start()
			m:Update(0.05)
			expect(m.Current.Name).toBe("Windup")
			m:Update(0.05)
			expect(m.Current.Name).toBe("Active")
			m:Update(0.2)
			expect(m.Current.Name).toBe("Recovery")
			expect(trace).toEqual({
				"enter:Windup",
				"exit:Windup",
				"enter:Active",
				"exit:Active",
				"enter:Recovery",
			})
		end)

		it("ends a Duration on the frame it's reached, despite floating-point dt sums", function()
			local m = build("Swing", {
				Swing = { Duration = 0.3, Next = "Recovery" },
				Recovery = { Duration = 0.2, Next = "Idle" },
				Idle = {},
			})
			m:Start()
			for _ = 1, 10 do
				m:Update(0.05)
			end
			expect(m.Current.Name).toBe("Idle")
		end)

		it("ignores Resistance when a Duration runs out", function()
			local m = build("Heavy", {
				Heavy = { Duration = 0.5, Next = "Idle", Resistance = math.huge },
				Idle = {},
			})
			m:Start()
			m:Update(0.5)
			expect(m.Current.Name).toBe("Idle")
		end)

		it("tracks time in state", function()
			local m = build("A", { A = { on = { Go = "B" } }, B = {} })
			m:Start()
			m:Update(0.25)
			expect(m:GetTimeInState()).toBe(0.25)
			m:Send("Go")
			expect(m:GetTimeInState()).toBe(0)
			expect(m:GetTimeInState("A")).toBe(0)
			m:Update(0.5)
			expect(m:GetTimeInState("B")).toBe(0.5)
		end)

		it("calls OnUpdate with dt for every active state, parents first", function()
			local calls = {}
			local m = build("Child", {
				Parent = {
					OnUpdate = function(_, dt)
						table.insert(calls, `Parent {dt}`)
					end,
				},
				Child = {
					Parent = "Parent",
					OnUpdate = function(_, dt)
						table.insert(calls, `Child {dt}`)
					end,
				},
			})
			m:Start()
			m:Update(0.5)
			expect(calls).toEqual({ "Parent 0.5", "Child 0.5" })
		end)

		it("can't be called from inside a callback", function()
			local m = build("A", {
				A = {
					OnUpdate = function(machine)
						machine:Update(1)
					end,
				},
			})
			m:Start()
			expect(function()
				m:Update(1)
			end).toThrow("Can't Update during a transition")
			expect(m._Transitioning).toBe(false)
		end)
	end)

	describe("AnyTransitions", function()
		local function fighter()
			local m, trace = build("Idle", {
				Idle = { on = { Attack = "Attack" } },
				Attack = {},
				Blocking = { on = { Hit = "BlockStun" } },
				BlockStun = {},
				Stunned = {},
				Dead = {},
			})
			table.insert(
				m.AnyTransitions,
				Felix.Transition.new({ From = "*", Target = "Stunned", Triggers = { "Hit" }, Except = { "Dead" } })
			)
			return m, trace
		end

		it("fires from any state", function()
			local m = fighter()
			m:Start()
			m:Send("Attack")
			expect(m:Send("Hit")).toBe(true)
			expect(m.Current.Name).toBe("Stunned")
		end)

		it("lets a state's own transition handle the trigger first", function()
			local m = fighter()
			m.Default = "Blocking"
			m:Start()
			m:Send("Hit")
			expect(m.Current.Name).toBe("BlockStun")
		end)

		it("doesn't fire from states in Except", function()
			local m = fighter()
			m.Default = "Dead"
			m:Start()
			expect(m:Send("Hit")).toBe(false)
			expect(m.Current.Name).toBe("Dead")
		end)

		it('must be From "*"', function()
			local m = fighter()
			m.AnyTransitions[1].From = "Idle"
			expect(function()
				m:Start()
			end).toThrow(`It must be From "*"`)
		end)
	end)

	describe("Priority and Resistance", function()
		local function armored(resistance)
			local m = build("Heavy", {
				Heavy = {
					Resistance = resistance,
					on = {
						Flinch = { Target = "HitReact", Priority = 1 },
						Stagger = { Target = "Staggered", Priority = 10 },
					},
				},
				HitReact = {},
				Staggered = {},
			})
			return m
		end

		it("blocks transitions whose Priority is below the state's Resistance", function()
			local m = armored(5)
			m:Start()
			expect(m:Send("Flinch")).toBe(false)
			expect(m.Current.Name).toBe("Heavy")
			expect(m:Send("Stagger")).toBe(true)
			expect(m.Current.Name).toBe("Staggered")
		end)

		it("re-evaluates a Resistance function, for cancel windows", function()
			local m = armored(function(machine)
				return if machine:GetTimeInState() < 0.25 then 5 else 0
			end)
			m:Start()
			expect(m:Send("Flinch")).toBe(false)
			m:Update(0.25)
			expect(m:Send("Flinch")).toBe(true)
		end)

		it("inherits a parent's Resistance unless the child sets its own", function()
			local m = build("Child", {
				Parent = { Resistance = 5 },
				Child = { Parent = "Parent", on = { Go = { Target = "Other", Priority = 1 } } },
				Other = {},
			})
			m:Start()
			expect(m:Send("Go")).toBe(false)
			for _, state in m.States do
				if state.Name == "Child" then
					state.Resistance = 0
				end
			end
			expect(m:Send("Go")).toBe(true)
		end)
	end)

	describe("Rejected and CanSend", function()
		it("reports why a trigger didn't fire", function()
			local open = false
			local m = build("Idle", {
				Idle = {
					Resistance = 1,
					on = {
						Locked = {
							Target = "Open",
							Priority = 1,
							Conditions = {
								function()
									return open
								end,
							},
						},
						Weak = { Target = "Open" },
					},
				},
				Open = {},
			})

			expect(select(2, m:CanSend("Locked"))).toBe("Inactive")
			m:Start()
			expect(select(2, m:CanSend("Nothing"))).toBe("NoTransition")
			expect(select(2, m:CanSend("Locked"))).toBe("Conditions")
			expect(select(2, m:CanSend("Weak"))).toBe("Resisted")
			open = true
			local can, reason = m:CanSend("Locked")
			expect(can).toBe(true)
			expect(reason).toBeNil()
			-- CanSend doesn't transition
			expect(m.Current.Name).toBe("Idle")
		end)

		it("fires Rejected with the trigger, reason and event data", function()
			local m = build("Idle", { Idle = {} })
			local got
			m.Rejected:Connect(function(...)
				got = { ... }
			end)
			m:Start()
			m:Send("Jump", 5)
			expect(got).toEqual({ "Jump", "NoTransition", 5 })
		end)
	end)

	describe("Buffer", function()
		local function combo()
			return build("Attack1", {
				Attack1 = { Duration = 0.3, Next = "Idle", on = { Attack = "Attack2" }, Resistance = 1 },
				Attack2 = {},
				Idle = { on = { Attack = "Attack1", Dodge = "Dodge" } },
				Dodge = {},
			})
		end

		it("fires right away when it can", function()
			local m = combo()
			m.Default = "Idle"
			m:Start()
			expect(m:Buffer("Attack", 0.2)).toBe(true)
			expect(m.Current.Name).toBe("Attack1")
		end)

		it("retries a buffered trigger once the state changes", function()
			local m = combo()
			m:Start()
			-- Attack1 can't dodge, so the press is buffered...
			expect(m:Buffer("Dodge", 0.5)).toBe(false)
			m:Update(0.2)
			expect(m.Current.Name).toBe("Attack1")
			-- ...and comes out as soon as Attack1 ends
			m:Update(0.1)
			expect(m.Current.Name).toBe("Dodge")
		end)

		it("drops a buffered trigger once its window expires", function()
			local m = combo()
			m:Start()
			m:Buffer("Dodge", 0.1)
			m:Update(0.3)
			expect(m.Current.Name).toBe("Idle")
		end)

		it("retries on Update, for Conditions that depend on time", function()
			local m = build("Recovery", {
				Recovery = {
					on = {
						Attack = {
							Target = "Attack",
							Conditions = {
								function(machine)
									return machine:GetTimeInState() >= 0.2
								end,
							},
						},
					},
				},
				Attack = {},
			})
			m:Start()
			m:Buffer("Attack", 0.5)
			m:Update(0.1)
			expect(m.Current.Name).toBe("Recovery")
			m:Update(0.1)
			expect(m.Current.Name).toBe("Attack")
		end)

		it("keeps one press per trigger, with the latest event data", function()
			local got = {}
			local m = build("Busy", {
				Busy = { on = { Done = "Idle" } },
				Idle = {
					on = {
						Attack = {
							Target = "Attack",
							Effects = {
								function(_, n)
									table.insert(got, n)
								end,
							},
						},
					},
				},
				Attack = { on = { Attack = "Attack" } },
			})
			m:Start()
			m:Buffer("Attack", 1, 1)
			m:Buffer("Attack", 1, 2)
			m:Send("Done")
			expect(got).toEqual({ 2 })
			expect(#m._Buffer).toBe(0)
		end)

		it("is cleared by Stop and ClearBuffer", function()
			local m = combo()
			m:Start()
			m:Buffer("Dodge", 1)
			m:ClearBuffer("Dodge")
			expect(#m._Buffer).toBe(0)
			m:Buffer("Dodge", 1)
			m:Stop()
			expect(#m._Buffer).toBe(0)
		end)
	end)

	describe("Tags", function()
		it("reads tags from the innermost state that sets them", function()
			local m = build("Dodge", {
				Combat = { Tags = { CanMove = true, InCombat = true } },
				Dodge = { Parent = "Combat", Tags = { CanMove = false, Invulnerable = true } },
			})
			m:Start()
			expect(m:HasTag("Invulnerable")).toBe(true)
			expect(m:HasTag("InCombat")).toBe(true)
			expect(m:HasTag("CanMove")).toBe(false)
			expect(m:GetTag("CanMove")).toBe(false)
			expect(m:GetTag("Missing")).toBeNil()
		end)
	end)

	describe("Hierarchy", function()
		local function hsm()
			return build("Idle", {
				Idle = { on = { Attack = "Attacking" } },
				Attacking = { Initial = "Light1", on = { Hit = "Stunned" }, Tags = { Busy = true } },
				Light1 = { Parent = "Attacking", on = { Attack = "Light2" } },
				Light2 = { Parent = "Attacking", on = { Again = "Attacking", Self = "Light2" } },
				Stunned = {},
			})
		end

		it("enters the parent, then its Initial child", function()
			local m, trace = hsm()
			m:Start()
			m:Send("Attack")
			expect(m.Current.Name).toBe("Light1")
			expect(m:Is("Attacking")).toBe(true)
			expect(m:Is("Light1")).toBe(true)
			expect(m:IsAny({ "Idle", "Attacking" })).toBe(true)
			expect(trace).toEqual({ "enter:Idle", "exit:Idle", "enter:Attacking", "enter:Light1" })
		end)

		it("keeps the parent active when moving between its children", function()
			local m, trace = hsm()
			m:Start()
			m:Send("Attack")
			table.clear(trace)
			m:Send("Attack")
			expect(trace).toEqual({ "exit:Light1", "enter:Light2" })
		end)

		it("uses a parent's transitions from its children, exiting innermost first", function()
			local m, trace = hsm()
			m:Start()
			m:Send("Attack")
			table.clear(trace)
			m:Send("Hit")
			expect(m.Current.Name).toBe("Stunned")
			expect(m:Is("Attacking")).toBe(false)
			expect(trace).toEqual({ "exit:Light1", "exit:Attacking", "enter:Stunned" })
		end)

		it("exits and re-enters a parent targeted from its child", function()
			local m, trace = hsm()
			m:Start()
			m:Send("Attack")
			m:Send("Attack")
			table.clear(trace)
			m:Send("Again")
			expect(trace).toEqual({ "exit:Light2", "exit:Attacking", "enter:Attacking", "enter:Light1" })
		end)

		it("exits and re-enters on a self-transition, leaving the parent alone", function()
			local m, trace = hsm()
			m:Start()
			m:Send("Attack")
			m:Send("Attack")
			table.clear(trace)
			m:Send("Self")
			expect(trace).toEqual({ "exit:Light2", "enter:Light2" })
		end)

		it("keeps a parent's scope alive across its children", function()
			local m = hsm()
			m:Start()
			m:Send("Attack")
			local scope = m:GetScope("Attacking")
			m:Send("Attack")
			expect(scope.Active).toBe(true)
			m:Send("Hit")
			expect(scope.Active).toBe(false)
		end)

		it("starts in a child by entering its parents first", function()
			local m, trace = hsm()
			m.Default = "Light2"
			m:Start()
			expect(trace).toEqual({ "enter:Attacking", "enter:Light2" })
		end)

		it("times out a parent, exiting its children", function()
			local m = build("Child", {
				Combo = { Duration = 1, Next = "Idle" },
				Child = { Parent = "Combo" },
				Idle = {},
			})
			m:Start()
			m:Update(1)
			expect(m.Current.Name).toBe("Idle")
		end)
	end)

	describe("Validation", function()
		it("rejects duplicate state names", function()
			local m = Felix.new("v", "A", nil, { Felix.State.new("A"), Felix.State.new("A") })
			expect(function()
				m:Start()
			end).toThrow(`Has two States named "A"`)
		end)

		it("rejects a transition whose From doesn't match its state", function()
			local a = Felix.State.new("A")
			table.insert(a.Transitions, Felix.Transition.new({ From = "B", Target = "A", Triggers = { "Go" } }))
			local m = Felix.new("v", "A", nil, { a })
			expect(function()
				m:Start()
			end).toThrow(`has a Transition From "B"`)
		end)

		it("rejects a missing Parent, a looping Parent, a bad Initial, and Duration without Next", function()
			local cases = {
				{ { A = { Parent = "Missing" } }, `Parent "Missing", which Doesn't Exist` },
				{ { A = { Parent = "B" }, B = { Parent = "A" } }, "is its own Parent" },
				{ { A = { Initial = "B" }, B = {} }, "isn't one of its children" },
				{ { A = { Duration = 1 } }, "has a Duration but no Next" },
				{ { A = { Duration = 1, Next = "Nope" } }, `Next "Nope", which Doesn't Exist` },
			}
			for _, case in cases do
				local m = build("A", case[1])
				expect(function()
					m:Start()
				end).toThrow(case[2])
			end
		end)
	end)

	describe("Lookups", function()
		it("picks up transitions inserted after Start", function()
			local m = build("A", { A = {}, B = {} })
			m:Start()
			expect(m:Send("Go")).toBe(false)
			table.insert(m.Current.Transitions, Felix.Transition.new({ From = "A", Target = "B", Triggers = { "Go" } }))
			expect(m:Send("Go")).toBe(true)
		end)

		it("picks up a changed transition after Refresh", function()
			local m = build("A", { A = { on = { Go = "B" } }, B = {} })
			m:Start()
			m.Current.Transitions[1].Triggers = { "Move" }
			m:Refresh()
			expect(m:Send("Go")).toBe(false)
			expect(m:Send("Move")).toBe(true)
		end)
	end)

	describe("CatchYields", function()
		it("turns a yielding callback into an error and keeps the machine usable", function()
			local m = build("A", {
				A = { on = { Go = "B" } },
				B = {
					on = { Back = "A" },
					OnEnter = function()
						coroutine.yield()
					end,
				},
			}, { CatchYields = true })
			m:Start()
			expect(function()
				m:Send("Go")
			end).toThrow("yielded during a transition")
			expect(m._Transitioning).toBe(false)
			expect(m.Current.Name).toBe("B")
			expect(m:Send("Back")).toBe(true)
		end)
	end)

	describe("History", function()
		it("remembers the previous state and the last few", function()
			local m = build("A", { A = { on = { Go = "B" } }, B = { on = { Go = "C" } }, C = { on = { Go = "A" } } }, {
				HistorySize = 3,
			})
			m:Start()
			expect(m.Previous).toBeNil()
			expect(m:GetHistory()).toEqual({ "A" })
			m:Send("Go")
			m:Send("Go")
			m:Send("Go")
			expect(m.Previous.Name).toBe("C")
			expect(m:GetHistory()).toEqual({ "B", "C", "A" })
			m:Start()
			expect(m:GetHistory()).toEqual({ "A" })
		end)

		it("keeps nothing with a HistorySize of 0", function()
			local m = build("A", { A = { on = { Go = "A" } } }, { HistorySize = 0 })
			m:Start()
			m:Send("Go")
			expect(m:GetHistory()).toEqual({})
		end)
	end)

	describe("Snapshot and ForceState", function()
		it("round-trips the state and its time", function()
			local server = build("Idle", { Idle = { on = { Attack = "Attack" } }, Attack = {} })
			local client, trace = build("Idle", { Idle = { on = { Attack = "Attack" } }, Attack = {} })
			server:Start()
			client:Start()
			server:Send("Attack")
			server:Update(0.4)

			local snapshot = server:Snapshot()
			expect(snapshot).toEqual({ State = "Attack", Time = 0.4 })

			client:ForceState(snapshot.State, snapshot.Time)
			expect(client.Current.Name).toBe("Attack")
			expect(client:GetTimeInState()).toBe(0.4)
			expect(trace).toEqual({ "enter:Idle", "exit:Idle", "enter:Attack" })

			-- Already there: only the time changes
			client:ForceState("Attack", 0.1)
			expect(#trace).toBe(3)
			expect(client:GetTimeInState()).toBe(0.1)
		end)

		it("ignores Resistance and Conditions", function()
			local m = build("Heavy", { Heavy = { Resistance = math.huge }, Idle = {} })
			m:Start()
			m:ForceState("Idle")
			expect(m.Current.Name).toBe("Idle")
		end)

		it("errors on an unknown state", function()
			local m = build("A", { A = {} })
			m:Start()
			expect(function()
				m:ForceState("Nope")
			end).toThrow(`State "Nope" Doesn't Exist`)
		end)
	end)

	describe("Stop", function()
		it("cleans up every active scope and pending timer", function()
			local cleaned = {}
			local fired = false
			local m = build("Child", {
				Parent = {
					OnEnter = function(machine)
						machine:GetScope():Add(function()
							table.insert(cleaned, "Parent")
						end)
					end,
				},
				Child = {
					Parent = "Parent",
					OnEnter = function(machine)
						machine:GetScope():Add(function()
							table.insert(cleaned, "Child")
						end)
						machine:GetScope():Delay(0.1, function()
							fired = true
						end)
					end,
				},
			})
			m:Start()
			m:Stop()
			expect(cleaned).toEqual({ "Child", "Parent" })
			m:Start()
			m:Stop()
			m:Update(1)
			expect(fired).toBe(false)
		end)
	end)
end
