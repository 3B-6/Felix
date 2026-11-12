--!nocheck
-- lune run test

local process = require("@lune/process")

local Harness = require("./lib/TestHarness")
local loadLibraries = require("./lib/Libraries")

local SPECS = {
	require("../tests/Compare.spec"),
	require("../tests/Combat.spec"),
}

local libs = loadLibraries()
local t = Harness.new()

for _, spec in SPECS do
	spec(t, libs)
end

local passed, failed = t.run()
print(`\n{passed} passed, {failed} failed`)

process.exit(if failed > 0 then 1 else 0)
