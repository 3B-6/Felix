--!nocheck
-- Shared timing helpers for `lune run bench` and the performance tests.

local Bench = {}

function Bench.toggleDefinition()
	return {
		initial = "A",
		states = {
			A = { on = { Toggle = { { target = "B" } } } },
			B = { on = { Toggle = { { target = "A" } } } },
		},
	}
end

-- Times `iterations` A <-> B toggles on a fresh machine. Returns (seconds, state it ended in).
function Bench.toggle(lib, iterations: number)
	local trace = {}
	local m = lib.create(Bench.toggleDefinition(), trace)
	m.start()

	-- Warm up, then drop the trace so it doesn't grow during timing
	for _ = 1, 1_000 do
		m.send("Toggle")
	end
	table.clear(trace)

	local start = os.clock()
	for _ = 1, iterations do
		m.send("Toggle")
	end
	local elapsed = os.clock() - start

	local final = m.current()
	m.stop()
	return elapsed, final
end

function Bench.format(name: string, elapsed: number, iterations: number): string
	return string.format(
		"%-8s %8.2f ms   %8.3f µs/transition   %10.0f transitions/s",
		name,
		elapsed * 1000,
		elapsed / iterations * 1e6,
		iterations / elapsed
	)
end

function Bench.ratio(felix: number, arch: number): string
	return string.format(
		"Felix is %.1fx %s than Arch",
		math.max(arch / felix, felix / arch),
		if felix < arch then "faster" else "slower"
	)
end

return Bench
