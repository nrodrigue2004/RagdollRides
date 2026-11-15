-- VehicleService: spawns each player's vehicle, hands its physics to the player, and relays poses.
-- The server never simulates a player's car: the driver's device owns it (spec: Network model).
-- Players have no avatar character in this game; the camera and streaming follow the car.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Looks = require(Shared.Looks)
local VehicleBuilder = require(Shared.VehicleBuilder)

local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.DataService)
local TestTrack = require(script.Parent.TestTrack)

local VehicleService = {}

VehicleService.Spawned = Signal.new() -- (player, model)
VehicleService.DamageChanged = Signal.new() -- (player, state buffer): the owner sent a new Damage.State

-- Where a player's car goes when it spawns with no position given (TracksService sets it: the start of
-- the player's current map). nil = the test track's spawn row.
VehicleService.homeFor = nil :: ((Player) -> CFrame?)?
-- Called when a player joins instead of spawning a car on the test track (TracksService sets it)
VehicleService.onJoin = nil :: ((Player) -> ())?
-- A player's collision group when it is not the mode's default (RaceService: racers bump each other)
VehicleService.collisionGroupFor = nil :: ((Player) -> string?)?
-- True while a player may not swap cars (RaceService: during a race)
VehicleService.equipLocked = nil :: ((Player) -> boolean)?

local vehiclesFolder: Folder
local vehicles: { [Player]: Model } = {}
local slots: { [Player]: number } = {}
-- Last Damage.State per player (10 bytes). Later modes read it (Brawl KOs, Highway wrecks).
local damageStates: { [Player]: buffer } = {}

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

function VehicleService.getDamageState(player: Player): buffer?
	return damageStates[player]
end

function VehicleService.spawn(player: Player, vehicleId: string, at: CFrame?)
	local old = vehicles[player]
	if old then
		vehicles[player] = nil
		old:Destroy()
	end
	damageStates[player] = nil -- a new car is a clean car

	local slot = slots[player]
	if not slot then
		slot = freeSlot()
		slots[player] = slot
	end
	local home = if at == nil and VehicleService.homeFor then VehicleService.homeFor(player) else nil
	local spawnCFrame = at or home or TestTrack.spawnCFrame(slot)
	local model = VehicleBuilder.build(vehicleId, player.UserId)
	VehicleService.applyLooks(player, model)
	local chassis = model.PrimaryPart :: BasePart
	-- The first respawn point: where the car was put down (the map's start in Tracks)
	model:SetAttribute("SpawnCFrame", yawOnly(spawnCFrame))
	-- Tracks free runs: other players' cars pass through each other (spec: Tracks > ghosts)
	local mode = workspace:GetAttribute("Mode")
	local group = VehicleService.collisionGroupFor and VehicleService.collisionGroupFor(player)
	if group then
		chassis.CollisionGroup = group
	elseif mode == "Tracks" then
		chassis.CollisionGroup = "Ghost"
	end

	-- Drop the car slightly above the ground so the suspension settles on spawn.
	local class = Config.Classes[Config.Vehicles[vehicleId].class]
	local lift = class.colliderSize[2] / 2 + class.wheelRadius + class.suspensionTravel + 0.5
	model:PivotTo(spawnCFrame + Vector3.new(0, lift, 0))

	model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	model.Parent = vehiclesFolder
	model:AddPersistentPlayer(player)
	chassis:SetNetworkOwner(player)
	player.ReplicationFocus = chassis
	vehicles[player] = model
	player:SetAttribute("VehicleId", vehicleId)
	Net.fire("Vehicle.Spawned", player, vehicleId)
	VehicleService.Spawned:Fire(player, model)
end

-- The player's cosmetics on their car (and the rider's outfit and hat, which every client builds)
function VehicleService.applyLooks(player: Player, model: Model?)
	model = model or vehicles[player]
	if model == nil then
		return
	end
	local profile = DataService.get(player)
	local vehicleId = model:GetAttribute("VehicleId")
	local entry = profile and vehicleId and profile.vehicles[vehicleId]
	Looks.vehicle(model, Looks.fromProfile(entry))
	model:SetAttribute("RiderOutfit", profile and profile.rider.outfit or nil)
	model:SetAttribute("RiderHat", profile and profile.rider.hat or nil)
end

-- Vehicles a player may drive: the ones they own; Studio and admins may try every vehicle
function VehicleService.mayDrive(player: Player, vehicleId: string): boolean
	if Config.Vehicles[vehicleId] == nil then
		return false
	end
	if DataService.isAdmin(player) then
		return true
	end
	local profile = DataService.get(player)
	local entry = profile and profile.vehicles[vehicleId]
	return entry ~= nil and entry.owned == true
end

local function onPlayerAdded(player: Player)
	if VehicleService.onJoin then
		VehicleService.onJoin(player)
	else
		VehicleService.spawn(player, Config.DefaultVehicle)
	end
end

local function onPlayerRemoving(player: Player)
	local model = vehicles[player]
	vehicles[player] = nil
	slots[player] = nil
	damageStates[player] = nil
	if model then
		model:Destroy()
	end
end

function VehicleService.init()
	vehiclesFolder = Instance.new("Folder")
	vehiclesFolder.Name = "Vehicles"
	vehiclesFolder.Parent = workspace

	Net.on("Vehicle.Equip", function(player: Player, vehicleId: string)
		if not VehicleService.mayDrive(player, vehicleId) then
			return
		end
		if VehicleService.equipLocked and VehicleService.equipLocked(player) then
			Net.fire("Notice", player, "equipLocked")
			return
		end
		local profile = DataService.get(player)
		if profile and profile.vehicles[vehicleId] and profile.vehicles[vehicleId].owned then
			profile.equippedVehicle = vehicleId
			DataService.changed(player)
		end
		-- On a map the new car starts at the map's start (the run starts over); on the test track it
		-- appears where the old one was.
		local current = vehicles[player]
		local at: CFrame? = nil
		if VehicleService.homeFor == nil or VehicleService.homeFor(player) == nil then
			if current and current.PrimaryPart then
				at = yawOnly(current.PrimaryPart.CFrame)
			end
		end
		VehicleService.spawn(player, vehicleId, at)
	end)

	Net.on("Vehicle.Pose", function(player: Player, pose: buffer)
		if vehicles[player] == nil then
			return
		end
		Net.fireAllExcept("Vehicle.Pose", player, player.UserId, pose)
	end)

	-- Damage: the owner's device computes it; the server keeps the latest and relays it to everyone else.
	-- (Owners resend every 3 s while damaged, which also covers players who join or stream in later.)
	Net.on("Damage.State", function(player: Player, state: buffer)
		if vehicles[player] == nil then
			return
		end
		damageStates[player] = state
		Net.fireAllExcept("Damage.State", player, player.UserId, state)
		VehicleService.DamageChanged:Fire(player, state)
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
