-- HighwayClient: Highway Havoc on this device (spec: Highway Havoc; Bone breaks; Highway screens;
-- Other modes' first 30 seconds). The server (HighwayService) owns the score; this builds the world and
-- does everything that has to feel instant.
-- * Highway.Seed gives the server's seed and clock: the road (Highway/Road) and traffic (Highway/Traffic)
--   are built here around your car, the same on every device. Highway.Start starts a run; the car
--   drops on the road already doing 50 studs/s.
-- * Hits: your car's impacts with traffic (and versus players), touches with props, and chain hits from
--   cars you sent flying are reported (Highway.Hit) and popped at once from the same maths the server
--   uses (Shared/Score); Highway.Score brings the confirmed totals. Reports stay under the remote's
--   rate limit.
-- * Tricks: near misses (2 studs or closer at 70+), air time and flips landed on the wheels.
-- * Bone breaks: a Hard hit or Huge crash at I 45+ in the seat, or a thrown rider's piece hitting
--   anything at 40+, asks the server to break a bone there (Bone.Break). A confirmed break freezes the
--   frame for 0.2 s, cracks the piece, puffs stars and flashes the X-ray (a glow with Fewer flashes).
--   The 12th is the Full Crack finale: the crash replay and the whole skeleton.
-- * Thrown riders climb back into the car where it is (1.5 s); meanwhile it holds its lane at 50.
-- * Pit Wrenches heal 30 and put one lost wheel back. RESET goes to your lane, where you are.
-- * Co-op: other players' cars do no damage; versus: bumping them scores.
-- * Ride then Wreck (nate, 2026-11-15): the ride scores distance (more near top speed) and near misses
--   while traffic thickens; a scrape is fine, but a traffic hit at I 22+, a Huge crash, being thrown or a
--   hard versus bump ends it (Highway.Trick "crash"). Then 10 s of Wreck Mode: smash everything, and
--   BOOM once (G, RB or the button) to blow the car up and throw everything near it.
-- * The tutorial lane (first run): a quiet road of your own with one slow car to steer around.
-- * Results, RIDE AGAIN, LEAVE (HUB) and the boards (TOP).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local HighwayMath = require(Shared.HighwayMath)
local Net = require(Shared.Net)
local NetSchema = require(Shared.NetSchema)
local Remotes = require(Shared.Remotes)
local Score = require(Shared.Score)

local Client = script.Parent.Parent
local ExplosionFx = require(Client.Fx.ExplosionFx)
local HighwayHud = require(Client.Ui.HighwayHud)
local Clip = require(Client.Highway.Clip)
local Road = require(Client.Highway.Road)
local Traffic = require(Client.Highway.Traffic)
local TracksHud = require(Client.Ui.TracksHud)

local LocalPlayer = Players.LocalPlayer
local cfg = Config.Highway
local scfg = cfg.score

local HighwayClient = {}

local controllers: any = nil

type RunState = {
	id: number,
	def: HighwayMath.Road,
	event: { [string]: any }?,
	tutorial: boolean,
	lane: number,
	startAt: number,
	endsAt: number,
	s0: number,
	road: Road.Builder,
	traffic: Traffic.Pool?,
	mirror: Score.Run,
	broken: { [number]: number },
	clock: Score.BreakClock,
	near: { [number]: boolean },
	props: { [number]: boolean },
	over: boolean,
	lastRoadS: number,
	checkpointTimer: number,
	air: number,
	spin: number,
	clip: Clip.Recorder,
	clipping: boolean,
	opts: HighwayMath.TrafficOpts,
	phase: string, -- "ride" or "wreck"
	wreckEndsAt: number,
	boomUsed: boolean,
	meters: number,
	lastSpeedX: number,
}

local seed: { seed: number, epoch: number, event: string?, versus: boolean }? = nil
local run: RunState? = nil
local lastResult: { [string]: any }? = nil
local boardState: { [string]: any } = { board = "score", tab = "daily", loading = false, rows = {} }
local riderTouches: { RBXScriptConnection } = {}
local riderVelocity: { [BasePart]: Vector3 } = {}
local chassisTouch: RBXScriptConnection? = nil
local buckets: { [string]: any } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function playerGui(): Instance
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function eventDef(id: string?): { [string]: any }?
	if id == nil then
		return nil
	end
	for _, e in cfg.events do
		if e.id == id then
			return e
		end
	end
	return nil
end

-- Stay under each remote's rate limit (a dropped call counts against you on the server)
local function send(name: string, ...: any): boolean
	local def = Remotes[name]
	local rate = (def and def.rate or 1) * 0.9
	local burst = math.max(1, (def and def.burst or 1) - 1)
	local bucket = buckets[name]
	local t = os.clock()
	if bucket == nil then
		bucket = NetSchema.newBucket(burst, t)
		buckets[name] = bucket
	end
	if not NetSchema.take(bucket, rate, burst, t) then
		return false
	end
	Net.send(name, ...)
	return true
end

local function myChassis(): BasePart?
	return controllers.Vehicle.getChassis()
end

local function live(): boolean
	return run ~= nil and not (run :: RunState).over
end

---------------------------------------------------------------------------
-- Points (popped here, confirmed by the server)
---------------------------------------------------------------------------

local function popPoints(points: number, at: Vector3?)
	if points <= 0 then
		return
	end
	Clip.addPoints((run :: RunState).clip, points)
	local m = Score.currentMultiplier((run :: RunState).mirror, now(), scfg)
	local color = if m >= 5
		then Color3.fromRGB(255, 120, 200)
		elseif m >= 3 then Color3.fromRGB(255, 180, 60)
		else nil
	HighwayHud.pop(playerGui(), "+" .. HighwayHud.commas(points), color, at)
end

-- Report a hit and pop its points. kind: 0 traffic, 1 prop, 2 player, 3 tutorial car
local function report(kind: number, id: number, impact: number, link: number, point: Vector3)
	local r = run
	if r == nil or r.over then
		return
	end
	impact = math.clamp(impact, 0, scfg.maxImpact)
	local base = 0
	if kind == 0 then
		local car = HighwayMath.car(r.def, id, now() - (seed :: any).epoch, cfg.traffic, r.opts)
		base = if car then car.kind.base else 0
	elseif kind == 1 then
		if r.props[id] then
			return
		end
		local prop = HighwayMath.prop(r.def, id, cfg.props)
		base = if prop then prop.kind.base else 0
	elseif kind == 2 then
		base = scfg.player.base
	elseif kind == 3 then
		base = cfg.traffic.types[1].base
	end
	if base <= 0 then
		return
	end
	-- Your own hits are always sent; chain hits only while there is room under the rate limit
	if not send("Highway.Hit", kind, id, math.floor(impact * 10 + 0.5) / 10, link) then
		return
	end
	if kind == 1 then
		r.props[id] = true
	end
	local before = Score.currentMultiplier(r.mirror, now(), scfg)
	local points = Score.hit(r.mirror, now(), base, impact, link, scfg)
	popPoints(points, point)
	local after = Score.currentMultiplier(r.mirror, now(), scfg)
	if after > before then
		controllers.Juice.fire("ComboUp", { pitch = 0.9 + after * 0.06 })
	end
end

---------------------------------------------------------------------------
-- Bones
---------------------------------------------------------------------------

local function askBone(preferred: { number }, impact: number)
	local r = run
	if r == nil or r.over then
		return
	end
	local t = now()
	if not Score.mayBreak(r.clock, t, cfg.bones) then
		return
	end
	local piece = Score.pickPiece(r.broken, preferred)
	if piece == nil then
		return
	end
	if send("Bone.Break", piece, math.min(impact, 1000)) then
		Score.noteBreak(r.clock, t, cfg.bones)
	end
end

-- A crack drawn on the rider's piece, and three stars puffing off it
local function crackFx(part: BasePart)
	local surface = Instance.new("SurfaceGui")
	surface.Name = "Crack"
	surface.Face = Enum.NormalId.Front
	surface.AlwaysOnTop = false
	surface.CanvasSize = Vector2.new(100, 100)
	surface.Parent = part
	for i = 1, 3 do
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.fromScale(0.35 + i * 0.1, 0.3 + i * 0.15)
		line.Size = UDim2.fromScale(0.45, 0.06)
		line.Rotation = if i % 2 == 0 then -35 else 35
		line.BackgroundColor3 = Color3.fromRGB(40, 30, 30)
		line.BorderSizePixel = 0
		line.Parent = surface
	end
	task.delay(4, function()
		surface:Destroy()
	end)
	for i = 1, 3 do
		local star = Instance.new("Part")
		star.Name = "Star"
		star.Shape = Enum.PartType.Ball
		star.Size = Vector3.one * 0.6
		star.Color = Color3.fromRGB(255, 230, 80)
		star.Material = Enum.Material.Neon
		star.Anchored = true
		star.CanCollide = false
		star.CanQuery = false
		star.CanTouch = false
		star.CFrame = part.CFrame
		star.Parent = Workspace
		local angle = i * math.pi * 2 / 3
		local goal = part.Position + Vector3.new(math.cos(angle) * 2.5, 2 + i * 0.3, math.sin(angle) * 2.5)
		TweenService:Create(star, TweenInfo.new(0.6, Enum.EasingStyle.Quad), {
			Position = goal,
			Size = Vector3.one * 0.1,
			Transparency = 0.6,
		}):Play()
		task.delay(0.65, function()
			star:Destroy()
		end)
	end
end

local function riderPart(piece: number): BasePart?
	local parts = controllers.Ragdoll.getLocalParts()
	return parts and parts[Score.PIECES[piece]]
end

local function glowRider(duration: number)
	local part = riderPart(2)
	local model = part and part.Parent
	if model == nil then
		return
	end
	local glow = Instance.new("Highlight")
	glow.FillColor = Color3.fromRGB(255, 240, 200)
	glow.FillTransparency = 0.4
	glow.OutlineColor = Color3.fromRGB(255, 120, 90)
	glow.Parent = model
	task.delay(duration, function()
		glow:Destroy()
	end)
end

local function xray(duration: number)
	local r = run :: RunState
	if controllers.Settings.get("reducedFlash") then
		glowRider(duration)
	else
		HighwayHud.xray(playerGui(), r.broken, duration)
	end
	controllers.Juice.fire("XRay")
end

local function onBone(e: { [string]: any })
	local r = run
	if r == nil then
		return
	end
	local piece = e.piece :: number
	r.broken[piece] = (r.broken[piece] or 0) + 1
	r.mirror.breaks = e.count
	-- Hit-stop on the crack
	controllers.Vehicle.freezeRender(cfg.bones.freeze)
	controllers.Camera.freeze(cfg.bones.freeze)
	local part = riderPart(piece)
	if part then
		crackFx(part)
	end
	controllers.Juice.fire("BoneCrack", { point = part and part.Position })
	if e.count >= cfg.bones.total then
		-- Full Crack: the replay and the whole skeleton
		HighwayHud.banner(
			playerGui(),
			"FULL CRACK!",
			"All 12 bones! What a ride!",
			Color3.fromRGB(255, 120, 90)
		)
		xray(cfg.bones.finale)
		controllers.CrashReplay.playNow()
	else
		xray(cfg.bones.xray)
		HighwayHud.banner(
			playerGui(),
			"CRACK!",
			string.format("%s  (%d / %d)", e.bone, e.count, cfg.bones.total),
			Color3.fromRGB(255, 240, 200)
		)
	end
	popPoints(e.points or 0, part and part.Position)
end

local function clearRiderTouches()
	for _, c in riderTouches do
		c:Disconnect()
	end
	table.clear(riderTouches)
	table.clear(riderVelocity)
end

-- A thrown rider: any piece hitting something hard breaks a bone there
local function watchRider()
	clearRiderTouches()
	local parts = controllers.Ragdoll.getLocalParts()
	if parts == nil then
		return
	end
	for index, name in Score.PIECES do
		local part = parts[name]
		if part == nil then
			continue
		end
		table.insert(
			riderTouches,
			part.Touched:Connect(function(other: BasePart)
				if not live() or other:IsDescendantOf(part.Parent :: Instance) then
					return
				end
				local before = riderVelocity[part] or part.AssemblyLinearVelocity
				local speed = (before - other.AssemblyLinearVelocity).Magnitude
				if speed >= cfg.bones.ejectSpeed then
					askBone({ index }, speed)
				end
			end)
		)
	end
end

---------------------------------------------------------------------------
-- The crash and Wreck Mode
---------------------------------------------------------------------------

local boom: () -> ()

-- The ride is over: Wreck Mode starts here at once (the server confirms with "wreckStart")
local function crash(why: string)
	local r = run
	if r == nil or r.over or r.phase ~= "ride" then
		return
	end
	r.phase = "wreck"
	r.wreckEndsAt = now() + cfg.ride.wreckLength
	if why ~= "traffic" then
		send("Highway.Trick", "crash", 0, 0)
	end
	HighwayHud.banner(playerGui(), "WRECK MODE!", "Smash everything you can!", Color3.fromRGB(255, 120, 90))
	controllers.Camera.shake(0.8, 0.4)
	HighwayHud.boom(playerGui(), boom)
end

-- BOOM: once per wreck, the car blows up and throws everything near it
boom = function()
	local r = run
	local chassis = myChassis()
	if r == nil or r.over or r.phase ~= "wreck" or r.boomUsed or chassis == nil then
		return
	end
	r.boomUsed = true
	HighwayHud.boom(playerGui(), nil)
	controllers.Damage.detonate()
	if r.traffic then
		Traffic.boom(r.traffic, chassis.Position, cfg.ride.boomRadius)
	end
	controllers.Camera.pull(0.8, 1.6)
end

---------------------------------------------------------------------------
-- Hits from your car
---------------------------------------------------------------------------

local function ownerOf(part: BasePart): number?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local id = model:GetAttribute("OwnerUserId")
		if id then
			return id :: number
		end
		model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function onImpact(info: { [string]: any })
	local r = run
	if r == nil or r.over then
		return
	end
	local other = info.other :: BasePart?
	local versus = seed ~= nil and seed.versus
	local riding = r.phase == "ride"
	if other then
		local rig = r.traffic and Traffic.rigOf(r.traffic, other)
		if rig and rig.id and riding and info.impact < cfg.ride.crashImpact then
			-- A scrape: the car gets a nudge, the ride goes on
			Traffic.hit(r.traffic :: Traffic.Pool, rig, info.impact, 0, false)
			HighwayHud.pop(playerGui(), "SCRAPE!", Color3.fromRGB(255, 240, 200), info.point, 0.04)
			controllers.Camera.shake(0.3, 0.2)
			return
		end
		if rig and rig.id and riding then
			crash("traffic")
		end
		if rig and rig.id then
			Traffic.hit(r.traffic :: Traffic.Pool, rig, info.impact, 0, true)
			report(if rig.tutorial then 3 else 0, rig.id, info.impact, 0, info.point)
			controllers.Juice.fire(
				"Smash",
				{ point = info.point, scale = math.clamp(info.impact / 60, 0.4, 1.5) }
			)
		else
			local owner = ownerOf(other)
			if owner and owner ~= LocalPlayer.UserId then
				if not versus then
					return -- co-op: bumping a friend does nothing
				end
				if riding then
					if info.impact >= cfg.ride.crashImpact then
						crash("player")
					end
					return
				end
				report(2, owner, info.impact, 0, info.point)
			end
		end
	end
	-- A Huge crash into anything (a wall, a ramp, the ground) ends the ride
	if riding and info.tier == "HugeCrash" and info.side ~= "Bottom" then
		crash("crash")
	end
	-- Bones in the seat
	if
		controllers.Vehicle.isDriverPresent()
		and info.impact >= cfg.bones.seatImpact
		and (info.tier == "HardHit" or info.tier == "HugeCrash")
	then
		askBone(Score.piecesFor(info.side), info.impact)
	end
end

local function onChassisTouched(other: BasePart)
	local r = run
	if r == nil or r.over then
		return
	end
	local id = other:GetAttribute("HighwayProp")
	if id == nil or r.props[id :: number] then
		return
	end
	local chassis = myChassis()
	if chassis == nil then
		return
	end
	local velocity = chassis.AssemblyLinearVelocity
	report(1, id :: number, velocity.Magnitude, 0, other.Position)
	Road.breakProp(r.road, id :: number, velocity * 0.9)
	controllers.Juice.fire("Smash", { point = other.Position, scale = 0.4, volume = 0.4 })
end

---------------------------------------------------------------------------
-- Tricks
---------------------------------------------------------------------------

local function checkNearMisses(r: RunState, chassis: BasePart)
	local pool = r.traffic
	if pool == nil or r.phase ~= "ride" then
		return
	end
	local speed = chassis.AssemblyLinearVelocity.Magnitude
	if speed < scfg.nearMiss.speed then
		return
	end
	local half = chassis.Size / 2
	for _, rig in pool.rigs do
		local id = rig.id
		if id == nil or rig.state ~= "lane" or rig.mine or r.near[id] then
			continue
		end
		local offset = rig.body.CFrame:PointToObjectSpace(chassis.Position)
		local size = rig.body.Size
		if math.abs(offset.Z) > size.Z / 2 then
			continue -- not alongside
		end
		local gap = math.abs(offset.X) - size.X / 2 - half.X
		if gap > 0 and gap <= scfg.nearMiss.gap then
			r.near[id] = true
			if send("Highway.Trick", "near", id, math.min(speed, 300)) then
				local points = Score.nearMiss(r.mirror, now(), scfg)
				Clip.addPoints(r.clip, points)
				HighwayHud.pop(
					playerGui(),
					"NEAR MISS +" .. points,
					Color3.fromRGB(160, 230, 255),
					nil,
					0.045
				)
				controllers.Juice.fire("NearMiss")
			end
		end
	end
end

local function checkAir(r: RunState, dt: number)
	local state = controllers.Vehicle.getState()
	if state == nil or not controllers.Vehicle.isDriverPresent() then
		r.air, r.spin = 0, 0
		return
	end
	local chassis = state.chassis :: BasePart
	if state.groundedCount <= 1 then
		r.air += dt
		local w = chassis.AssemblyAngularVelocity
		local cf = chassis.CFrame
		-- Spin about the car's own pitch and roll axes (yaw doesn't count)
		r.spin += (math.abs(w:Dot(cf.RightVector)) + math.abs(w:Dot(cf.LookVector))) * dt
		return
	end
	if r.air >= scfg.air.every then
		local seconds = r.air
		local flips = math.floor(r.spin / (math.pi * 2 * 0.85))
		local landedUpright = chassis.CFrame.UpVector.Y > 0.7
		if send("Highway.Trick", "air", 0, math.min(seconds, 300)) then
			local points = Score.trick(r.mirror, now(), Score.airPoints(seconds, scfg), scfg)
			if points > 0 then
				HighwayHud.pop(playerGui(), "AIR +" .. points, Color3.fromRGB(160, 230, 255), nil, 0.045)
			end
			if flips >= 1 and landedUpright and send("Highway.Trick", "flip", 0, flips) then
				local flipPoints = Score.trick(r.mirror, now(), Score.flipPoints(flips, scfg), scfg)
				HighwayHud.banner(
					playerGui(),
					if flips > 1 then flips .. "x FLIP!" else "FLIP!",
					"+" .. flipPoints,
					Color3.fromRGB(190, 120, 255)
				)
				controllers.Juice.fire("Trick")
			end
		end
	end
	r.air, r.spin = 0, 0
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

local function laneFrame(r: RunState, s: number, lane: number): CFrame
	return Road.frame(r.def, s, HighwayMath.laneOffset(r.def, lane), 0)
end

local function endVisuals()
	local r = run
	if r == nil then
		return
	end
	if r.traffic then
		Traffic.destroy(r.traffic)
	end
	Road.destroy(r.road)
	HighwayHud.run(playerGui(), nil)
	run = nil
end

-- The car keeps its lane while the rider is thrown: steer to the lane centre, hold 50
local function autopilot(_dt: number)
	local r = run
	local chassis = myChassis()
	if r == nil or chassis == nil then
		return nil
	end
	local pos = chassis.Position
	local s, lateral = HighwayMath.locate(r.def, pos.X, pos.Z)
	local lane = HighwayMath.laneAt(r.def, lateral)
	local ahead = laneFrame(r, s + 25, lane).Position
	local localAhead = chassis.CFrame:PointToObjectSpace(ahead)
	local steer = math.clamp(localAhead.X / 12, -1, 1)
	local speed = -chassis.CFrame:VectorToObjectSpace(chassis.AssemblyLinearVelocity).Z
	local want = cfg.startSpeed
	return {
		throttle = if speed < want then 0.7 else 0,
		brake = if speed > want + 15 then 0.3 else 0,
		steer = steer,
		lean = 0,
		handbrake = false,
		analogSteer = true,
	}
end

local function makeTraffic(r: RunState, chassis: BasePart)
	local epoch = (seed :: any).epoch
	r.traffic = Traffic.new(r.def, {
		opts = r.opts,
		epoch = epoch,
		tutorial = if r.tutorial then { s0 = r.s0, startAt = r.startAt, lane = r.lane } else nil,
		refMass = chassis.AssemblyMass,
		report = report,
		onBlast = function(position: Vector3)
			ExplosionFx.play(position)
			controllers.Damage.shockwave(position)
			-- Props near the blast fly too (and count as chain hits)
			for id, entry in r.road.props do
				local p = entry.parts[1]
				if p and (p.Position - position).Magnitude <= Config.Damage.shockwave.radius then
					report(1, id, 50, 1, p.Position)
					local away = p.Position - position
					local push = if away.Magnitude > 0.01 then away.Unit * 40 else Vector3.new(0, 40, 0)
					Road.breakProp(r.road, id, push)
				end
			end
		end,
		onSmash = function(_rig, impact: number, point: Vector3)
			controllers.Juice.fire(
				"Smash",
				{ point = point, scale = math.clamp(impact / 80, 0.3, 1), volume = 0.4 }
			)
		end,
	})
	if r.tutorial then
		-- SMASH! over the practice cars
		task.defer(function()
			local pool = r.traffic
			if pool == nil then
				return
			end
			Traffic.update(pool, 0, r.s0, chassis.Position)
			for _, rig in pool.rigs do
				if rig.tutorial and rig.id then
					local tag = Instance.new("BillboardGui")
					tag.Name = "Smash"
					tag.Size = UDim2.fromOffset(140, 50)
					tag.StudsOffset = Vector3.new(0, 6, 0)
					tag.AlwaysOnTop = true
					tag.Parent = rig.body
					local label = Instance.new("TextLabel")
					label.BackgroundTransparency = 1
					label.Size = UDim2.fromScale(1, 1)
					label.Font = Enum.Font.FredokaOne
					label.TextScaled = true
					label.Text = "DODGE!"
					label.TextColor3 = Color3.fromRGB(255, 205, 40)
					label.TextStrokeTransparency = 0
					label.Parent = tag
				end
			end
		end)
	end
end

local function onSpawned(model: Model)
	local r = run
	if r == nil then
		return
	end
	if chassisTouch then
		chassisTouch:Disconnect()
		chassisTouch = nil
	end
	local chassis = model.PrimaryPart
	if chassis == nil then
		return
	end
	chassisTouch = chassis.Touched:Connect(onChassisTouched)
	-- Already rolling at 50 studs/s, in your lane
	local cf = laneFrame(r, r.s0, r.lane) + Vector3.new(0, controllers.Vehicle.rideHeight() + 0.3, 0)
	controllers.Vehicle.placeAt(cf, cf.LookVector * cfg.startSpeed)
	controllers.Vehicle.setCheckpoint(laneFrame(r, r.s0, r.lane), 0)
	if r.traffic == nil then
		makeTraffic(r, chassis)
	end
end

local function onStart(msg: { [string]: any })
	if seed == nil then
		return
	end
	endVisuals()
	HighwayHud.hideResults()
	HighwayHud.closeBoard()
	local tutorial = msg.tutorial == true
	local def = HighwayMath.road(
		seed.seed,
		cfg.road,
		if tutorial then { origin = msg.origin, lanes = msg.lanes } else nil
	)
	local event = if tutorial then nil else eventDef(msg.event)
	-- The tutorial lane has a ramp ahead of the practice cars
	local extra = if tutorial then { { index = -1, s = msg.s + cfg.tutorial.rampAt, lane = 1 } } else nil
	local builder = Road.new(def, event :: any, extra)
	Road.update(builder, msg.s)
	local opts = HighwayMath.runOpts(
		event :: any,
		if tutorial then cfg.tutorial.quiet else nil,
		msg.s,
		msg.t0 or (msg.startAt - seed.epoch),
		cfg.ride.density
	)
	run = {
		id = msg.run,
		def = def,
		event = event,
		tutorial = tutorial,
		lane = msg.lane,
		startAt = msg.startAt,
		endsAt = msg.endsAt,
		s0 = msg.s,
		road = builder,
		traffic = nil,
		mirror = Score.newRun(),
		broken = {},
		clock = Score.newBreakClock(),
		near = {},
		props = {},
		over = false,
		lastRoadS = msg.s,
		checkpointTimer = 0,
		air = 0,
		spin = 0,
		clip = Clip.newRecorder(),
		clipping = false,
		opts = opts,
		phase = "ride",
		wreckEndsAt = math.huge,
		boomUsed = false,
		meters = 0,
		lastSpeedX = 1,
	}
	HighwayHud.boom(playerGui(), nil)
	controllers.Vehicle.setKillY(def.origin[2] - 40)
	if tutorial then
		TracksHud.showCue("DODGE THE TRAFFIC!", 2)
		TracksHud.toast("Go as far as you can! When you crash, smash everything for points.", 5)
	elseif event then
		TracksHud.showCue(event.name, 1.6)
		TracksHud.toast(event.line, 3)
	else
		TracksHud.showCue("GO AS FAR AS YOU CAN!", 1.6)
	end
	controllers.Juice.fire("Finish", { volume = 0.4 })
	-- The car may be there already (Ride again keeps it)
	local chassis = myChassis()
	if chassis and chassis.Parent then
		local model = chassis.Parent :: Model
		task.defer(onSpawned, model)
	end
end

local function onScore(msg: { [string]: any })
	local r = run
	if r == nil or msg.run ~= r.id then
		return
	end
	local m = r.mirror
	m.score = msg.score
	m.combo = msg.combo
	m.comboUntil = if msg.combo > 0 then msg.comboUntil else -math.huge
	m.breaks = msg.breaks
	m.bestMultiplier = msg.bestMultiplier
	r.meters = msg.meters or r.meters
	if msg.phase == "wreck" and r.phase == "ride" then
		crash("server")
	end
end

local function onEvent(e: { [string]: any })
	local kind = e.kind
	if kind == "wreckStart" then
		local r = run
		if r and e.run == r.id then
			if r.phase == "ride" then
				crash("server")
			end
			r.wreckEndsAt = e.endsAt or r.wreckEndsAt
			r.meters = e.meters or r.meters
			HighwayHud.pop(
				playerGui(),
				string.format("%s m ridden!", HighwayHud.commas(r.meters)),
				Color3.fromRGB(110, 200, 255),
				nil,
				0.05
			)
		end
	elseif kind == "bone" then
		onBone(e)
	elseif kind == "pileStart" then
		HighwayHud.pop(playerGui(), "PILE-UP BUILDING!", Color3.fromRGB(255, 180, 60), nil, 0.05)
	elseif kind == "pileup" then
		HighwayHud.banner(
			playerGui(),
			"PILE-UP!",
			string.format(
				"%d cars  +%s%s",
				e.cars or 0,
				HighwayHud.commas(e.points or 0),
				if e.by then "  (with " .. e.by .. ")" else ""
			),
			Color3.fromRGB(255, 180, 60)
		)
		controllers.Juice.fire("PileUp")
		if run then
			Clip.addPoints(run.clip, e.points or 0)
		end
		controllers.Camera.pull(0.6, 1.4) -- the camera pulls back over the wreck
	elseif kind == "wreck" then
		local r = run
		if r and r.traffic and not r.tutorial then
			Traffic.foreignWreck(r.traffic, e.id)
		end
	elseif kind == "meterFull" then
		HighwayHud.banner(
			playerGui(),
			"HAVOC METER FULL!",
			if (e.coins or 0) > 0
				then "+" .. e.coins .. " coins for helping!"
				else "Smash more to share the next one!",
			Color3.fromRGB(255, 120, 90)
		)
		controllers.Juice.fire("HavocFull")
	end
end

local TITLES = {
	timer = "WHAT A RIDE!",
	fullCrack = "FULL CRACK!",
	wrecked = "WRECKED!",
	left = "RUN OVER",
}

local function drawBoard()
	HighwayHud.openBoard(playerGui(), {
		board = boardState.board,
		tab = boardState.tab,
		rows = boardState.rows or {},
		mine = boardState.mine,
		loading = boardState.loading,
		eventName = (eventDef(seed and seed.event) or {}).name,
		onBoard = function(board: string)
			boardState.board = board
			HighwayClient.openBoard()
		end,
		onTab = function(tab: string)
			boardState.tab = tab
			HighwayClient.openBoard()
		end,
	}, function() end)
end

-- TOP: the boards panel, asking the server for the tab shown
function HighwayClient.openBoard()
	boardState.loading = true
	boardState.rows = {}
	boardState.mine = nil
	if not send("Highway.Board", boardState.board, boardState.tab) then
		boardState.loading = false
	end
	drawBoard()
end

local function onBoardData(msg: { [string]: any })
	if msg.board ~= boardState.board or msg.tab ~= boardState.tab then
		return
	end
	boardState.loading = false
	boardState.rows = msg.rows or {}
	boardState.mine = msg.mine
	if HighwayHud.boardOpen() then
		drawBoard()
	end
end

-- CLIP: the run's best 10 s, then SHARE (a screen capture from its best moment) or DONE
local function playClip(r: RunState)
	local chassis = myChassis()
	local model = chassis and chassis.Parent
	if model == nil or not model:IsA("Model") then
		return
	end
	local captured: any = nil
	local clipS = -math.huge
	local function finish()
		HighwayHud.clipBar(playerGui(), nil, nil)
		HighwayHud.setResultsVisible(true)
		r.clipping = false
		r.lastRoadS = -math.huge -- rebuild the road around the car again
	end
	local function share()
		if captured == nil then
			return
		end
		controllers.Telemetry.send("clip_share", 1, "highway")
		local CaptureService = game:GetService("CaptureService") :: any
		local ok = pcall(function()
			CaptureService:PromptShareCapture(captured, "", function() end, function() end)
		end)
		if not ok then
			pcall(function()
				CaptureService:PromptSaveCapturesToGallery({ captured }, function() end)
			end)
		end
	end
	local playing = Clip.play(r.clip, {
		model = model :: Model,
		riderParts = controllers.Ragdoll.getLocalParts(),
		camera = controllers.Camera,
		hud = controllers.Hud,
		onPeak = function()
			-- The screen at the best moment (verify CaptureService on devices)
			pcall(function()
				local CaptureService = game:GetService("CaptureService") :: any
				CaptureService:CaptureScreenshot(function(contentId)
					captured = contentId
					HighwayHud.clipBar(playerGui(), share, function()
						Clip.stop(r.clip)
					end)
				end)
			end)
		end,
		onFrame = function(carCf: CFrame)
			local s = HighwayMath.locate(r.def, carCf.X, carCf.Z)
			if math.abs(s - clipS) > 20 then
				clipS = s
				Road.update(r.road, s)
			end
		end,
		onDone = finish,
	})
	if playing then
		r.clipping = true
		HighwayHud.setResultsVisible(false)
		HighwayHud.clipBar(playerGui(), nil, function()
			Clip.stop(r.clip)
		end)
	end
end

-- BEAT MY SCORE: a Roblox invite carrying your score (no text of yours: Roblox's own invite card)
local function challenge(score: number)
	local SocialService = game:GetService("SocialService")
	local okCan, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(LocalPlayer)
	end)
	if not okCan or not can then
		TracksHud.toast("Invites aren't available right now.", 3)
		return
	end
	pcall(function()
		local options = Instance.new("ExperienceInviteOptions")
		options.PromptMessage = "Challenge a friend to beat your Highway Havoc score!"
		options.LaunchData = HttpService:JSONEncode({ beat = math.floor(score), by = LocalPlayer.UserId })
		SocialService:PromptGameInvite(LocalPlayer, options)
	end)
end

local function showResults(msg: { [string]: any })
	local r = run
	local chestLine: string? = nil
	if msg.chest then
		chestLine = if msg.chest.item
			then "Havoc chest open: a new item for your garage!"
			else string.format("Havoc chest open: +%d coins!", msg.chest.coins or 0)
	end
	HighwayHud.showResults(playerGui(), {
		title = if msg.tutorial then "PRACTICE DONE!" else (TITLES[msg.reason] or "RUN OVER"),
		score = msg.score,
		bones = msg.bones,
		bestMultiplier = msg.bestMultiplier,
		pileups = msg.pileups,
		coins = msg.coins,
		capped = msg.capped,
		flagged = msg.flagged,
		best = msg.best,
		newBest = msg.newBest,
		havoc = msg.havoc,
		target = msg.target,
		chestLine = chestLine,
		tutorial = msg.tutorial,
		meters = msg.meters,
		bestMeters = msg.bestMeters,
		newBestMeters = msg.newBestMeters,
		ridePoints = msg.ridePoints,
		wreckPoints = msg.wreckPoints,
		line = if msg.tutorial
			then "Now for real: the full highway, with everyone!"
			elseif msg.challenge and msg.challenge.beaten then string.format(
				"You beat %s's %s!",
				msg.challenge.name,
				HighwayHud.commas(msg.challenge.score)
			)
			elseif msg.challenge then string.format(
				"%s's score to beat: %s",
				msg.challenge.name,
				HighwayHud.commas(msg.challenge.score)
			)
			else nil,
	}, {
		onAgain = function()
			send("Highway.Again")
		end,
		onLeave = function()
			HighwayClient.goHome()
		end,
		onBoard = function()
			HighwayClient.openBoard()
		end,
		onClip = if r and Clip.hasClip(r.clip)
			then function()
				playClip(r)
			end
			else nil,
		onChallenge = if not msg.tutorial and msg.score > 0
			then function()
				challenge(msg.score)
			end
			else nil,
	})
end

local function onEnd(msg: { [string]: any })
	local r = run
	if r == nil or msg.run ~= r.id then
		return
	end
	r.over = true
	lastResult = msg
	HighwayHud.boom(playerGui(), nil)
	controllers.Juice.fire("RunOver")
	controllers.Shop.close()
	local delay = if msg.reason == "fullCrack" then 0.2 else 0.6
	task.delay(delay, function()
		if run == r then
			showResults(msg)
		end
	end)
end

local function step(dt: number)
	local r = run
	if r == nil then
		return
	end
	local chassis = myChassis()
	local t = now()
	if chassis == nil or chassis.Parent == nil then
		return
	end
	local pos = chassis.Position
	local s, lateral = HighwayMath.locate(r.def, pos.X, pos.Z)
	if not r.clipping and math.abs(s - r.lastRoadS) > 5 then
		r.lastRoadS = s
		Road.update(r.road, s)
	end
	if r.traffic then
		Traffic.update(r.traffic, dt, s, pos)
	end
	-- Pit Wrenches
	local wrench = Road.stepWrenches(r.road, os.clock(), pos)
	if wrench and not r.over then
		Road.takeWrench(r.road, wrench)
		controllers.Damage.heal(cfg.wrench.heal, true)
		HighwayHud.pop(playerGui(), "PIT WRENCH!", Color3.fromRGB(255, 220, 60), pos, 0.05)
	end
	-- RESET and remounts come back to your lane, where you are
	r.checkpointTimer += dt
	if r.checkpointTimer >= 0.5 then
		r.checkpointTimer = 0
		local lane = HighwayMath.laneAt(r.def, lateral)
		controllers.Vehicle.setCheckpoint(laneFrame(r, math.max(s, 0), lane), 0)
	end
	if not r.over then
		checkNearMisses(r, chassis)
		checkAir(r, dt)
		-- BOOM from the keyboard or a gamepad (G, RB); the button does the same
		if controllers.Input.consume("action") and r.phase == "wreck" then
			boom()
		end
		-- The ride's speed multiplier (the server measures the same from your progress)
		local state = controllers.Vehicle.getState()
		local top = state and state.class.topSpeed or 100
		local speedX = if r.phase == "ride"
			then Score.speedTier(math.max(0, state and state.forwardSpeed or 0) / top, cfg.ride)
			else 1
		if speedX > r.lastSpeedX and r.phase == "ride" then
			HighwayHud.pop(playerGui(), "SPEED x" .. speedX, Color3.fromRGB(255, 205, 40), nil, 0.04)
		end
		r.lastSpeedX = speedX
		local mirror = r.mirror
		local left = math.max(0, mirror.comboUntil - t)
		local meterGoal = Workspace:GetAttribute("HavocGoal") or cfg.meter.goal
		HighwayHud.run(playerGui(), {
			timeLeft = r.endsAt - t,
			phase = r.phase,
			meters = r.meters,
			speedX = speedX,
			wreckLeft = r.wreckEndsAt - t,
			score = mirror.score,
			multiplier = Score.currentMultiplier(mirror, t, scfg),
			comboLeft = if Score.comboAlive(mirror, t) then left / scfg.comboWindow else 0,
			breaks = mirror.breaks,
			meter = (Workspace:GetAttribute("HavocMeter") or 0) / math.max(1, meterGoal :: number),
			event = r.event :: any,
			tutorial = r.tutorial,
		})
	end
	if not r.over then
		Clip.record(r.clip, dt, chassis, controllers.Ragdoll.getLocalParts(), r.traffic and r.traffic.rigs)
	end
	-- Rider piece velocities from the last frame (for thrown-rider bone breaks)
	if #riderTouches > 0 then
		local parts = controllers.Ragdoll.getLocalParts()
		if parts then
			for _, part in parts do
				riderVelocity[part] = part.AssemblyLinearVelocity
			end
		end
	end
end

function HighwayClient.goHome()
	send("Highway.Leave")
end

function HighwayClient.lastResult(): { [string]: any }?
	return lastResult
end

function HighwayClient.init(all)
	controllers = all
end

function HighwayClient.start()
	Net.listen("Highway.Seed", function(msg)
		if type(msg) == "table" then
			seed = msg
		end
	end)
	Net.listen("Highway.Start", onStart)
	Net.listen("Highway.Score", onScore)
	Net.listen("Highway.Event", onEvent)
	Net.listen("Highway.End", onEnd)
	Net.listen("Highway.BoardData", onBoardData)

	controllers.Ragdoll.setAutoRespawn(2)
	controllers.Vehicle.setRemountInPlace(true)
	controllers.Vehicle.setAutopilot(autopilot)
	controllers.Vehicle.Spawned:Connect(onSpawned)
	controllers.Vehicle.Impact:Connect(onImpact)
	controllers.Vehicle.Respawned:Connect(function()
		-- A RESET: back in your lane at speed
		local chassis = myChassis()
		if chassis and run then
			controllers.Vehicle.placeAt(chassis.CFrame, chassis.CFrame.LookVector * cfg.startSpeed)
		end
	end)
	controllers.Ragdoll.Ejected:Connect(function()
		watchRider()
		crash("thrown")
	end)
	controllers.Ragdoll.Respawned:Connect(clearRiderTouches)
	-- Co-op: other players' cars do no damage (versus keeps it)
	controllers.Damage.setImpactFilter(function(info): boolean
		if seed and seed.versus then
			return true
		end
		local other = info.other :: BasePart?
		if other == nil then
			return true
		end
		local owner = ownerOf(other)
		return owner == nil or owner == LocalPlayer.UserId
	end)
	RunService.Heartbeat:Connect(step)
end

return HighwayClient
