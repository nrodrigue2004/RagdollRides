-- MapService: publishing player maps (spec: Map builder > Publish rules, Data model > Map record).
-- Milestone 4 adds browse, play, rate, report and moderation here.
-- The map's name word ids, tags and full damage flag travel in its MapCodec header.
-- Publish gates, checked in this order (each failure answers with a preset reason key, never text):
--   the map is valid again on the server (MapRules), its name word ids and tags exist, its pieces are
--   exactly the ones the creator finished in TEST this session, no publish ban, 1 finished Tracks run,
--   15 minutes of play, under the live-map limit (5, VIP 15), and the 10 minute cooldown. A publish
--   blocked only by the cooldown is queued and goes out when it ends (spec: Publish when ready).
-- Store: Maps_v1, key M_<mapId> = the map record (below); N_<adjective>_<noun>_<place> counts how often
-- a name was taken (the auto number). MapIndex_v1 scope Newest: mapId -> publish time (browse, M4).
-- Republishing a draft that is already live updates the same map: plays and ratings stay, and the
-- leaderboard epoch moves on if the creator time changed by over 10%.
-- Studio without API access: records live in memory for the session (same rules).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapCodec = require(Shared.MapCodec)
local MapNames = require(Shared.MapNames)
local MapRules = require(Shared.MapRules)
local Net = require(Shared.Net)

local Services = script.Parent
local BuilderService = require(Services.BuilderService)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)

local MapService = {}

MapService.RECORD_VERSION = 1

export type MapRecord = {
	v: number,
	owner: number,
	name: { number }, -- adjective, noun, place, number
	tags: number,
	flags: number,
	data: string, -- base64 MapCodec buffer
	creatorMs: number,
	created: number,
	updated: number,
	plays: number,
	ratingSum: number,
	ratingCount: number,
	hidden: boolean,
	boardEpoch: number,
}

local mapStore: DataStore? = nil
local newestIndex: OrderedDataStore? = nil
local memoryRecords: { [string]: any } = {}
local memoryCounters: { [string]: number } = {}
local publishing: { [Player]: boolean } = {}
local queued: { [Player]: { slot: number, map: buffer } } = {}

local function useMemory(): boolean
	return DataService.isMemoryMode() or mapStore == nil
end

local function update(key: string, fn: (any) -> any): (boolean, any)
	if useMemory() then
		local value = fn(memoryRecords[key])
		if value ~= nil then
			memoryRecords[key] = value
		end
		return true, value
	end
	return pcall(function()
		return (mapStore :: DataStore):UpdateAsync(key, fn)
	end)
end

function MapService.getRecord(mapId: string): MapRecord?
	if useMemory() then
		return memoryRecords["M_" .. mapId]
	end
	local ok, value = pcall(function()
		return (mapStore :: DataStore):GetAsync("M_" .. mapId)
	end)
	return if ok then value else nil
end

-- The auto number for a name: 1 for the first map with these three words, then 2, 3...
local function takeName(a: number, n: number, p: number): number?
	local key = string.format("N_%d_%d_%d", a, n, p)
	if useMemory() then
		memoryCounters[key] = (memoryCounters[key] or 0) + 1
		return memoryCounters[key]
	end
	local ok, value = pcall(function()
		return (mapStore :: DataStore):UpdateAsync(key, function(old)
			return (tonumber(old) or 0) + 1
		end)
	end)
	return if ok then tonumber(value) else nil
end

local function answer(player: Player, ok: boolean, reason: string?, extra: { [string]: any }?)
	local result = { ok = ok, reason = reason }
	for k, v in extra or {} do
		result[k] = v
	end
	Net.fire("Map.Published", player, result)
end

-- Every gate but the cooldown. Returns the decoded map and its name ids, or nil and a reason key.
local function checkGates(
	player: Player,
	profile: { [string]: any },
	slot: number,
	b: buffer
): (MapCodec.MapData?, { number }?, string?, number?)
	local map = MapCodec.decode(b)
	if map == nil then
		return nil, nil, "invalid", nil
	end
	local ok = MapRules.checkPlayable(map, { vip = BuilderService.isVip(profile) })
	if not ok then
		return nil, nil, "invalid", nil
	end
	local a, n, p = map.name[1], map.name[2], map.name[3]
	if not MapNames.valid(a, n, p) or not MapNames.validTags(map.tags) then
		return nil, nil, "badName", nil
	end
	local done = BuilderService.getTested(player)
	if
		done == nil
		or done.slot ~= slot
		or done.fingerprint ~= MapCodec.fingerprint(b, MapCodec.PIECES_FROM)
	then
		return nil, nil, "notTested", nil
	end
	local now = os.time()
	if (profile.flags.banPublishUntil or 0) > now then
		return nil, nil, "banned", profile.flags.banPublishUntil - now
	end
	local cfg = Config.Builder
	if profile.stats.finishes < cfg.minFinishes then
		return nil, nil, "needRun", nil
	end
	local played = DataService.playSeconds(player)
	if played < cfg.minPlaySeconds then
		return nil, nil, "needPlayTime", math.ceil(cfg.minPlaySeconds - played)
	end
	local linked = profile.maps.links[tostring(slot)]
	if linked == nil and #profile.maps.published >= BuilderService.liveLimit(profile) then
		return nil, nil, "tooMany", nil
	end
	return map, { a, n, p }, nil, nil
end

local function publish(player: Player, slot: number, b: buffer)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	if BuilderService.buildingSlot(player) ~= slot then
		answer(player, false, "notBuilding")
		return
	end
	local map, nameIds, reason, wait = checkGates(player, profile, slot, b)
	if map == nil or nameIds == nil then
		answer(player, false, reason, { wait = wait })
		return
	end
	local now = os.time()
	local cooldownLeft = (profile.maps.lastPublish or 0) + Config.Builder.publishCooldown - now
	if cooldownLeft > 0 then
		-- Publish when ready: keep it and send it when the cooldown ends (if nothing changed)
		local first = queued[player] == nil
		queued[player] = { slot = slot, map = b }
		answer(player, false, "cooldown", { wait = cooldownLeft, queued = true })
		if first then
			task.delay(cooldownLeft + 1, function()
				local job = queued[player]
				queued[player] = nil
				if job and player.Parent == Players then
					publish(player, job.slot, job.map)
				end
			end)
		end
		return
	end
	if publishing[player] then
		return
	end
	publishing[player] = true
	local slotKey = tostring(slot)
	local tested = BuilderService.getTested(player) :: BuilderService.Tested
	local mapId = profile.maps.links[slotKey]
	local isNew = mapId == nil
	if mapId then
		-- A republish only updates a map this player owns (a stale link starts a new map)
		local existing = MapService.getRecord(mapId)
		if existing == nil or existing.owner ~= player.UserId then
			mapId = nil
			isNew = true
		end
	end
	mapId = mapId or HttpService:GenerateGUID(false):gsub("-", ""):lower()

	local ok, record = update("M_" .. mapId, function(old: any)
		local sameName = old ~= nil
			and old.name[1] == nameIds[1]
			and old.name[2] == nameIds[2]
			and old.name[3] == nameIds[3]
		local number = if sameName then old.name[4] else nil
		if number == nil then
			number = takeName(nameIds[1], nameIds[2], nameIds[3]) or 1
		end
		local epoch = if old then old.boardEpoch or 0 else 0
		if old and old.creatorMs > 0 then
			local change = math.abs(tested.creatorMs - old.creatorMs) / old.creatorMs
			if change > Config.Builder.boardResetChange then
				epoch += 1
			end
		end
		return {
			v = MapService.RECORD_VERSION,
			owner = player.UserId,
			name = { nameIds[1], nameIds[2], nameIds[3], number },
			tags = map.tags,
			flags = map.flags,
			data = GhostCodec.toBase64(b),
			creatorMs = tested.creatorMs,
			created = if old then old.created else now,
			updated = now,
			plays = if old then old.plays else 0,
			ratingSum = if old then old.ratingSum else 0,
			ratingCount = if old then old.ratingCount else 0,
			hidden = false,
			boardEpoch = epoch,
		}
	end)
	publishing[player] = nil
	if not ok or type(record) ~= "table" then
		warn(string.format("[Maps] publish failed for %s: %s", player.Name, tostring(record)))
		answer(player, false, "storeDown")
		return
	end
	if isNew and not useMemory() and newestIndex then
		pcall(function()
			(newestIndex :: OrderedDataStore):SetAsync(mapId, now)
		end)
	end

	-- The profile remembers the link, the cooldown and the count
	profile.maps.links[slotKey] = mapId
	if isNew then
		table.insert(profile.maps.published, mapId)
		profile.stats.mapsPublished += 1
	end
	profile.maps.lastPublish = now
	DataService.changed(player)
	task.spawn(DataService.save, player, false)
	EconomyService.builderFunnel(player, 6, "Publish")
	BuilderService.sendDrafts(player)
	answer(player, true, nil, {
		mapId = mapId,
		name = MapNames.format(record.name[1], record.name[2], record.name[3], record.name[4]),
		republish = not isNew,
		first = profile.stats.mapsPublished == 1 and isNew,
	})
end

function MapService.init()
	if not DataService.isMemoryMode() then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore("Maps_v1")
		end)
		if ok then
			mapStore = store
		end
		local okIndex, index = pcall(function()
			return DataStoreService:GetOrderedDataStore("MapIndex_v1", "Newest")
		end)
		if okIndex then
			newestIndex = index
		end
	end
	Net.on("Map.Publish", publish)
	Players.PlayerRemoving:Connect(function(player)
		queued[player] = nil
		publishing[player] = nil
	end)
end

return MapService
