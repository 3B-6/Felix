--!nocheck
--[[
	Runs the same scenarios against Felix and Arch.

	A shared definition looks like:
	{
		context = {}, -- optional, the machine's initial context table
		initial = "Idle",
		states = {
			Idle = {
				onEnter = function(api, ctx, ...) end, -- optional, api.send(event, ...) re-enters the machine
				onExit = function(api, ctx, ...) end, -- optional, same arguments
				on = {
					Go = { { target = "Run", guard = fn?, action = fn? }, ... }, -- first passing guard wins
				},
			},
		},
	}

	guard(ctx, ...) and action(ctx, ...) get the context and the event data sent with the event (`...`).
	Adapters expose m.start(), m.send(event, ...), m.stop(), m.current() and m.context().

	Every adapter records "enter:X" / "exit:X" into `trace`; actions record whatever the test pushes.
]]

local Bench = require("../lune/lib/Bench")

return function(t, libs)
	local describe, it, expect = t.describe, t.it, t.expect

	local function walkDefinition(trace)
		return {
			initial = "Idle",
			states = {
				Idle = {
					on = {
						Go = {
							{
								target = "Run",
								action = function()
									table.insert(trace, "action:go")
								end,
							},
						},
					},
				},
				Run = {
					on = {
						Jump = { { target = "Jump" } },
						Stop = { { target = "Idle" } },
					},
				},
				Jump = {
					on = {
						Land = { { target = "Idle" } },
					},
				},
			},
		}
	end

	-- Scenarios both libraries should agree on
	for _, lib in libs do
		describe(`{lib.name}: parity`, function()
			it("enters the initial state on Start", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				expect(m.current()).toBe("Idle")
				expect(trace).toEqual({ "enter:Idle" })
			end)

			it("runs exit -> action -> enter on a transition", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("Run")
				expect(trace).toEqual({ "enter:Idle", "exit:Idle", "action:go", "enter:Run" })
			end)

			it("ignores events the current state doesn't handle", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				m.send("Land")
				m.send("NotAnEvent")
				expect(m.current()).toBe("Idle")
				expect(trace).toEqual({ "enter:Idle" })
			end)

			it("follows a multi-step path", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				for _, event in { "Go", "Jump", "Land", "Go", "Stop" } do
					m.send(event)
				end
				expect(m.current()).toBe("Idle")
				expect(trace).toEqual({
					"enter:Idle",
					"exit:Idle",
					"action:go",
					"enter:Run",
					"exit:Run",
					"enter:Jump",
					"exit:Jump",
					"enter:Idle",
					"exit:Idle",
					"action:go",
					"enter:Run",
					"exit:Run",
					"enter:Idle",
				})
			end)

			it("blocks a transition when its guard fails", function()
				local trace = {}
				local allowed = false
				local m = lib.create({
					initial = "Locked",
					states = {
						Locked = {
							on = {
								Open = {
									{
										target = "Open",
										guard = function()
											return allowed
										end,
									},
								},
							},
						},
						Open = {},
					},
				}, trace)
				m.start()
				m.send("Open")
				expect(m.current()).toBe("Locked")
				allowed = true
				m.send("Open")
				expect(m.current()).toBe("Open")
			end)

			it("picks the first candidate whose guard passes", function()
				local trace = {}
				local m = lib.create({
					initial = "A",
					states = {
						A = {
							on = {
								Go = {
									{
										target = "B",
										guard = function()
											return false
										end,
									},
									{
										target = "C",
										guard = function()
											return true
										end,
									},
									{ target = "D" },
								},
							},
						},
						B = {},
						C = {},
						D = {},
					},
				}, trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("C")
			end)

			it("exits and re-enters on a self-transition", function()
				local trace = {}
				local m = lib.create({
					initial = "A",
					states = { A = { on = { Reset = { { target = "A" } } } } },
				}, trace)
				m.start()
				m.send("Reset")
				expect(m.current()).toBe("A")
				expect(trace).toEqual({ "enter:A", "exit:A", "enter:A" })
			end)

			it("ignores events sent before Start", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.send("Go")
				expect(m.current()).toBeNil()
				expect(trace).toEqual({})
			end)

			it("ignores events sent after Stop", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				m.stop()
				local before = #trace
				m.send("Go")
				expect(#trace).toBe(before)
			end)

			it("exits the active state on Stop", function()
				local trace = {}
				local m = lib.create(walkDefinition(trace), trace)
				m.start()
				m.stop()
				expect(trace).toEqual({ "enter:Idle", "exit:Idle" })
			end)

			it("finishes a transition before handling an event sent from OnExit", function()
				local trace = {}
				local m = lib.create({
					initial = "A",
					states = {
						A = {
							onExit = function(api)
								api.send("Next")
							end,
							on = { Go = { { target = "B" } } },
						},
						B = { on = { Next = { { target = "C" } } } },
						C = {},
					},
				}, trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("C")
				expect(trace).toEqual({ "enter:A", "exit:A", "enter:B", "exit:B", "enter:C" })
			end)

			it("finishes a transition before handling an event sent from an action", function()
				local trace = {}
				local m
				m = lib.create({
					initial = "A",
					states = {
						A = {
							on = {
								Go = {
									{
										target = "B",
										action = function()
											table.insert(trace, "action:go")
											m.send("Next")
										end,
									},
								},
							},
						},
						B = { on = { Next = { { target = "C" } } } },
						C = {},
					},
				}, trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("C")
				expect(trace).toEqual({ "enter:A", "exit:A", "action:go", "enter:B", "exit:B", "enter:C" })
			end)

			it("passes event data to guards, OnExit, actions and OnEnter", function()
				local trace = {}
				local m = lib.create({
					context = { log = {} },
					initial = "A",
					states = {
						A = {
							onExit = function(_api, ctx, amount)
								table.insert(ctx.log, `exit:{amount}`)
							end,
							on = {
								Go = {
									{
										target = "B",
										guard = function(ctx, amount)
											table.insert(ctx.log, `guard:{amount}`)
											return amount > 5
										end,
										action = function(ctx, amount)
											table.insert(ctx.log, `action:{amount}`)
										end,
									},
								},
							},
						},
						B = {
							onEnter = function(_api, ctx, amount, extra)
								table.insert(ctx.log, `enter:{amount}:{extra}`)
							end,
						},
					},
				}, trace)
				m.start()
				m.send("Go", 3, "x")
				expect(m.current()).toBe("A")
				m.send("Go", 10, "y")
				expect(m.current()).toBe("B")
				expect(m.context().log).toEqual({ "guard:3", "guard:10", "exit:10", "action:10", "enter:10:y" })
			end)

			it("shares one context between all callbacks", function()
				local trace = {}
				local m = lib.create({
					context = { count = 0 },
					initial = "Off",
					states = {
						Off = {
							on = {
								Toggle = {
									{
										target = "On",
										guard = function(ctx)
											return ctx.count < 2
										end,
									},
								},
							},
						},
						On = {
							onEnter = function(_api, ctx)
								ctx.count += 1
							end,
							on = { Toggle = { { target = "Off" } } },
						},
					},
				}, trace)
				m.start()
				for _ = 1, 6 do
					m.send("Toggle")
				end
				-- Only the first two Off -> On transitions pass the guard
				expect(m.context().count).toBe(2)
				expect(m.current()).toBe("Off")
			end)

			it("keeps event data on an event sent from a callback", function()
				local trace = {}
				local m = lib.create({
					context = {},
					initial = "A",
					states = {
						A = { on = { Go = { { target = "B" } } } },
						B = {
							onEnter = function(api)
								api.send("Next", "payload", 42)
							end,
							on = { Next = { { target = "C" } } },
						},
						C = {
							onEnter = function(_api, ctx, text, number)
								ctx.received = { text, number }
							end,
						},
					},
				}, trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("C")
				expect(m.context().received).toEqual({ "payload", 42 })
			end)

			it("handles an event sent from inside OnEnter", function()
				local trace = {}
				local m = lib.create({
					initial = "A",
					states = {
						A = { on = { Go = { { target = "B" } } } },
						B = {
							onEnter = function(api)
								api.send("Next")
							end,
							on = { Next = { { target = "C" } } },
						},
						C = {},
					},
				}, trace)
				m.start()
				m.send("Go")
				expect(m.current()).toBe("C")
				expect(trace).toEqual({ "enter:A", "exit:A", "enter:B", "exit:B", "enter:C" })
			end)
		end)
	end

	-- Timing comparison. Only sanity-checks results; the numbers are reported, not asserted,
	-- since thresholds would be flaky across machines. Use `lune run bench` for longer runs.
	describe("performance", function()
		local ITERATIONS = 20_000

		it(`toggles A <-> B {ITERATIONS} times`, function()
			local results, lines = {}, {}
			for _, lib in libs do
				local elapsed, final = Bench.toggle(lib, ITERATIONS)
				-- 1,000 warm-up + ITERATIONS toggles, both even, so we end where we started
				expect(final).toBe("A")
				results[lib.name] = elapsed
				table.insert(lines, Bench.format(lib.name, elapsed, ITERATIONS))
			end
			if results.Felix and results.Arch then
				table.insert(lines, Bench.ratio(results.Felix, results.Arch))
			end
			return table.concat(lines, "\n")
		end)
	end)

	-- Places where the two libraries intentionally/currently behave differently.
	-- These assert each library's *actual* behavior so the suite documents the gap.
	-- describe("known differences", function()
	-- 	local byName = {}
	-- 	for _, lib in libs do
	-- 		byName[lib.name] = lib
	-- 	end

	-- 	-- (With an action attached, Arch's event loop thread crashes on `t.target.id` instead.)
	-- 	it("Undefined target: Arch silently ignores it, Felix throws on Start", function()
	-- 		local function definition(_trace)
	-- 			return {
	-- 				initial = "A",
	-- 				states = {
	-- 					A = { on = { Go = { { target = "Missing" } } } },
	-- 				},
	-- 			}
	-- 		end

	-- 		local archTrace = {}
	-- 		local arch = byName.Arch.create(definition(archTrace), archTrace)
	-- 		arch.start()
	-- 		arch.send("Go")
	-- 		expect(arch.current()).toBe("A")
	-- 		expect(archTrace).toEqual({ "enter:A" })

	-- 		local felixTrace = {}
	-- 		local felix = byName.Felix.create(definition(felixTrace), felixTrace)
	-- 		expect(function()
	-- 			felix.start()
	-- 		end).toThrow(`has a Transition to "Missing"`)
	-- 		expect(felixTrace).toEqual({})
	-- 	end)
	-- end)

	-- Felix-only behavior
	describe("Felix", function()
		local Felix
		for _, lib in libs do
			if lib.name == "Felix" then
				Felix = lib
			end
		end

		it("gives the machine an empty Context when none is passed", function()
			local machine = Felix.module.new("NoContext", "A", nil, { Felix.module.State.new("A") })
			expect(machine.Context).toEqual({})
			machine.Context.score = 5
			expect(machine.Context.score).toBe(5)
		end)

		it("passes the machine itself to every callback", function()
			local module = Felix.module
			local a, b = module.State.new("A"), module.State.new("B")
			local seen = {}
			local machine
			a.OnExit = function(m)
				table.insert(seen, m == machine)
			end
			b.OnEnter = function(m)
				table.insert(seen, m == machine)
			end
			table.insert(
				a.Transitions,
				module.Transition.new({
					From = "A",
					Target = "B",
					Triggers = { "Go" },
					Conditions = {
						function(m)
							table.insert(seen, m == machine)
							return true
						end,
					},
					Effects = {
						function(m)
							table.insert(seen, m == machine)
						end,
					},
				})
			)
			machine = module.new("Self", "A", nil, { a, b })
			machine:Start()
			machine:Send("Go")
			expect(seen).toEqual({ true, true, true, true })
		end)

		it("exits the current state when Start is called on a running machine", function()
			local trace = {}
			local m = Felix.create(walkDefinition(trace), trace)
			m.start()
			m.send("Go")
			m.start()
			expect(m.current()).toBe("Idle")
			expect(trace).toEqual({ "enter:Idle", "exit:Idle", "action:go", "enter:Run", "exit:Run", "enter:Idle" })
		end)

		it("returns false from a Send that was queued during a transition", function()
			local trace = {}
			local queuedResult
			local m
			m = Felix.create({
				initial = "A",
				states = {
					A = {
						on = {
							Go = {
								{
									target = "B",
									action = function()
										queuedResult = m.raw:Send("Next")
									end,
								},
							},
						},
					},
					B = { on = { Next = { { target = "C" } } } },
					C = {},
				},
			}, trace)
			m.start()
			expect(m.raw:Send("Go")).toBe(true)
			expect(queuedResult).toBe(false)
			expect(m.current()).toBe("C")
		end)

		it("defers a Stop called from OnEnter until the transition finishes", function()
			local trace = {}
			local m
			m = Felix.create({
				initial = "A",
				states = {
					A = { on = { Go = { { target = "B" } } } },
					B = {
						onEnter = function(api)
							api.send("Next") -- dropped: Stop wins over queued events
							m.stop()
						end,
						on = { Next = { { target = "C" } } },
					},
					C = {},
				},
			}, trace)
			m.start()
			m.send("Go")
			expect(m.current()).toBeNil()
			expect(trace).toEqual({ "enter:A", "exit:A", "enter:B", "exit:B" })
		end)

		it("stays usable after a callback errors mid-transition", function()
			local trace = {}
			local failed = false
			local m = Felix.create({
				initial = "A",
				states = {
					A = {
						on = {
							Go = {
								{
									target = "B",
									action = function()
										if not failed then
											failed = true
											error("boom")
										end
									end,
								},
							},
						},
					},
					B = { on = { Back = { { target = "A" } } } },
				},
			}, trace)
			m.start()
			expect(function()
				m.raw:Send("Go")
			end).toThrow("boom")
			-- The failed transition exited A but never entered B, so Current is still A and the retry works
			expect(m.raw._Transitioning).toBe(false)
			expect(m.raw:Send("Go")).toBe(true)
			expect(m.current()).toBe("B")
		end)
	end)
end
