--!nocheck
-- Builds an Arch (bohraz/arch) machine from the same shared test definition.

return function(Arch, definition, trace: { string }, runtime)
	local adapter = {}
	local machine

	local api = {
		send = function(event: string, ...)
			adapter.send(event, ...)
		end,
	}

	local states = {}
	for name, stateDef in definition.states do
		local events = {}

		for event, candidates in stateDef.on or {} do
			local list = {}
			for _, candidate in candidates do
				table.insert(list, {
					target = candidate.target,
					guards = if candidate.guard
						then {
							function(context, ...)
								return candidate.guard(context, ...)
							end,
						}
						else {},
					actions = if candidate.action
						then {
							function(context, ...)
								candidate.action(context, ...)
							end,
						}
						else {},
				})
			end
			events[event] = list
		end

		states[name] = {
			OnEntry = function(context, ...)
				table.insert(trace, `enter:{name}`)
				if stateDef.onEnter then
					stateDef.onEnter(api, context, ...)
				end
			end,
			OnExit = function(context, ...)
				table.insert(trace, `exit:{name}`)
				if stateDef.onExit then
					stateDef.onExit(api, context, ...)
				end
			end,
			events = events,
		}
	end

	machine = Arch.createMachine({
		id = definition.id or "test",
		initial = definition.initial,
		states = states,
	}, { context = definition.context })

	-- Arch warns on Send-before-Start / Stop-twice; silence that in tests
	local function quiet(fn, ...)
		runtime.setWarningsMuted(true)
		local results = table.pack(pcall(fn, ...))
		runtime.setWarningsMuted(false)
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end

	function adapter.start()
		quiet(machine.Start, machine)
	end

	function adapter.send(event: string, ...)
		quiet(machine.Send, machine, event, ...)
	end

	function adapter.context()
		return machine.context
	end

	function adapter.current(): string?
		local atomic = machine.value[1]
		return atomic and atomic.id
	end

	function adapter.stop()
		quiet(machine.Stop, machine)
	end

	adapter.raw = machine
	return adapter
end
