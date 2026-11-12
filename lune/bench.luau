--!nocheck
-- lune run bench [iterations]

local process = require("@lune/process")

local Bench = require("./lib/Bench")
local loadLibraries = require("./lib/Libraries")

local ITERATIONS = tonumber(process.args[1]) or 100_000

print(`Toggling A <-> B {ITERATIONS} times\n`)

local results = {}
for _, lib in loadLibraries() do
	local elapsed = Bench.toggle(lib, ITERATIONS)
	results[lib.name] = elapsed
	print(Bench.format(lib.name, elapsed, ITERATIONS))
end

if results.Felix and results.Arch then
	print("\n" .. Bench.ratio(results.Felix, results.Arch))
end
