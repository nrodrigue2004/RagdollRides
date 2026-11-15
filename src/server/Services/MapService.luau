-- MapService: publishing player maps (spec: Map builder > Publish rules, Data model > Map record).
-- The map's name word ids, tags and full damage flag travel in its MapCodec header.
-- Publish gates, checked in this order (each failure answers with a preset reason key, never text):
--   the map is valid again on the server (MapRules), its name word ids and tags exist, its pieces are
--   exactly the ones the creator finished in TEST this session, no publish ban (profile flag and the
--   Moderation_v1 record, so a ban from another server counts at once), 1 finished Tracks run,
--   15 minutes of play, under the live-map limit (5, VIP 15), and the 10 minute cooldown. A publish
--   blocked only by the cooldown is queued and goes out when it ends (spec: Publish when ready).
-- Stores (Services/MapStore): M_<mapId> the map record (below), N_<a>_<n>_<p> name counters (the auto
-- number), C_<userId> the creator's map ids (the Friends tab), MapIndex_v1 Newest (publish time).
-- Plays, ratings and royalties are MapPlayService's; reports, hides and bans are ModerationService's.
-- Republishing a draft that is already live updates the same map: plays and ratings stay, and the
-- leaderboard epoch moves on if the creator time changed by over 10%. A map hidden by reports can be
-- edited and resubmitted once (spec: Moderation); after that only an admin can unhide it.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

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
local MapStore = require(Services.MapStore)

local MapService = {}

MapService.RECORD_VERSION = 1
MapService.FOREVER = 2 ^ 31 - 1 -- a permanent ban's end time

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
	plays: number, -- plays by other players, all time (one per player per map per day)
	playsByDay: { [string]: number }, -- the last 7 days (the Popular score)
	finishers: number, -- players who finished it at least once (report thresholds)
	ratingSum: number,
	ratingCount: number,
	hidden: boolean,
	hiddenAt: number?,
	resubmits: number,
	featured: boolean,
	boardEpoch: number,
}

local publishing: { [Player]: boolean } = {}
local queued: { [Player]: { slot: number, map: buffer } } = {}

function MapService.validId(mapId: any): boolean
	return type(mapId) == "string" and #mapId >= 8 and #mapId <= 40 and mapId:match("^%w+$") ~= nil
end

function MapService.getRecord(mapId: string, fresh: boolean?): MapRecord?
	if not MapService.validId(mapId) then
		return nil
	end
	local ok, value = MapStore.get(MapStore.MAPS, "M_" .. mapId, fresh)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

-- Change an existing record: fn(old) returns the new record, or nil to leave it
function MapService.updateRecord(mapId: string, fn: (MapRecord) -> MapRecord?): (boolean, MapRecord?)
	return MapStore.update(MapStore.MAPS, "M_" .. mapId, function(old)
		if type(old) ~= "table" then
			return nil
		end
		return fn(old)
	end)
end

function MapService.displayName(record: MapRecord): string
	return MapNames.format(record.name[1], record.name[2], record.name[3], record.name[4])
end

-- A creator's publish ban end (unix time; 0 = none), from Moderation_v1 (shared by every server)
function MapService.banUntil(userId: number): number
	local ok, value = MapStore.get(MapStore.MODERATION, "U_" .. tostring(userId), true)
	if ok and type(value) == "table" then
		return tonumber(value.banUntil) or 0
	end
	return 0
end

-- The auto number for a name: 1 for the first map with these three words, then 2, 3...
local function takeName(a: number, n: number, p: number): number?
	local ok, value = MapStore.update(MapStore.MAPS, string.format("N_%d_%d_%d", a, n, p), function(old)
		return (tonumber(old) or 0) + 1
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

-- Every gate but the cooldown. Returns the decoded map and its name ids, or nil, a reason key and a wait.
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
	local banned = math.max(profile.flags.banPublishUntil or 0, MapService.banUntil(player.UserId))
	if banned > now then
		profile.flags.banPublishUntil = banned
		return nil, nil, "banned", if banned >= MapService.FOREVER then nil else banned - now
	end
	local cfg = Config.Builder
	if profile.stats.finishes < cfg.minFinishes then
		return nil, nil, "needRun", nil
	end
	local played = DataService.playSeconds(player)
	local needed = if RunService:IsStudio() then cfg.studioPlaySeconds else cfg.minPlaySeconds
	if played < needed then
		return nil, nil, "needPlayTime", math.ceil(needed - played)
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
	local cooldown = if RunService:IsStudio()
		then Config.Builder.studioCooldown
		else Config.Builder.publishCooldown
	local cooldownLeft = (profile.maps.lastPublish or 0) + cooldown - now
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
	local existing: MapRecord? = nil
	if mapId then
		-- A republish only updates a map this player owns (a stale link starts a new map)
		existing = MapService.getRecord(mapId, true)
		if existing == nil or existing.owner ~= player.UserId then
			existing = nil
			mapId = nil
			isNew = true
		elseif existing.hidden and (existing.resubmits or 0) >= 1 then
			publishing[player] = nil
			answer(player, false, "reviewLocked")
			return
		end
	end
	mapId = mapId or HttpService:GenerateGUID(false):gsub("-", ""):lower()

	-- The auto number first (an UpdateAsync callback must never yield)
	local number: number
	if
		existing
		and existing.name[1] == nameIds[1]
		and existing.name[2] == nameIds[2]
		and existing.name[3] == nameIds[3]
	then
		number = existing.name[4]
	else
		number = takeName(nameIds[1], nameIds[2], nameIds[3]) or 1
	end

	local wasHidden = false
	local ok, record = MapStore.update(MapStore.MAPS, "M_" .. mapId, function(old: any)
		local epoch = if old then old.boardEpoch or 0 else 0
		if old and old.creatorMs > 0 then
			local change = math.abs(tested.creatorMs - old.creatorMs) / old.creatorMs
			if change > Config.Builder.boardResetChange then
				epoch += 1
			end
		end
		wasHidden = old ~= nil and old.hidden == true
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
			plays = if old then old.plays or 0 else 0,
			playsByDay = if old then old.playsByDay or {} else {},
			finishers = if old then old.finishers or 0 else 0,
			ratingSum = if old then old.ratingSum or 0 else 0,
			ratingCount = if old then old.ratingCount or 0 else 0,
			hidden = false,
			hiddenAt = nil,
			-- An edit of a hidden map is its one resubmit (spec: Moderation)
			resubmits = (if old then old.resubmits or 0 else 0) + (if old and old.hidden then 1 else 0),
			featured = if old then old.featured == true else false,
			boardEpoch = epoch,
		}
	end)
	publishing[player] = nil
	if not ok or type(record) ~= "table" then
		answer(player, false, "storeDown")
		return
	end
	if isNew then
		MapStore.indexSet("Newest", mapId, now)
		MapStore.update(MapStore.MAPS, "C_" .. tostring(player.UserId), function(old)
			local list = if type(old) == "table" then old else {}
			if not table.find(list, mapId) then
				table.insert(list, mapId)
			end
			return list
		end)
	elseif wasHidden then
		-- Back for review: its reports start over and it shows in Newest again
		MapStore.update(MapStore.MODERATION, "R_" .. mapId, function()
			return { count = 0, users = {} }
		end)
		MapStore.indexSet("Newest", mapId, now)
		MapStore.indexRemove("Hidden", mapId)
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
	pcall(function()
		AnalyticsService:LogCustomEvent(player, if isNew then "map_publish" else "map_republish", 1)
	end)
	answer(player, true, nil, {
		mapId = mapId,
		name = MapService.displayName(record),
		republish = not isNew,
		first = profile.stats.mapsPublished == 1 and isNew,
	})
end

function MapService.init()
	Net.on("Map.Publish", publish)
	Players.PlayerRemoving:Connect(function(player)
		queued[player] = nil
		publishing[player] = nil
	end)
end

return MapService
