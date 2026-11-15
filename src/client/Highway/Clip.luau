-- Clip: the Highway results card's CLIP button (spec: Highway screens > Results card: Clip, one tap,
-- best 10 s; Analytics > clip_share). Clips are made on this device and never carry rewards.
-- * Recording: 15 times a second during a run, your car, your rider's 6 pieces and the traffic cars
--   near you. The last 10 s are kept, and whenever they hold more points than any 10 s before, they are
--   copied as the run's best moment.
-- * Playback: copies of your car, rider and those cars replay the best 10 s from a few slow-turning
--   camera angles while the real car waits (looks only, nothing collides).
-- * Share: at the moment with the most points the screen is captured; SHARE offers it through
--   Roblox's capture sharing (CaptureService, verify on devices). Without it the clip still plays.
-- PLACEHOLDER ART: traffic in the clip are plain blocks in their colours.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Clip = {}
Clip.__index = Clip

local RATE = 15
local LENGTH = 10
local MAX_TRAFFIC = 8

export type CarShot = { cf: CFrame, size: Vector3, color: Color3 }
export type Frame = {
	t: number,
	car: CFrame,
	rider: { [string]: CFrame }?,
	traffic: { [number]: CarShot },
	points: number, -- points scored since the last frame
}
export type Recorder = {
	frames: { Frame },
	best: { Frame },
	bestPoints: number,
	timer: number,
	pending: number,
	lastCopy: number,
	stopper: (() -> ())?,
}

function Clip.newRecorder(): Recorder
	return setmetatable({
		frames = {},
		best = {},
		bestPoints = 0,
		timer = 0,
		pending = 0,
		lastCopy = -math.huge,
	}, Clip) :: any
end

-- Points scored now count toward the frame being recorded
function Clip.addPoints(self: Recorder, points: number)
	self.pending += math.max(0, points)
end

function Clip.record(
	self: Recorder,
	dt: number,
	chassis: BasePart?,
	riderParts: { [string]: BasePart }?,
	traffic: { { body: BasePart, id: number? } }?
)
	self.timer += dt
	if self.timer < 1 / RATE or chassis == nil then
		return
	end
	self.timer = 0
	local t = os.clock()
	local rider = nil
	if riderParts then
		rider = {}
		for name, part in riderParts do
			rider[name] = part.CFrame
		end
	end
	local cars = {}
	if traffic then
		local count = 0
		for _, rig in traffic do
			if rig.id and count < MAX_TRAFFIC and (rig.body.Position - chassis.Position).Magnitude < 90 then
				count += 1
				cars[rig.id] = { cf = rig.body.CFrame, size = rig.body.Size, color = rig.body.Color }
			end
		end
	end
	table.insert(
		self.frames,
		{ t = t, car = chassis.CFrame, rider = rider, traffic = cars, points = self.pending }
	)
	self.pending = 0
	while #self.frames > 0 and t - self.frames[1].t > LENGTH do
		table.remove(self.frames, 1)
	end
	-- A new best 10 s? (copied at most once a second)
	local total = 0
	for _, f in self.frames do
		total += f.points
	end
	if total > self.bestPoints and t - self.lastCopy >= 1 then
		self.bestPoints = total
		self.best = table.clone(self.frames)
		self.lastCopy = t
	end
end

function Clip.hasClip(self: Recorder): boolean
	return #self.best >= RATE -- at least a second of action
end

local function sample(frames: { Frame }, t: number): (Frame, Frame, number)
	for i = 1, #frames - 1 do
		local a, b = frames[i], frames[i + 1]
		if t <= b.t then
			return a, b, math.clamp((t - a.t) / math.max(b.t - a.t, 1e-4), 0, 1)
		end
	end
	local last = frames[#frames]
	return last, last, 0
end

local function ghostOf(source: Instance): Instance
	local archivable = source.Archivable
	source.Archivable = true
	local copy = source:Clone()
	source.Archivable = archivable
	for _, d in copy:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	return copy
end

export type PlayArgs = {
	model: Model, -- your car (copied)
	riderParts: { [string]: BasePart }?,
	camera: any, -- CameraController
	hud: any, -- HudController
	onPeak: () -> (), -- the moment with the most points (capture the screen here)
	onFrame: ((carCf: CFrame) -> ())?, -- each frame (the road is rebuilt around the clip)
	onDone: () -> (),
}

-- Play the best 10 s. Returns false when there is nothing to play.
function Clip.play(self: Recorder, args: PlayArgs): boolean
	local frames = self.best
	if #frames < 2 then
		return false
	end
	local folder = Instance.new("Folder")
	folder.Name = "ClipReplay"
	folder.Parent = Workspace
	-- Your car: an anchored copy moved as one by its pivot
	local car = ghostOf(args.model) :: Model
	car.Parent = folder
	local root = car.PrimaryPart
	local pivotOffset = if root then root.CFrame:ToObjectSpace(car:GetPivot()) else CFrame.identity
	-- Your rider: one copy per piece
	local riderCopies: { [string]: BasePart } = {}
	if args.riderParts then
		for name, part in args.riderParts do
			local copy = part:Clone()
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			for _, d in copy:GetChildren() do
				if not d:IsA("Decal") and not d:IsA("SpecialMesh") then
					d:Destroy()
				end
			end
			copy.Parent = folder
			riderCopies[name] = copy
		end
	end
	local trafficCopies: { [number]: Part } = {}
	-- The peak: the frame with the most points
	local peakT, peakPoints = frames[1].t, -1
	for _, f in frames do
		if f.points > peakPoints then
			peakT, peakPoints = f.t, f.points
		end
	end
	local start, finish = frames[1].t, frames[#frames].t
	local duration = finish - start
	local elapsed = 0
	local captured = false
	args.hud.setReplay(true)
	local focus = frames[1].car.Position
	args.camera.setOverride(function(_dt: number)
		-- Three slow angles in turn: chase, side, low front
		local shot = math.floor(elapsed / (duration / 3)) % 3
		local a, b, alpha = sample(frames, start + elapsed)
		local carCf = a.car:Lerp(b.car, alpha)
		focus = focus:Lerp(carCf.Position, 0.2)
		local eye
		if shot == 0 then
			eye = carCf * CFrame.new(0, 7, 22)
		elseif shot == 1 then
			eye = carCf * CFrame.new(20, 5, 4)
		else
			eye = carCf * CFrame.new(-6, 2.5, -24)
		end
		return CFrame.lookAt(eye.Position, focus + Vector3.new(0, 1.5, 0)), 65
	end)
	local connection: RBXScriptConnection
	local function stop()
		self.stopper = nil
		connection:Disconnect()
		args.camera.setOverride(nil)
		args.hud.setReplay(false)
		folder:Destroy()
		args.onDone()
	end
	self.stopper = stop
	connection = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			stop()
			return
		end
		local t = start + elapsed
		local a, b, alpha = sample(frames, t)
		local carCf = a.car:Lerp(b.car, alpha)
		if root then
			car:PivotTo(carCf * pivotOffset)
		end
		if args.onFrame then
			args.onFrame(carCf)
		end
		if a.rider then
			for name, cf in a.rider do
				local copy = riderCopies[name]
				local other = b.rider and b.rider[name]
				if copy then
					copy.CFrame = if other then cf:Lerp(other, alpha) else cf
				end
			end
		end
		-- Traffic: blocks for the cars in this frame
		local seen = {}
		for id, shot in a.traffic do
			seen[id] = true
			local block = trafficCopies[id]
			if block == nil then
				local p = Instance.new("Part")
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.Material = Enum.Material.SmoothPlastic
				p.Size = shot.size
				p.Color = shot.color
				p.Parent = folder
				trafficCopies[id] = p
				block = p
			end
			local nextShot = b.traffic[id]
			block.CFrame = if nextShot then shot.cf:Lerp(nextShot.cf, alpha) else shot.cf
		end
		for id, block in trafficCopies do
			if not seen[id] then
				block:Destroy()
				trafficCopies[id] = nil
			end
		end
		if not captured and t >= peakT then
			captured = true
			task.spawn(args.onPeak)
		end
	end)
	return true
end

-- Stop a clip that is playing (DONE)
function Clip.stop(self: Recorder)
	local stop = self.stopper
	if stop then
		stop()
	end
end

return Clip
