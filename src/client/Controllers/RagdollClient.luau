-- RagdollClient: the 6-piece rider (spec: Rider ragdoll and bone breaks > Rig).
-- Every client builds its own local rider for every vehicle. Seated riders are anchored and follow the
-- car's Seat attachment each frame (hands follow the steering). Only the owner simulates their own rider
-- when it is thrown; everyone else sees it from the 6 transforms in Vehicle.Pose (10 Hz), interpolated
-- 100 ms behind. Riders are always thrown clear unharmed: cartoon only, no gore.
-- Bone breaks (Highway Havoc) are added on top of this rig in milestone 8.
--
-- PLACEHOLDER ART: block rider in the crash-suit colours until the rider model and outfits are made.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local PoseCodec = require(Shared.PoseCodec)
local Signal = require(Shared.Util.Signal)

local LocalPlayer = Players.LocalPlayer

local RagdollClient = {}

RagdollClient.Ejected = Signal.new()
RagdollClient.RespawnAvailable = Signal.new()
RagdollClient.Respawned = Signal.new()

local PIECES = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
local LIMB_JOINTS = {
	LeftArm = "shoulder",
	RightArm = "shoulder",
	LeftLeg = "hip",
	RightLeg = "hip",
	Head = "neck",
}

local controllers: any = nil
local folder: Folder
local riders: { [Model]: any } = {}
local localRider: any = nil
local random = Random.new()

---------------------------------------------------------------------------
-- Rig geometry (rider scale s, in seat space: seat point = hip height, centre of the seat)
---------------------------------------------------------------------------

local function sizes(s: number)
	return {
		Head = Vector3.new(1.3, 1.3, 1.3) * s,
		Torso = Vector3.new(2, 2, 1) * s,
		LeftArm = Vector3.new(0.8, 2, 0.8) * s,
		RightArm = Vector3.new(0.8, 2, 0.8) * s,
		LeftLeg = Vector3.new(0.9, 2, 0.9) * s,
		RightLeg = Vector3.new(0.9, 2, 0.9) * s,
	}
end

-- Joint positions in torso space
local function joints(s: number)
	return {
		Head = Vector3.new(0, 1, 0) * s,
		LeftArm = Vector3.new(-1.4, 0.8, 0) * s,
		RightArm = Vector3.new(1.4, 0.8, 0) * s,
		LeftLeg = Vector3.new(-0.5, -1, 0) * s,
		RightLeg = Vector3.new(0.5, -1, 0) * s,
	}
end

-- Seated pose relative to the Seat attachment. steer is -1..1.
local function seatedPose(s: number, steer: number): { [string]: CFrame }
	local torso = CFrame.new(0, 1 * s, 0)
	local j = joints(s)
	local armReach = math.rad(70)
	local thigh = math.rad(75)
	local steerTilt = steer * math.rad(14)
	return {
		Torso = torso,
		Head = torso * CFrame.new(j.Head) * CFrame.new(0, 0.65 * s, 0),
		LeftArm = torso
			* CFrame.new(j.LeftArm)
			* CFrame.Angles(armReach + steerTilt, 0, 0)
			* CFrame.new(0, -1 * s, 0),
		RightArm = torso
			* CFrame.new(j.RightArm)
			* CFrame.Angles(armReach - steerTilt, 0, 0)
			* CFrame.new(0, -1 * s, 0),
		LeftLeg = torso * CFrame.new(j.LeftLeg) * CFrame.Angles(thigh, 0, 0) * CFrame.new(0, -1 * s, 0),
		RightLeg = torso * CFrame.new(j.RightLeg) * CFrame.Angles(thigh, 0, 0) * CFrame.new(0, -1 * s, 0),
	}
end

local function axisAttachment(name: string, parent: BasePart, position: Vector3, primary: Vector3): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	-- Primary (X) axis along the limb; secondary (Y) axis forward-back so twist has a fixed reference
	attachment.CFrame = CFrame.fromMatrix(position, primary, Vector3.new(0, 0, 1))
	attachment.Parent = parent
	return attachment
end

local function buildRider(model: Model, isLocal: boolean)
	local chassis = model:WaitForChild("Chassis", 10) :: BasePart?
	if not chassis then
		return nil
	end
	local seat = chassis:WaitForChild("Seat", 10) :: Attachment?
	if not seat then
		return nil
	end
	local class = Config.Classes[model:GetAttribute("ClassId") or "Buggy"] or Config.Classes.Buggy
	local s = class.riderScale
	local size = sizes(s)
	local colors = Config.Rider.colors

	local rig = Instance.new("Model")
	rig.Name = "Rider_" .. tostring(model:GetAttribute("OwnerUserId"))

	local volume = 0
	for _, name in PIECES do
		local v = size[name]
		volume += v.X * v.Y * v.Z
	end
	local density = math.clamp(Config.Driving.baseMass * Config.Rider.massFractionOfSedan / volume, 0.01, 100)

	local parts: { [string]: BasePart } = {}
	for _, name in PIECES do
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size[name]
		if name == "Head" then
			part.Shape = Enum.PartType.Ball
			part.Color = colors.helmet and Config.color3(colors.helmet) or Color3.new(1, 1, 1)
			local face = Instance.new("Decal")
			face.Texture = "rbxasset://textures/face.png"
			face.Face = Enum.NormalId.Front
			face.Parent = part
		elseif name == "LeftLeg" or name == "RightLeg" then
			part.Color = Config.color3(colors.boots)
		else
			part.Color = Config.color3(colors.suit)
		end
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = true
		part.CollisionGroup = "Rider"
		part.CustomPhysicalProperties = PhysicalProperties.new(density, 0.6, 0.15)
		part.Parent = rig
		parts[name] = part
	end
	-- Stripe on the suit so the torso's spin reads
	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Size = Vector3.new(2.05, 0.35, 1.05) * s
	stripe.Color = Color3.fromRGB(255, 255, 255)
	stripe.Material = Enum.Material.SmoothPlastic
	stripe.CanCollide = false
	stripe.CanTouch = false
	stripe.CanQuery = false
	stripe.Massless = true
	stripe.Anchored = false
	stripe.Parent = rig
	local stripeWeld = Instance.new("WeldConstraint")
	stripe.CFrame = parts.Torso.CFrame
	stripeWeld.Part0 = parts.Torso
	stripeWeld.Part1 = stripe
	stripeWeld.Parent = stripe

	-- Ragdoll joints (disabled while seated)
	local constraints = {}
	local j = joints(s)
	for _, limb in { "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg" } do
		local jointType = LIMB_JOINTS[limb]
		local primary = if limb == "Head" then Vector3.yAxis else -Vector3.yAxis
		local a0 = axisAttachment(limb .. "Joint0", parts.Torso, j[limb], primary)
		local limbLocal = if limb == "Head" then Vector3.new(0, -0.65 * s, 0) else Vector3.new(0, 1 * s, 0)
		local a1 = axisAttachment(limb .. "Joint1", parts[limb], limbLocal, primary)
		local socket = Instance.new("BallSocketConstraint")
		socket.Name = limb .. "Socket"
		socket.Attachment0 = a0
		socket.Attachment1 = a1
		socket.LimitsEnabled = true
		socket.UpperAngle = Config.Rider.jointCone[jointType]
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = -Config.Rider.jointTwist[jointType]
		socket.TwistUpperAngle = Config.Rider.jointTwist[jointType]
		socket.Restitution = 0
		socket.MaxFrictionTorque = 4
		socket.Enabled = false
		socket.Parent = parts.Torso
		table.insert(constraints, socket)
		-- Neighbouring pieces never collide with the torso
		local noCollide = Instance.new("NoCollisionConstraint")
		noCollide.Part0 = parts.Torso
		noCollide.Part1 = parts[limb]
		noCollide.Parent = parts.Torso
	end

	rig.Parent = folder

	return {
		model = model,
		chassis = chassis,
		seat = seat,
		rig = rig,
		parts = parts,
		scale = s,
		constraints = constraints,
		isLocal = isLocal,
		state = "seated",
		ragdollTime = 0,
		respawnOffered = false,
		fading = false,
		noCollides = {},
		snapshots = {},
		remoteRagdollUntil = 0,
		steer = 0,
	}
end

local function setTransparency(rider, value: number)
	for _, part in rider.parts do
		part.LocalTransparencyModifier = value
	end
	local stripe = rider.rig:FindFirstChild("Stripe")
	if stripe then
		stripe.LocalTransparencyModifier = value
	end
end

local function placeSeated(rider, steer: number)
	local seatCFrame = rider.seat.WorldCFrame
	local pose = seatedPose(rider.scale, steer)
	for name, part in rider.parts do
		part.CFrame = seatCFrame * pose[name]
	end
end

local function setPhysical(rider, physical: boolean)
	for _, part in rider.parts do
		part.Anchored = not physical
		part.CanCollide = physical
	end
	for _, socket in rider.constraints do
		socket.Enabled = physical
	end
end

---------------------------------------------------------------------------
-- Local rider: eject, flail, respawn
---------------------------------------------------------------------------

-- extraUp adds an upward kick (an explosion throws the rider clear upward, unharmed)
function RagdollClient.eject(vehicleVelocity: Vector3, extraUp: number?)
	local rider = localRider
	if not rider or rider.state ~= "seated" then
		return
	end
	rider.state = "ragdoll"
	rider.ragdollTime = 0
	rider.respawnOffered = false
	rider.fading = false
	controllers.Input.consume("flail")
	controllers.Input.consume("respawn")

	-- No collision with our own car for a moment so the rider clears it
	for _, part in rider.parts do
		local noCollide = Instance.new("NoCollisionConstraint")
		noCollide.Part0 = part
		noCollide.Part1 = rider.chassis
		noCollide.Parent = part
		table.insert(rider.noCollides, noCollide)
	end
	task.delay(Config.Rider.ownCarNoCollideTime, function()
		for _, noCollide in rider.noCollides do
			noCollide:Destroy()
		end
		table.clear(rider.noCollides)
	end)

	setPhysical(rider, true)
	local velocity = vehicleVelocity * Config.Rider.ejectVelocityFactor
		+ Vector3.new(0, Config.Rider.ejectUpSpeed + (extraUp or 0), 0)
	for _, part in rider.parts do
		part.AssemblyLinearVelocity = velocity
		part.AssemblyAngularVelocity = random:NextUnitVector() * random:NextNumber(2, 6)
	end
	RagdollClient.Ejected:Fire()
end

local function flail(rider)
	local limbs = { "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Head" }
	local part = rider.parts[limbs[random:NextInteger(1, #limbs)]]
	part:ApplyImpulse(random:NextUnitVector() * Config.Rider.flailImpulse * part.AssemblyMass)
end

function RagdollClient.respawn()
	local rider = localRider
	if not rider or rider.state ~= "ragdoll" then
		return
	end
	rider.state = "seated"
	setPhysical(rider, false)
	setTransparency(rider, 0)
	controllers.Vehicle.respawnDriver()
	RagdollClient.Respawned:Fire()
end

function RagdollClient.flail()
	if localRider and localRider.state == "ragdoll" then
		flail(localRider)
	end
end

function RagdollClient.isRagdolled(): boolean
	return localRider ~= nil and localRider.state == "ragdoll"
end

function RagdollClient.canRespawn(): boolean
	return RagdollClient.isRagdolled() and localRider.ragdollTime >= Config.Rider.respawnButtonAfter
end

function RagdollClient.getFocusPart(): BasePart?
	if localRider and localRider.state == "ragdoll" then
		return localRider.parts.Torso
	end
	return nil
end

-- 6 transforms in spec order for Vehicle.Pose
function RagdollClient.getPoseTransforms(): { { number } }?
	if not RagdollClient.isRagdolled() then
		return nil
	end
	local list = {}
	for index, name in PIECES do
		list[index] = PoseCodec.fromCFrame(localRider.parts[name].CFrame)
	end
	return list
end

---------------------------------------------------------------------------
-- Remote riders
---------------------------------------------------------------------------

function RagdollClient.applyRemotePose(model: Model, pose)
	local rider = riders[model]
	if not rider or rider.isLocal then
		return
	end
	rider.steer = pose.steer
	if pose.rider then
		local transforms = {}
		for index, t in pose.rider do
			transforms[index] = PoseCodec.toCFrame(t)
		end
		table.insert(rider.snapshots, { time = os.clock(), transforms = transforms })
		if #rider.snapshots > 8 then
			table.remove(rider.snapshots, 1)
		end
		rider.remoteRagdollUntil = os.clock() + 0.5
	else
		rider.remoteRagdollUntil = 0
		table.clear(rider.snapshots)
	end
end

local function renderRemoteRagdoll(rider)
	local snapshots = rider.snapshots
	if #snapshots == 0 then
		return
	end
	local renderTime = os.clock() - Config.Rider.interpolationDelay
	local a, b = snapshots[1], snapshots[#snapshots]
	for i = 1, #snapshots - 1 do
		if snapshots[i].time <= renderTime and snapshots[i + 1].time >= renderTime then
			a, b = snapshots[i], snapshots[i + 1]
			break
		end
	end
	local alpha = 1
	if b.time > a.time then
		alpha = math.clamp((renderTime - a.time) / (b.time - a.time), 0, 1)
	end
	for index, name in PIECES do
		rider.parts[name].CFrame = a.transforms[index]:Lerp(b.transforms[index], alpha)
	end
end

---------------------------------------------------------------------------
-- Frame update
---------------------------------------------------------------------------

-- The crash replay pauses the rider's timers and flailing while it plays the crash back
local frozen = false

function RagdollClient.setFrozen(value: boolean)
	frozen = value
end

-- The local rider's 6 parts (for the crash replay's recording), or nil
function RagdollClient.getLocalParts(): { [string]: BasePart }?
	return if localRider then localRider.parts else nil
end

local function render(dt: number)
	for _, rider in riders do
		if rider.chassis.Parent == nil or rider.seat.Parent == nil then
			continue
		end
		if rider.isLocal then
			if rider.state == "seated" then
				local vehicleState = controllers.Vehicle.getState()
				local steer = 0
				if vehicleState then
					steer = vehicleState.steerAngle / math.rad(Config.Driving.maxSteerAtZero)
				end
				placeSeated(rider, steer)
			elseif not frozen then
				rider.ragdollTime += dt
				if controllers.Input.consume("flail") then
					flail(rider)
				end
				if rider.ragdollTime >= Config.Rider.respawnButtonAfter and not rider.respawnOffered then
					rider.respawnOffered = true
					RagdollClient.RespawnAvailable:Fire()
				end
				if rider.respawnOffered and controllers.Input.consume("respawn") then
					RagdollClient.respawn()
				elseif rider.ragdollTime >= Config.Rider.lifetime then
					local fade =
						math.clamp((rider.ragdollTime - Config.Rider.lifetime) / Config.Rider.fadeTime, 0, 1)
					setTransparency(rider, fade)
					if fade >= 1 then
						RagdollClient.respawn()
					end
				end
			end
		else
			if os.clock() < rider.remoteRagdollUntil then
				renderRemoteRagdoll(rider)
			else
				placeSeated(rider, rider.steer)
			end
		end
	end
end

local function addVehicle(model: Instance)
	if not model:IsA("Model") or riders[model] then
		return
	end
	local isLocal = model:GetAttribute("OwnerUserId") == LocalPlayer.UserId
	task.spawn(function()
		local rider = buildRider(model, isLocal)
		if not rider then
			return
		end
		if model.Parent == nil then
			rider.rig:Destroy()
			return
		end
		riders[model] = rider
		if isLocal then
			localRider = rider
		end
	end)
end

local function removeVehicle(model: Instance)
	local rider = riders[model :: Model]
	if rider then
		riders[model :: Model] = nil
		rider.rig:Destroy()
		if localRider == rider then
			localRider = nil
		end
	end
end

function RagdollClient.init(all)
	controllers = all
	folder = Instance.new("Folder")
	folder.Name = "LocalRiders"
	folder.Parent = workspace
end

function RagdollClient.start()
	local vehicles = workspace:WaitForChild("Vehicles")
	vehicles.ChildAdded:Connect(addVehicle)
	vehicles.ChildRemoved:Connect(removeVehicle)
	for _, model in vehicles:GetChildren() do
		addVehicle(model)
	end
	RunService.RenderStepped:Connect(render)
end

return RagdollClient
