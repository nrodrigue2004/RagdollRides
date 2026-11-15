-- Client entry point. Players have no avatar character in Ragdoll Rides: they are always in a vehicle,
-- with their rider in the seat. Controllers are created in order, given each other, then started.

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

require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net")).waitForRemotes()

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
	{ "Dev", "DevPanel" },
}

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
