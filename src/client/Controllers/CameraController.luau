-- CameraController: the follow camera (spec: Weight cues > Camera).
-- Follow lag 0.08 s at rest rising to 0.18 s at top speed, FOV 70 to 82 with speed, 3 degree pitch under
-- hard braking. The follower predicts the car's motion by the lag time, so at a steady speed the camera
-- sits at its normal distance and the lag only shows when speed or direction changes (the "weight").
-- Shake and punch come from JuiceService. Drag on empty screen (or right mouse) orbits; it eases back.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local CameraController = {}

local controllers: any = nil
local camera: Camera
local position: Vector3? = nil
local heading = Vector3.new(0, 0, -1)
local fov = Config.Camera.fovAtRest
local pitch = 0
local orbitYaw = 0
local orbitPitch = 0
local lastOrbitInput = 0
local shakeAmount, shakeTime, shakeLeft = 0, 0, 0
local punch = Vector3.zero
-- Smoothed follow target: the suspension bobs the chassis every frame, and following it exactly made the
-- picture shake (nate, 2026-11-15: "choppy"). The camera follows a filtered focus and velocity instead.
local smoothFocus: Vector3? = nil
local smoothVelocity = Vector3.zero
local reducedMotion = false
local random = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function CameraController.shake(amount: number, duration: number)
	if reducedMotion then
		return
	end
	shakeAmount = math.max(shakeAmount * (shakeLeft / math.max(shakeTime, 1e-3)), amount)
	shakeTime = math.max(duration, 0.01)
	shakeLeft = shakeTime
end

function CameraController.punch(direction: Vector3, amount: number)
	if reducedMotion or direction.Magnitude < 1e-3 then
		return
	end
	punch += direction.Unit * amount
end

function CameraController.setReducedMotion(value: boolean)
	reducedMotion = value
end

function CameraController.isReducedMotion(): boolean
	return reducedMotion
end

-- Hit-stop: the camera holds still for a moment (physics keeps running). Off with reduced motion.
local frozenUntil = 0
function CameraController.freeze(duration: number)
	if reducedMotion then
		return
	end
	frozenUntil = math.max(frozenUntil, os.clock() + duration)
end

-- Pull back: the follow distance grows by `amount` (0.5 = half again) and eases back over `duration`
-- (a Highway pile-up shows the whole wreck)
local pullAmount, pullStart, pullDuration = 0, 0, 1
function CameraController.pull(amount: number, duration: number)
	pullAmount, pullStart, pullDuration = amount, os.clock(), math.max(duration, 0.1)
end

local function pullFactor(): number
	local t = (os.clock() - pullStart) / pullDuration
	if t >= 1 or pullAmount <= 0 then
		return 1
	end
	-- Out fast, back slowly
	local shape = if t < 0.2 then t / 0.2 else 1 - (t - 0.2) / 0.8
	return 1 + pullAmount * shape
end

-- Something else (the crash replay) drives the camera: override(dt) returns the camera CFrame and FOV.
local override: ((number) -> (CFrame, number))? = nil
function CameraController.setOverride(fn: ((number) -> (CFrame, number))?)
	override = fn
	if fn == nil then
		position = nil -- snap back behind the car
		smoothFocus = nil
	end
end

local function update(dt: number)
	if override then
		local cf, overrideFov = override(dt)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = cf
		camera.FieldOfView = overrideFov
		return
	end
	if os.clock() < frozenUntil then
		return
	end
	local vehicle = controllers.Vehicle.getState()
	if not vehicle or not vehicle.chassis.Parent then
		return
	end
	local cfg = Config.Camera
	local class = vehicle.class
	local chassis: BasePart = vehicle.chassis
	local ragdollFocus = controllers.Ragdoll and controllers.Ragdoll.getFocusPart()

	local focus: Vector3
	local velocity: Vector3
	local distance, height
	if ragdollFocus then
		focus = ragdollFocus.Position
		velocity = ragdollFocus.AssemblyLinearVelocity
		distance, height = cfg.ragdollDistance, cfg.ragdollHeight
	else
		focus = chassis.Position
		velocity = chassis.AssemblyLinearVelocity
		distance, height = class.cameraDistance * pullFactor(), class.cameraHeight * pullFactor()
		-- Heading follows the car's nose, flattened; while reversing it holds still
		local look = chassis.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.2 and vehicle.forwardSpeed > -8 then
			local turnBlend = 1 - math.exp(-dt / 0.12)
			heading = heading:Lerp(flat.Unit, turnBlend)
			if heading.Magnitude > 1e-3 then
				heading = heading.Unit
			end
		end
	end

	-- Filter the focus: tight sideways and along the road, looser up and down (suspension bob, bumps)
	if smoothFocus == nil or (smoothFocus - focus).Magnitude > 60 then
		smoothFocus = focus
		smoothVelocity = velocity
	end
	local flatBlend = 1 - math.exp(-dt / cfg.focusSmoothing)
	local upBlend = 1 - math.exp(-dt / cfg.focusSmoothingVertical)
	local sf = smoothFocus :: Vector3
	sf = Vector3.new(
		sf.X + (focus.X - sf.X) * flatBlend,
		sf.Y + (focus.Y - sf.Y) * upBlend,
		sf.Z + (focus.Z - sf.Z) * flatBlend
	)
	smoothFocus = sf
	smoothVelocity = smoothVelocity:Lerp(velocity, 1 - math.exp(-dt / cfg.velocitySmoothing))
	focus = sf
	velocity = smoothVelocity

	local speedFraction = math.clamp(velocity.Magnitude / class.topSpeed, 0, 1)
	local lag = lerp(cfg.lagAtRest, cfg.lagAtTop, speedFraction)

	-- Orbit offset eases back after 1.5 s without input
	if os.clock() - lastOrbitInput > cfg.orbitReturnDelay then
		local back = 1 - math.exp(-dt * cfg.orbitReturnSpeed)
		orbitYaw = lerp(orbitYaw, 0, back)
		orbitPitch = lerp(orbitPitch, 0, back)
	end
	local orbitedHeading = CFrame.fromAxisAngle(Vector3.yAxis, orbitYaw):VectorToWorldSpace(heading)
	local desired = focus - orbitedHeading * distance + Vector3.new(0, height + orbitPitch * distance, 0)
	local predicted = desired + velocity * lag
	if position == nil or (position - desired).Magnitude > 200 then
		position = desired
	end
	position = (position :: Vector3):Lerp(predicted, 1 - math.exp(-dt / lag))

	-- Brake pitch
	local targetPitch = if not ragdollFocus and vehicle.decel > cfg.brakePitchDecel
		then cfg.brakePitchDegrees
		else 0
	pitch = lerp(pitch, targetPitch, 1 - math.exp(-dt / 0.12))

	-- FOV
	local targetFov = lerp(cfg.fovAtRest, cfg.fovAtTop, speedFraction)
	fov = lerp(fov, targetFov, 1 - math.exp(-dt / 0.25))

	-- Shake and punch
	local shakeOffset = Vector3.zero
	if shakeLeft > 0 then
		shakeLeft -= dt
		local amplitude = shakeAmount * math.clamp(shakeLeft / shakeTime, 0, 1) * cfg.maxShake
		shakeOffset = random:NextUnitVector() * amplitude
	end
	punch = punch:Lerp(Vector3.zero, 1 - math.exp(-dt / 0.06))

	local lookAt = focus + Vector3.new(0, 1.5, 0) + heading * cfg.lookAhead
	local eye = position :: Vector3

	-- Keep the camera out of walls
	local ignore = { vehicle.model }
	local riders = workspace:FindFirstChild("LocalRiders")
	if riders then
		table.insert(ignore, riders)
	end
	rayParams.FilterDescendantsInstances = ignore
	local toEye = eye - lookAt
	local hit = workspace:Raycast(lookAt, toEye, rayParams)
	if hit then
		eye = hit.Position - toEye.Unit * 0.6
	end

	local cf = CFrame.lookAt(eye + shakeOffset + punch, lookAt + shakeOffset * 0.5)
	cf *= CFrame.Angles(-math.rad(pitch), 0, 0)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cf
	camera.FieldOfView = fov
end

function CameraController.init(all)
	controllers = all
end

function CameraController.start()
	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera
	end)

	local dragging = false
	UserInputService.InputBegan:Connect(function(input, processed)
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton2
		if isMouse or (input.UserInputType == Enum.UserInputType.Touch and not processed) then
			dragging = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if not dragging then
			return
		end
		local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement
		local isTouch = input.UserInputType == Enum.UserInputType.Touch and not processed
		if isMouse or isTouch then
			orbitYaw -= input.Delta.X * 0.008
			orbitPitch = math.clamp(orbitPitch + input.Delta.Y * 0.004, -0.25, 0.6)
			lastOrbitInput = os.clock()
		end
	end)

	RunService:BindToRenderStep("RagdollRidesCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraController
