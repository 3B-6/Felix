--!nocheck
-- Minimal describe/it/expect runner for Lune.

local stdio = require("@lune/stdio")

local Harness = {}

local function deepEqual(a, b): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(value): string
	if type(value) ~= "table" then
		return if type(value) == "string" then `"{value}"` else tostring(value)
	end
	local parts = {}
	for i, v in value do
		table.insert(parts, if type(i) == "number" then show(v) else `{i} = {show(v)}`)
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function Harness.expect(actual)
	local e = {}

	function e.toBe(expected)
		if actual ~= expected then
			error(`expected {show(expected)}, got {show(actual)}`, 2)
		end
	end

	function e.toEqual(expected)
		if not deepEqual(actual, expected) then
			error(`expected {show(expected)},\n         got {show(actual)}`, 2)
		end
	end

	function e.toBeNil()
		if actual ~= nil then
			error(`expected nil, got {show(actual)}`, 2)
		end
	end

	function e.toThrow(pattern: string?)
		local ok, err = pcall(actual)
		if ok then
			error("expected function to throw", 2)
		end
		if pattern and not string.find(tostring(err), pattern, 1, true) then
			error(`expected error containing "{pattern}", got "{err}"`, 2)
		end
	end

	return e
end

function Harness.new()
	local root = { name = nil, children = {}, tests = {} }
	local current = root

	local api = {}

	function api.describe(name: string, fn: () -> ())
		local node = { name = name, children = {}, tests = {} }
		table.insert(current.children, node)
		local parent = current
		current = node
		fn()
		current = parent
	end

	function api.it(name: string, fn: () -> ())
		table.insert(current.tests, { name = name, fn = fn })
	end

	api.expect = Harness.expect

	function api.run(): (number, number)
		local passed, failed = 0, 0

		local function visit(node, depth: number)
			local indent = string.rep("  ", depth)
			if node.name then
				print(indent .. stdio.style("bold") .. node.name .. stdio.style("reset"))
			end
			local inner = if node.name then depth + 1 else depth
			for _, test in node.tests do
				local start = os.clock()
				local ok, err = pcall(test.fn)
				local ms = (os.clock() - start) * 1000
				local pad = string.rep("  ", inner)
				local timing = stdio.style("dim") .. string.format(" (%.2f ms)", ms) .. stdio.style("reset")
				if ok then
					passed += 1
					print(pad .. stdio.color("green") .. "✓ " .. stdio.color("reset") .. test.name .. timing)
					-- A test may return a string report, printed under its result line
					if type(err) == "string" then
						for line in string.gmatch(err, "[^\n]+") do
							print(pad .. "    " .. stdio.style("dim") .. line .. stdio.style("reset"))
						end
					end
				else
					failed += 1
					print(pad .. stdio.color("red") .. "✗ " .. test.name .. stdio.color("reset"))
					print(pad .. "    " .. tostring(err))
				end
			end
			for _, child in node.children do
				visit(child, inner)
			end
		end

		visit(root, 0)
		return passed, failed
	end

	return api
end

return Harness
