-- CrashReplay: hit-stop and the slow-mo crash replay (spec: Impact > decision on slow-mo).
-- Roblox cannot slow shared physics, so slow-mo is a replay. A 3 s buffer records the own car and rider at
-- 30 Hz. On a Huge crash in solo runs and Highway Havoc, the last 0.6 s plays back at half speed from a
-- crash-cam angle for 1.2 s while the car is held in place, then control returns. In Brawl and races there
-- is no hold: only hit-stop and camera punch, so nobody loses time.
-- Hit-stop (Hard hit 40 to 80 ms scaled by Impact, Huge crash 80 ms) freezes the camera and the wheel
-- animation locally; physics keeps running. Reduced motion turns off hit-stop and the replay.
--
-- The replay never moves the real car (its position replicates to everyone): the real car is held still and
-- hidden on this device while a local copy plays the crash back. The replay starts 0.3 s after the crash so
-- it shows the rider flying too, and only when the rider was thrown.

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local CrashReplay = {}

type Frame = { t: number, car: CFrame, rider: { [string]: CFrame }? }

local controllers: any = nil
local frames: { Frame } = {}
local recordTimer = 0
local playing = false
local lastCrash = -math.huge

local function mode(): string
	return workspace:GetAttribute("Mode") or "TestTrack"
end

local function reducedMotion(): boolean
	return controllers.Camera.isReducedMotion()
end

local function record(dt: number)
	if playing then
		return
	end
	recordTimer += dt
	local cfg = Config.CrashFx
	if recordTimer < 1 / cfg.replayRate then
		return
	end
	recordTimer = 0
	local chassis = controllers.Vehicle.getChassis()
	if not chassis then
		return
	end
	local rider = nil
	local parts = controllers.Ragdoll.getLocalParts()
	if parts then
		rider = {}
		for name, part in parts do
			rider[name] = part.CFrame
		end
	end
	local now = os.clock()
	table.insert(frames, { t = now, car = chassis.CFrame, rider = rider })
	while #frames > 0 and now - frames[1].t > cfg.replayBuffer do
		table.remove(frames, 1)
	end
end

local function sample(window: { Frame }, t: number): (CFrame, { [string]: CFrame }?)
	if t <= window[1].t then
		return window[1].car, window[1].rider
	end
	for i = 1, #window - 1 do
		local a, b = window[i], window[i + 1]
		if t <= b.t then
			local alpha = (t - a.t) / math.max(b.t - a.t, 1e-4)
			local rider = nil
			if a.rider and b.rider then
				rider = {}
				for name, cf in a.rider do
					local other = b.rider[name]
					rider[name] = if other then cf:Lerp(other, alpha) else cf
				end
			end
			return a.car:Lerp(b.car, alpha), rider
		end
	end
	local last = window[#window]
	return last.car, last.rider
end

-- A local, non-colliding copy of the car that shows exactly what the real one looks like now
local function makeGhost(model: Model): (Model, Part)
	local archivable = model.Archivable
	model.Archivable = true
	local ghost = model:Clone()
	model.Archivable = archivable
	-- Match parts by their path inside the model (local-only children may not have been copied)
	local function pathOf(instance: Instance, root: Instance): string
		local names = {}
		local node: Instance? = instance
		while node and node ~= root do
			table.insert(names, 1, node.Name)
			node = node.Parent
		end
		return table.concat(names, "/")
	end
	local hiddenPaths = {}
	for _, original in model:GetDescendants() do
		if original:IsA("BasePart") and original.LocalTransparencyModifier >= 1 then
			hiddenPaths[pathOf(original, model)] = true
		end
	end
	for _, copy in ghost:GetDescendants() do
		if copy:IsA("BasePart") then
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			copy.Anchored = copy.Name == "Chassis"
			if hiddenPaths[pathOf(copy, ghost)] then
				copy.Transparency = 1 -- detached panels stay gone
			end
		elseif copy:IsA("VectorForce") or copy:IsA("Torque") then
			copy:Destroy()
		end
	end
	local dentShell = ghost:FindFirstChild("DentShell", true)
	if dentShell then
		dentShell:Destroy()
		local floor = ghost:FindFirstChild("Panel_Floor", true) :: BasePart?
		local realFloor = model:FindFirstChild("Panel_Floor", true) :: BasePart?
		if floor and realFloor then
			floor.Transparency = realFloor.Transparency
		end
	end
	ghost.Name = "ReplayGhost"
	ghost.Parent = workspace:FindFirstChild("LocalDebris") or workspace
	return ghost, ghost:FindFirstChild("Chassis") :: Part
end

local function setHidden(model: Model, hidden: boolean, saved: { [BasePart]: number })
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			if hidden then
				saved[part] = part.LocalTransparencyModifier
				part.LocalTransparencyModifier = 1
			elseif saved[part] ~= nil then
				part.LocalTransparencyModifier = saved[part]
			end
		end
	end
end

local function play()
	local cfg = Config.CrashFx
	local vehicle = controllers.Vehicle.getState()
	if playing or not vehicle or #frames < 4 then
		return
	end
	local riderParts = controllers.Ragdoll.getLocalParts()
	if not controllers.Ragdoll.isRagdolled() or not riderParts then
		return
	end
	local now = os.clock()
	local window = {}
	for _, frame in frames do
		if now - frame.t <= cfg.replayWindow then
			table.insert(window, frame)
		end
	end
	if #window < 2 then
		return
	end
	playing = true

	local model: Model = vehicle.model
	local chassis: BasePart = vehicle.chassis
	local heldAt = chassis.CFrame
	local savedVelocity, savedAngular = chassis.AssemblyLinearVelocity, chassis.AssemblyAngularVelocity
	local savedRider = {}
	for name, part in riderParts do
		savedRider[name] = {
			cf = part.CFrame,
			velocity = part.AssemblyLinearVelocity,
			angular = part.AssemblyAngularVelocity,
			anchored = part.Anchored,
		}
		part.Anchored = true
	end
	controllers.Ragdoll.setFrozen(true)

	local ghost, ghostRoot = makeGhost(model)
	local hiddenSaved = {}
	setHidden(model, true, hiddenSaved)

	-- Crash cam: off to the side of the crash, looking at the car
	local crashPoint = window[#window].car.Position
	local travel = (window[#window].car.Position - window[1].car.Position)
	local flat = Vector3.new(travel.X, 0, travel.Z)
	local sideways = if flat.Magnitude > 1 then flat.Unit:Cross(Vector3.yAxis) else Vector3.xAxis
	local camPos = crashPoint + sideways * cfg.crashCamDistance + Vector3.new(0, cfg.crashCamHeight, 0)

	local duration = (window[#window].t - window[1].t) / cfg.replaySpeed
	local elapsed = 0
	local finished = false
	local ghostPosition = crashPoint

	local function finish(restoreRider: boolean)
		if finished then
			return
		end
		finished = true
		controllers.Camera.setOverride(nil)
		controllers.Hud.setReplay(false)
		ghost:Destroy()
		if model.Parent then
			setHidden(model, false, hiddenSaved)
		end
		-- After a respawn the rider is back in the seat and owned by the ragdoll code again; leave it be
		if restoreRider then
			for name, part in riderParts do
				local saved = savedRider[name]
				if part.Parent then
					part.Anchored = saved.anchored
					part.CFrame = saved.cf
					if not saved.anchored then
						part.AssemblyLinearVelocity = saved.velocity
						part.AssemblyAngularVelocity = saved.angular
					end
				end
			end
		end
		controllers.Ragdoll.setFrozen(false)
		playing = false
	end

	local hold
	hold = controllers.Vehicle.runScripted(function(_dt: number): CFrame?
		if elapsed >= duration then
			return nil
		end
		return heldAt
	end, function()
		if chassis.Parent then
			chassis.AssemblyLinearVelocity = savedVelocity
			chassis.AssemblyAngularVelocity = savedAngular
		end
	end)

	controllers.Hud.setReplay(true)
	controllers.Camera.setOverride(function(_dt: number)
		return CFrame.lookAt(camPos, ghostPosition + Vector3.new(0, 1, 0)), 60
	end)

	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local respawned = not controllers.Vehicle.isScriptActive(hold) and elapsed < duration
		if respawned or not controllers.Ragdoll.isRagdolled() then
			-- The player respawned during the replay: drop it, leave the rider where the respawn put it
			connection:Disconnect()
			finish(false)
			return
		end
		local t = window[1].t + math.min(elapsed, duration) * cfg.replaySpeed
		local carCf, riderCfs = sample(window, t)
		ghostRoot.CFrame = carCf
		ghostPosition = carCf.Position
		if riderCfs then
			for name, cf in riderCfs do
				local part = riderParts[name]
				if part then
					part.CFrame = cf
				end
			end
			local torso = riderCfs.Torso
			if torso then
				ghostPosition = ghostPosition:Lerp(torso.Position, 0.5)
			end
		end
		if elapsed >= duration then
			connection:Disconnect()
			finish(true)
		end
	end)
end

local function onImpact(info)
	if info.side == "Bottom" or reducedMotion() then
		return
	end
	local cfg = Config.CrashFx
	if info.tier == "HardHit" then
		local alpha = math.clamp((info.impact - 25) / 35, 0, 1)
		local duration = cfg.hitStopMin + (cfg.hitStopMax - cfg.hitStopMin) * alpha
		controllers.Camera.freeze(duration)
		controllers.Vehicle.freezeRender(duration)
	elseif info.tier == "HugeCrash" then
		controllers.Camera.freeze(cfg.hitStopHuge)
		controllers.Vehicle.freezeRender(cfg.hitStopHuge)
		local now = os.clock()
		if cfg.replayModes[mode()] and now - lastCrash > 3 then
			lastCrash = now
			task.delay(cfg.replayDelay, play)
		end
	end
end

-- Play the last crash now (Highway's Full Crack finale); only when the rider is thrown, as always
function CrashReplay.playNow()
	if not playing and not reducedMotion() then
		task.spawn(play)
	end
end

function CrashReplay.isPlaying(): boolean
	return playing
end

function CrashReplay.init(all)
	controllers = all
end

function CrashReplay.start()
	controllers.Vehicle.Impact:Connect(onImpact)
	controllers.Vehicle.Respawned:Connect(function()
		table.clear(frames)
	end)
	RunService.Heartbeat:Connect(record)
end

return CrashReplay
