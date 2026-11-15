-- RaceService: Tracks quick races (spec: Tracks: quick race; Round state machine; Hub > race pad).
-- * Race.Join from the hub (the race pad or the TRACKS card's QUICK RACE chip). A party leader brings
--   every party member who is in the hub. Leaving the hub before the race starts leaves the queue.
-- * One open lobby at a time: it starts 10 s after the 2nd racer joins, or at once with 8. Up to 4
--   races run at once, each on its own copy of a starter map (Pip's Hill stays a tutorial) in a race
--   slot far from everything else, built while the 3 s countdown runs.
-- * Countdown: cars on a 4 x 2 grid, held but steerable (the client holds them). Collisions between
--   racers are on (free runs stay ghosted). Damage is looks-only unless the map has Full damage on.
-- * Play: every racer's run starts on the server at GO and is checked like any run (checkpoints in
--   order, speed checks, the finish). Ends 20 s after the first finisher, when all are done, or 180 s.
-- * Results (6 s, skippable): places pay 80 / 60 / 45 / 35 / 25 / 20 / 15 / 10, a DNF 10, all inside
--   the Tracks daily cap. Then everyone who stayed is back in the hub and in the next lobby
--   (auto-requeue); Race.Leave stops that.
-- Race.Result goes to each racer: { mapName, places = { { userId, name, place, time, dnf } }, mine }.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local MapBuilder = require(Shared.MapBuilder)
local Net = require(Shared.Net)
local RaceMath = require(Shared.RaceMath)
local Signal = require(Shared.Util.Signal)
local StarterMaps = require(Shared.StarterMaps)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local HubService = require(Services.HubService)
local PartyService = require(Services.PartyService)
local RoundManager = require(Services.RoundManager)
local TracksService = require(Services.TracksService)
local VehicleService = require(Services.VehicleService)

local RaceService = {}

RaceService.Finished = Signal.new() -- (player, place, dnf): a race this player was in has ended

local HUB = TracksService.HUB
local cfg = Config.Race

local lobby: any = nil
local active: { any } = {}
local roundOf: { [Player]: any } = {}
local slotUsed: { [number]: boolean } = {}
local racesRun = 0

-- The maps quick races use: every starter map after Pip's Hill, in order
local RACE_MAPS = {}
for _, map in StarterMaps.maps do
	if map.id ~= StarterMaps.FIRST_MAP then
		table.insert(RACE_MAPS, map.id)
	end
end

local function freeSlot(): number?
	for slot = 1, cfg.maxRaces do
		if not slotUsed[slot] then
			return slot
		end
	end
	return nil
end

local function racing(player: Player): boolean
	local round = roundOf[player]
	return round ~= nil and round ~= lobby and round:phase() ~= "Lobby"
end
RaceService.isRacing = racing

function RaceService.count(): number
	local n = 0
	for _, round in active do
		n += #round.players
	end
	return n
end

local function clearAttributes(player: Player)
	player:SetAttribute("RaceId", nil)
	player:SetAttribute("DamageMode", nil)
end

---------------------------------------------------------------------------
-- The race mode (RoundManager calls these)
---------------------------------------------------------------------------

local mode = {}

function mode.counts(round): { players: number, finished: number, skipped: number }
	local finished, skipped = 0, 0
	for _, player in round.players do
		if round.data.times[player.UserId] or round.data.out[player.UserId] then
			finished += 1
		end
		if round.data.skipped[player] then
			skipped += 1
		end
	end
	return { players = #round.players, finished = finished, skipped = skipped }
end

function mode.info(round, _player: Player): { [string]: any }?
	local def = round.data.def
	return {
		map = if def
			then { id = def.id, base = round.data.base, offset = def.offset, name = def.name }
			else nil,
		order = round.data.order,
		goAt = round.data.goAt,
		building = round.data.building,
	}
end

local function newLobby()
	local round = RoundManager.new("race", cfg :: any, mode)
	round.data = { times = {}, out = {}, skipped = {}, order = nil }
	lobby = round
	return round
end

-- Countdown: claim a slot, build the map copy and put the cars on the grid
function mode.init(round)
	if round == lobby then
		lobby = nil -- new joiners get a new lobby
	end
	table.insert(active, round)
	local slot = freeSlot() :: number
	slotUsed[slot] = true
	round.data.slot = slot
	local base = RaceMath.pickMap(RACE_MAPS, racesRun) :: string
	racesRun += 1
	local source = StarterMaps.byId[base]
	local o = cfg.slotOrigin
	local def = table.clone(source) :: any
	def.id = "race" .. slot
	def.offset = { o[1], o[2], o[3] - (slot - 1) * cfg.slotSpacing }
	def.race = round.id
	def.tut = nil
	def.reward = nil
	def.autoRespawn = source.autoRespawn
	round.data.def = def
	round.data.base = base
	round.data.building = true
	local racers = table.clone(round.players)
	task.spawn(function()
		MapBuilder.destroy(def.id)
		MapBuilder.buildAsync(def, Config.Builder.buildBatch)
		TracksService.registerMap(def)
		round.data.building = false
		-- The countdown runs from when the cars are on the grid (plus a moment to stream the road in)
		round.state.endsAt = workspace:GetServerTimeNow() + cfg.countdown + 0.5
		local start = MapBuilder.startCFrame(def)
		for index, player in racers do
			if roundOf[player] == round and player.Parent == Players then
				player:SetAttribute("RaceId", round.id)
				player:SetAttribute("DamageMode", if def.fullDamage then "TracksFullDamage" else "TracksRace")
				local right, forward = RaceMath.gridOffset(index, cfg.gridSpacing)
				task.spawn(TracksService.enterMap, player, def.id, start * CFrame.new(right, 0, -forward))
			end
		end
		round:broadcast()
	end)
end

-- GO: every racer's run starts now on the server's clock
function mode.start(round)
	local def = round.data.def
	round.data.goAt = workspace:GetServerTimeNow()
	for _, player in round.players do
		TracksService.startRun(player, def.id)
	end
end

local orderClock = 0
function mode.tick(round, dt: number)
	orderClock += dt
	if orderClock < 1 then
		return
	end
	orderClock = 0
	local list = {}
	for _, player in round.players do
		local count, at = TracksService.progress(player)
		table.insert(list, {
			userId = player.UserId,
			checkpoints = count,
			at = at,
			finished = round.data.times[player.UserId],
		})
	end
	round.data.order = RaceMath.liveOrder(list)
	round:broadcast()
end

-- Results: places and pay
function mode.finish(round)
	local def = round.data.def
	local racers = {}
	for _, player in round.players do
		table.insert(racers, { userId = player.UserId, time = round.data.times[player.UserId] })
	end
	local placings = RaceMath.places(racers)
	local names = {}
	for _, player in round.players do
		names[player.UserId] = player.DisplayName
	end
	local places = {}
	local paid: { [number]: number } = {}
	local capped: { [number]: boolean } = {}
	for _, placing in placings do
		local player = Players:GetPlayerByUserId(placing.userId)
		table.insert(places, {
			userId = placing.userId,
			name = names[placing.userId] or "",
			place = placing.place,
			time = placing.time,
			dnf = placing.dnf,
		})
		if player then
			local want = RaceMath.coins(placing, cfg)
			local got = EconomyService.grantCoins(player, want, "tracks", "Race_" .. placing.place)
			paid[placing.userId] = got
			capped[placing.userId] = got < want
			local profile = DataService.get(player)
			if profile then
				profile.stats.races += 1
				DataService.changed(player)
			end
			RaceService.Finished:Fire(player, placing.place, placing.dnf)
			pcall(function()
				game:GetService("AnalyticsService"):LogCustomEvent(player, "quick_race", placing.place, {
					[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = round.data.base,
					[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = tostring(#placings),
				})
			end)
		end
	end
	for _, placing in placings do
		local player = Players:GetPlayerByUserId(placing.userId)
		if player then
			Net.fire("Race.Result", player, {
				mapName = def and def.name or "",
				places = places,
				mine = {
					place = placing.place,
					dnf = placing.dnf,
					coins = paid[placing.userId] or 0,
					capped = capped[placing.userId] == true,
				},
				requeue = cfg.results,
			})
		end
	end
end

local function join(player: Player): boolean
	if roundOf[player] or player.Parent ~= Players or DataService.get(player) == nil then
		return false
	end
	if lobby == nil or lobby.closed or #lobby.players >= cfg.maxPlayers then
		newLobby()
	end
	if lobby:add(player) then
		roundOf[player] = lobby
		return true
	end
	return false
end

-- Requeue: everyone who stayed goes back to the hub and into the next lobby; the slot is freed
function mode.cleanup(round)
	local def = round.data.def
	local stayed = table.clone(round.players)
	for _, player in stayed do
		roundOf[player] = nil
		clearAttributes(player)
	end
	table.clear(round.players)
	round:close()
	local index = table.find(active, round)
	if index then
		table.remove(active, index)
	end
	for _, player in stayed do
		if player.Parent == Players then
			task.spawn(function()
				TracksService.enterMap(player, HUB)
				join(player)
			end)
		end
	end
	if def then
		TracksService.unregisterMap(def.id)
		MapBuilder.destroy(def.id)
	end
	slotUsed[round.data.slot] = nil
end

---------------------------------------------------------------------------

-- Take a player out of their race or queue. toHub: also put them back in the hub (mid-race).
function RaceService.leave(player: Player, toHub: boolean?)
	local round = roundOf[player]
	if round == nil then
		return
	end
	roundOf[player] = nil
	round:remove(player)
	clearAttributes(player)
	if toHub and player.Parent == Players then
		task.spawn(TracksService.enterMap, player, HUB)
	end
end

local function onJoin(player: Player)
	if TracksService.currentMap(player) ~= HUB then
		Net.fire("Notice", player, "raceFromHub")
		return
	end
	local party = PartyService.members(player)
	if not join(player) then
		return
	end
	if PartyService.inParty(player) and PartyService.isLeader(player) then
		for _, member in party do
			if member ~= player and TracksService.currentMap(member) == HUB then
				join(member)
			end
		end
	end
end

local function onLeave(player: Player)
	RaceService.leave(player, racing(player))
end

local function onSkip(player: Player)
	local round = roundOf[player]
	if round and round:phase() == "Results" then
		round.data.skipped[player] = true
	end
end

-- A finished race run (TracksService.onFinish): note the time; places come at Results
local function onRaceFinish(player: Player, map: any, time: number): { [string]: any }
	local round = roundOf[player]
	if round == nil or round.id ~= map.race or round:phase() ~= "Play" then
		return { ok = false, race = true, reason = "race over" }
	end
	if round.data.times[player.UserId] == nil then
		round.data.times[player.UserId] = time
		local place = 0
		for _ in round.data.times do
			place += 1
		end
		round:noteFinish()
		return { ok = true, race = true, place = place, time = time }
	end
	return { ok = false, race = true }
end

function RaceService.init()
	Net.on("Race.Join", onJoin)
	Net.on("Race.Leave", onLeave)
	Net.on("Race.Skip", onSkip)
	TracksService.raceFinish = onRaceFinish
	HubService.raceCount = RaceService.count
	TracksService.RunRejected:Connect(function(player: Player, mapId: string)
		local round = roundOf[player]
		if round and round.data.def and round.data.def.id == mapId and round:phase() == "Play" then
			round.data.out[player.UserId] = true
		end
	end)
	-- Leaving the hub leaves the queue; leaving the race map leaves the race
	TracksService.MapChanged:Connect(function(player: Player, mapId: string?)
		local round = roundOf[player]
		if round == nil then
			return
		end
		if round:phase() == "Lobby" then
			if mapId ~= HUB then
				RaceService.leave(player)
			end
		elseif round.data.def and mapId ~= round.data.def.id then
			RaceService.leave(player)
		end
	end)
	VehicleService.collisionGroupFor = function(player: Player): string?
		if racing(player) then
			return "Vehicles"
		end
		return nil
	end
	VehicleService.equipLocked = racing
	Players.PlayerRemoving:Connect(function(player)
		RaceService.leave(player)
	end)
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock < 0.1 then
			return
		end
		local step = clock
		clock = 0
		-- The open lobby only starts when a race slot is free
		if lobby and not lobby.closed and (freeSlot() ~= nil or lobby:phase() ~= "Lobby") then
			lobby:step(step)
		end
		for _, round in table.clone(active) do
			if not round.data.building then
				round:step(step)
			end
		end
	end)
end

return RaceService
