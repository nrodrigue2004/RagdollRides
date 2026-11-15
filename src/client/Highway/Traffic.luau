-- Traffic: the Sunny Pass traffic around your car (spec: Highway Havoc > Traffic; Network model >
-- Highway). Every device knows where every car is from the seed and the server clock (Shared/
-- HighwayMath), so traffic is never sent over the network; this keeps a pool of 16 cars on the slots
-- nearest you.
-- * The 8 nearest within 140 studs are real physics bodies held on their lane by a LinearVelocity and an
--   AlignOrientation (force: 90 x mass, so any real hit overpowers it); the rest glide, anchored.
-- * A hit under the wreck line knocks a car off its lane for 1.2 s, then it finds its lane and slot
--   again. One hit of I 40+, or two of I 20+, wrecks it: free physics until it is cleared 6 s later.
--   A hit of I 70+ blows it up 0.8 s later: a blast that pushes cars and props and sets off cars
--   within 8 studs.
-- * A car you sent flying that hits another car or a prop reports that as a chain hit (link + 1, up to
--   3 links), so the originator gets their share.
-- * Tutorial: 3 soft compacts in your lane, driving slowly from your start; they wreck at I 10.
-- PLACEHOLDER ART: each car is a body block, a cabin block and a dark wheel strip in its type's colour.

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local HighwayMath = require(Shared.HighwayMath)

local cfg = Config.Highway
local tcfg = cfg.traffic

local Traffic = {}
Traffic.__index = Traffic

local TUTORIAL_KIND = 3 -- Highway.Hit kind for tutorial cars (0 is traffic, 1 props, 2 players)
local TUTORIAL_WRECK = 10
local CHAIN_MIN = 12 -- a wrecked car must hit this hard for a chain hit to count
local PAIR_COOLDOWN = 0.5
local MAX_RIGS = 24 -- the pool plus wrecks still tumbling

export type Report = (kind: number, id: number, impact: number, link: number, point: Vector3) -> ()

export type Rig = {
	model: Model,
	body: Part,
	cabin: Part,
	wheels: Part,
	attach: Attachment,
	lv: LinearVelocity,
	align: AlignOrientation,
	id: number?,
	kindIndex: number,
	kind: HighwayMath.TrafficType?,
	lane: number,
	speed: number,
	state: string, -- "free", "lane", "stagger", "wreck"
	dynamic: boolean,
	staggerUntil: number,
	wreckedAt: number,
	hard: number,
	link: number, -- the link its own touches report (0: it was hit by you; nil-like 9: not yours)
	mine: boolean,
	lastHit: number,
	exploding: boolean,
	pairs: { [any]: number },
	tutorial: boolean,
}

export type Opts = {
	opts: HighwayMath.TrafficOpts?,
	epoch: number,
	tutorial: { s0: number, startAt: number, lane: number }?,
	refMass: number,
	report: Report,
	onBlast: (position: Vector3) -> (),
	onSmash: (rig: Rig, impact: number, point: Vector3) -> (),
}

export type Pool = {
	def: HighwayMath.Road,
	o: Opts,
	folder: Folder,
	rigs: { Rig },
	byId: { [number]: Rig },
	wantTimer: number,
	tutorialPlaced: boolean,
}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function color(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function forwardAt(def: HighwayMath.Road, s: number): (Vector3, Vector3, number)
	local h = HighwayMath.heading(def, s)
	-- The road runs toward -Z with heading h turning it; CFrame.Angles(0, -h, 0) faces along it
	local cf = CFrame.Angles(0, -h, 0)
	return cf.LookVector, cf.RightVector, h
end

local function setKind(pool: Pool, rig: Rig, kindIndex: number)
	local kind = tcfg.types[kindIndex]
	rig.kindIndex = kindIndex
	rig.kind = kind
	local w, h, l = kind.size[1], kind.size[2], kind.size[3]
	local bodyH = h * 0.6
	rig.body.Size = Vector3.new(w, bodyH, l)
	rig.cabin.Size = Vector3.new(
		w * 0.9,
		h - bodyH,
		l * (if kind.id == "compact" or kind.id == "sedan" then 0.55 else 0.85)
	)
	rig.wheels.Size = Vector3.new(w + 0.3, 1.4, l * 0.8)
	local tone = color(kind.color)
	-- Night Lights: the traffic glows
	local event = pool.o.opts and pool.o.opts.event
	rig.cabin.Material = if event and (event :: any).night then Enum.Material.Neon else Enum.Material.Glass
	rig.body.Color = tone
	rig.cabin.Color = tone:Lerp(Color3.new(1, 1, 1), 0.35)
	rig.wheels.Color = Color3.fromRGB(40, 40, 46)
	local volume = w * bodyH * l
	local mass = kind.mass * pool.o.refMass
	rig.body.CustomPhysicalProperties =
		PhysicalProperties.new(math.clamp(mass / volume, 0.01, 100), 0.05, 0.4, 10, 1)
	-- Welds keep the cabin on top (towards the back for cars) and the wheel strip at the bottom
	local cabinWeld = rig.cabin:FindFirstChildOfClass("Weld") :: Weld
	cabinWeld.C0 = CFrame.new(
		0,
		bodyH / 2 + (h - bodyH) / 2,
		if kind.id == "compact" or kind.id == "sedan" then l * 0.12 else l * 0.05
	)
	local wheelWeld = rig.wheels:FindFirstChildOfClass("Weld") :: Weld
	wheelWeld.C0 = CFrame.new(0, -bodyH / 2 + 0.5, 0)
	rig.lv.MaxForce = mass * tcfg.maxForce
	rig.align.MaxTorque = mass * 4000
end

local function newRig(pool: Pool): Rig
	local model = Instance.new("Model")
	model.Name = "TrafficCar"
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Material = Enum.Material.SmoothPlastic
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Anchored = true
	body.Parent = model
	local cabin = Instance.new("Part")
	cabin.Name = "Cabin"
	cabin.Material = Enum.Material.Glass
	cabin.Transparency = 0.1
	cabin.CanCollide = false
	cabin.CanQuery = false
	cabin.CanTouch = false
	cabin.Massless = true
	cabin.Parent = model
	local wheels = Instance.new("Part")
	wheels.Name = "Wheels"
	wheels.Material = Enum.Material.SmoothPlastic
	wheels.CanCollide = false
	wheels.CanQuery = false
	wheels.CanTouch = false
	wheels.Massless = true
	wheels.Parent = model
	for _, p in { cabin, wheels } do
		local weld = Instance.new("Weld")
		weld.Part0 = body
		weld.Part1 = p
		weld.Parent = p
	end
	local attach = Instance.new("Attachment")
	attach.Parent = body
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	lv.Enabled = false
	lv.Parent = body
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attach
	align.Responsiveness = 25
	align.Enabled = false
	align.Parent = body
	model.PrimaryPart = body
	model.Parent = pool.folder
	local rig: Rig = {
		model = model,
		body = body,
		cabin = cabin,
		wheels = wheels,
		attach = attach,
		lv = lv,
		align = align,
		id = nil,
		kindIndex = 0,
		kind = nil,
		lane = 1,
		speed = 0,
		state = "free",
		dynamic = false,
		staggerUntil = 0,
		wreckedAt = 0,
		hard = 0,
		link = 9,
		mine = false,
		lastHit = -math.huge,
		exploding = false,
		pairs = {},
		tutorial = false,
	}
	body.Touched:Connect(function(other: BasePart)
		Traffic.onRigTouched(pool, rig, other)
	end)
	table.insert(pool.rigs, rig)
	return rig
end

local function park(rig: Rig)
	rig.lv.Enabled = false
	rig.align.Enabled = false
	rig.body.Anchored = true
	rig.dynamic = false
	rig.body.CFrame = CFrame.new(0, -500, 0)
	rig.body:SetAttribute("TrafficCar", nil)
	rig.body:SetAttribute("TutorialCar", nil)
	rig.id = nil
	rig.state = "free"
	rig.exploding = false
	rig.hard = 0
	rig.link = 9
	rig.mine = false
	table.clear(rig.pairs)
end

local function setDynamic(rig: Rig, on: boolean, velocity: Vector3?)
	if rig.dynamic == on then
		return
	end
	rig.dynamic = on
	rig.body.Anchored = not on
	if on and velocity then
		rig.body.AssemblyLinearVelocity = velocity
	end
end

function Traffic.new(def: HighwayMath.Road, o: Opts): Pool
	local folder = Instance.new("Folder")
	folder.Name = "HighwayTraffic"
	folder.Parent = Workspace
	local self = {
		def = def,
		o = o,
		folder = folder,
		rigs = {},
		byId = {},
		wantTimer = math.huge, -- place the first cars on the first update
		tutorialPlaced = false,
	}
	return setmetatable(self, Traffic) :: any
end

local function trafficTime(pool: Pool): number
	return now() - pool.o.epoch
end

-- Where a car's slot is right now
function Traffic.slot(pool: Pool, rig: Rig): (number?, number)
	local id = rig.id
	if id == nil then
		return nil, 0
	end
	local tut = pool.o.tutorial
	if rig.tutorial and tut then
		local ahead = cfg.tutorial.cars[id]
		return tut.s0 + ahead + cfg.tutorial.carSpeed * (now() - tut.startAt),
			HighwayMath.laneOffset(pool.def, tut.lane)
	end
	local car = HighwayMath.car(pool.def, id, trafficTime(pool), tcfg, pool.o.opts)
	if car == nil then
		return nil, 0
	end
	return car.s, HighwayMath.laneOffset(pool.def, car.lane)
end

local function poseAt(pool: Pool, rig: Rig, s: number, lateral: number): CFrame
	local x, z, h = HighwayMath.place(pool.def, s, lateral)
	local kind = rig.kind :: HighwayMath.TrafficType
	local y = pool.def.origin[2] + kind.size[2] * 0.3 + 0.05
	return CFrame.new(x, y, z) * CFrame.Angles(0, -h, 0)
end

local function assign(pool: Pool, rig: Rig, id: number, kindIndex: number, tutorial: boolean)
	if rig.kindIndex ~= kindIndex then
		setKind(pool, rig, kindIndex)
	end
	rig.id = id
	rig.tutorial = tutorial
	rig.state = "lane"
	rig.hard = 0
	rig.link = 9
	rig.mine = false
	rig.lastHit = -math.huge
	rig.exploding = false
	rig.body.Transparency = 0
	rig.cabin.Transparency = 0.1
	rig.body.Color = color((rig.kind :: HighwayMath.TrafficType).color)
	rig.body:SetAttribute("TrafficCar", id)
	rig.body:SetAttribute("TutorialCar", if tutorial then true else nil)
	pool.byId[id] = rig
	local s, lateral = Traffic.slot(pool, rig)
	if s then
		rig.body.Anchored = true
		rig.dynamic = false
		rig.body.CFrame = poseAt(pool, rig, s, lateral)
	end
end

local function freeRig(pool: Pool): Rig?
	for _, rig in pool.rigs do
		if rig.state == "free" then
			return rig
		end
	end
	if #pool.rigs < MAX_RIGS then
		return newRig(pool)
	end
	return nil
end

local function release(pool: Pool, rig: Rig)
	if rig.id and pool.byId[rig.id] == rig then
		pool.byId[rig.id] = nil
	end
	park(rig)
end

local function kindIndexOf(kind: HighwayMath.TrafficType): number
	for index, k in tcfg.types do
		if k.id == kind.id then
			return index
		end
	end
	return 1
end

-- Which slots should have a car: the nearest 16 around s (tutorial: its 3 cars)
local function refreshWanted(pool: Pool, s: number)
	local tut = pool.o.tutorial
	if tut then
		if not pool.tutorialPlaced then
			pool.tutorialPlaced = true -- only once: wrecked tutorial cars stay gone
			for index = 1, #cfg.tutorial.cars do
				local rig = freeRig(pool)
				if rig then
					assign(pool, rig, index, 1, true)
					rig.lane = tut.lane
					rig.speed = cfg.tutorial.carSpeed
				end
			end
		end
		return
	end
	local list = HighwayMath.carsBetween(
		pool.def,
		s - tcfg.behind,
		s + tcfg.ahead,
		trafficTime(pool),
		tcfg,
		pool.o.opts,
		s
	)
	local keep: { [number]: HighwayMath.Car } = {}
	for i = 1, math.min(tcfg.count, #list) do
		keep[list[i].id] = list[i]
	end
	for _, rig in pool.rigs do
		if rig.state == "lane" and rig.id and keep[rig.id] == nil then
			release(pool, rig)
		end
	end
	for id, car in keep do
		if pool.byId[id] == nil then
			local rig = freeRig(pool)
			if rig == nil then
				break
			end
			assign(pool, rig, id, kindIndexOf(car.kind), false)
			rig.lane = car.lane
			rig.speed = car.speed
		end
	end
end

-- A hit on a car: by you (link 0), by a car you sent flying (link 1 to 3), or by someone else
-- (mine false: it only gets knocked loose, and its touches report nothing)
function Traffic.hit(pool: Pool, rig: Rig, impact: number, link: number, mine: boolean)
	if rig.id == nil or rig.state == "free" then
		return
	end
	local t = os.clock()
	rig.lastHit = t
	if mine then
		rig.mine = true
		rig.link = math.min(rig.link, link)
	end
	local soft = rig.tutorial
	if impact >= cfg.wreck.double then
		rig.hard += 1
	end
	local wreckAt = if soft then TUTORIAL_WRECK else cfg.wreck.single
	if rig.state ~= "wreck" and (impact >= wreckAt or rig.hard >= 2) then
		rig.state = "wreck"
		rig.wreckedAt = t
		rig.lv.Enabled = false
		rig.align.Enabled = false
		setDynamic(rig, true)
		rig.body.Color = rig.body.Color:Lerp(Color3.fromRGB(60, 55, 50), 0.35)
		local tag = rig.body:FindFirstChild("Smash")
		if tag then
			tag:Destroy() -- the tutorial's SMASH! label
		end
	elseif rig.state == "lane" or rig.state == "stagger" then
		rig.state = "stagger"
		rig.staggerUntil = t + tcfg.stagger
		rig.lv.Enabled = false
		rig.align.Enabled = false
		setDynamic(rig, true)
	end
	if impact >= cfg.explode.impact and not rig.exploding then
		Traffic.armBlast(pool, rig)
	end
end

function Traffic.armBlast(pool: Pool, rig: Rig)
	rig.exploding = true
	local id = rig.id
	task.delay(cfg.explode.delay, function()
		if rig.id ~= id or rig.state == "free" then
			return
		end
		Traffic.blast(pool, rig)
	end)
end

-- The car blows up: it is thrown, everything near is pushed, and cars within 8 studs go off too
function Traffic.blast(pool: Pool, rig: Rig)
	local position = rig.body.Position
	rig.body.Color = Color3.fromRGB(40, 36, 34)
	rig.cabin.Transparency = 0.6
	if rig.state ~= "wreck" then
		rig.state = "wreck"
		rig.wreckedAt = os.clock()
		rig.lv.Enabled = false
		rig.align.Enabled = false
		setDynamic(rig, true)
	end
	rig.body:ApplyImpulse(Vector3.new(0, 40, 0) * rig.body.AssemblyMass)
	local shock = Config.Damage.shockwave
	for _, other in pool.rigs do
		if other == rig or other.id == nil or other.state == "free" then
			continue
		end
		local offset = other.body.Position - position
		local distance = offset.Magnitude
		if distance > shock.radius then
			continue
		end
		local fall = 1 - distance / shock.radius
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local outward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.xAxis
		local link = math.min(rig.link + 1, 3)
		local yours = rig.mine and rig.link < 3
		Traffic.hit(pool, other, 30 + 40 * fall, link, yours)
		other.body:ApplyImpulse(
			(outward * shock.push * fall + Vector3.new(0, shock.up, 0)) * other.body.AssemblyMass
		)
		if yours and other.id then
			pool.o.report(
				if other.tutorial then TUTORIAL_KIND else 0,
				other.id,
				30 + 40 * fall,
				link,
				other.body.Position
			)
		end
		if distance <= cfg.explode.radius and not other.exploding then
			Traffic.armBlast(pool, other)
		end
	end
	pool.o.onBlast(position)
end

-- BOOM (Wreck Mode): every car within radius is thrown and counts as yours (link 1); the near ones go off too
function Traffic.boom(pool: Pool, position: Vector3, radius: number)
	for _, rig in pool.rigs do
		if rig.id == nil or rig.state == "free" then
			continue
		end
		local offset = rig.body.Position - position
		local distance = offset.Magnitude
		if distance > radius then
			continue
		end
		local fall = 1 - distance / radius
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local outward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.xAxis
		local impact = math.min(30 + 50 * fall, cfg.score.maxImpact)
		Traffic.hit(pool, rig, impact, 1, true)
		rig.body:ApplyImpulse(
			(outward * 90 * fall + Vector3.new(0, 35 + 40 * fall, 0)) * rig.body.AssemblyMass
		)
		pool.o.report(if rig.tutorial then TUTORIAL_KIND else 0, rig.id, impact, 1, rig.body.Position)
		pool.o.onSmash(rig, impact, rig.body.Position)
		if distance <= radius * 0.5 and not rig.exploding then
			Traffic.armBlast(pool, rig)
		end
	end
end

-- A car you sent flying hit something: a chain hit for you
function Traffic.onRigTouched(pool: Pool, rig: Rig, other: BasePart)
	if rig.id == nil or not rig.mine or rig.link >= 3 or rig.state == "lane" then
		return
	end
	local otherId = other:GetAttribute("TrafficCar")
	local propId = other:GetAttribute("HighwayProp")
	if otherId == nil and propId == nil then
		return
	end
	local key = if otherId then "c" .. tostring(otherId) else "p" .. tostring(propId)
	local t = os.clock()
	if t - (rig.pairs[key] or -math.huge) < PAIR_COOLDOWN then
		return
	end
	local relative = (rig.body.AssemblyLinearVelocity - other.AssemblyLinearVelocity).Magnitude
	if relative < CHAIN_MIN then
		return
	end
	rig.pairs[key] = t
	local link = rig.link + 1
	local impact = math.min(relative, cfg.score.maxImpact)
	if otherId then
		local target = pool.byId[otherId :: number]
		if target == nil or target == rig then
			return
		end
		Traffic.hit(pool, target, impact, link, true)
		pool.o.report(
			if target.tutorial then TUTORIAL_KIND else 0,
			otherId :: number,
			impact,
			link,
			other.Position
		)
		pool.o.onSmash(target, impact, other.Position)
	else
		pool.o.report(1, propId :: number, impact, link, other.Position)
	end
end

-- Another player wrecked this car on their device: knock ours loose too (no reports)
function Traffic.foreignWreck(pool: Pool, id: number)
	local rig = pool.byId[id]
	if rig and rig.state ~= "wreck" then
		Traffic.hit(pool, rig, cfg.wreck.single, 9, false)
		rig.body:ApplyImpulse(Vector3.new(0, 15, 0) * rig.body.AssemblyMass)
	end
end

function Traffic.rigOf(pool: Pool, part: BasePart): Rig?
	local id = part:GetAttribute("TrafficCar")
	if id == nil then
		return nil
	end
	local rig = pool.byId[id :: number]
	if rig and rig.body == part then
		return rig
	end
	return nil
end

-- Every frame: move the gliding cars, steer the physics ones, clear old wrecks. s: your place on the road.
function Traffic.update(pool: Pool, dt: number, s: number, position: Vector3)
	pool.wantTimer += dt
	if pool.wantTimer >= 0.1 then
		pool.wantTimer = 0
		refreshWanted(pool, s)
	end
	local t = os.clock()
	-- The nearest few in lane are physics bodies
	local near: { { rig: Rig, d: number } } = {}
	for _, rig in pool.rigs do
		if rig.id and (rig.state == "lane" or rig.state == "stagger") then
			local d = (rig.body.Position - position).Magnitude
			if d <= tcfg.physicsRange then
				table.insert(near, { rig = rig, d = d })
			end
		end
	end
	table.sort(near, function(a, b)
		return a.d < b.d
	end)
	local physics: { [Rig]: boolean } = {}
	for i = 1, math.min(tcfg.physics, #near) do
		physics[near[i].rig] = true
	end
	for _, rig in pool.rigs do
		local id = rig.id
		if id == nil or rig.state == "free" then
			continue
		end
		if rig.state == "wreck" then
			-- Cleared a while after wrecking, or once far behind you
			local behind = (rig.body.Position - position).Magnitude > tcfg.behind + 100
			if
				t - rig.wreckedAt > tcfg.despawnAfter
				or behind
				or rig.body.Position.Y < pool.def.origin[2] - 60
			then
				release(pool, rig)
			end
			continue
		end
		local slotS, lateral = Traffic.slot(pool, rig)
		if slotS == nil then
			release(pool, rig)
			continue
		end
		if rig.state == "stagger" then
			if t < rig.staggerUntil then
				continue
			end
			rig.state = "lane"
		end
		local forward, right, h = forwardAt(pool.def, slotS)
		local laneSpeed = rig.speed
		if physics[rig] or rig.dynamic and rig.lastHit > t - 4 then
			if not rig.dynamic then
				setDynamic(rig, true, forward * laneSpeed)
			end
			-- Hold the lane: speed toward the slot, a pull back to the lane centre, upright along the road
			local pos = rig.body.Position
			local atS, atLateral = HighwayMath.locate(pool.def, pos.X, pos.Z)
			local along = laneSpeed + math.clamp((slotS - atS) * 0.8, -15, 15)
			local side = math.clamp((lateral - atLateral) * 1.5, -8, 8)
			local v = forward * along + right * side
			rig.lv.PlaneVelocity = Vector2.new(v.X, v.Z)
			rig.lv.Enabled = true
			rig.align.CFrame = CFrame.Angles(0, -h, 0)
			rig.align.Enabled = true
			-- Stuck or thrown far from its slot (and not hit lately): put it back
			local off = math.abs(slotS - atS) + math.abs(lateral - atLateral)
			if off > 40 and t - rig.lastHit > 4 then
				setDynamic(rig, false)
				rig.lv.Enabled = false
				rig.align.Enabled = false
				rig.body.CFrame = poseAt(pool, rig, slotS, lateral)
			end
		else
			if rig.dynamic then
				setDynamic(rig, false)
				rig.lv.Enabled = false
				rig.align.Enabled = false
			end
			rig.body.CFrame = poseAt(pool, rig, slotS, lateral)
		end
	end
end

function Traffic.destroy(pool: Pool)
	pool.folder:Destroy()
	table.clear(pool.rigs)
	table.clear(pool.byId)
end

return Traffic
