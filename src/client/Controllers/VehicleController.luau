-- VehicleController: drives the local player's vehicle (spec: Vehicle physics).
-- Raycast suspension, tyre forces, engine curve, brakes, steering, arcade assists, air control, hop,
-- flip and reset all run here, on the owner's device, once per frame before physics (PreSimulation).
-- The server owns nothing about the car's movement; it only spawned it and gave us network ownership.
--
-- After physics (PostSimulation) the controller compares the car's velocity change with the forces it
-- applied: whatever is left over came from a collision. That gives the spec's Impact value
-- (closing speed x mass factor), the crash tier and which side was hit.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Damage = require(Shared.Damage)
local Net = require(Shared.Net)
local PoseCodec = require(Shared.PoseCodec)
local Signal = require(Shared.Util.Signal)
local VehicleBuilder = require(Shared.VehicleBuilder)
local VehicleMath = require(Shared.VehicleMath)

local LocalPlayer = Players.LocalPlayer

local VehicleController = {}

VehicleController.Impact = Signal.new() -- (info) see ImpactInfo
VehicleController.Landed = Signal.new() -- (fallSpeed)
VehicleController.Spawned = Signal.new() -- (model)
VehicleController.Respawned = Signal.new() -- ()
VehicleController.Hopped = Signal.new() -- ()
VehicleController.CheckpointReached = Signal.new() -- (index, part)
VehicleController.Touched = Signal.new() -- (part) a non-colliding trigger the car touched (Finish, ...)
VehicleController.HazardHit = Signal.new() -- () a hazard threw the rider

export type ImpactInfo = {
	impact: number,
	tier: string,
	side: string,
	closingSpeed: number,
	point: Vector3,
	other: BasePart?,
}

type Wheel = {
	name: string,
	mount: Vector3,
	motor: Motor6D,
	steered: boolean,
	driven: boolean,
	rear: boolean,
	compression: number,
	overshoot: number,
	grounded: boolean,
	load: number,
	spring: number,
	contact: Vector3,
	normal: Vector3,
	material: Enum.Material,
	lateralSlip: number,
	spin: number,
	visualExtension: number,
}

type Sequence = {
	kind: string,
	t: number,
	duration: number,
	from: CFrame,
	to: CFrame,
	swapped: boolean,
	script: ((number) -> CFrame?)?,
	onFinish: (() -> ())?,
}

local controllers: any = nil
local state: any = nil -- the current vehicle's state, or nil
-- The newest car of ours to appear: a slower set-up of an older car (it waits for its parts) must not
-- take over from it
local latestModel: Model? = nil
local settings = { steerAssist = "High" } -- ProfileClient applies the saved setting (and maps can force High)
local killY = Config.World.killY -- TracksClient sets each map's own (a little under its lowest road)
local ZERO_INPUT = { throttle = 0, brake = 0, steer = 0, lean = 0, handbrake = false, analogSteer = false }
-- While the rider is thrown: nil (the car coasts) or a driver (Highway: the car keeps its lane)
local autopilot: ((number) -> any)? = nil
-- A mode's anti-roll multiplier (Highway rides: the car stays flat through lane changes at speed)
local rollAssist = 1
-- Damage effects on handling (DamageController sets these from the zone numbers; spec: Damage zones)
local CLEAN_HANDLING = {
	topSpeed = 1,
	drive = 1,
	engineDead = false,
	steerPull = 0,
	grip = { 1, 1, 1, 1 },
	lost = { false, false, false, false },
	smoke = 0,
}
local renderFrozenUntil = 0

local function rotateAround(v: Vector3, axis: Vector3, angle: number): Vector3
	return CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(v)
end

local function yawOnly(cf: CFrame): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(cf.Position, cf.Position + flat.Unit)
end

local function mode(): string
	return workspace:GetAttribute("Mode") or "TestTrack"
end

local function rideHeight(s): number
	-- Height of the chassis centre above the ground when settled
	local class = s.class
	local sag = workspace.Gravity / (2 * math.pi * class.springFrequency) ^ 2
	return -class.mountY + (class.suspensionTravel - sag) + class.wheelRadius
end

local function applyInertia(s, alpha: Vector3): Vector3
	-- Torque = R * (I . (R^T * alpha)) for the chassis box
	local cf = s.chassis.CFrame
	local localAlpha = cf:VectorToObjectSpace(alpha)
	local i = s.inertia
	return cf:VectorToWorldSpace(Vector3.new(localAlpha.X * i.X, localAlpha.Y * i.Y, localAlpha.Z * i.Z))
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function teardown()
	if state then
		for _, connection in state.connections do
			connection:Disconnect()
		end
		if state.vectorForce then
			state.vectorForce:Destroy()
		end
		if state.torque then
			state.torque:Destroy()
		end
		if state.effects then
			state.effects:Destroy()
		end
	end
	state = nil
end

local function onTouched(s, hit: BasePart)
	if hit:IsDescendantOf(s.model) then
		return
	end
	if CollectionService:HasTag(hit, "Checkpoint") then
		local index = hit:GetAttribute("Index") or 0
		local offset = hit:GetAttribute("GroundOffset") or 0
		local cf = yawOnly(hit.CFrame) - Vector3.new(0, offset, 0)
		if s.checkpointIndex ~= index then
			s.checkpointIndex = index
			VehicleController.CheckpointReached:Fire(index, hit)
		end
		s.checkpoint = cf
		return
	end
	if CollectionService:HasTag(hit, "Hazard") then
		VehicleController.hazardHit(hit:GetAttribute("RespawnCFrame") :: CFrame?)
		return
	end
	local now = os.clock()
	if CollectionService:HasTag(hit, "Bouncer") then
		if now - (s.padTimes[hit] or 0) > 0.5 then
			s.padTimes[hit] = now
			local v = s.chassis.AssemblyLinearVelocity
			local newV = Vector3.new(v.X, math.max(v.Y, Config.Pads.bouncerUpSpeed), v.Z)
			s.chassis.AssemblyLinearVelocity = newV
			s.scriptedDeltaV += newV - v
		end
		return
	elseif CollectionService:HasTag(hit, "SpeedPad") then
		if now - (s.padTimes[hit] or 0) > 1.0 then
			s.padTimes[hit] = now
			local boost = hit.CFrame.LookVector * Config.Pads.speedPadBoost
			s.chassis.AssemblyLinearVelocity += boost
			s.scriptedDeltaV += boost
		end
		return
	end
	if hit.CanCollide then
		s.recentTouch = hit
		s.recentTouchTime = now
	else
		VehicleController.Touched:Fire(hit)
	end
end

local function setup(model: Model)
	teardown()
	local chassis = model:WaitForChild("Chassis", 10) :: BasePart
	if not chassis then
		return
	end
	local vehicleId = model:GetAttribute("VehicleId")
	local def = Config.Vehicles[vehicleId]
	local class = Config.Classes[def.class]
	local mass = VehicleBuilder.chassisMass(class)
	local cornerMass = mass / 4
	local k, c = VehicleMath.springCoefficients(cornerMass, class.springFrequency, class.dampingRatio)
	local size = chassis.Size
	local ix, iy, iz = VehicleMath.boxInertia(mass, size.X, size.Y, size.Z)

	local s = {
		model = model,
		chassis = chassis,
		def = def,
		class = class,
		mass = mass,
		cornerMass = cornerMass,
		k = k,
		c = c,
		inertia = Vector3.new(ix, iy, iz),
		amplification = 1,
		a0 = VehicleMath.baseAcceleration(
			class.topSpeed,
			class.timeToTop,
			Config.Driving.torqueFlatFraction,
			Config.Driving.topSpeedReachFraction
		),
		wheelbase = math.abs(class.rearAxleZ - class.frontAxleZ),
		wheels = {} :: { Wheel },
		connections = {},
		lastVelocity = chassis.AssemblyLinearVelocity,
		lastForce = Vector3.zero,
		scriptedDeltaV = Vector3.zero,
		skipImpactFrames = 2,
		pairTimes = {},
		padTimes = {},
		recentTouch = nil,
		recentTouchTime = 0,
		steerAngle = 0,
		input = ZERO_INPUT,
		groundedCount = 0,
		groundNormal = Vector3.yAxis,
		airTime = 0,
		maxFallSpeed = 0,
		tiltedTime = 0,
		flipAvailable = false,
		hopTimer = 0,
		sequence = nil :: Sequence?,
		driverPresent = true,
		handling = CLEAN_HANDLING,
		checkpoint = yawOnly((model:GetAttribute("SpawnCFrame") :: CFrame?) or chassis.CFrame),
		checkpointIndex = 0,
		poseTimer = 0,
		forwardSpeed = 0,
		decel = 0,
		lastForwardSpeed = 0,
	}

	for index, mount in VehicleBuilder.mountOffsets(class) do
		local name = VehicleBuilder.WHEEL_NAMES[index]
		local rear = index >= 3
		table.insert(s.wheels, {
			name = name,
			mount = mount,
			motor = chassis:WaitForChild("WheelMotor_" .. name) :: Motor6D,
			steered = not rear,
			driven = class.drive == "all" or rear,
			rear = rear,
			compression = 0,
			overshoot = 0,
			grounded = false,
			load = 0,
			spring = 0,
			contact = Vector3.zero,
			normal = Vector3.yAxis,
			material = Enum.Material.Plastic,
			lateralSlip = 0,
			deltaV = 0,
			spin = 0,
			visualExtension = class.suspensionTravel,
			index = index,
			lost = false,
			axleDrag = false,
		})
	end
	do
		local xs, zs = {}, {}
		for i, w in s.wheels do
			xs[i], zs[i] = w.mount.X, w.mount.Z
		end
		s.amplification = VehicleMath.cornerAmplification(
			xs,
			zs,
			mass,
			iz / Config.Driving.springRollFactor,
			ix / Config.Driving.springPitchFactor
		)
	end

	local center = chassis:WaitForChild("Center") :: Attachment
	if latestModel ~= model or model.Parent == nil then
		return
	end
	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "DriveForce"
	vectorForce.Attachment0 = center
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.ApplyAtCenterOfMass = true
	vectorForce.Force = Vector3.zero
	vectorForce.Parent = chassis
	s.vectorForce = vectorForce

	local torque = Instance.new("Torque")
	torque.Name = "DriveTorque"
	torque.Attachment0 = center
	torque.RelativeTo = Enum.ActuatorRelativeTo.World
	torque.Torque = Vector3.zero
	torque.Parent = chassis
	s.torque = torque

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local ignore = { model }
	local riders = workspace:FindFirstChild("LocalRiders")
	if riders then
		table.insert(ignore, riders)
	end
	local debris = workspace:FindFirstChild("LocalDebris")
	if debris then
		table.insert(ignore, debris)
	end
	params.FilterDescendantsInstances = ignore
	-- Wheels see what the chassis would hit: in Tracks other cars are ghosts, so wheels pass through them
	params.CollisionGroup = chassis.CollisionGroup
	s.params = params

	table.insert(
		s.connections,
		chassis.Touched:Connect(function(hit)
			onTouched(s, hit)
		end)
	)

	if controllers.SurfaceEffects then
		s.effects = controllers.SurfaceEffects.attach(model, class)
	end

	state = s
	VehicleController.Spawned:Fire(model)
end

---------------------------------------------------------------------------
-- Physics step (before the physics engine runs)
---------------------------------------------------------------------------

local function runSequence(s, dt: number)
	local seq = s.sequence :: Sequence
	seq.t += dt
	local alpha = math.clamp(seq.t / seq.duration, 0, 1)
	if seq.kind == "script" then
		-- A scripted hold (the crash replay): the script places the car each frame until it returns nil
		local cf = (seq.script :: (number) -> CFrame?)(dt)
		if cf == nil then
			s.sequence = nil
			s.skipImpactFrames = 3
			s.lastForce = Vector3.zero
			if seq.onFinish then
				seq.onFinish()
			end
			s.lastVelocity = s.chassis.AssemblyLinearVelocity
			return
		end
		s.model:PivotTo(cf)
		alpha = 0
	elseif seq.kind == "flip" then
		local eased = alpha * alpha * (3 - 2 * alpha)
		s.model:PivotTo(seq.from:Lerp(seq.to, eased))
	elseif seq.kind == "reset" and not seq.swapped and seq.t >= seq.duration / 2 then
		seq.swapped = true
		s.model:PivotTo(seq.to)
		VehicleController.Respawned:Fire()
	end
	s.chassis.AssemblyLinearVelocity = Vector3.zero
	s.chassis.AssemblyAngularVelocity = Vector3.zero
	s.vectorForce.Force = Vector3.zero
	s.torque.Torque = Vector3.zero
	s.lastForce = Vector3.zero
	s.skipImpactFrames = 3
	if alpha >= 1 then
		s.sequence = nil
		s.tiltedTime = 0
		s.flipAvailable = false
		s.airTime = 0
	end
end

local function step(dt: number)
	local s = state
	if not s or not s.chassis.Parent then
		return
	end
	dt = math.clamp(dt, 1 / 240, Config.Driving.maxStep)
	local drive = Config.Driving
	local chassis = s.chassis
	local class = s.class

	if s.sequence then
		runSequence(s, dt)
		return
	end

	local input = if s.driverPresent
		then controllers.Input.read(dt)
		else (autopilot and autopilot(dt) or ZERO_INPUT)
	s.input = input

	local cf = chassis.CFrame
	local up, look, right = cf.UpVector, cf.LookVector, cf.RightVector
	local com = chassis.AssemblyCenterOfMass
	local velocity = chassis.AssemblyLinearVelocity
	local angular = chassis.AssemblyAngularVelocity
	local mass = s.mass
	local cornerMass = s.cornerMass
	local gravity = workspace.Gravity
	local forwardSpeed = velocity:Dot(look)
	local speedFraction = math.clamp(math.abs(forwardSpeed) / class.topSpeed, 0, 1)
	s.forwardSpeed = forwardSpeed

	-- Step-size guards: the explicit spring and tyre forces must not overshoot in one frame at low fps.
	-- (The damper is an exponential velocity change, stable at any frame rate.)
	-- Roll and pitch move a corner more than heave does (s.amplification), so the guard allows for it.
	local springLimit = cornerMass / s.amplification * (1.6 / dt) ^ 2
	local suspension: VehicleMath.SuspensionParams = {
		k = math.min(s.k, springLimit),
		c = s.c,
		bumpK = math.min(s.k * drive.bumpStopStiffnessMultiplier, springLimit),
		bumpDampingMultiplier = drive.bumpStopDampingMultiplier,
		cornerMass = cornerMass,
		travel = class.suspensionTravel,
		radius = class.wheelRadius,
		progressiveSpeed = drive.progressiveDampingSpeed,
		reboundMultiplier = drive.reboundDampingMultiplier,
	}
	-- Sideways grip takes at most half the slip in one frame (roll and yaw make a corner react up to about
	-- 1.6x more than a quarter of the mass would)
	local lateralStiffness = cornerMass * math.min(drive.lateralStiffness, 0.5 / dt)
	local maxGripLoad = cornerMass * gravity * drive.maxGripLoadG

	-- Suspension rays (one frame of lookahead so fast drops are caught before the belly hits)
	local reach = class.suspensionTravel + class.wheelRadius
	local grounded = 0
	local drivenGrounded = 0
	local normalSum = Vector3.zero
	local dampingImpulse = Vector3.zero
	local damped: { any } = {}
	local handling = s.handling
	for _, w in s.wheels do
		local mountWorld = cf:PointToWorldSpace(w.mount)
		w.lost = handling.lost[w.index] == true
		if w.lost then
			-- No wheel: no suspension. The bare axle drags if that corner is on the ground.
			local axle = workspace:Raycast(mountWorld, -up * (class.wheelRadius * 0.6 + 0.3), s.params)
			w.axleDrag = axle ~= nil
			if axle then
				w.contact = axle.Position
				w.normal = axle.Normal
			end
			w.compression, w.overshoot, w.spring, w.load = 0, 0, 0, 0
			w.grounded = false
			w.lateralSlip = 0
			continue
		end
		w.axleDrag = false
		local compressionSpeed = -chassis:GetVelocityAtPosition(mountWorld):Dot(up)
		local lookahead = math.max(0, compressionSpeed) * dt
		local result = workspace:Raycast(mountWorld, -up * (reach + lookahead), s.params)
		local spring, deltaV, touching, compression, overshoot = 0, 0, false, 0, 0
		if result then
			spring, deltaV, touching, compression, overshoot =
				VehicleMath.suspensionStep(suspension, result.Distance, compressionSpeed, dt)
		end
		if result and (touching or deltaV ~= 0) then
			w.deltaV = deltaV
			table.insert(damped, w)
		end
		if touching and result then
			w.compression = compression
			w.overshoot = overshoot
			w.spring = spring
			w.load = math.min(spring + math.max(0, deltaV) * cornerMass / dt, maxGripLoad)
			w.grounded = true
			w.contact = result.Position
			w.normal = result.Normal
			w.material = result.Material
			grounded += 1
			normalSum += result.Normal
			if w.driven then
				drivenGrounded += 1
			end
		else
			w.compression = 0
			w.overshoot = 0
			w.spring = 0
			w.load = 0
			w.grounded = false
			w.lateralSlip = 0
		end
	end
	-- The dampers' speed changes, solved together for the rigid body (VehicleMath.dampingImpulses)
	if #damped > 0 then
		local xs, zs, dvs = {}, {}, {}
		local comLocal = cf:PointToObjectSpace(com)
		local any = false
		for i, w in damped do
			local p = w.mount - comLocal
			xs[i], zs[i], dvs[i] = p.X, p.Z, w.deltaV
			any = any or w.deltaV ~= 0
		end
		if any then
			local inertia = s.inertia
			local impulses = VehicleMath.dampingImpulses(xs, zs, dvs, mass, inertia.Z, inertia.X)
			for i, w in damped do
				if impulses[i] ~= 0 then
					local impulse = up * impulses[i]
					chassis:ApplyImpulseAtPosition(impulse, cf:PointToWorldSpace(w.mount))
					dampingImpulse += impulse
				end
			end
		end
	end
	s.scriptedDeltaV += dampingImpulse / mass
	s.groundedCount = grounded
	s.groundNormal = if grounded > 0 then normalSum.Unit else Vector3.yAxis

	-- Steering: 32 degrees at standstill to 10 at top speed, plus touch countersteer
	local maxSteer =
		math.rad(VehicleMath.maxSteerAngle(speedFraction, drive.maxSteerAtZero, drive.maxSteerAtTop))
	local steerAngle = input.steer * maxSteer
	if controllers.Input.lastDevice() == "touch" and forwardSpeed > 5 and grounded >= 2 then
		local assist = drive.countersteer[settings.steerAssist] or 0
		local slipAngle = math.atan2(velocity:Dot(right), forwardSpeed)
		steerAngle += assist * slipAngle
	end
	if grounded >= 2 and handling.steerPull ~= 0 then
		steerAngle += math.rad(handling.steerPull) -- a damaged wheel pulls the car toward it
	end
	steerAngle = math.clamp(steerAngle, -math.rad(drive.maxSteerAtZero), math.rad(drive.maxSteerAtZero))
	s.steerAngle = steerAngle

	-- Longitudinal command
	local braking = (input.brake > 0 and forwardSpeed > 1) or (input.throttle > 0 and forwardSpeed < -1)
	local brakeAmount = if braking then (if forwardSpeed > 1 then input.brake else input.throttle) else 0
	local reversing = input.brake > 0 and forwardSpeed <= 1 and input.throttle == 0
	local driveTotal = 0
	local topSpeed = class.topSpeed * handling.topSpeed
	if input.throttle > 0 and not braking then
		driveTotal = mass
			* s.a0
			* VehicleMath.torqueCurve(math.max(forwardSpeed, 0) / topSpeed, drive.torqueFlatFraction)
			* input.throttle
	elseif reversing then
		local reverseTop = topSpeed * drive.reverseTopSpeedFraction
		driveTotal = -mass
			* s.a0
			* VehicleMath.torqueCurve(math.max(-forwardSpeed, 0) / reverseTop, drive.torqueFlatFraction)
			* input.brake
	end
	driveTotal *= if handling.engineDead then 0 else handling.drive
	local brakeTotal = mass * s.a0 * drive.brakeMultiplier * brakeAmount
	local coasting = driveTotal == 0 and brakeTotal == 0

	local totalForce = Vector3.zero
	local totalTorque = Vector3.zero
	local gripImpulse = Vector3.zero
	local springTorque = Vector3.zero
	for _, w in s.wheels do
		if w.lost and w.axleDrag then
			-- A dragging axle: friction against the ground at that corner
			local n = w.normal
			local slide = chassis:GetVelocityAtPosition(w.contact)
			slide -= n * slide:Dot(n)
			local speed = slide.Magnitude
			if speed > 0.05 then
				local cap = cornerMass * gravity * Config.Damage.handling.axleDragG
				local drag = -slide.Unit * math.min(cap, speed * cornerMass / dt)
				totalForce += drag
				totalTorque += (w.contact - com):Cross(drag)
			end
			continue
		end
		if not w.grounded then
			continue
		end
		local n = w.normal
		local steerHere = if w.steered then steerAngle else 0
		local heading = rotateAround(look, up, -steerHere)
		local wheelForward = heading - n * heading:Dot(n)
		if wheelForward.Magnitude < 1e-3 then
			continue
		end
		wheelForward = wheelForward.Unit
		local wheelRight = wheelForward:Cross(n)
		local pointVelocity = chassis:GetVelocityAtPosition(w.contact)
		local lateral = pointVelocity:Dot(wheelRight)
		local longitudinal = pointVelocity:Dot(wheelForward)
		w.lateralSlip = lateral

		local handbraking = input.handbrake and w.rear
		local mu = class.grip
			* (if handbraking then drive.handbrakeRearGripFraction else 1)
			* (handling.grip[w.index] or 1)
		local maxForce = mu * w.load
		local fy = VehicleMath.lateralForce(lateral, lateralStiffness, maxForce)
		local fx = 0
		if w.driven and drivenGrounded > 0 then
			fx += driveTotal / drivenGrounded
		end
		if brakeTotal > 0 then
			fx += VehicleMath.stoppingForce(longitudinal, brakeTotal / grounded, cornerMass, dt)
		end
		if handbraking then
			fx += VehicleMath.stoppingForce(longitudinal, maxForce, cornerMass, dt)
		elseif coasting then
			fx += VehicleMath.stoppingForce(
				longitudinal,
				cornerMass * drive.rollingResistance,
				cornerMass,
				dt
			)
		end
		fx, fy = VehicleMath.frictionCircle(fx, fy, maxForce)

		local suspensionForce = up * w.spring
		local tire = wheelForward * fx
		local mountWorld = cf:PointToWorldSpace(w.mount)
		local heightToCom = (com - w.contact):Dot(up)
		local tirePoint = w.contact + up * (heightToCom * (1 - drive.tireForceHeightFactor))
		-- Sideways grip is an impulse for this frame. As a held force it kept pushing through a long next
		-- frame, over-corrected, and the car rocked itself over after a hitch.
		if fy ~= 0 then
			local impulse = wheelRight * (fy * dt)
			chassis:ApplyImpulseAtPosition(impulse, tirePoint)
			gripImpulse += impulse
		end
		totalForce += suspensionForce + tire
		springTorque += (mountWorld - com):Cross(suspensionForce)
		totalTorque += (tirePoint - com):Cross(tire)
	end

	s.scriptedDeltaV += gripImpulse / mass
	-- Springs roll and pitch the body more softly than they lift it: a stiff roll spring held through a
	-- long frame overshoots and rocks the car over (frame hitches on phones and at load)
	totalTorque += look * (springTorque:Dot(look) * drive.springRollFactor) + right * (springTorque:Dot(right) * drive.springPitchFactor) + up * springTorque:Dot(
		up
	)

	-- Assists and air control, as angular accelerations
	local alpha = Vector3.zero
	if grounded >= 2 then
		-- Downforce: 0.5 x weight at top speed, scaled by speed^2
		totalForce += -up * VehicleMath.downforce(mass * gravity, speedFraction, drive.downforceAtTop)
		-- Anti-roll toward the ground plane
		local groundN = s.groundNormal
		local rollAngle = math.asin(math.clamp(right:Dot(groundN), -1, 1))
		local rollRate = angular:Dot(look)
		-- (the damping never takes more than half the roll rate in one frame)
		local rollDamping = math.min(rollAssist * drive.antiRollDamping, 0.5 / dt)
		alpha += look * (rollAssist * drive.antiRollStiffness * rollAngle - rollDamping * rollRate)
		-- Yaw damping: remove part of the yaw rate the steering does not explain
		local yawRate = angular:Dot(up)
		local expectedYaw = -VehicleMath.expectedYawRate(forwardSpeed, steerAngle, s.wheelbase)
		local factor = if input.handbrake then drive.yawDampingHandbrakeFactor else 1
		alpha += up * (-(drive.yawDamping / 0.1) * factor * (yawRate - expectedYaw))
	end
	if #s.wheels - grounded >= drive.airWheelsOffForControl then
		local leanRate = math.rad(class.leanRate)
		if input.lean ~= 0 then
			local target = -input.lean * leanRate -- lean forward = nose down
			alpha += right * ((target - angular:Dot(right)) / drive.airResponseTime)
		end
		if input.steer ~= 0 then
			local target = input.steer * leanRate * drive.airRollFraction
			alpha += look * ((target - angular:Dot(look)) / drive.airResponseTime)
		end
		local maxRate = leanRate * drive.airMaxRateMultiplier
		if angular.Magnitude > maxRate then
			alpha += -(angular - angular.Unit * maxRate) / 0.1
		end
	end
	totalTorque += applyInertia(s, alpha)

	-- Hop (JUMP button): Starter Buggy hops at 12 studs/s
	s.hopTimer = math.max(0, s.hopTimer - dt)
	if s.driverPresent and controllers.Input.consume("jump") then
		if s.def.hopSpeed > 0 and grounded >= 2 and s.hopTimer <= 0 then
			s.hopTimer = drive.hopCooldown
			local impulse = up * s.def.hopSpeed
			chassis:ApplyImpulse(impulse * mass)
			s.scriptedDeltaV += impulse
			VehicleController.Hopped:Fire()
		end
	end

	s.vectorForce.Force = totalForce
	s.torque.Torque = totalTorque
	s.lastForce = totalForce
	s.lastVelocity = velocity

	-- Deceleration for the camera's brake pitch
	s.decel = (s.lastForwardSpeed - forwardSpeed) / dt
	s.lastForwardSpeed = forwardSpeed
end

---------------------------------------------------------------------------
-- After physics: impacts, landings, recovery, kill plane, pose
---------------------------------------------------------------------------

local function beginSequence(s, kind: string, target: CFrame, duration: number)
	s.sequence = {
		kind = kind,
		t = 0,
		duration = duration,
		from = s.chassis.CFrame,
		to = target,
		swapped = false,
	}
	if kind == "reset" and controllers.Hud then
		controllers.Hud.fade(duration)
	end
end

local function respawnCFrame(s): CFrame
	return s.checkpoint + Vector3.new(0, rideHeight(s) + 0.3, 0)
end

local function detectImpact(s, dt: number)
	if s.skipImpactFrames > 0 then
		s.skipImpactFrames -= 1
		s.lastVelocity = s.chassis.AssemblyLinearVelocity
		s.scriptedDeltaV = Vector3.zero
		return
	end
	local chassis = s.chassis
	local velocity = chassis.AssemblyLinearVelocity
	local expected = (s.lastForce / s.mass + Vector3.new(0, -workspace.Gravity, 0)) * dt + s.scriptedDeltaV
	s.scriptedDeltaV = Vector3.zero
	local deltaV = velocity - s.lastVelocity - expected
	local magnitude = deltaV.Magnitude
	if magnitude < Config.Impact.detectMinDeltaV then
		return
	end

	local now = os.clock()
	local other: BasePart? = nil
	if s.recentTouch and now - s.recentTouchTime < 0.15 and s.recentTouch.Parent then
		other = s.recentTouch
	end
	local otherMass: number? = nil
	if other and not other.Anchored then
		otherMass = other.AssemblyMass
	end
	local key = if other then (other.AssemblyRootPart or other) else "world"
	if now - (s.pairTimes[key] or 0) < Config.Impact.pairCooldown then
		return
	end
	s.pairTimes[key] = now

	local cf = chassis.CFrame
	local normal = deltaV.Unit
	local localNormal = cf:VectorToObjectSpace(normal)
	local side = Damage.contactSide(
		localNormal.X,
		localNormal.Y,
		localNormal.Z,
		Config.Impact.landingNormalDot,
		Config.Impact.roofNormalDot
	)
	local closing = Damage.closingSpeedFromDeltaV(magnitude, s.mass, otherMass)
	local impact = Damage.impact(closing, Damage.massFactor(s.mass, otherMass, Config.Impact))
	local tier = Damage.tier(impact, Config.Impact)
	local half = chassis.Size / 2
	local point = cf:PointToWorldSpace(
		Vector3.new(-localNormal.X * half.X, -localNormal.Y * half.Y, -localNormal.Z * half.Z)
	)

	local info: ImpactInfo = {
		impact = impact,
		tier = tier,
		side = side,
		closingSpeed = closing,
		point = point,
		other = other,
	}
	VehicleController.Impact:Fire(info)

	-- Rider ejection rules for this mode (spec: When the rider ejects)
	local rules = Config.EjectRules[mode()] or Config.EjectRules.TestTrack
	if s.driverPresent and controllers.Ragdoll then
		local eject = false
		if side == "Roof" then
			eject = rules.roofLanding and closing >= rules.roofLandingSpeed
		elseif side ~= "Bottom" then
			eject = rules.hugeCrash and tier == "HugeCrash"
		end
		if eject then
			VehicleController.ejectRider()
		end
	end
end

local function postStep(dt: number)
	local s = state
	if not s or not s.chassis.Parent then
		return
	end
	if s.sequence then
		return
	end
	local chassis = s.chassis
	detectImpact(s, dt)

	-- Airborne time and wheel landings
	local velocity = chassis.AssemblyLinearVelocity
	if s.groundedCount <= 1 then
		s.airTime += dt
		s.maxFallSpeed = math.max(s.maxFallSpeed, -velocity.Y)
	else
		if s.airTime > 0.25 and s.maxFallSpeed > 10 then
			VehicleController.Landed:Fire(s.maxFallSpeed)
		end
		s.airTime = 0
		s.maxFallSpeed = 0
	end

	-- FLIP: resting on the roof or side for 1.5 s
	local up = chassis.CFrame.UpVector
	if up.Y < 0.5 and velocity.Magnitude < 6 and s.groundedCount < 2 then
		s.tiltedTime += dt
	else
		s.tiltedTime = 0
	end
	s.flipAvailable = s.tiltedTime >= Config.Driving.flipAfter
	if s.driverPresent then
		if controllers.Input.consume("flip") and (s.flipAvailable or up.Y < 0.5) then
			local position = chassis.Position + Vector3.new(0, 3, 0)
			beginSequence(
				s,
				"flip",
				yawOnly(CFrame.new(position) * chassis.CFrame.Rotation),
				Config.Driving.flipDuration
			)
		elseif controllers.Input.consume("reset") then
			VehicleController.reset()
		end
	end

	-- Kill plane
	if chassis.Position.Y < killY then
		VehicleController.reset()
	end

	-- Pose broadcast at 10 Hz
	s.poseTimer += dt
	if s.poseTimer >= 1 / Config.Rider.poseRate then
		s.poseTimer = 0
		local flags = 0
		local rider = nil
		if controllers.Ragdoll and controllers.Ragdoll.isRagdolled() then
			flags += PoseCodec.FLAG_RAGDOLL
			rider = controllers.Ragdoll.getPoseTransforms()
		end
		if s.input.brake > 0 and s.forwardSpeed > 1 then
			flags += PoseCodec.FLAG_BRAKING
		end
		if s.input.handbrake then
			flags += PoseCodec.FLAG_HANDBRAKE
		end
		if s.groundedCount <= 1 then
			flags += PoseCodec.FLAG_AIRBORNE
		end
		local compression = {}
		local skidding = false
		for i, w in s.wheels do
			compression[i] = w.compression / s.class.suspensionTravel
			if w.grounded and math.abs(w.lateralSlip) > Config.Surface.skidSlipSpeed then
				skidding = true
			end
		end
		if skidding then
			flags += PoseCodec.FLAG_SKIDDING
		end
		if rider == nil then
			flags = bit32.band(flags, bit32.bnot(PoseCodec.FLAG_RAGDOLL))
		end
		Net.send(
			"Vehicle.Pose",
			PoseCodec.encode({
				steer = s.steerAngle / math.rad(Config.Driving.maxSteerAtZero),
				throttle = s.input.throttle - s.input.brake,
				flags = flags,
				compression = compression,
				rider = rider,
			})
		)
	end
end

---------------------------------------------------------------------------
-- Visuals: wheels follow the suspension and spin with the road
---------------------------------------------------------------------------

local function render(dt: number)
	local s = state
	if not s or not s.chassis.Parent then
		return
	end
	if os.clock() < renderFrozenUntil then
		return -- hit-stop: wheels and effects hold still for a moment (physics keeps running)
	end
	local class = s.class
	local look = s.chassis.CFrame.LookVector
	local forwardSpeed = s.chassis.AssemblyLinearVelocity:Dot(look)
	local blend = 1 - math.exp(-dt / 0.03)
	local damage = controllers.Damage
	for _, w in s.wheels do
		local target = if w.grounded then class.suspensionTravel - w.compression else class.suspensionTravel
		w.visualExtension += (target - w.visualExtension) * blend
		w.spin -= forwardSpeed / class.wheelRadius * dt
		w.spin %= math.pi * 2
		local steer = if w.steered then s.steerAngle else 0
		local camber = if damage then damage.camber(s.model, w.index) else 0
		local side = if w.index == 1 or w.index == 3 then -1 else 1
		w.motor.Transform = CFrame.new(0, -w.visualExtension, 0)
			* CFrame.Angles(0, -steer, math.rad(camber * side))
			* CFrame.Angles(w.spin, 0, 0)
	end
	if s.effects then
		s.effects:update(dt, s.wheels, forwardSpeed, s.groundedCount)
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function VehicleController.getState()
	return state
end

function VehicleController.getChassis(): BasePart?
	return state and state.chassis
end

function VehicleController.ejectRider(extraUp: number?)
	local s = state
	if not s or not s.driverPresent or not controllers.Ragdoll then
		return
	end
	s.driverPresent = false
	controllers.Ragdoll.eject(s.chassis.AssemblyLinearVelocity, extraUp)
end

-- Damage effects on handling (from DamageModel.handling)
function VehicleController.setHandling(handling)
	if state then
		state.handling = handling or CLEAN_HANDLING
	end
end

-- A scripted change of velocity (shockwaves, the explosion hop); never counted as a crash
function VehicleController.applyKick(deltaV: Vector3, angular: Vector3?)
	local s = state
	if not s or s.sequence then
		return
	end
	s.chassis:ApplyImpulse(deltaV * s.mass)
	s.scriptedDeltaV += deltaV
	if angular then
		s.chassis.AssemblyAngularVelocity += angular
	end
end

-- Hold the car on a script (the crash replay). script(dt) returns where the car is this frame, or nil
-- to finish, after which onFinish runs (to give the car back its speed). Returns a handle;
-- isScriptActive(handle) is false once anything else took over the car.
function VehicleController.runScripted(script: (number) -> CFrame?, onFinish: (() -> ())?): any
	local s = state
	if not s then
		return nil
	end
	s.sequence = {
		kind = "script",
		t = 0,
		duration = math.huge,
		from = s.chassis.CFrame,
		to = s.chassis.CFrame,
		swapped = false,
		script = script,
		onFinish = onFinish,
	}
	return s.sequence
end

function VehicleController.isScriptActive(handle: any): boolean
	return state ~= nil and handle ~= nil and state.sequence == handle
end

-- Hit-stop: hold the wheel and effect animation for a moment
function VehicleController.freezeRender(duration: number)
	renderFrozenUntil = math.max(renderFrozenUntil, os.clock() + duration)
end

-- RESET: back to the last checkpoint, upright, in 0.5 s (always available, except on a Brawl arena
-- mid-round: setResetAllowed)
local resetAllowed = true
function VehicleController.setResetAllowed(value: boolean)
	resetAllowed = value
end

function VehicleController.reset()
	local s = state
	if not s or s.sequence or not resetAllowed then
		return
	end
	beginSequence(s, "reset", respawnCFrame(s), Config.Driving.resetDuration)
end

-- Called by the ragdoll when the rider respawns: car back to the checkpoint, rider back in the seat.
-- With remount in place (Highway: the car kept driving on autopilot) the rider just climbs back in.
local remountInPlace = false
function VehicleController.respawnDriver()
	local s = state
	if not s then
		return
	end
	s.driverPresent = true
	controllers.Input.consume("jump")
	controllers.Input.consume("reset")
	controllers.Input.consume("flip")
	if remountInPlace then
		return
	end
	if s.sequence then
		s.sequence = nil
	end
	beginSequence(s, "reset", respawnCFrame(s), Config.Driving.resetDuration)
end

function VehicleController.setRemountInPlace(value: boolean)
	remountInPlace = value
end

function VehicleController.setRollAssist(multiplier: number)
	rollAssist = math.clamp(multiplier, 1, 10)
end

-- Who drives while the rider is thrown (nil: nobody, the car coasts)
function VehicleController.setAutopilot(fn: ((number) -> any)?)
	autopilot = fn
end

function VehicleController.isDriverPresent(): boolean
	return state ~= nil and state.driverPresent
end

-- Dev tests: put the car somewhere at a given velocity, now.
function VehicleController.placeAt(cf: CFrame, velocity: Vector3?, angular: Vector3?)
	local s = state
	if not s then
		return
	end
	s.sequence = nil
	s.model:PivotTo(cf)
	s.chassis.AssemblyLinearVelocity = velocity or Vector3.zero
	s.chassis.AssemblyAngularVelocity = angular or Vector3.zero
	s.lastVelocity = velocity or Vector3.zero
	s.skipImpactFrames = 3
	s.airTime = 0
end

-- A hazard threw the rider (a Hazard trigger, or a spinner bar's hit test in TracksClient). respawnAt is
-- where to come back (Pip's Hill: just past the hazard); nil keeps the last checkpoint.
function VehicleController.hazardHit(respawnAt: CFrame?)
	local s = state
	if not s or not s.driverPresent or s.sequence then
		return
	end
	local rules = Config.EjectRules[mode()] or Config.EjectRules.Tracks
	if not rules.hazard then
		return
	end
	if respawnAt then
		s.checkpoint = yawOnly(respawnAt)
	end
	VehicleController.ejectRider(Config.Rider.hazardKickUp)
	VehicleController.HazardHit:Fire()
end

-- Where the car respawns (a new run sets it back to the start); index is the checkpoint it counts as
function VehicleController.setCheckpoint(cf: CFrame, index: number)
	if state then
		state.checkpoint = yawOnly(cf)
		state.checkpointIndex = index
	end
end

-- Falling below this height resets the car (each map sets its own; nil = the world default)
function VehicleController.setKillY(y: number?)
	killY = y or Config.World.killY
end

function VehicleController.rideHeight(): number
	return if state then rideHeight(state) else 3
end

function VehicleController.setSteerAssist(level: string)
	if Config.Driving.countersteer[level] ~= nil then
		settings.steerAssist = level
	end
end

function VehicleController.equip(vehicleId: string)
	Net.send("Vehicle.Equip", vehicleId)
end

function VehicleController.init(all)
	controllers = all
end

function VehicleController.start()
	local folder = workspace:WaitForChild("Vehicles")
	local function consider(model: Instance)
		if model:IsA("Model") and model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
			latestModel = model
			task.spawn(setup, model)
		end
	end
	folder.ChildAdded:Connect(consider)
	folder.ChildRemoved:Connect(function(model)
		if state and state.model == model then
			teardown()
		end
	end)
	for _, model in folder:GetChildren() do
		consider(model)
	end

	RunService.PreSimulation:Connect(step)
	RunService.PostSimulation:Connect(postStep)
	RunService.RenderStepped:Connect(render)
end

return VehicleController
