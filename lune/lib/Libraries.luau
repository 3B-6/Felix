--!nocheck
-- Loads Felix (native Lune require) and Arch (Rojo build + Instance require shim).

local fs = require("@lune/fs")

local Loader = require("./RobloxLoader")
local FelixMachine = require("../../src")
local FelixAdapter = require("../../tests/adapters/Felix")
local ArchAdapter = require("../../tests/adapters/Arch")

local PROJECT = "test.project.json"
local PLACE = "build/test.rbxl"

return function()
	if not fs.isDir("DevPackages") then
		error("DevPackages missing, run `wally install` first")
	end
	if not fs.isDir("build") then
		fs.writeDir("build")
	end

	Loader.build(PROJECT, PLACE)
	local runtime = Loader.loadPlace(PLACE)
	local Arch = runtime.require(runtime.game:GetService("ReplicatedStorage").DevPackages.Arch)

	return {
		{
			name = "Felix",
			module = FelixMachine,
			create = function(definition, trace)
				return FelixAdapter(FelixMachine, definition, trace)
			end,
		},
		{
			name = "Arch",
			module = Arch,
			create = function(definition, trace)
				return ArchAdapter(Arch, definition, trace, runtime)
			end,
		},
	}
end
