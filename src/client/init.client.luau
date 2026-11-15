-- Client entry point. Players have no avatar character in Ragdoll Rides: they are always in a vehicle,
-- with their rider in the seat. Controllers are created in order, given each other, then started.
-- Some only run in one place (Shared/Place): the map builder, browsing, quick races and the hub in
-- Tumble Park; Bumper Brawl in Cinder Cove; Highway Havoc in Sunny Pass.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local Controllers = script:WaitForChild("Controllers")

-- No default character controls or backpack
task.spawn(function()
	local ok, err = pcall(function()
		local playerModule = require(
			LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript
		) :: any
		playerModule:GetControls():Disable()
	end)
	if not ok then
		warn("[Client] could not disable default controls: " .. tostring(err))
	end
end)
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
require(Shared:WaitForChild("Net")).waitForRemotes()
local role = require(Shared:WaitForChild("Place")).role()

-- { name, module, only in this place role (nil = every place) }
local ORDER = {
	{ "Input", "InputController" },
	{ "SurfaceEffects", "SurfaceEffects" },
	{ "Debris", "Debris" },
	{ "Ragdoll", "RagdollClient" },
	{ "Vehicle", "VehicleController" },
	{ "RemoteVehicles", "RemoteVehicles" },
	{ "Damage", "DamageController" },
	{ "Camera", "CameraController" },
	{ "CrashReplay", "CrashReplay" },
	{ "Juice", "JuiceService" },
	{ "Hud", "HudController" },
	{ "Profile", "ProfileClient" },
	{ "Settings", "SettingsMenu" },
	{ "Tracks", "TracksClient" },
	{ "Builder", "BuilderClient", "Hub" },
	{ "Browse", "BrowseClient", "Hub" },
	{ "Shop", "ShopClient" },
	{ "Race", "RaceClient", "Hub" },
	{ "Hub", "HubClient", "Hub" },
	{ "Brawl", "BrawlClient", "Brawl" },
	{ "Highway", "HighwayClient", "Highway" },
	{ "Dev", "DevPanel" },
}
local active = {}
for _, entry in ORDER do
	if entry[3] == nil or entry[3] == role then
		table.insert(active, entry)
	end
end
ORDER = active

local all = {}
for _, entry in ORDER do
	all[entry[1]] = require(Controllers:WaitForChild(entry[2]) :: ModuleScript)
end
for _, entry in ORDER do
	local controller = all[entry[1]]
	if controller.init then
		controller.init(all)
	end
end
for _, entry in ORDER do
	local controller = all[entry[1]]
	if controller.start then
		task.spawn(controller.start)
	end
end
