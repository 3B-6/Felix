--!nocheck
-- lune run check
-- Type-checks with luau-analyze (https://github.com/luau-lang/luau/releases), which must be on PATH:
--   1. src/ and tests/typecheck.luau (consumer usage) must have no errors
--   2. every line marked `-- error` in tests/typecheck_errors.luau must have a type error

local fs = require("@lune/fs")
local process = require("@lune/process")

local MUST_PASS = { "tests/typecheck.luau" }
local MUST_FAIL = "tests/typecheck_errors.luau"

local function analyze(files: { string })
	local ok, result = pcall(process.exec, "luau-analyze", files)
	if not ok then
		print("luau-analyze not found on PATH.")
		print("Download luau-windows.zip from https://github.com/luau-lang/luau/releases,")
		print("extract it somewhere on your PATH, then run `lune run check` again.")
		process.exit(1)
	end
	return result
end

for _, name in fs.readDir("src") do
	if string.match(name, "%.luau$") then
		table.insert(MUST_PASS, `src/{name}`)
	end
end
table.sort(MUST_PASS)

local failed = false

-- 1. Clean files
local clean = analyze(MUST_PASS)
local output = clean.stdout .. clean.stderr
if output ~= "" then
	print(output)
end
if clean.ok then
	print(`{#MUST_PASS} files type-checked, no errors.`)
else
	failed = true
end

-- 2. Expected errors
local expected = {}
local lineNumber = 0
for line in string.gmatch(fs.readFile(MUST_FAIL) .. "\n", "([^\n]*)\n") do
	lineNumber += 1
	if string.find(line, "%-%- error%s*$") then
		expected[lineNumber] = line
	end
end

local errored = {}
local errors = analyze({ MUST_FAIL })
for lineText in string.gmatch(errors.stdout .. errors.stderr, "[^\n]+") do
	local n = string.match(lineText, "%((%d+),%d+%): TypeError")
	if n then
		errored[tonumber(n)] = true
	end
end

local missing = 0
for n, line in expected do
	if not errored[n] then
		missing += 1
		print(`{MUST_FAIL}:{n}: expected a type error, got none:\n    {string.gsub(line, "^%s+", "")}`)
	end
end
if missing == 0 then
	local count = 0
	for _ in expected do
		count += 1
	end
	print(`{count} expected type errors all reported.`)
else
	failed = true
end

print(if failed then "Type check failed." else "Type check passed.")
process.exit(if failed then 1 else 0)
