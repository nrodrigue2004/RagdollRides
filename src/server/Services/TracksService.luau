-- TracksService: the Tracks free-run loop on the server (spec: Tracks, Anti-exploit, Onboarding).
-- * Builds the starter maps and puts each player on one (a first-time player lands straight on Pip's
--   Hill, with no menu first; a returning player opens on the Tumble Park hub). Map.Go moves a player
--   to a starter map or the hub ("hub", no runs there). Published player maps are loaded and entered by
--   MapPlayService; quick race copies of starter maps by RaceService (def.race: the server starts every
--   racer's run at GO, and RaceService.finish decides the result).
-- * Signals for the map services: MapChanged (who is on which map), RunStarted (plays), Finished
--   (finishers). A builder TEST map (def.testOwner) goes to BuilderService's customFinish instead of pay.
-- * Runs: Run.Start, Run.Checkpoint and Run.Finish are timed on the server's own clock. A checkpoint
--   counts only in order and with the car near it; a finish needs every checkpoint, the car at the
--   finish, a time no faster than the map allows and no speed flags (TracksMath.validateFinish).
-- * Speed check at 4 Hz while a run is on: faster than top speed x 1.4 plus launch allowances flags the
--   run (a reset to a respawn point is not speed). Five flags in a session kicks (not in Studio).
-- * Pay: stars once per tier per map, coins with boosts and the daily cap (TracksMath.payout). Pip's
--   Hill's first finish pays its fixed 100 coins and 1 star.
-- * Ghosts: the server samples the car at 5 Hz during a run; a new best stores it in the profile
--   (GhostCodec, base64) and sends it back on Run.Ghost so the client can race it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local Net = require(Shared.Net)
local PoseCodec = require(Shared.PoseCodec)
local ProfileSchema = require(Shared.ProfileSchema)
local ShopMath = require(Shared.ShopMath)
local Signal = require(Shared.Util.Signal)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MapBuilder = require(Shared.MapBuilder)
local TestTrack = require(Services.TestTrack)
local VehicleService = require(Services.VehicleService)

local TracksService = {}

TracksService.MapChanged = Signal.new() -- (player, mapId or nil)
TracksService.RunStarted = Signal.new() -- (player, map)
TracksService.Finished = Signal.new() -- (player, map, firstFinish, { tier, isBest, trailCoins, ms }): a paid finish
TracksService.RunRejected = Signal.new() -- (player, mapId, reason): a run that will not count

local TEST_TRACK = "test_track" -- Studio and admins: the milestone 1 test track, for the dev panel tests
local HUB = "hub" -- the Tumble Park plaza (HubService builds it): drive around, no runs
TracksService.HUB = HUB

type Run = TracksMath.RunRecord & {
	splits: { number }, -- the driver's timer at each checkpoint (ms), for the split display
	samples: { GhostCodec.Sample },
	sampleClock: number,
	valid: boolean,
	reason: string?,
}

local playerMap: { [Player]: string } = {}
local runs: { [Player]: Run } = {}
local lastPositions: { [Player]: { position: Vector3, time: number } } = {}
local speedFlags: { [Player]: number } = {}
local speedHistory: { [Player]: { { time: number, distance: number } } } = {}
local rejectTimes: { [Player]: { number } } = {}

-- Starter maps always keep their ghost
local KEEP_GHOSTS: { [string]: boolean } = {}
for _, map in StarterMaps.maps do
	KEEP_GHOSTS[map.id] = true
end

-- World-space respawn points per map (for the speed check)
local respawnPoints: { [string]: { Vector3 } } = {}

-- Every map a run can be on: the starter maps, plus builder maps (a creator's TEST, later published
-- maps) registered by id. Builder maps are not reachable through Map.Go; their service enters them.
local mapDefs: { [string]: StarterMaps.MapDef } = table.clone(StarterMaps.byId)

-- A finished run on a builder map: the owning service decides what it means (a TEST records the
-- creator time; published maps pay in milestone 4). Returns the Run.Result fields.
TracksService.customFinish = nil :: ((Player, StarterMaps.MapDef, number) -> { [string]: any })?
-- A finished quick race run (RaceService): returns the Run.Result fields
TracksService.raceFinish = nil :: ((Player, StarterMaps.MapDef, number) -> { [string]: any })?

local function worldPoint(map: StarterMaps.MapDef, x: number, y: number, z: number): Vector3
	local wx, wy, wz = StarterMaps.toWorld(map, x, y, z)
	return Vector3.new(wx, wy, wz)
end

local function indexRespawns(map: StarterMaps.MapDef)
	local points = {}
	for _, p in StarterMaps.respawnPoints(map) do
		table.insert(points, worldPoint(map, p[1], p[2], p[3]))
	end
	respawnPoints[map.id] = points
end

function TracksService.registerMap(def: StarterMaps.MapDef)
	mapDefs[def.id] = def
	indexRespawns(def)
end

function TracksService.unregisterMap(id: string)
	if StarterMaps.byId[id] == nil then
		mapDefs[id] = nil
		respawnPoints[id] = nil
	end
end

function TracksService.getMapDef(id: string): StarterMaps.MapDef?
	return mapDefs[id]
end

function TracksService.currentMap(player: Player): string?
	return playerMap[player]
end

-- The next starter map for a player: the first one they have not reached Gold on yet
local function nextStarter(profile: { [string]: any }?): string
	if profile == nil or not profile.tut.pipHill then
		return StarterMaps.FIRST_MAP
	end
	for _, map in StarterMaps.maps do
		local entry = profile.tracks[map.id]
		if entry == nil or (entry.stars or 0) < 3 then
			return map.id
		end
	end
	return StarterMaps.FIRST_MAP
end
TracksService.nextStarter = nextStarter

-- Where a joining player starts: Pip's Hill until it is finished (no menu, no teleport before the first
-- win), then the hub (spec: returning sessions open on the hub)
local function homeMap(profile: { [string]: any }?): string
	if profile == nil or not profile.tut.pipHill then
		return StarterMaps.FIRST_MAP
	end
	return HUB
end

function TracksService.homeMapFor(player: Player): string
	return homeMap(DataService.get(player))
end

-- The hub's spawn row: cars side by side facing the mode gates, spread so nobody lands on anyone
local hubSpawnCount = 0
local function hubSpawn(): CFrame
	hubSpawnCount += 1
	local cfg = Config.Hub
	local column = (hubSpawnCount - 1) % 8
	local o = cfg.origin
	local p = cfg.spawn
	local position = Vector3.new(o[1] + p[1] + (column - 3.5) * 10, o[2] + p[2], o[3] + p[3])
	return CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
end

local function sendGhost(player: Player, mapId: string)
	local profile = DataService.get(player)
	local ghost = profile and profile.ghosts[mapId]
	Net.fire("Run.Ghost", player, mapId, ghost)
end

-- Put a player on a map: their car at its start (or at `at`: a race grid slot), no run until they
-- drive off
function TracksService.enterMap(player: Player, mapId: string, at: CFrame?)
	if player.Parent ~= Players then
		return
	end
	local cf: CFrame
	if mapId == TEST_TRACK then
		cf = TestTrack.spawnCFrame(1)
	elseif mapId == HUB then
		cf = hubSpawn()
	else
		local map = mapDefs[mapId]
		if map == nil then
			return
		end
		cf = at or MapBuilder.startCFrame(map)
	end
	runs[player] = nil
	-- Stream the start in first so the car never lands before the road exists on the player's device
	pcall(function()
		player:RequestStreamAroundAsync(cf.Position, 5)
	end)
	if player.Parent ~= Players then
		return
	end
	playerMap[player] = mapId
	runs[player] = nil
	lastPositions[player] = nil
	player:SetAttribute("MapId", mapId)
	TracksService.MapChanged:Fire(player, mapId)
	local profile = DataService.get(player)
	local vehicleId = Config.DefaultVehicle
	if profile and VehicleService.mayDrive(player, profile.equippedVehicle) then
		vehicleId = profile.equippedVehicle
	end
	VehicleService.spawn(player, vehicleId, cf)
	if mapId == HUB or mapId == TEST_TRACK then
		return
	end
	local def = mapDefs[mapId] :: any
	if profile and not def.testOwner then
		-- The hub's mode card that glows next session
		profile.flags.lastMode = if def.race then "race" else "tracks"
	end
	if not def.testOwner and not def.race then
		sendGhost(player, mapId)
	end
end

-- Quick races: every racer's run starts on the server at GO (the client's Run.Start is ignored)
function TracksService.startRun(player: Player, mapId: string)
	local map = mapDefs[mapId]
	if map == nil or playerMap[player] ~= mapId then
		return
	end
	speedHistory[player] = nil
	runs[player] = {
		mapId = mapId,
		startTime = os.clock(),
		checkpoints = {},
		checkpointCount = map.checkpoints,
		speedFlags = 0,
		splits = {},
		samples = {},
		sampleClock = 0,
		valid = true,
		reason = nil,
	}
	lastPositions[player] = nil
end

-- A run's progress (quick race positions): checkpoints reached and when the last one was
function TracksService.progress(player: Player): (number, number)
	local run = runs[player]
	if run == nil then
		return 0, 0
	end
	local count, last = 0, 0
	for _, at in run.checkpoints do
		count += 1
		last = math.max(last, at)
	end
	return count, last
end

-- Off every map (the builder): no runs until the next enterMap
function TracksService.leaveMap(player: Player)
	playerMap[player] = nil
	runs[player] = nil
	lastPositions[player] = nil
	player:SetAttribute("MapId", nil)
	TracksService.MapChanged:Fire(player, nil)
end

local function chassisOf(player: Player): BasePart?
	local model = VehicleService.getVehicle(player)
	return model and model.PrimaryPart
end

local function nearPiece(player: Player, map: StarterMaps.MapDef, piece: StarterMaps.Piece?): boolean
	if piece == nil then
		return false
	end
	local chassis = chassisOf(player)
	if chassis == nil then
		return false
	end
	local target = worldPoint(map, piece.x, piece.y, piece.z)
	return (chassis.Position - target).Magnitude <= Config.Tracks.reportDistance
end

local function noteReject(player: Player, reason: string)
	warn(string.format("[Tracks] %s run rejected: %s", player.Name, reason))
	local times = rejectTimes[player] or {}
	rejectTimes[player] = times
	local now = os.clock()
	table.insert(times, now)
	while times[1] and now - times[1] > 600 do
		table.remove(times, 1)
	end
	if #times >= Config.Tracks.rejectsForBoardBan then
		-- No leaderboard posts for the rest of the day (boards arrive with ranked play)
		local profile = DataService.get(player)
		if profile then
			profile.flags.boardBanDay = ProfileSchema.dayKey(os.time())
		end
	end
end

local function onStart(player: Player, mapId: string)
	local map = mapDefs[mapId]
	if map == nil or playerMap[player] ~= mapId or (map :: any).race then
		return
	end
	speedHistory[player] = nil
	runs[player] = {
		mapId = mapId,
		startTime = os.clock(),
		checkpoints = {},
		checkpointCount = map.checkpoints,
		speedFlags = 0,
		splits = {},
		samples = {},
		sampleClock = 0,
		valid = true,
		reason = nil,
	}
	lastPositions[player] = nil
	local profile = DataService.get(player)
	if profile and not profile.tut.pipHill and mapId == StarterMaps.FIRST_MAP then
		EconomyService.funnel(player, 2, "First throttle")
	end
	TracksService.RunStarted:Fire(player, map)
end

local function onCheckpoint(player: Player, mapId: string, index: number, clientTime: number)
	local run = runs[player]
	local map = mapDefs[mapId]
	if run == nil or map == nil or run.mapId ~= mapId or not run.valid then
		return
	end
	if not TracksMath.acceptCheckpoint(run, index) then
		return
	end
	if not nearPiece(player, map, StarterMaps.find(map, "Checkpoint", index)) then
		return
	end
	run.checkpoints[index] = os.clock()
	run.splits[index] = math.floor(math.max(0, clientTime) * 1000 + 0.5)
	local profile = DataService.get(player)
	if profile and not profile.tut.pipHill and mapId == StarterMaps.FIRST_MAP and index == 1 then
		-- Checkpoint 1 sits at the end of the ramp's landing zone: reaching it means the jump was made
		EconomyService.funnel(player, 3, "Jump")
	end
end

local function rejectResult(player: Player, mapId: string, reason: string)
	local map = mapDefs[mapId]
	TracksService.RunRejected:Fire(player, mapId, reason)
	if map == nil or not map.custom then
		noteReject(player, reason) -- a creator testing their own map is never board-banned for it
	end
	Net.fire("Run.Result", player, {
		ok = false,
		mapId = mapId,
		reason = reason,
		nextMap = StarterMaps.nextMap(mapId),
		race = if map and (map :: any).race then true else nil,
	})
end

local function onFinish(player: Player, mapId: string, clientTime: number, trailCoins: number)
	local run = runs[player]
	local map = mapDefs[mapId]
	if run == nil or map == nil or run.mapId ~= mapId then
		return
	end
	runs[player] = nil
	local now = os.clock()
	if not run.valid then
		rejectResult(player, mapId, run.reason or "run cancelled")
		return
	end
	if not nearPiece(player, map, StarterMaps.find(map, "Finish")) then
		rejectResult(player, mapId, "not at the finish")
		return
	end
	local ok, reason, elapsed = TracksMath.validateFinish(run, now, map.creatorTime, Config.Tracks)
	if not ok then
		rejectResult(player, mapId, reason or "invalid")
		return
	end
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	-- The server's clock decides (spec: client time is advisory); the client's is only logged when far off
	local time = elapsed
	if math.abs(clientTime - elapsed) > 1 then
		warn(string.format("[Tracks] %s timer off by %.2f s on %s", player.Name, clientTime - elapsed, mapId))
	end
	if (map :: any).testOwner or (map :: any).race then
		local handler = if (map :: any).race then TracksService.raceFinish else TracksService.customFinish
		local result = if handler then handler(player, map, time) else {}
		result.ok = if result.ok == nil then true else result.ok
		result.mapId = mapId
		result.time = time
		Net.fire("Run.Result", player, result)
		return
	end
	local entry = profile.tracks[mapId]
	local daily = profile.daily
	local firstFinish = entry == nil
	local payout = TracksMath.payout(
		{
			timeSeconds = time,
			creatorSeconds = map.creatorTime,
			previousTier = if entry then entry.stars or 0 else 0,
			previousBestMs = if entry then entry.best else nil,
			isStarter = StarterMaps.byId[mapId] ~= nil,
			finishesToday = daily.mapFinishes[mapId] or 0,
			trailCoins = math.clamp(trailCoins, 0, map.coins),
			coinValue = map.coinValue,
			reward = map.reward,
			rewardClaimed = map.tut ~= nil and profile.tut[map.tut] == true,
			boost = EconomyService.boostFor(player),
			earnedToday = daily.coinsByMode.tracks,
			capMultiplier = ShopMath.capMultiplier(profile.rebirths),
		} :: any,
		Config.Tracks
	)

	-- Record the result
	local previousBest = if entry then entry.best else nil
	entry = entry or { best = payout.bestMs, stars = 0, splits = {} }
	entry.stars = math.max(entry.stars or 0, payout.tier)
	if payout.isBest then
		entry.best = payout.bestMs
		entry.splits = run.splits
	end
	profile.tracks[mapId] = entry
	ProfileSchema.noteTrack(profile, mapId, KEEP_GHOSTS)
	daily.mapFinishes[mapId] = (daily.mapFinishes[mapId] or 0) + 1
	profile.stats.finishes += 1

	local coins = EconomyService.grantCoins(player, payout.coins, "tracks", "Finish_" .. mapId)
	local stars = EconomyService.grantStars(player, payout.stars, "Stars_" .. mapId)

	if map.tut and not profile.tut[map.tut] then
		profile.tut[map.tut] = true
		if map.tut == "pipHill" then
			EconomyService.funnel(player, 4, "Finish Pip's Hill")
		elseif map.tut == "lean" then
			EconomyService.funnel(player, 5, "Second track")
		end
	end

	-- A new best keeps its ghost
	if payout.isBest and #run.samples > 0 then
		local ghost = GhostCodec.toBase64(GhostCodec.encode(run.samples, Config.Tracks.ghostRate))
		ProfileSchema.storeGhost(profile, mapId, ghost, KEEP_GHOSTS)
		Net.fire("Run.Ghost", player, mapId, ghost)
	end
	DataService.changed(player)

	Net.fire("Run.Result", player, {
		ok = true,
		mapId = mapId,
		time = time,
		best = entry.best / 1000,
		previousBest = if previousBest then previousBest / 1000 else nil,
		isBest = payout.isBest,
		firstFinish = firstFinish,
		tier = payout.tier,
		bestTier = entry.stars,
		stars = stars,
		coins = coins,
		capped = payout.capped,
		firstReward = payout.firstReward,
		nextMap = if map.custom then nil else StarterMaps.nextMap(mapId),
		walletCoins = profile.coins,
		walletStars = profile.stars,
		custom = map.custom == true,
		myRating = if map.custom then profile.ratings[mapId] else nil,
	})
	TracksService.Finished:Fire(player, map, firstFinish, {
		tier = payout.tier,
		isBest = payout.isBest,
		trailCoins = math.clamp(trailCoins, 0, map.coins),
		ms = math.floor(time * 1000 + 0.5),
	})
end

local function nearRespawn(mapId: string, position: Vector3): boolean
	for _, point in respawnPoints[mapId] or {} do
		if (position - point).Magnitude <= Config.Tracks.respawnAllowance then
			return true
		end
	end
	return false
end

-- One 4 Hz step of the car on the server.
-- * Step faster than top speed x 1.4 + launch allowances (and not a reset to a respawn point): a speed or
--   fly hack. The car goes back to its last checkpoint, the run stops counting, 5 flags a session kicks.
-- * Ground covered over the last 1 s above top speed x 1.25 (+ the speed pad boost): a fake finish
--   guard. The run stops counting.
local function checkSpeed(player: Player, run: Run, from: Vector3, to: Vector3, dt: number, now: number)
	local cfg = Config.Tracks
	local vehicleId = player:GetAttribute("VehicleId")
	local def = Config.Vehicles[vehicleId or ""] or Config.Vehicles[Config.DefaultVehicle]
	local topSpeed = Config.Classes[def.class].topSpeed
	local step = to - from
	local history = speedHistory[player] or {}
	speedHistory[player] = history
	if nearRespawn(run.mapId, to) and step.Magnitude > topSpeed * dt then
		table.clear(history) -- a reset, not driving
		return
	end
	if TracksMath.tooFast(step.Magnitude, dt, topSpeed, cfg.speedLimitFactor, cfg.launchAllowance) then
		run.speedFlags += 1
		run.valid = false
		run.reason = "speed check"
		table.clear(history)
		speedFlags[player] = (speedFlags[player] or 0) + 1
		warn(string.format("[Tracks] %s speed flag (%.0f studs in %.2f s)", player.Name, step.Magnitude, dt))
		Net.fire("Run.Reset", player)
		if
			speedFlags[player] >= cfg.speedFlagsToKick
			and (not RunService:IsStudio() or Config.Net.kickInStudio)
		then
			player:Kick("Connection problem: your car moved too fast. Please rejoin!")
		end
		return
	end
	table.insert(history, { time = now, distance = Vector3.new(step.X, 0, step.Z).Magnitude })
	while history[1] and now - history[1].time > cfg.windowSeconds + 0.5 do
		table.remove(history, 1)
	end
	if
		run.valid
		and TracksMath.windowTooFast(
			history,
			now,
			topSpeed,
			cfg.windowFactor,
			Config.Pads.speedPadBoost,
			cfg.windowSeconds
		)
	then
		run.speedFlags += 1
		run.valid = false
		run.reason = "speed check"
		warn(string.format("[Tracks] %s too fast over 1 s on %s", player.Name, run.mapId))
	end
end

-- Speed checks and ghost samples, from the server's own view of the car
local function sampleRuns(dt: number)
	local cfg = Config.Tracks
	local now = os.clock()
	for player, run in runs do
		local chassis = chassisOf(player)
		local map = mapDefs[run.mapId]
		if chassis == nil or map == nil then
			continue
		end
		local position = chassis.Position

		-- Speed checks at 4 Hz (spec: Anti-exploit)
		local last = lastPositions[player]
		if last == nil or now - last.time >= 1 / cfg.speedCheckRate then
			if last then
				checkSpeed(player, run, last.position, position, now - last.time, now)
			end
			lastPositions[player] = { position = position, time = now }
		end

		-- Ghost samples at 5 Hz, capped at the longest ghost the profile keeps
		run.sampleClock += dt
		if run.sampleClock >= 1 / cfg.ghostRate and #run.samples < cfg.maxGhostSeconds * cfg.ghostRate then
			run.sampleClock -= 1 / cfg.ghostRate
			local t = PoseCodec.fromCFrame(chassis.CFrame)
			table.insert(run.samples, {
				x = t[1] - map.offset[1],
				y = t[2] - map.offset[2],
				z = t[3] - map.offset[3],
				qx = t[4],
				qy = t[5],
				qz = t[6],
				qw = t[7],
			})
		end
	end
end

local function onJoin(player: Player)
	task.spawn(function()
		local profile = DataService.waitFor(player)
		if player.Parent ~= Players then
			return
		end
		local mapId = homeMap(profile)
		if profile and not profile.tut.pipHill then
			EconomyService.funnel(player, 1, "Joined")
		end
		TracksService.enterMap(player, mapId)
	end)
end

function TracksService.init()
	workspace:SetAttribute("Mode", "Tracks")
	for _, map in StarterMaps.maps do
		MapBuilder.build(map)
		indexRespawns(map)
	end

	VehicleService.homeFor = function(player: Player): CFrame?
		local mapId = playerMap[player]
		if mapId == HUB then
			return hubSpawn()
		end
		local map = mapId and mapDefs[mapId]
		if map then
			return MapBuilder.startCFrame(map)
		end
		return nil
	end
	VehicleService.onJoin = onJoin

	-- A new car (an equip, or the watchdog) means the run starts over
	VehicleService.Spawned:Connect(function(player: Player)
		runs[player] = nil
		lastPositions[player] = nil
	end)

	Net.on("Run.Start", onStart)
	Net.on("Run.Checkpoint", onCheckpoint)
	Net.on("Run.Finish", onFinish)
	Net.on("Map.Go", function(player: Player, mapId: string)
		if
			StarterMaps.byId[mapId]
			or mapId == HUB
			or (mapId == TEST_TRACK and DataService.isAdmin(player))
		then
			TracksService.enterMap(player, mapId)
		end
	end)

	DataService.Reset:Connect(function(player: Player)
		task.spawn(TracksService.enterMap, player, StarterMaps.FIRST_MAP)
	end)

	Players.PlayerRemoving:Connect(function(player)
		playerMap[player] = nil
		TracksService.MapChanged:Fire(player, nil)
		runs[player] = nil
		lastPositions[player] = nil
		speedFlags[player] = nil
		speedHistory[player] = nil
		rejectTimes[player] = nil
	end)

	RunService.Heartbeat:Connect(sampleRuns)
end

return TracksService
