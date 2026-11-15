-- VehicleService: spawns each player's vehicle, hands its physics to the player, and relays poses.
-- The server never simulates a player's car: the driver's device owns it (spec: Network model).
-- Players have no avatar character in this game; the camera and streaming follow the car.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local VehicleBuilder = require(Shared.VehicleBuilder)

local TestTrack = require(script.Parent.TestTrack)

local VehicleService = {}

local vehiclesFolder: Folder
local vehicles: { [Player]: Model } = {}
local slots: { [Player]: number } = {}

local function freeSlot(): number
	local used = {}
	for _, slot in slots do
		used[slot] = true
	end
	local index = 1
	while used[index] do
		index += 1
	end
	return index
end

local function yawOnly(cf: CFrame): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(cf.Position, cf.Position + flat.Unit)
end

function VehicleService.getVehicle(player: Player): Model?
	return vehicles[player]
end

function VehicleService.spawn(player: Player, vehicleId: string, at: CFrame?)
	local old = vehicles[player]
	if old then
		vehicles[player] = nil
		old:Destroy()
	end

	local slot = slots[player]
	if not slot then
		slot = freeSlot()
		slots[player] = slot
	end
	local spawnCFrame = TestTrack.spawnCFrame(slot)
	local model = VehicleBuilder.build(vehicleId, player.UserId)
	local chassis = model.PrimaryPart :: BasePart
	model:SetAttribute("SpawnCFrame", spawnCFrame)

	-- Drop the car slightly above the ground so the suspension settles on spawn.
	local class = Config.Classes[Config.Vehicles[vehicleId].class]
	local lift = class.colliderSize[2] / 2 + class.wheelRadius + class.suspensionTravel + 0.5
	model:PivotTo((at or spawnCFrame) + Vector3.new(0, lift, 0))

	model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	model.Parent = vehiclesFolder
	model:AddPersistentPlayer(player)
	chassis:SetNetworkOwner(player)
	player.ReplicationFocus = chassis
	vehicles[player] = model
	player:SetAttribute("VehicleId", vehicleId)
	Net.fire("Vehicle.Spawned", player, vehicleId)
end

local function onPlayerAdded(player: Player)
	VehicleService.spawn(player, Config.DefaultVehicle)
end

local function onPlayerRemoving(player: Player)
	local model = vehicles[player]
	vehicles[player] = nil
	slots[player] = nil
	if model then
		model:Destroy()
	end
end

function VehicleService.init()
	vehiclesFolder = Instance.new("Folder")
	vehiclesFolder.Name = "Vehicles"
	vehiclesFolder.Parent = workspace

	Net.on("Vehicle.Equip", function(player: Player, vehicleId: string)
		if Config.Vehicles[vehicleId] == nil then
			return
		end
		-- Milestone 1 test track: every vehicle is free to try. Ownership checks arrive with saves (milestone 2).
		local current = vehicles[player]
		local at: CFrame? = nil
		if current and current.PrimaryPart then
			at = yawOnly(current.PrimaryPart.CFrame)
		end
		VehicleService.spawn(player, vehicleId, at)
	end)

	Net.on("Vehicle.Pose", function(player: Player, pose: buffer)
		if vehicles[player] == nil then
			return
		end
		Net.fireAllExcept("Vehicle.Pose", player, player.UserId, pose)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Watchdog: a car lost far below the world, or one whose owner changed, is put right.
	task.spawn(function()
		while true do
			task.wait(2)
			local snapshot = {}
			for player, model in vehicles do
				table.insert(snapshot, { player, model })
			end
			for _, entry in snapshot do
				local player, model = entry[1], entry[2]
				local chassis = model.PrimaryPart
				if chassis == nil or chassis.Parent == nil then
					continue
				end
				local y = chassis.Position.Y
				if y ~= y or y < Config.World.killY - 400 then
					VehicleService.spawn(player, model:GetAttribute("VehicleId") or Config.DefaultVehicle)
				elseif chassis:GetNetworkOwner() ~= player then
					chassis:SetNetworkOwner(player)
				end
			end
		end
	end)
end

return VehicleService
