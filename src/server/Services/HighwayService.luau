-- HighwayService: Highway Havoc runs in Sunny Pass (spec: Game modes > Highway Havoc; Bone breaks;
-- Anti-exploit > Inflated Highway scores; Network model > Highway). The server owns the score.
-- Ride then Wreck (nate, 2026-11-15, replacing the spec's 3:30 timed smash run):
-- * The ride: go as far as you can through traffic without crashing. Distance scores (x2 and x3 near
--   your top speed), near misses score big, and traffic thickens the further you get. The server measures
--   the distance itself from your car's position (4 times a second, capped at what the car can do).
-- * The crash ends the ride: a traffic hit at I 22+ (lighter is a scrape), a Huge crash, being thrown, a
--   hard versus bump or blowing up. Then Wreck Mode: 10 s where everything you smash scores (combos,
--   chains, pile-ups, bone breaks) and BOOM blows your car up once. Then the results.
-- * One seed per server: every device builds the same road from it and the server clock
--   (Shared/HighwayMath). Traffic is the same maths, but each ride's density ramp starts where that ride
--   began, so each player's traffic is their own; in co-op other players' cars are ghosts.
--   Highway.Seed on join and when the UTC day (the daily event) changes.
-- * A first-timer's first ride is on the tutorial lane: a quiet copy of the road of their own.
-- * Hits: the hitter's device reports (kind, id, I, chain link). The server rebuilds where that traffic
--   car, prop or tutorial car should be and accepts only one near the player (12 studs plus what speed
--   and ping explain); a car already hit is tracked from where it was hit. Points come from Shared/Score,
--   capped at 2,000 a second and 3,000 an event. Too many rejected hits flag the run: half coins and no
--   board posts.
-- * Co-op: players bump without damage or points, and a pile-up pays everyone within 80 studs.
--   Versus: hitting a player scores 120 base (2 s per pair), and pile-ups pay the originator only.
-- * Pay at the end: 1 coin per 250 points (max 120), boosts, then the Highway daily cap (720, rising with
--   rebirths). Today's total toward the 15,000 Havoc target opens the daily Havoc chest once. The
--   server's Havoc meter fills with everyone's points and pays its contributors when full.
-- * Boards (Boards_v1): daily and weekly Destruction Score and Best Bone-Break Run, each with Friends.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Boards = require(Shared.Boards)
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local DamageModel = require(Shared.DamageModel)
local HighwayMath = require(Shared.HighwayMath)
local Net = require(Shared.Net)
local Place = require(Shared.Place)
local ProfileSchema = require(Shared.ProfileSchema)
local Quests = require(Shared.Quests)
local Score = require(Shared.Score)
local ShopMath = require(Shared.ShopMath)
local TracksMath = require(Shared.TracksMath)

local Services = script.Parent
local Analytics = require(Services.Analytics)
local BoardStore = require(Services.BoardStore)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local LiveCounts = require(Services.LiveCounts)
local QuestService = require(Services.QuestService)
local ShopService = require(Services.ShopService)
local TeleportHub = require(Services.TeleportHub)
local VehicleService = require(Services.VehicleService)

local HighwayService = {}

local cfg = Config.Highway
local BOARD_STORE = "Boards_v1"

type HitRecord = { hard: number, wrecked: boolean, at: number, x: number, z: number, base: number }
type Run = {
	id: number,
	road: HighwayMath.Road,
	tutorial: boolean,
	opts: HighwayMath.TrafficOpts,
	event: any,
	s0: number,
	lane: number,
	startAt: number,
	endsAt: number,
	over: boolean,
	ending: boolean,
	score: Score.Run,
	broken: { [number]: number },
	clock: Score.BreakClock,
	hits: { [string]: HitRecord },
	props: { [number]: boolean },
	near: { [number]: boolean },
	pairs: { [number]: number },
	lastAir: number,
	lastFlip: number,
	rejected: number,
	flagged: boolean,
	phase: string, -- "ride" or "wreck"
	lastS: number, -- the ride: where the car was at the last check
	lastCheck: number,
	lastProgress: number, -- when it last moved forward
	distance: number, -- studs ridden
	ridePoints: number,
	rideCarry: number, -- fractions of a point carried to the next check
	wreckEndsAt: number,
	why: string, -- what ended the ride
}

local versus = false
local seed = 0
local epoch = 0
local road: HighwayMath.Road
local today = 0
local event: any = nil
local runs: { [Player]: Run } = {}
local tutorialSlots: { [Player]: number } = {}
local nextRunId = 0
local dirty: { [Player]: boolean } = {}
local meter = 0
local contributions: { [Player]: number } = {}
local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function dayNumber(): number
	return ProfileSchema.dayNumber(os.time())
end

local function chassisOf(player: Player): BasePart?
	local model = VehicleService.getVehicle(player)
	return model and model.PrimaryPart
end

local function active(run: Run?): boolean
	return run ~= nil and not run.over and not run.ending
end

local function vehicleFor(player: Player): string
	local profile = DataService.get(player)
	if profile and VehicleService.mayDrive(player, profile.equippedVehicle) then
		return profile.equippedVehicle
	end
	return Config.DefaultVehicle
end

local function flatDistance(x1: number, z1: number, x2: number, z2: number): number
	return math.sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2)
end

---------------------------------------------------------------------------
-- The day's event
---------------------------------------------------------------------------

local function applyEvent()
	Workspace.Gravity = Config.World.gravity * (event.gravity or 1)
	if event.night then
		Lighting.ClockTime = 18.7
		Lighting.Brightness = 1.2
		Lighting.OutdoorAmbient = Color3.new(0.35, 0.3, 0.45)
	else
		Lighting.ClockTime = 14
		Lighting.Brightness = 2.5
		Lighting.OutdoorAmbient = Color3.new(0.55, 0.55, 0.6)
	end
	Workspace:SetAttribute("HighwayEvent", event.id)
end

local function seedMessage(): { [string]: any }
	return { seed = seed, epoch = epoch, event = event.id, versus = versus }
end

local function checkDay()
	local day = dayNumber()
	if day == today then
		return
	end
	today = day
	event = HighwayMath.eventFor(day, cfg.events)
	applyEvent()
	Net.fireAll("Highway.Seed", seedMessage())
end

---------------------------------------------------------------------------
-- Runs
---------------------------------------------------------------------------

local function tutorialRoad(player: Player): HighwayMath.Road
	local slot = tutorialSlots[player]
	if slot == nil then
		local used = {}
		for _, s in tutorialSlots do
			used[s] = true
		end
		slot = 0
		while used[slot] do
			slot += 1
		end
		tutorialSlots[player] = slot
	end
	local o = cfg.tutorial.origin
	return HighwayMath.road(
		seed,
		cfg.road,
		{ origin = { o[1] + slot * cfg.tutorial.spacing, o[2], o[3] }, lanes = cfg.tutorial.lanes }
	)
end

-- Where each running player is on the shared road
local function packS(except: Player?): { number }
	local list = {}
	for player, run in runs do
		if player ~= except and active(run) and not run.tutorial then
			local chassis = chassisOf(player)
			if chassis then
				local s = HighwayMath.locate(road, chassis.Position.X, chassis.Position.Z)
				table.insert(list, s)
			end
		end
	end
	return list
end

local function roadCFrame(r: HighwayMath.Road, s: number, lane: number): CFrame
	local x, z, h = HighwayMath.place(r, s, HighwayMath.laneOffset(r, lane))
	return CFrame.new(x, r.origin[2], z) * CFrame.Angles(0, -h, 0)
end

local function startRun(player: Player)
	local profile = DataService.get(player)
	if profile == nil or player.Parent ~= Players then
		return
	end
	local old = runs[player]
	if old and not old.over then
		return
	end
	local tutorial = not profile.tut.highway and not versus
	local r = if tutorial then tutorialRoad(player) else road
	local lane = if tutorial then 1 else 2
	local t = now()
	local s0 = HighwayMath.clearStart(
		r,
		if tutorial then 0 else HighwayMath.startS(packS(player), cfg.packBehind, cfg.road.maxS),
		lane,
		t - epoch,
		cfg.traffic,
		cfg.ride.density,
		if tutorial then nil else event,
		if tutorial then cfg.tutorial.quiet else nil,
		cfg.ride.startGap
	)
	local length = if tutorial then cfg.tutorial.length else cfg.runLength
	nextRunId += 1
	local opts = HighwayMath.runOpts(
		if tutorial then nil else event,
		if tutorial then cfg.tutorial.quiet else nil,
		s0,
		t - epoch,
		cfg.ride.density
	)
	local run: Run = {
		id = nextRunId,
		road = r,
		tutorial = tutorial,
		opts = opts,
		event = event,
		s0 = s0,
		lane = lane,
		startAt = t,
		endsAt = t + length,
		over = false,
		ending = false,
		score = Score.newRun(),
		broken = {},
		clock = Score.newBreakClock(),
		hits = {},
		props = {},
		near = {},
		pairs = {},
		lastAir = t,
		lastFlip = t,
		rejected = 0,
		flagged = false,
		phase = "ride",
		lastS = s0,
		lastCheck = t,
		lastProgress = t,
		distance = 0,
		ridePoints = 0,
		rideCarry = 0,
		wreckEndsAt = math.huge,
		why = "",
	}
	runs[player] = run
	Analytics.modeStep(player, Analytics.MODE.roundStart)
	profile.flags.lastMode = "highway"
	Net.fire("Highway.Start", player, {
		run = run.id,
		s = s0,
		lane = lane,
		tutorial = tutorial,
		origin = r.origin,
		lanes = r.lanes,
		event = if tutorial then nil else event.id,
		startAt = t,
		endsAt = run.endsAt,
		length = length,
		t0 = t - epoch, -- the traffic ramp's clock (HighwayMath.runOpts)
	})
	-- The car goes down on the road after Highway.Start, so the device has built the road under it
	VehicleService.spawn(player, vehicleFor(player), roadCFrame(r, s0, lane))
	player:SetAttribute("HighwayRun", run.id)
	dirty[player] = true
end

---------------------------------------------------------------------------
-- Points
---------------------------------------------------------------------------

local function addMeter(player: Player, points: number)
	if points <= 0 then
		return
	end
	meter += points
	contributions[player] = (contributions[player] or 0) + points
	if meter < cfg.meter.goal then
		return
	end
	for contributor, share in contributions do
		local profile = DataService.get(contributor)
		if profile and contributor.Parent == Players and share >= cfg.meter.minShare then
			local cap = math.floor(cfg.dailyCap * ShopMath.capMultiplier(profile.rebirths) + 0.5)
			local coins = TracksMath.applyCap(cfg.meter.coins, 0, profile.daily.coinsByMode.highway or 0, cap)
			local got = EconomyService.grantCoins(contributor, coins, "highway", "Havoc_meter")
			Net.fire("Highway.Event", contributor, { kind = "meterFull", coins = got })
		end
	end
	for _, p in Players:GetPlayers() do
		if contributions[p] == nil or contributions[p] < cfg.meter.minShare then
			Net.fire("Highway.Event", p, { kind = "meterFull", coins = 0 })
		end
	end
	meter = 0
	table.clear(contributions)
end

local function scored(player: Player, points: number)
	dirty[player] = true
	addMeter(player, points)
end

local function reject(player: Player, run: Run, why: string)
	Analytics.cheat(player, "highway_" .. why)
	run.rejected += 1
	if run.rejected >= cfg.rejectLimit and not run.flagged then
		run.flagged = true
		warn(string.format("[Highway] run %d of %s flagged (%s)", run.id, player.Name, why))
		Net.fire("Highway.Event", player, { kind = "flagged" })
	end
end

local function tolerance(player: Player, chassis: BasePart): number
	local ping = math.clamp(player:GetNetworkPing(), 0, 1)
	local speed = chassis.AssemblyLinearVelocity.Magnitude
	return cfg.hitCheck.radius + speed * (cfg.hitCheck.speedAllowance + ping)
end

-- The most impact a hit could have at this car's speed
local function impactCap(player: Player): number
	local vehicle = Config.Vehicles[vehicleFor(player)]
	local class = Config.Classes[vehicle.class]
	local closing = class.topSpeed * 1.25 + 70
	return math.min(cfg.score.maxImpact, closing * Config.Impact.massFactorMax)
end

-- Where a tutorial car is (they drive slowly in your lane, from your start)
local function tutorialCar(run: Run, index: number, t: number): number?
	local ahead = cfg.tutorial.cars[index]
	if ahead == nil then
		return nil
	end
	return run.s0 + ahead + cfg.tutorial.carSpeed * (t - run.startAt)
end

local function noteWreck(player: Player, run: Run, t: number)
	if Score.wreck(run.score, t, cfg.score) then
		Net.fire("Highway.Event", player, { kind = "pileStart" })
	end
end

-- The crash: the ride is over and Wreck Mode begins
local function startWreck(player: Player, run: Run, why: string)
	if run.phase ~= "ride" then
		return
	end
	local t = now()
	run.phase = "wreck"
	run.why = why
	if RunService:IsStudio() then
		print(
			string.format(
				"[Highway] %s: wreck mode (%s) after %d studs",
				player.Name,
				why,
				math.floor(run.distance)
			)
		)
	end
	run.wreckEndsAt = t + cfg.ride.wreckLength
	Net.fire("Highway.Event", player, {
		kind = "wreckStart",
		run = run.id,
		endsAt = run.wreckEndsAt,
		meters = math.floor(run.distance * cfg.ride.metersPerStud),
		ridePoints = run.ridePoints,
		why = why,
	})
	dirty[player] = true
end

-- The ride: distance from the car's own position on the road, at most what the car could have done
local function stepRide(player: Player, run: Run, t: number)
	local chassis = chassisOf(player)
	if chassis == nil then
		run.lastCheck = t
		return
	end
	local dt = t - run.lastCheck
	run.lastCheck = t
	if dt <= 0 then
		return
	end
	local s = HighwayMath.locate(run.road, chassis.Position.X, chassis.Position.Z)
	local progress = s - run.lastS
	run.lastS = s
	if progress <= 0.5 then
		if t - run.lastProgress >= cfg.ride.idleLimit then
			startWreck(player, run, "idle")
		end
		return
	end
	run.lastProgress = t
	local vehicle = Config.Vehicles[vehicleFor(player)]
	local top = Config.Classes[vehicle.class].topSpeed
	local allowed = (top * cfg.ride.maxProgress + 30) * dt
	if progress > allowed + 40 then
		reject(player, run, "ride fast")
		progress = allowed
	end
	progress = math.min(progress, allowed)
	run.distance += progress
	local exact = Score.ridePoints(progress, (progress / dt) / top, cfg.ride) + run.rideCarry
	local whole = math.floor(exact)
	run.rideCarry = exact - whole
	if whole > 0 then
		run.ridePoints += Score.addBonus(run.score, whole, math.huge)
		scored(player, whole)
	end
end

local function onHit(player: Player, kind: number, id: number, impact: number, link: number)
	local run = runs[player]
	if not active(run) then
		return
	end
	local r = run :: Run
	local chassis = chassisOf(player)
	if chassis == nil then
		return
	end
	local t = now()
	local pos = chassis.Position
	local reach = tolerance(player, chassis)
	impact = math.min(impact, impactCap(player))
	if r.phase == "ride" then
		if kind == 2 then
			return -- players: a hard versus bump ends the ride from the device (Highway.Trick "crash")
		elseif (kind == 0 or kind == 3) and impact < cfg.ride.crashImpact and link == 0 then
			return -- a scrape: no points, the ride goes on
		elseif (kind == 0 or kind == 3) and link > 0 then
			return -- nothing you sent flying yet
		end
	end
	local points = 0
	if kind == 0 or kind == 3 then
		if kind == 3 and not r.tutorial then
			return reject(player, r, "tutorial car")
		end
		local key = kind .. ":" .. id
		local rec = r.hits[key]
		if rec and t - rec.at > cfg.hitCheck.wreckLife then
			if rec.wrecked then
				return -- devices clear wrecks before this, so a late report is only lag: ignore it
			end
			-- A car only knocked (it found its lane and slot again): check it like a fresh one
			r.hits[key] = nil
			rec = nil
		end
		if rec then
			-- Hit before: it is off its lane now, so check against where it was hit
			if flatDistance(pos.X, pos.Z, rec.x, rec.z) > cfg.hitCheck.wreckRadius + reach then
				return reject(player, r, "wreck far")
			end
		else
			local s, lane, base, length
			local ping = math.clamp(player:GetNetworkPing(), 0, 1)
			if kind == 0 then
				local car = HighwayMath.car(r.road, id, t - ping / 2 - epoch, cfg.traffic, r.opts)
				if car == nil then
					return reject(player, r, "no car")
				end
				s, lane, base, length = car.s, car.lane, car.kind.base, car.kind.size[3]
			else
				s = tutorialCar(r, id, t - ping / 2)
				if s == nil then
					return reject(player, r, "no tutorial car")
				end
				lane, base, length = r.lane, cfg.traffic.types[1].base, cfg.traffic.types[1].size[3]
			end
			local x, z = HighwayMath.place(r.road, s :: number, HighwayMath.laneOffset(r.road, lane))
			local limit = length / 2 + 6 + reach + (if link > 0 then cfg.hitCheck.wreckRadius else 0)
			if flatDistance(pos.X, pos.Z, x, z) > limit then
				return reject(player, r, "far")
			end
			rec = { hard = 0, wrecked = false, at = t, x = x, z = z, base = base }
			r.hits[key] = rec
			-- (Each ride's traffic is its own, so a wreck is never sent to other players' devices.)
		end
		if r.phase == "ride" then
			startWreck(player, r, "traffic")
		end
		local hit = rec :: HitRecord
		hit.at = t
		points = Score.hit(r.score, t, hit.base, impact, link, cfg.score)
		if impact >= cfg.wreck.double then
			hit.hard += 1
		end
		if not hit.wrecked and (impact >= cfg.wreck.single or hit.hard >= 2) then
			hit.wrecked = true
			noteWreck(player, r, t)
		end
	elseif kind == 1 then
		if r.props[id] then
			return
		end
		local prop = HighwayMath.prop(r.road, id, cfg.props)
		if prop == nil then
			return reject(player, r, "no prop")
		end
		local x, z = HighwayMath.place(r.road, prop.s, prop.lateral)
		local limit = cfg.hitCheck.propRadius + reach + (if link > 0 then cfg.hitCheck.wreckRadius else 0)
		if flatDistance(pos.X, pos.Z, x, z) > limit then
			return reject(player, r, "prop far")
		end
		r.props[id] = true
		points = Score.hit(r.score, t, prop.kind.base, impact, link, cfg.score)
	elseif kind == 2 then
		if not versus or link ~= 0 then
			return -- co-op: players bump for fun, no points
		end
		local target = Players:GetPlayerByUserId(id)
		local other = target and chassisOf(target)
		if target == nil or target == player or other == nil or not active(runs[target]) then
			return
		end
		if t - (r.pairs[id] or -math.huge) < cfg.score.player.pairCooldown then
			return
		end
		local gap = flatDistance(pos.X, pos.Z, other.Position.X, other.Position.Z)
		if gap > 14 + reach then
			return reject(player, r, "player far")
		end
		r.pairs[id] = t
		points = Score.hit(r.score, t, cfg.score.player.base, impact, 0, cfg.score)
	end
	scored(player, points)
end

local function onTrick(player: Player, kind: string, id: number, value: number)
	local run = runs[player]
	if not active(run) then
		return
	end
	local r = run :: Run
	local chassis = chassisOf(player)
	if chassis == nil then
		return
	end
	local t = now()
	local points = 0
	if kind == "crash" then
		-- The device saw the ride end (a Huge crash, a throw, a wall, a versus bump): Wreck Mode
		if r.phase == "ride" then
			startWreck(player, r, "crash")
		end
		return
	end
	if kind == "near" then
		if r.near[id] then
			return
		end
		local speed = chassis.AssemblyLinearVelocity.Magnitude
		if speed < cfg.score.nearMiss.speed * (1 - cfg.hitCheck.speedAllowance) then
			return reject(player, r, "near slow")
		end
		local ping = math.clamp(player:GetNetworkPing(), 0, 1)
		local car = HighwayMath.car(r.road, id, t - ping / 2 - epoch, cfg.traffic, r.opts)
		if car == nil then
			return reject(player, r, "near no car")
		end
		local x, z = HighwayMath.place(r.road, car.s, HighwayMath.laneOffset(r.road, car.lane))
		local pos = chassis.Position
		if flatDistance(pos.X, pos.Z, x, z) > car.kind.size[3] / 2 + 6 + tolerance(player, chassis) then
			return reject(player, r, "near far")
		end
		r.near[id] = true
		points = Score.nearMiss(r.score, t, cfg.score)
	elseif kind == "air" then
		-- Air time can't be longer than the time since the last report
		local seconds = math.min(value, t - r.lastAir + 0.25, cfg.score.air.maxSeconds)
		r.lastAir = t
		points = Score.trick(r.score, t, Score.airPoints(seconds, cfg.score), cfg.score)
	elseif kind == "flip" then
		-- A flip lands right after a jump (its air report), at most one report a second
		if t - r.lastFlip < 1 or t - r.lastAir > 1.5 then
			return
		end
		r.lastFlip = t
		points = Score.trick(r.score, t, Score.flipPoints(value, cfg.score), cfg.score)
	end
	scored(player, points)
end

local function finishRun(player: Player, reason: string)
	local run = runs[player]
	if run == nil or run.over then
		return
	end
	run.over = true
	player:SetAttribute("HighwayRun", nil)
	Analytics.modeStep(player, Analytics.MODE.roundEnd)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local s = run.score
	ProfileSchema.rollDay(profile, os.time())
	-- Coins: 1 per 250 points (max 120), halved on a flagged run; boosts; the daily cap
	local want = Score.coins(s.score, cfg.coins)
	if run.flagged then
		want = math.floor(want * cfg.flaggedCoins)
	end
	local cap = math.floor(cfg.dailyCap * ShopMath.capMultiplier(profile.rebirths) + 0.5)
	local boost = EconomyService.boostFor(player)
	local coins = TracksMath.applyCap(want, boost, profile.daily.coinsByMode.highway or 0, cap)
	local got = EconomyService.grantCoins(player, coins, "highway", "Highway_run")
	local capped = got < math.floor(want * (1 + boost) + 0.5)
	local stats = profile.stats
	local previousBest = stats.bestHighway or 0
	stats.highwayRuns = (stats.highwayRuns or 0) + 1
	stats.bestHighway = math.max(previousBest, s.score)
	stats.bestBones = math.max(stats.bestBones or 0, s.breaks)
	local meters = math.floor(run.distance * cfg.ride.metersPerStud)
	local previousDistance = stats.bestDistance or 0
	stats.bestDistance = math.max(previousDistance, meters)
	stats.pileups = (stats.pileups or 0) + s.pileups
	-- The daily Havoc target opens the daily chest once (150 coins or a common cosmetic you don't own)
	local before = profile.daily.havoc or 0
	profile.daily.havoc = before + s.score
	local chest: { [string]: any }? = nil
	if not profile.daily.havocChest and profile.daily.havoc >= cfg.dailyTarget then
		profile.daily.havocChest = true
		local options = {}
		for _, item in Catalog.shopItems() do
			if item.rarity == "common" and profile.inventory[item.id] == nil then
				table.insert(options, item.id)
			end
		end
		if #options > 0 and random:NextNumber() < cfg.chest.cosmeticChance then
			local item = options[random:NextInteger(1, #options)]
			ShopService.giveItem(profile, item)
			chest = { item = item }
		else
			chest = { coins = EconomyService.grantCoins(player, cfg.chest.coins, nil, "HavocChest") }
		end
	end
	QuestService.event(player, "highwayRun", 1)
	QuestService.event(player, "highwayScore", s.score)
	local mastery = math.floor(s.score / Config.Progression.masteryPoints.destructionPer)
	if mastery > 0 then
		ShopService.addMastery(player, mastery)
	end
	if run.tutorial and not profile.tut.highway then
		profile.tut.highway = true
		EconomyService.funnel(player, 9, "Highway tutorial")
	end
	-- Boards: never for a flagged run, the tutorial or a board-banned player
	local banned = profile.flags.boardBanDay == ProfileSchema.dayKey(os.time())
	if not run.flagged and not run.tutorial and not banned and s.score > 0 then
		local day = dayNumber()
		local week = Quests.weekOf(day)
		BoardStore.post(BOARD_STORE, Boards.modeScope("HW_Score", "D", day), player.UserId, s.score, true)
		BoardStore.post(BOARD_STORE, Boards.modeScope("HW_Score", "W", week), player.UserId, s.score, true)
		if meters > 0 then
			BoardStore.post(BOARD_STORE, Boards.modeScope("HW_Dist", "D", day), player.UserId, meters, true)
			BoardStore.post(BOARD_STORE, Boards.modeScope("HW_Dist", "W", week), player.UserId, meters, true)
		end
	end
	DataService.changed(player)
	pcall(function()
		game:GetService("AnalyticsService"):LogCustomEvent(player, "highway_run", s.score, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = string.format(
				"%d m / bones %d / x%d / pileups %d",
				meters,
				s.breaks,
				s.bestMultiplier,
				s.pileups
			),
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = reason,
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = if run.tutorial
				then "tutorial"
				else tostring(run.event and run.event.id),
		})
	end)
	-- A friend's Beat my score card: beaten once this run's score passes it
	local challenge: { [string]: any }? = nil
	local flags = profile.flags
	if (flags.challengeScore or 0) > 0 and not run.tutorial and reason ~= "left" then
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(flags.challengeBy)
		end)
		challenge = {
			score = flags.challengeScore,
			name = if ok and type(name) == "string" then name else "Your friend",
			beaten = s.score > flags.challengeScore,
		}
		if s.score > flags.challengeScore then
			flags.challengeScore = 0
			flags.challengeBy = 0
		end
	end
	if player.Parent == Players then
		Net.fire("Highway.End", player, {
			run = run.id,
			score = s.score,
			bones = s.breaks,
			bestMultiplier = s.bestMultiplier,
			pileups = s.pileups,
			coins = got,
			capped = capped,
			flagged = run.flagged,
			best = stats.bestHighway,
			newBest = s.score > previousBest and previousBest > 0,
			havoc = profile.daily.havoc,
			target = cfg.dailyTarget,
			chest = chest,
			reason = reason,
			tutorial = run.tutorial,
			event = if run.tutorial then nil else run.event.id,
			challenge = challenge,
			meters = meters,
			bestMeters = stats.bestDistance,
			newBestMeters = meters > previousDistance and previousDistance > 0,
			ridePoints = run.ridePoints,
			wreckPoints = s.score - run.ridePoints,
		})
	end
end

local function onBone(player: Player, piece: number, impact: number)
	local run = runs[player]
	if not active(run) then
		return
	end
	local r = run :: Run
	local t = now()
	if r.phase == "ride" then
		startWreck(player, r, "crash") -- a crash hard enough to break a bone ends the ride
	end
	if impact < math.min(cfg.bones.seatImpact, cfg.bones.ejectSpeed) then
		return reject(player, r, "soft bone")
	end
	if not Score.mayBreak(r.clock, t, cfg.bones) then
		return
	end
	local chosen = Score.pickPiece(r.broken, { piece })
	if chosen == nil then
		return
	end
	local bone = Score.breakOn(r.broken, chosen)
	Score.noteBreak(r.clock, t, cfg.bones)
	local points = Score.boneBreak(r.score, t, cfg.score)
	QuestService.event(player, "bones", 1)
	Net.fire("Highway.Event", player, {
		kind = "bone",
		piece = chosen,
		bone = bone,
		count = r.score.breaks,
		points = points,
	})
	scored(player, points)
	if r.score.breaks >= cfg.bones.total then
		-- Full Crack: the finale plays on the device, then the results
		r.ending = true
		task.delay(cfg.bones.finale + 0.3, function()
			finishRun(player, "fullCrack")
		end)
	end
end

---------------------------------------------------------------------------
-- Ticks: pile-ups, timers, score sends
---------------------------------------------------------------------------

local function payPileups(t: number)
	local multiplier = if event and event.pileup then event.pileup else 1
	for player, run in runs do
		if run.over then
			continue
		end
		local points, cars = Score.pileupDue(run.score, t, if run.tutorial then 1 else multiplier, cfg.score)
		if points == nil then
			continue
		end
		QuestService.event(player, "pileup", 1)
		local paid = { player }
		if not versus and not run.tutorial then
			-- Co-op: everyone within 80 studs shares the bonus
			local here = chassisOf(player)
			for other, otherRun in runs do
				local there = chassisOf(other)
				if other ~= player and active(otherRun) and not otherRun.tutorial and here and there then
					if (here.Position - there.Position).Magnitude <= cfg.score.coopRadius then
						table.insert(paid, other)
					end
				end
			end
		end
		for _, p in paid do
			local target = runs[p]
			if target then
				local got = Score.addBonus(target.score, points :: number, math.huge)
				Net.fire("Highway.Event", p, {
					kind = "pileup",
					cars = cars,
					points = got,
					by = if p ~= player then player.DisplayName else nil,
				})
				scored(p, got)
			end
		end
	end
end

local function sendScores(t: number)
	for player, isDirty in dirty do
		local run = runs[player]
		if isDirty and run and player.Parent == Players then
			local s = run.score
			Net.fire("Highway.Score", player, {
				run = run.id,
				score = s.score,
				multiplier = Score.currentMultiplier(s, t, cfg.score),
				combo = if Score.comboAlive(s, t) then s.combo else 0,
				comboUntil = s.comboUntil,
				breaks = s.breaks,
				bestMultiplier = s.bestMultiplier,
				phase = run.phase,
				meters = math.floor(run.distance * cfg.ride.metersPerStud),
				ridePoints = run.ridePoints,
			})
		end
	end
	table.clear(dirty)
end

---------------------------------------------------------------------------
-- Boards
---------------------------------------------------------------------------

local function onBoard(player: Player, board: string, tab: string)
	local day = dayNumber()
	local prefix = if board == "distance" then "HW_Dist" else "HW_Score"
	local scope = if tab == "daily"
		then Boards.modeScope(prefix, "D", day)
		else Boards.modeScope(prefix, "W", Quests.weekOf(day))
	local count = if tab == "friends" then Config.Boards.friendsPool else Config.Boards.topCount
	local entries = BoardStore.read(BOARD_STORE, scope, count, true)
	local friends = if tab == "friends" then BoardStore.friendsOf(player) else {}
	local list, mine = Boards.rows(tab, entries, player.UserId, nil, friends, Config.Boards.topCount)
	local ids = {}
	for _, row in list do
		table.insert(ids, row.userId)
	end
	local names = BoardStore.names(ids)
	local rows = {}
	for _, row in list do
		table.insert(rows, {
			rank = row.rank,
			name = names[row.userId] or "Driver",
			value = row.ms,
			me = row.me,
			friend = row.friend,
		})
	end
	Net.fire("Highway.BoardData", player, {
		board = board,
		tab = tab,
		rows = rows,
		mine = if mine then { rank = mine.rank, value = mine.ms, name = player.DisplayName } else nil,
	})
end

---------------------------------------------------------------------------
-- Joining and leaving
---------------------------------------------------------------------------

local function onJoin(player: Player)
	task.spawn(function()
		local profile = DataService.waitFor(player)
		if profile == nil or player.Parent ~= Players then
			return
		end
		Net.fire("Highway.Seed", player, seedMessage())
		LiveCounts.bump()
		if versus and not TeleportHub.versusOpen(player) and not DataService.isAdmin(player) then
			Net.fire("Notice", player, "versusLocked")
			VehicleService.spawn(player, vehicleFor(player), roadCFrame(road, 0, 2))
			task.delay(3, function()
				if player.Parent == Players then
					TeleportHub.home(player)
				end
			end)
			return
		end
		startRun(player)
	end)
end

local function onLeaving(player: Player, _profile: { [string]: any })
	-- Pay what the run had scored before the last save
	finishRun(player, "left")
end

local function onRemoving(player: Player)
	runs[player] = nil
	tutorialSlots[player] = nil
	dirty[player] = nil
	contributions[player] = nil
end

function HighwayService.init()
	versus = Place.isVersus()
	seed = random:NextInteger(1, 2 ^ 30)
	epoch = now()
	road = HighwayMath.road(seed, cfg.road)
	today = dayNumber()
	event = HighwayMath.eventFor(today, cfg.events)
	applyEvent()
	Workspace:SetAttribute("Mode", "Highway")
	Workspace:SetAttribute("HighwayVersus", versus)
	Workspace:SetAttribute("HavocMeter", 0)
	Workspace:SetAttribute("HavocGoal", cfg.meter.goal)

	VehicleService.onJoin = onJoin
	-- Co-op: each ride's traffic is its own, so other players' cars are ghosts (versus cars are solid)
	VehicleService.collisionGroupFor = function(_player: Player): string?
		return if versus then nil else "Ghost"
	end
	VehicleService.equipLocked = function(player: Player): boolean
		return active(runs[player])
	end
	VehicleService.homeFor = function(player: Player): CFrame?
		local run = runs[player]
		if run == nil then
			return nil
		end
		local chassis = chassisOf(player)
		local s = run.s0
		if chassis then
			s = HighwayMath.locate(run.road, chassis.Position.X, chassis.Position.Z)
		end
		return roadCFrame(run.road, s, run.lane)
	end
	VehicleService.DamageChanged:Connect(function(player: Player, state: buffer)
		local run = runs[player]
		if not active(run) then
			return
		end
		local decoded = DamageModel.decode(state)
		if decoded and bit32.band(decoded.flags, DamageModel.FLAG_EXPLODED) ~= 0 then
			local r = run :: Run
			if r.phase == "ride" then
				startWreck(player, r, "boom")
			end
			-- Blown up: Wreck Mode keeps going a few seconds for the flying wreckage, then the results
			r.wreckEndsAt = math.min(r.wreckEndsAt, now() + 4)
		end
	end)
	DataService.Leaving:Connect(onLeaving)
	Players.PlayerRemoving:Connect(onRemoving)

	Net.on("Highway.Hit", onHit)
	Net.on("Highway.Trick", onTrick)
	Net.on("Bone.Break", onBone)
	Net.on("Highway.Again", function(player: Player)
		local run = runs[player]
		if run == nil or run.over then
			Analytics.modeStep(player, Analytics.MODE.requeue)
			startRun(player)
		end
	end)
	Net.on("Highway.Leave", function(player: Player)
		local ok, reason = TeleportHub.home(player)
		if not ok and reason then
			Net.fire("Notice", player, reason)
		end
	end)
	Net.on("Highway.Board", onBoard)

	LiveCounts.start(function()
		return { highway = #Players:GetPlayers() }
	end)

	local clock, dayClock = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		dayClock += dt
		if clock < 0.25 then
			return
		end
		clock = 0
		local t = now()
		for player, run in runs do
			if run.over or run.ending then
				continue
			end
			if run.phase == "ride" then
				stepRide(player, run, t)
			end
			if t >= run.wreckEndsAt then
				finishRun(player, "wrecked")
			elseif t >= run.endsAt then
				finishRun(player, "timer")
			end
		end
		payPileups(t)
		sendScores(t)
		Workspace:SetAttribute("HavocMeter", math.floor(meter))
		if dayClock >= 30 then
			dayClock = 0
			checkDay()
		end
	end)
end

return HighwayService
