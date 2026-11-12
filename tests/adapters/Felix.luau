--!nocheck
-- Builds a Felix machine from a shared test definition (see tests/README in Compare.spec).

return function(FelixMachine, definition, trace: { string })
	local State = FelixMachine.State
	local Transition = FelixMachine.Transition

	local adapter = {}
	local machine

	local api = {
		send = function(event: string, ...)
			adapter.send(event, ...)
		end,
	}

	local states = {}
	for name, stateDef in definition.states do
		local state = State.new(name)

		state.OnEnter = function(m, ...)
			table.insert(trace, `enter:{name}`)
			if stateDef.onEnter then
				stateDef.onEnter(api, m.Context, ...)
			end
		end

		state.OnExit = function(m, ...)
			table.insert(trace, `exit:{name}`)
			if stateDef.onExit then
				stateDef.onExit(api, m.Context, ...)
			end
		end

		for event, candidates in stateDef.on or {} do
			for _, candidate in candidates do
				table.insert(
					state.Transitions,
					Transition.new({
						From = name,
						Target = candidate.target,
						Triggers = { event },
						Conditions = if candidate.guard
							then {
								function(m, ...)
									return candidate.guard(m.Context, ...)
								end,
							}
							else nil,
						Effects = if candidate.action
							then {
								function(m, ...)
									candidate.action(m.Context, ...)
								end,
							}
							else nil,
					})
				)
			end
		end

		table.insert(states, state)
	end

	machine = FelixMachine.new(
		definition.id or "test",
		definition.initial,
		{ DebugMode = false, Context = definition.context },
		states
	)

	function adapter.start()
		machine:Start()
	end

	function adapter.send(event: string, ...)
		machine:Send(event, ...)
	end

	function adapter.context()
		return machine.Context
	end

	function adapter.current(): string?
		return machine.Current and machine.Current.Name
	end

	function adapter.stop()
		machine:Stop()
	end

	adapter.raw = machine
	return adapter
end
