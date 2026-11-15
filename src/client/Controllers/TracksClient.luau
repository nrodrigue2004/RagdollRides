-- TracksClient: the Tracks free run on this device (spec: Tracks, Onboarding > Pip's Hill beat sheet).
-- The server times and pays every run; this shows it and reports what the driver did:
-- * Run: READY at the start, the timer starts when the car moves off (Run.Start), checkpoints in order
--   (Run.Checkpoint with the split against your best), the finish (Run.Finish), then the results card
--   and the next map. RETRY puts you back on the start line.
-- * Coins: trail coins are picked up here (a distance check) with a rising-pitch ding; the count goes
--   with Run.Finish and the server clamps it to the map's coins.
-- * Moving pieces (spinners, hammers, pistons, tilt decks; Shared/Movers) move here from the server's
--   clock, so everyone sees the same angle. A hitting part that reaches the car throws the rider (a
--   piston shoves the car instead). Pip's Hill respawns by itself after 1 s.
-- * Player maps: BrowseClient registers a shared map's definition (Map.Data) and it drives like any
--   map; its results card adds rating and reporting, and NEXT is the next card from the browse list.
-- * Builder maps: BuilderClient registers its draft here and TESTs it like any map. A test from the
--   start gate is timed by the server (it proves the map can be finished and sets the creator time);
--   a practice run from a checkpoint stays on this device. Both end in TestFinished, not the results card.
-- * Ghosts: your best run on this map drives beside you at 60% opacity; other players' cars are ghosts
--   too (60% opacity, no collisions).
-- * Onboarding (first time on a map): DRIVE pulses GAS at the start, JUMP! before Pip's Hill's ramp,
--   LEAN BACK! on Lean Ledge, Pip honks if you sit still for 6 s, steering assist is High on the first 2.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapSpace = require(Shared.MapSpace)
local Movers = require(Shared.Movers)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)
local VehicleBuilder = require(Shared.VehicleBuilder)

local Client = script.Parent.Parent
local Confetti = require(Client:WaitForChild("Fx"):WaitForChild("Confetti"))
local TracksHud = require(Client:WaitForChild("Ui"):WaitForChild("TracksHud"))

local LocalPlayer = Players.LocalPlayer

local TracksClient = {}

-- A builder test ended: { ok, time, test = true } from the server, or { practice = true, time }
TracksClient.TestFinished = Signal.new()
-- A quick race run's answer (Run.Result with race = true): RaceClient shows it
TracksClient.RaceRun = Signal.new()

local COIN_RADIUS = 7
local COIN_STREAK_GAP = 1.2 -- pickups closer together than this climb in pitch
local GHOST_OPACITY = 0.6
local RESULT_TIMEOUT = 4
local PUSH_COOLDOWN = 0.6

local controllers: any = nil
local map: StarterMaps.MapDef? = nil
local runState = "idle" -- "idle" (no map), "ready", "running", "finished"
local startClock = 0
local finishTime = 0
local reached = 0
local collected: { [number]: boolean } = {}
local coinCount = 0
local coinPoints: { Vector3 } = {}
local lastCoinClock = 0
local coinStreak = 0
local cues: { { kind: string, cf: CFrame, size: Vector3, shown: boolean } } = {}
local hits: { Movers.Hit } = {}
local lastPush = 0
local coinParts: { [BasePart]: CFrame } = {}
local moverParts: { [BasePart]: { pivot: CFrame, offset: CFrame, motion: Movers.Motion } } = {}
-- Every map this client can drive: the starter maps, plus builder maps registered by id
local maps: { [string]: StarterMaps.MapDef } = table.clone(StarterMaps.byId)
-- Builder test: nil (a normal run), "test" (from the start gate, timed by the server) or "practice"
local testKind: string? = nil
local practiceFrom = 0
local ghostRuns: { [string]: { samples: { GhostCodec.Sample }, rate: number } } = {}
local ghostModel: Model? = nil
local ghostVehicleId: string? = nil
local ghostFolder: Folder
local idleTime = 0
local resultToken = 0

local function firstTimeHere(): boolean
	local view = controllers.Profile.get()
	if map == nil or map.tut == nil or view == nil then
		return false
	end
	return view.tut[map.tut] ~= true
end

local function device(): string
	return controllers.Input.lastDevice()
end

local function cueText(kind: string): string
	local d = device()
	if kind == "drive" then
		return if d == "touch"
			then "HOLD GAS TO DRIVE!"
			elseif d == "gamepad" then "HOLD RT TO DRIVE!"
			else "HOLD W TO DRIVE!"
	elseif kind == "jump" then
		return if d == "touch" then "JUMP!" elseif d == "gamepad" then "Ⓐ JUMP!" else "SPACE: JUMP!"
	elseif kind == "lean" then
		return if d == "touch"
			then "LEAN BACK!"
			elseif d == "gamepad" then "STICK DOWN: LEAN BACK!"
			else "Q: LEAN BACK!"
	end
	return ""
end

---------------------------------------------------------------------------
-- Ghosts
---------------------------------------------------------------------------

local function hideGhost()
	if ghostModel then
		ghostModel.Parent = nil
	end
end

local function makeGhost(vehicleId: string): Model
	local model = VehicleBuilder.build(vehicleId, 0)
	model.Name = "Ghost"
	model:SetAttribute("OwnerUserId", nil)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
			if d.Transparency < 1 then
				d.Transparency = 1 - GHOST_OPACITY * (1 - d.Transparency)
			end
		end
	end
	return model
end

local function showGhostAt(elapsed: number)
	local current = map
	local run = current and ghostRuns[current.id]
	if current == nil or run == nil or #run.samples < 2 then
		hideGhost()
		return
	end
	local position = elapsed * run.rate + 1
	local i0 = math.floor(position)
	if i0 >= #run.samples then
		hideGhost() -- the ghost has finished
		return
	end
	local vehicleId = LocalPlayer:GetAttribute("VehicleId") or Config.DefaultVehicle
	if ghostModel == nil or ghostVehicleId ~= vehicleId then
		if ghostModel then
			ghostModel:Destroy()
		end
		ghostModel = makeGhost(vehicleId)
		ghostVehicleId = vehicleId
	end
	local a, b = run.samples[i0], run.samples[i0 + 1]
	local o = current.offset
	local cfA = CFrame.new(a.x + o[1], a.y + o[2], a.z + o[3], a.qx, a.qy, a.qz, a.qw)
	local cfB = CFrame.new(b.x + o[1], b.y + o[2], b.z + o[3], b.qx, b.qy, b.qz, b.qw)
	local model = ghostModel :: Model
	model:PivotTo(cfA:Lerp(cfB, position - i0))
	if model.Parent ~= ghostFolder then
		model.Parent = ghostFolder
	end
end

---------------------------------------------------------------------------
-- Map setup and runs
---------------------------------------------------------------------------

local function isOnMap(part: Instance): boolean
	return map ~= nil and part:GetAttribute("MapId") == map.id
end

local function setCoinVisible(part: BasePart, visible: boolean)
	part.LocalTransparencyModifier = if visible then 0 else 1
end

local function refreshCoins()
	for part in coinParts do
		local index = part:GetAttribute("CoinIndex")
		setCoinVisible(part, not (isOnMap(part) and collected[index :: number]))
	end
end

local function hudRunLine()
	local current = map
	if current then
		TracksHud.setCheckpoints(reached, current.checkpoints)
	else
		TracksHud.setCheckpoints(0, 0)
	end
end

-- Back to READY on the start line (a new car, a new map, or RETRY)
local function resetRun()
	resultToken += 1
	runState = if map then "ready" else "idle"
	reached = if testKind == "practice" then practiceFrom else 0
	coinCount = 0
	coinStreak = 0
	table.clear(collected)
	for _, cue in cues do
		cue.shown = false
	end
	idleTime = 0
	hideGhost()
	refreshCoins()
	TracksHud.setTimer(if map then 0 else nil)
	hudRunLine()
	if map and map.id == StarterMaps.FIRST_MAP and firstTimeHere() then
		TracksHud.showCue(cueText("drive"), 30)
		controllers.Hud.pulse("Gas", 30)
	end
end

local function prepareMap(mapId: string?)
	local current = if mapId then maps[mapId] else nil
	map = current
	table.clear(coinPoints)
	table.clear(cues)
	hits = if current then Movers.hits(current) else {}
	TracksHud.hideResults()
	if current == nil then
		controllers.Vehicle.setKillY(nil)
		controllers.Ragdoll.setAutoRespawn(nil)
		controllers.Settings.forceSteerAssist(nil)
		resetRun()
		return
	end
	for _, piece in current.pieces do
		if piece.kind == "Coin" then
			table.insert(coinPoints, MapSpace.point(current, piece.x, piece.y, piece.z))
		elseif piece.kind == "JumpCue" or piece.kind == "LeanCue" then
			table.insert(cues, {
				kind = if piece.kind == "JumpCue" then "jump" else "lean",
				cf = MapSpace.pieceCFrame(current, piece),
				size = Vector3.new(piece.sx, piece.sy, piece.sz),
				shown = false,
			})
		end
	end
	controllers.Vehicle.setKillY(current.offset[2] + StarterMaps.killY(current))
	controllers.Ragdoll.setAutoRespawn(current.autoRespawn)
	controllers.Settings.forceSteerAssist(
		if current.assist and firstTimeHere() then Config.Tracks.firstTracksAssist else nil
	)
	resetRun()
end

local function elapsed(): number
	return os.clock() - startClock
end

local function startRun()
	local current = map
	if current == nil or (current :: any).race then
		return -- a quick race starts at GO (TracksClient.startRace)
	end
	runState = "running"
	startClock = os.clock()
	if testKind ~= "practice" then
		Net.send("Run.Start", current.id)
	end
	TracksHud.hideCue()
	controllers.Hud.stopPulse("Gas")
end

local function friendlyReason(reason: string?): string
	if reason == nil then
		return "This run didn't count."
	elseif reason == "speed check" then
		return "Your car moved too fast for this run."
	elseif string.find(reason, "checkpoint", 1, true) then
		return "A checkpoint was missed."
	elseif reason == "faster than the map allows" then
		return "That time was too fast to be real."
	elseif reason == "not at the finish" then
		return "The finish line didn't see you."
	end
	return "This run didn't count."
end

-- RETRY: the car back to the start line (with the reset fade), a fresh run
local function restart()
	local current = map
	if current == nil then
		return
	end
	local start = MapSpace.startCFrame(current)
	local fromIndex = 0
	local practicePiece = if testKind == "practice" and practiceFrom > 0
		then StarterMaps.find(current, "Checkpoint", practiceFrom)
		else nil
	if practicePiece then
		-- A practice run starts again at its checkpoint, on the ground, facing along the road
		start = CFrame.new(
			MapSpace.point(current, practicePiece.x, practicePiece.y - practicePiece.sy / 2, practicePiece.z)
		) * CFrame.Angles(0, math.rad(practicePiece.yaw), 0)
		fromIndex = practiceFrom
	end
	controllers.Vehicle.setCheckpoint(start, fromIndex)
	local vehicle = controllers.Vehicle.getState()
	if controllers.Ragdoll.isRagdolled() then
		controllers.Ragdoll.respawn()
	elseif vehicle and vehicle.sequence ~= nil then
		-- Something else holds the car (a replay, a flip): put it on the line now
		controllers.Vehicle.placeAt(start + Vector3.new(0, controllers.Vehicle.rideHeight() + 0.3, 0))
	else
		controllers.Vehicle.reset()
	end
	resetRun()
end

local function goNext(nextMap: string)
	Net.send("Map.Go", nextMap)
end

local function showResult(result: { [string]: any })
	local current = map
	if current == nil then
		return
	end
	local title
	if not result.ok then
		title = "RUN NOT COUNTED"
	elseif result.firstReward and current.tut == "pipHill" then
		title = "PIP'S HILL DONE!"
	elseif result.firstFinish then
		title = "FIRST FINISH!"
	elseif result.isBest then
		title = "NEW BEST!"
	else
		title = "FINISH!"
	end
	local bestText: string? = nil
	if result.ok and not result.firstFinish then
		if result.isBest and result.previousBest then
			bestText = "Was " .. TracksMath.formatTime(result.previousBest)
		elseif result.best then
			bestText = "Best " .. TracksMath.formatTime(result.best)
		end
	end
	local nextMap = result.nextMap or StarterMaps.nextMap(current.id)
	local nextDef = StarterMaps.byId[nextMap]
	local nextName = if nextDef then nextDef.name else ""
	local onNext = function()
		goNext(nextMap)
	end
	local rate = nil
	local mapName = current.name
	if current.custom then
		-- A player map: NEXT drives the next card from the browse list; rate and report below the card
		local upNext = controllers.Browse.nextAfter(current.id)
		nextName = if upNext then upNext.name else "More maps"
		onNext = function()
			controllers.Browse.playNext(current.id)
		end
		local about = controllers.Browse.info(current.id)
		if about then
			mapName ..= "  by " .. about.creator
		end
		if result.ok then
			local mine = about ~= nil and about.owner == LocalPlayer.UserId
			rate = {
				current = result.myRating or (about and about.myRating),
				canRate = not mine,
				reported = controllers.Browse.hasReported(current.id),
				onRate = function(stars: number)
					controllers.Browse.rate(current.id, stars)
				end,
				onReport = function(reason: string)
					controllers.Browse.report(current.id, reason)
				end,
			}
			if mine then
				-- Nothing to rate or report on your own map
				rate = nil
			end
		end
	end
	local view = controllers.Profile.get()
	TracksHud.showResults({
		ok = result.ok == true,
		title = title,
		mapName = mapName,
		time = result.time,
		bestText = bestText,
		tier = result.tier or 0,
		newStars = result.stars or 0,
		coins = result.coins or 0,
		capped = result.capped == true,
		reason = if result.ok then nil else friendlyReason(result.reason),
		nextName = nextName,
		goal = controllers.Profile.goal(),
		walletCoins = result.walletCoins or (view and view.coins) or 0,
		walletStars = result.walletStars or (view and view.stars) or 0,
		rate = rate,
	}, {
		onRetry = restart,
		onNext = onNext,
		onStarPop = function(_, isNew)
			if isNew then
				controllers.Juice.fire("StarEarned")
			end
		end,
	})
end

local function finishRun(finishPart: BasePart)
	local current = map
	if current == nil then
		return
	end
	runState = "finished"
	finishTime = elapsed()
	TracksHud.setTimer(finishTime)
	controllers.Juice.fire("Finish")
	Confetti.burst(finishPart.Position + Vector3.new(0, 4, 0))
	hideGhost()
	if testKind == "practice" then
		TracksClient.TestFinished:Fire({ practice = true, time = finishTime })
		return
	end
	Net.send("Run.Finish", current.id, finishTime, coinCount)
	if (current :: any).race then
		return -- RaceClient shows the place, then the race results
	end
	-- No answer (a dropped request): say so rather than leave the player waiting
	resultToken += 1
	local token = resultToken
	task.delay(RESULT_TIMEOUT, function()
		if resultToken == token and runState == "finished" and not TracksHud.resultsOpen() then
			if testKind then
				TracksClient.TestFinished:Fire({ ok = false, test = true, time = finishTime })
			else
				showResult({ ok = false, mapId = current.id, nextMap = StarterMaps.nextMap(current.id) })
			end
		end
	end)
end

local function onCheckpoint(index: number, part: BasePart?)
	local current = map
	if current == nil or runState ~= "running" or part == nil or not isOnMap(part) then
		return
	end
	if index ~= reached + 1 then
		return
	end
	reached = index
	local t = elapsed()
	if testKind ~= "practice" then
		Net.send("Run.Checkpoint", current.id, index, t)
	end
	hudRunLine()
	local best = controllers.Profile.track(current.id)
	if best and best.splits and best.splits[index] then
		TracksHud.showSplit(t * 1000 - best.splits[index])
	end
end

local function onTouched(part: BasePart)
	local current = map
	if current == nil or runState ~= "running" or not isOnMap(part) then
		return
	end
	if CollectionService:HasTag(part, "Finish") then
		if reached >= current.checkpoints then
			finishRun(part)
		else
			TracksHud.toast("Go through every checkpoint first!")
		end
	end
end

local function collectCoin(index: number)
	collected[index] = true
	coinCount += 1
	local now = os.clock()
	coinStreak = if now - lastCoinClock <= COIN_STREAK_GAP then coinStreak + 1 else 0
	lastCoinClock = now
	controllers.Juice.fire("Coin", { pitch = 1 + math.min(coinStreak, 12) * 0.06, volume = 0.5 })
	for part in coinParts do
		if isOnMap(part) and part:GetAttribute("CoinIndex") == index then
			setCoinVisible(part, false)
		end
	end
end

local function inBox(cf: CFrame, size: Vector3, point: Vector3, grow: Vector3): boolean
	local p = cf:PointToObjectSpace(point)
	return math.abs(p.X) <= size.X / 2 + grow.X
		and math.abs(p.Y) <= size.Y / 2 + grow.Y
		and math.abs(p.Z) <= size.Z / 2 + grow.Z
end

local function update(dt: number)
	TracksHud.update(dt)
	local t = os.clock()

	-- Spin coins and spinners near the camera (all clients, any state)
	local camera = workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position or Vector3.zero
	for part, base in coinParts do
		if part.LocalTransparencyModifier < 1 and (part.Position - eye).Magnitude < 400 then
			part.CFrame = CFrame.new(base.Position) * CFrame.Angles(0, t * 3, 0) * base.Rotation
		end
	end
	local now = workspace:GetServerTimeNow()
	for part, info in moverParts do
		if (info.pivot.Position - eye).Magnitude < 600 then
			part.CFrame = info.pivot * Movers.transform(info.motion, now) * info.offset
		end
	end

	local current = map
	local vehicle = controllers.Vehicle.getState()
	if current == nil or vehicle == nil or runState == "idle" then
		return
	end
	local chassis: BasePart = vehicle.chassis
	local position = chassis.Position
	local ragdolled = controllers.Ragdoll.isRagdolled()

	if runState == "ready" then
		local input = vehicle.input
		if (input and input.throttle > 0.1) or math.abs(vehicle.forwardSpeed) > 4 then
			startRun()
		end
	end

	if runState == "running" then
		local e = elapsed()
		TracksHud.setTimer(e)
		showGhostAt(e)
	end

	if runState == "ready" or runState == "running" then
		-- Coins
		if not ragdolled then
			for index, point in coinPoints do
				if not collected[index] and (position - point).Magnitude <= COIN_RADIUS then
					collectCoin(index)
				end
			end
		end
		-- Hitting parts: bars and hammer heads throw the rider, pistons shove the car while they punch out
		if not ragdolled then
			for _, hit in hits do
				if not Movers.touches(hit, now, position) then
					continue
				end
				if hit.part.hit == "push" then
					if Movers.extending(hit.motion, now) and os.clock() - lastPush >= PUSH_COOLDOWN then
						lastPush = os.clock()
						controllers.Vehicle.applyKick(Movers.pushVelocity(hit, now))
						controllers.Juice.fire("PistonPush")
					end
				else
					controllers.Vehicle.hazardHit(nil)
				end
			end
		end
		-- First-time cues
		if firstTimeHere() then
			for _, cue in cues do
				if not cue.shown and inBox(cue.cf, cue.size, position, Vector3.new(2, 4, 2)) then
					cue.shown = true
					TracksHud.showCue(cueText(cue.kind), 1.6)
					controllers.Hud.pulse(if cue.kind == "jump" then "Jump" else "LeanBack", 1.6)
				end
			end
			-- Pip honks and points if the car sits still
			if
				current.id == StarterMaps.FIRST_MAP
				and not ragdolled
				and math.abs(vehicle.forwardSpeed) < 2
				and not TracksHud.resultsOpen()
			then
				idleTime += dt
				if idleTime >= Config.Tracks.idleHonkTime then
					idleTime = 0
					controllers.Juice.fire("Honk")
					TracksHud.showCue("HONK HONK! " .. cueText("drive"), 2.5)
					controllers.Hud.pulse("Gas", 3)
				end
			else
				idleTime = 0
			end
		end
	end
end

---------------------------------------------------------------------------
-- Parts streamed in: coins and spinners keep their built frame as the base for spinning
---------------------------------------------------------------------------

local function watchTag(tag: string, store: { [BasePart]: CFrame }, onAdded: ((BasePart) -> ())?)
	local function add(instance: Instance)
		if instance:IsA("BasePart") then
			store[instance] = (instance:GetAttribute("BaseCFrame") :: CFrame?) or instance.CFrame
			if onAdded then
				onAdded(instance)
			end
		end
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		store[instance :: BasePart] = nil
	end)
	for _, instance in CollectionService:GetTagged(tag) do
		add(instance)
	end
end

-- Other players' cars and riders are see-through in Tracks, except the cars racing you
local remoteModels: { [Model]: boolean } = {}

local function inMyRace(model: Model): boolean
	local raceId = LocalPlayer:GetAttribute("RaceId")
	if raceId == nil then
		return false
	end
	local owner = Players:GetPlayerByUserId(model:GetAttribute("OwnerUserId") or 0)
	return owner ~= nil and owner:GetAttribute("RaceId") == raceId
end

local function shade(model: Model)
	local value = if workspace:GetAttribute("Mode") == "Tracks" and not inMyRace(model)
		then 1 - GHOST_OPACITY
		else 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = value
		end
	end
end

local function ghostRemote(model: Instance)
	if not model:IsA("Model") or model:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
		return
	end
	local m = model :: Model
	remoteModels[m] = true
	shade(m)
	m.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if workspace:GetAttribute("Mode") == "Tracks"
					and not inMyRace(m)
				then 1 - GHOST_OPACITY
				else 0
		end
	end)
	m.AncestryChanged:Connect(function()
		if m.Parent == nil then
			remoteModels[m] = nil
		end
	end)
end

-- Someone joined or left a race: re-shade every other car
function TracksClient.reshadeCars()
	for model in remoteModels do
		shade(model)
	end
end

---------------------------------------------------------------------------

function TracksClient.getMap(): StarterMaps.MapDef?
	return map
end

function TracksClient.getRunState(): string
	return runState
end

-- Builder maps: register a map definition (PieceCatalog.toMapDef) so it can be driven like any map
function TracksClient.registerMap(def: StarterMaps.MapDef)
	maps[def.id] = def
	if (map and map.id == def.id) or LocalPlayer:GetAttribute("MapId") == def.id then
		prepareMap(def.id)
	end
end

-- A quick race's GO (server time): the run is on, timed from GO
function TracksClient.startRace(goAt: number)
	local current = map
	if current == nil or not (current :: any).race or runState ~= "ready" then
		return
	end
	runState = "running"
	startClock = os.clock() - math.max(0, workspace:GetServerTimeNow() - goAt)
	TracksHud.hideCue()
end

function TracksClient.unregisterMap(id: string)
	if StarterMaps.byId[id] == nil then
		maps[id] = nil
	end
end

-- Builder TEST: kind "test" (from the start gate, server timed) or "practice" (from checkpoint
-- `fromCheckpoint`, this device only); nil goes back to normal runs.
function TracksClient.setTest(kind: string?, fromCheckpoint: number?)
	testKind = kind
	practiceFrom = if kind == "practice" then fromCheckpoint or 0 else 0
	TracksHud.hideResults()
	if map then
		resetRun()
	end
end

function TracksClient.getTest(): string?
	return testKind
end

function TracksClient.toast(message: string)
	TracksHud.toast(message)
end

-- RETRY: back to the start line (a practice run: its checkpoint), a fresh run
TracksClient.retry = restart

-- The builder's TEST: no map picker (BUILD goes back to building)
function TracksClient.setBuilderButtons(testing: boolean)
	TracksHud.setButtonVisible("Maps", not testing)
end

local NOTICES = {
	saveDown = "Saving is down right now, so progress from this session won't be kept. Sorry!",
	mapGone = "That map isn't shared any more.",
	mapHidden = "That map is hidden while we check it.",
	mapHiddenOwner = "One of your maps was hidden for review. Check MY MAPS.",
	mapsFull = "This server is busy loading maps. Try again in a moment!",
	mapBroken = "That map couldn't load. Try another one!",
	publishBanned = "Sharing maps is paused for your account for now.",
	adminDone = "Done.",
	adminFailed = "That didn't work. Try again.",
	giftReceived = "A friend sent you 10 coins!",
	equipLocked = "Finish the race first!",
	partyFull = "That party is full (4 players).",
	partyFriendsOnly = "Parties are for Roblox friends.",
	partyInviteSent = "Invite sent!",
	partyInviteGone = "That invite ran out.",
	raceFromHub = "Quick races start from the hub's race pad.",
	modeSoon = "Coming soon! This mode is being built.",
	rankedLocked = "Ranked opens after 3 casual Bumper Brawl rounds. Play some casual first!",
	versusLocked = "Versus opens after 2 co-op Highway runs. Ride co-op first!",
	seasonRewards = "New ranked season! Your rewards are in the garage.",
	teleportFailed = "Couldn't get there. Try again in a moment!",
}

function TracksClient.init(all)
	controllers = all
	ghostFolder = Instance.new("Folder")
	ghostFolder.Name = "LocalGhosts"
	ghostFolder.Parent = workspace
end

function TracksClient.start()
	while controllers.Hud.getGui() == nil do
		task.wait()
	end
	TracksHud.build(controllers.Hud.getGui(), controllers.Hud.getResetButton(), {
		onMaps = function()
			if controllers.Browse then
				controllers.Browse.toggle()
			end
		end,
		onBuild = function()
			if controllers.Builder then
				controllers.Builder.onBuildButton()
			end
		end,
		onShop = function()
			controllers.Shop.toggle("shop")
		end,
		onGarage = function()
			controllers.Shop.toggle("garage")
		end,
		onQuests = function()
			controllers.Shop.toggle("quests")
		end,
		onHub = function()
			if controllers.Hub then
				controllers.Hub.goHub()
			elseif controllers.Brawl then
				controllers.Brawl.goHome()
			elseif controllers.Highway then
				controllers.Highway.goHome()
			end
		end,
		onTop = function()
			if controllers.Hub then
				controllers.Hub.openBoard()
			elseif controllers.Highway then
				controllers.Highway.openBoard()
			end
		end,
		onSettings = function()
			if controllers.Settings.isOpen() then
				controllers.Settings.close()
			else
				controllers.Settings.open()
			end
		end,
	})
	TracksHud.setTimer(nil)
	TracksHud.setCheckpoints(0, 0)
	if controllers.Hub == nil then
		-- A mode place (Cinder Cove, Sunny Pass): no maps or builder here; HUB goes back to the park.
		-- TOP shows the Highway boards in Sunny Pass.
		for _, name in { "Maps", "Build", "Top" } do
			TracksHud.setButtonVisible(name, name == "Top" and controllers.Highway ~= nil)
		end
		TracksHud.setButtonVisible("Hub", true)
	end

	controllers.Profile.Changed:Connect(function(view, previous)
		TracksHud.setWallet(view.coins, view.stars, controllers.Profile.goal())
		if previous == nil then
			-- The first profile decides the first-time cues and forced assist for the map we are on
			prepareMap(LocalPlayer:GetAttribute("MapId"))
		end
	end)
	controllers.Profile.Notice:Connect(function(key)
		local message = NOTICES[key]
		if message then
			TracksHud.toast(message, 8)
		end
	end)

	watchTag("Coin", coinParts, function(part)
		local index = part:GetAttribute("CoinIndex")
		setCoinVisible(part, not (isOnMap(part) and collected[index :: number]))
	end)
	local function addMover(instance: Instance)
		if not instance:IsA("BasePart") then
			return
		end
		local pivot = instance:GetAttribute("Pivot")
		local offset = instance:GetAttribute("Offset")
		if typeof(pivot) ~= "CFrame" or typeof(offset) ~= "CFrame" then
			return
		end
		moverParts[instance] = {
			pivot = pivot,
			offset = offset,
			motion = {
				motion = instance:GetAttribute("Motion") or "",
				phase = instance:GetAttribute("Phase") or 0,
				speed = instance:GetAttribute("Speed") or 0,
				period = instance:GetAttribute("Period") or 1,
				amount = instance:GetAttribute("Amount") or 0,
			},
		}
	end
	CollectionService:GetInstanceAddedSignal("Mover"):Connect(addMover)
	CollectionService:GetInstanceRemovedSignal("Mover"):Connect(function(instance)
		moverParts[instance :: BasePart] = nil
	end)
	for _, instance in CollectionService:GetTagged("Mover") do
		addMover(instance)
	end

	LocalPlayer:GetAttributeChangedSignal("MapId"):Connect(function()
		prepareMap(LocalPlayer:GetAttribute("MapId"))
	end)
	prepareMap(LocalPlayer:GetAttribute("MapId"))

	-- A new car (map entry, equip) starts a fresh run
	controllers.Vehicle.Spawned:Connect(function()
		if map then
			resetRun()
		end
	end)
	controllers.Vehicle.CheckpointReached:Connect(onCheckpoint)
	controllers.Vehicle.Touched:Connect(onTouched)

	Net.listen("Run.Result", function(result)
		if type(result) ~= "table" or map == nil or result.mapId ~= map.id or runState ~= "finished" then
			return
		end
		resultToken += 1
		if result.race then
			TracksClient.RaceRun:Fire(result)
			return
		end
		if testKind then
			TracksClient.TestFinished:Fire(result)
			return
		end
		showResult(result)
	end)
	-- The server's speed check: back to the last checkpoint (the run no longer counts)
	Net.listen("Run.Reset", function()
		controllers.Vehicle.reset()
		TracksHud.toast("Whoa, too fast! Back to the checkpoint.")
	end)
	Net.listen("Run.Ghost", function(mapId, ghost)
		if type(mapId) ~= "string" then
			return
		end
		if type(ghost) ~= "string" then
			ghostRuns[mapId] = nil
			return
		end
		local raw = GhostCodec.fromBase64(ghost)
		local samples, rate = nil, 0
		if raw then
			samples, rate = GhostCodec.decode(raw)
		end
		if samples and rate > 0 then
			ghostRuns[mapId] = { samples = samples, rate = rate }
		end
	end)

	local vehicles = workspace:WaitForChild("Vehicles")
	vehicles.ChildAdded:Connect(ghostRemote)
	for _, model in vehicles:GetChildren() do
		ghostRemote(model)
	end

	RunService.RenderStepped:Connect(update)
end

return TracksClient
