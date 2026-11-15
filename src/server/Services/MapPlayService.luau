-- MapPlayService: driving published player maps (spec: Map builder > Playing player maps, Browse,
-- Creator royalties, Ratings).
-- * Map.Play loads the map's record, builds it in one of this server's map slots (Config.Maps, far
--   from the starter maps and build plots) a batch of pieces per frame, registers it with TracksService,
--   sends the pieces to the player (Map.Data, so their device knows checkpoints, cues and moving parts)
--   and puts their car on the start. A map nobody has been on for 60 s is unloaded.
-- * A finish pays like any map (TracksService: 30 coins, stars by the creator time).
-- * Plays: a run started by someone other than the creator counts once per player per map per day. It
--   adds to the map's plays and its last-7-days counts (Popular) and pays the creator 5 coins, at most
--   200 a day. Royalties wait in Maps_v1 R_<userId> and are paid when the creator is in a server.
-- * Ratings (1 to 5 stars) only after finishing the map, never your own; a player can change theirs.
-- Plays, finishers and ratings are batched per map and written every minute (MapService.updateRecord);
-- the Popular index is rewritten every 10 minutes for the maps that changed (MapStats.popularScore).
-- Leaderboards per map: BoardService (the map definition carries the record's boardEpoch).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapBuilder = require(Shared.MapBuilder)
local MapCodec = require(Shared.MapCodec)
local MapStats = require(Shared.MapStats)
local Net = require(Shared.Net)
local PieceCatalog = require(Shared.PieceCatalog)
local ProfileSchema = require(Shared.ProfileSchema)
local Signal = require(Shared.Util.Signal)
local StarterMaps = require(Shared.StarterMaps)

local Services = script.Parent
local BuilderService = require(Services.BuilderService)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MapService = require(Services.MapService)
local MapStore = require(Services.MapStore)
local TracksService = require(Services.TracksService)

local MapPlayService = {}

MapPlayService.Rated = Signal.new() -- (player, mapId, stars): a rating was accepted

type Loaded = {
	mapId: string,
	slot: number,
	def: { [string]: any },
	record: MapService.MapRecord,
	players: { [Player]: boolean },
	emptySince: number?,
}

type Pending = { plays: number, finishers: number, ratingSum: number, ratingCount: number }

local loaded: { [string]: Loaded } = {}
local loading: { [string]: boolean } = {}
local slots: { [number]: string } = {}
local onMap: { [Player]: string } = {}
local pending: { [string]: Pending } = {}
local royalties: { [number]: number } = {} -- creator userId -> coins not yet written
local popularDue: { [string]: number } = {} -- mapId -> its newest score, written on the next pass
local creatorNames: { [number]: string } = {}

local function today(): number
	return ProfileSchema.dayNumber(os.time()) -- whole days, so "the last 7 days" works across months
end

local function pendingFor(mapId: string): Pending
	local entry = pending[mapId]
	if entry == nil then
		entry = { plays = 0, finishers = 0, ratingSum = 0, ratingCount = 0 }
		pending[mapId] = entry
	end
	return entry
end

function MapPlayService.creatorName(userId: number): string
	local name = creatorNames[userId]
	if name then
		return name
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		name = player.Name
	else
		local ok, result = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		name = if ok and type(result) == "string" then result else "a player"
	end
	creatorNames[userId] = name :: string
	return name :: string
end

function MapPlayService.isLoaded(mapId: string): boolean
	return loaded[mapId] ~= nil
end

-- What this server has batched but not written yet (so reports and cards see it at once)
function MapPlayService.pendingFinishers(mapId: string): number
	local entry = pending[mapId]
	return if entry then entry.finishers else 0
end

local function freeSlot(): number?
	for index = 1, Config.Maps.maxLoaded do
		if slots[index] == nil then
			return index
		end
	end
	-- Every slot used: take the one empty for longest
	local oldest, oldestTime = nil, math.huge
	for id, entry in loaded do
		if entry.emptySince and entry.emptySince < oldestTime then
			oldest, oldestTime = id, entry.emptySince
		end
	end
	if oldest then
		local slot = loaded[oldest].slot
		MapPlayService.unload(oldest)
		return slot
	end
	return nil
end

function MapPlayService.unload(mapId: string)
	local entry = loaded[mapId]
	if entry == nil then
		return
	end
	-- Anyone still on it goes home first (a hide, or the slot was needed)
	for player in entry.players do
		if onMap[player] == mapId then
			task.spawn(TracksService.enterMap, player, TracksService.homeMapFor(player))
		end
	end
	loaded[mapId] = nil
	slots[entry.slot] = nil
	TracksService.unregisterMap(mapId)
	MapBuilder.destroy(mapId)
end

-- Load a published map into a slot (yields while it builds). Returns the entry or nil and a reason key.
local function ensureLoaded(mapId: string, record: MapService.MapRecord): (Loaded?, string?)
	while loading[mapId] do
		task.wait()
	end
	if loaded[mapId] then
		return loaded[mapId], nil
	end
	local raw = GhostCodec.fromBase64(record.data)
	local map = raw and MapCodec.decode(raw)
	if map == nil then
		return nil, "mapBroken"
	end
	local slot = freeSlot()
	if slot == nil then
		return nil, "mapsFull"
	end
	loading[mapId] = true
	slots[slot] = mapId
	local def = PieceCatalog.toMapDef(map.pieces, {
		id = mapId,
		name = MapService.displayName(record),
		offset = MapStats.slotOffset(slot),
		creatorTime = record.creatorMs / 1000,
		fullDamage = MapCodec.fullDamage(map),
	})
	def.owner = record.owner
	def.boardEpoch = record.boardEpoch or 0
	local model = MapBuilder.buildAsync(def :: any, Config.Builder.buildBatch)
	if model == nil then
		loading[mapId] = nil
		slots[slot] = nil
		return nil, "mapBroken"
	end
	TracksService.registerMap(def :: any)
	local entry: Loaded = {
		mapId = mapId,
		slot = slot,
		def = def,
		record = record,
		players = {},
		emptySince = os.clock(),
	}
	loaded[mapId] = entry
	loading[mapId] = nil
	return entry, nil
end

local function play(player: Player, mapId: string)
	if StarterMaps.byId[mapId] then
		BuilderService.exitBuild(player)
		TracksService.enterMap(player, mapId)
		return
	end
	if not MapService.validId(mapId) then
		return
	end
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local record = MapService.getRecord(mapId)
	if record == nil then
		Net.fire("Notice", player, "mapGone")
		return
	end
	if record.hidden and record.owner ~= player.UserId and not DataService.isAdmin(player) then
		Net.fire("Notice", player, "mapHidden")
		return
	end
	local entry, reason = ensureLoaded(mapId, record)
	if entry == nil then
		Net.fire("Notice", player, reason or "mapBroken")
		return
	end
	if player.Parent ~= Players then
		return
	end
	local r = entry.record
	Net.fire("Map.Data", player, {
		mapId = mapId,
		data = r.data,
		offset = entry.def.offset,
		creatorMs = r.creatorMs,
		name = MapService.displayName(r),
		owner = r.owner,
		creator = MapPlayService.creatorName(r.owner),
		tags = r.tags,
		myRating = profile.ratings[mapId],
		hidden = r.hidden == true,
	})
	BuilderService.exitBuild(player)
	TracksService.enterMap(player, mapId)
end

-- Track who is on which loaded map (empty maps unload after a while)
local function onMapChanged(player: Player, mapId: string?)
	local old = onMap[player]
	if old and loaded[old] then
		loaded[old].players[player] = nil
		if next(loaded[old].players) == nil then
			loaded[old].emptySince = os.clock()
		end
	end
	onMap[player] = nil
	if mapId and loaded[mapId] then
		onMap[player] = mapId
		loaded[mapId].players[player] = true
		loaded[mapId].emptySince = nil
	end
end

-- A run started: a play, once per player per map per day, and never the creator's own
local function onRunStarted(player: Player, map: any)
	if not map.custom or map.testOwner or map.owner == nil or map.owner == player.UserId then
		return
	end
	local profile = DataService.get(player)
	if profile == nil or profile.daily.mapStarts[map.id] then
		return
	end
	profile.daily.mapStarts[map.id] = 1
	DataService.changed(player)
	pendingFor(map.id).plays += 1
	royalties[map.owner] = (royalties[map.owner] or 0) + Config.Maps.coinsPerPlay
end

local function onFinished(player: Player, map: any, firstFinish: boolean)
	if not map.custom or map.testOwner or not firstFinish or map.owner == player.UserId then
		return
	end
	pendingFor(map.id).finishers += 1
end

-- Map.Rate: 1 to 5 stars, after finishing the map; changing your rating moves the sum, not the count
local function onRate(player: Player, mapId: string, stars: number)
	local profile = DataService.get(player)
	if profile == nil or not MapService.validId(mapId) or profile.tracks[mapId] == nil then
		return
	end
	local entry = loaded[mapId]
	local owner = if entry then entry.record.owner else nil
	if owner == nil then
		local record = MapService.getRecord(mapId)
		owner = record and record.owner
	end
	if owner == nil or owner == player.UserId then
		return
	end
	local old = profile.ratings[mapId]
	if old == stars then
		return
	end
	local sumDelta, countDelta = MapStats.ratingDelta(old, stars)
	local p = pendingFor(mapId)
	p.ratingSum += sumDelta
	p.ratingCount += countDelta
	profile.ratings[mapId] = stars
	DataService.changed(player)
	MapPlayService.Rated:Fire(player, mapId, stars)
end

-- Pay royalties waiting in the store to a creator who is in this server
local function claimRoyalties(player: Player)
	local userId = player.UserId
	local claimed = 0
	local ok = MapStore.update(MapStore.MAPS, "R_" .. tostring(userId), function(old: any)
		if type(old) ~= "table" or (old.coins or 0) <= 0 then
			claimed = 0
			return nil
		end
		claimed = old.coins
		return { coins = 0, day = old.day or 0, today = old.today or 0 }
	end)
	if ok and claimed > 0 and player.Parent == Players then
		local granted = EconomyService.grantCoins(player, claimed, nil, "Royalties")
		Net.fire("Map.Royalty", player, granted)
	end
end

local function flushRoyalties()
	local batch = royalties
	royalties = {}
	local day = today()
	for userId, coins in batch do
		local ok = MapStore.update(MapStore.MAPS, "R_" .. tostring(userId), function(old: any)
			local record = if type(old) == "table" then old else { coins = 0, day = day, today = 0 }
			if record.day ~= day then
				record.day = day
				record.today = 0
			end
			local room = MapStats.royaltyRoom(coins, record.today or 0)
			if room <= 0 then
				return nil
			end
			record.coins = (record.coins or 0) + room
			record.today = (record.today or 0) + room
			return record
		end)
		if not ok then
			-- Keep it for the next flush
			royalties[userId] = (royalties[userId] or 0) + coins
		else
			local creator = Players:GetPlayerByUserId(userId)
			if creator then
				task.spawn(claimRoyalties, creator)
			end
		end
	end
end

local function flushMaps()
	local batch = pending
	pending = {}
	local day = today()
	for mapId, p in batch do
		local ok, record = MapService.updateRecord(mapId, function(old)
			old.plays = (old.plays or 0) + p.plays
			old.playsByDay = old.playsByDay or {}
			if p.plays > 0 then
				local key = tostring(day)
				old.playsByDay[key] = (old.playsByDay[key] or 0) + p.plays
			end
			MapStats.trimDays(old.playsByDay, day)
			old.finishers = (old.finishers or 0) + p.finishers
			old.ratingSum = math.max(0, (old.ratingSum or 0) + p.ratingSum)
			old.ratingCount = math.max(0, (old.ratingCount or 0) + p.ratingCount)
			return old
		end)
		if not ok then
			-- Put it back for the next flush
			local again = pendingFor(mapId)
			again.plays += p.plays
			again.finishers += p.finishers
			again.ratingSum += p.ratingSum
			again.ratingCount += p.ratingCount
		elseif type(record) == "table" then
			if loaded[mapId] then
				loaded[mapId].record = record
			end
			if not record.hidden then
				popularDue[mapId] =
					MapStats.popularScore(record.playsByDay, day, record.ratingSum, record.ratingCount)
			end
		end
	end
end

local function writePopular()
	local batch = popularDue
	popularDue = {}
	for mapId, score in batch do
		MapStore.indexSet("Popular", mapId, score)
	end
end

local function flushAll()
	flushMaps()
	flushRoyalties()
end
MapPlayService.flush = flushAll

-- A map was hidden or changed elsewhere: drop it from this server's slots (players on it go home)
function MapPlayService.dropFromServer(mapId: string)
	popularDue[mapId] = nil
	MapPlayService.unload(mapId)
end

function MapPlayService.init()
	TracksService.MapChanged:Connect(onMapChanged)
	TracksService.RunStarted:Connect(onRunStarted)
	TracksService.Finished:Connect(onFinished)
	Net.on("Map.Play", function(player: Player, mapId: string)
		play(player, mapId)
	end)
	Net.on("Map.Rate", onRate)

	DataService.Loaded:Connect(function(player: Player)
		task.delay(5, claimRoyalties, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		onMapChanged(player, nil)
		creatorNames[player.UserId] = nil
	end)

	-- Unload maps nobody has been on for a while
	task.spawn(function()
		while true do
			task.wait(10)
			local now = os.clock()
			for mapId, entry in loaded do
				if entry.emptySince and now - entry.emptySince >= Config.Maps.unloadAfter then
					MapPlayService.unload(mapId)
				end
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Maps.flushInterval)
			flushAll()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Maps.popularInterval)
			writePopular()
		end
	end)
	game:BindToClose(function()
		flushAll()
		writePopular()
	end)
end

return MapPlayService
