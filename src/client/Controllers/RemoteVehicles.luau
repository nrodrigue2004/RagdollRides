-- RemoteVehicles: shows other players' cars from their Vehicle.Pose stream (10 Hz).
-- The car body itself moves by Roblox's own replication of the owner's physics; this module only adds what
-- replication cannot carry: suspension travel, steering, wheel spin, skid marks and the rider's pose.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local PoseCodec = require(Shared.PoseCodec)
local VehicleBuilder = require(Shared.VehicleBuilder)

local LocalPlayer = Players.LocalPlayer

local RemoteVehicles = {}

local controllers: any = nil
local remotes: { [Model]: any } = {}

local function track(model: Instance)
	if not model:IsA("Model") or remotes[model] then
		return
	end
	if model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		return
	end
	task.spawn(function()
		local chassis = model:WaitForChild("Chassis", 10) :: BasePart?
		if not chassis or model.Parent == nil then
			return
		end
		local class = Config.Classes[model:GetAttribute("ClassId") or "Buggy"] or Config.Classes.Buggy
		local wheels = {}
		for index, mount in VehicleBuilder.mountOffsets(class) do
			local name = VehicleBuilder.WHEEL_NAMES[index]
			local motor = chassis:WaitForChild("WheelMotor_" .. name, 10) :: Motor6D?
			if not motor then
				return
			end
			table.insert(wheels, {
				mount = mount,
				motor = motor,
				steered = index <= 2,
				rear = index >= 3,
				compression = 0.3 * class.suspensionTravel,
				targetCompression = 0.3 * class.suspensionTravel,
				spin = 0,
				grounded = true,
				contact = Vector3.zero,
				lateralSlip = 0,
				material = Enum.Material.Plastic,
			})
		end
		remotes[model] = {
			model = model,
			chassis = chassis,
			class = class,
			wheels = wheels,
			steer = 0,
			targetSteer = 0,
			flags = 0,
			effects = controllers.SurfaceEffects.attach(model, class),
		}
	end)
end

local function untrack(model: Instance)
	local remote = remotes[model :: Model]
	if remote then
		remotes[model :: Model] = nil
		if remote.effects then
			remote.effects:Destroy()
		end
	end
end

local function onPose(userId: number, data: buffer)
	if type(userId) ~= "number" or type(data) ~= "buffer" then
		return
	end
	local folder = workspace:FindFirstChild("Vehicles")
	local model = folder and folder:FindFirstChild("Vehicle_" .. userId)
	if not model then
		return
	end
	local pose = PoseCodec.decode(data)
	if not pose then
		return
	end
	local remote = remotes[model]
	if remote then
		remote.targetSteer = pose.steer * math.rad(Config.Driving.maxSteerAtZero)
		remote.flags = pose.flags
		for index, wheel in remote.wheels do
			wheel.targetCompression = pose.compression[index] * remote.class.suspensionTravel
		end
	end
	if controllers.Ragdoll then
		controllers.Ragdoll.applyRemotePose(model, pose)
	end
end

local function render(dt: number)
	local blend = 1 - math.exp(-dt / 0.08)
	for _, remote in remotes do
		local chassis = remote.chassis
		if chassis.Parent == nil then
			continue
		end
		local class = remote.class
		local cf = chassis.CFrame
		local forwardSpeed = chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
		local airborne = bit32.band(remote.flags, PoseCodec.FLAG_AIRBORNE) ~= 0
		local skidding = bit32.band(remote.flags, PoseCodec.FLAG_SKIDDING) ~= 0
		remote.steer += (remote.targetSteer - remote.steer) * blend
		for _, w in remote.wheels do
			w.compression += (w.targetCompression - w.compression) * blend
			local extension = class.suspensionTravel - w.compression
			w.spin = (w.spin - forwardSpeed / class.wheelRadius * dt) % (math.pi * 2)
			local steer = if w.steered then remote.steer else 0
			w.motor.Transform = CFrame.new(0, -extension, 0)
				* CFrame.Angles(0, -steer, 0)
				* CFrame.Angles(w.spin, 0, 0)
			w.grounded = not airborne
			w.contact = cf:PointToWorldSpace(w.mount - Vector3.new(0, extension + class.wheelRadius, 0))
			w.lateralSlip = if skidding and w.rear then Config.Surface.skidSlipSpeed + 1 else 0
		end
		if remote.effects then
			remote.effects:update(dt, remote.wheels, forwardSpeed, if airborne then 0 else 4)
		end
	end
end

function RemoteVehicles.init(all)
	controllers = all
end

function RemoteVehicles.start()
	local folder = workspace:WaitForChild("Vehicles")
	folder.ChildAdded:Connect(track)
	folder.ChildRemoved:Connect(untrack)
	for _, model in folder:GetChildren() do
		track(model)
	end
	Net.listen("Vehicle.Pose", onPose)
	RunService.RenderStepped:Connect(render)
end

return RemoteVehicles
