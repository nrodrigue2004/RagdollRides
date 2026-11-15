-- ModerationService: keeping shared maps safe (spec: Moderation; map sharing is piece-based with
-- preset names only, so reports are about shapes and fairness, never text).
-- * Map.Report (one of three preset reasons: Shape, Impossible, Spam) counts only from an account at
--   least 3 days old that finished the map, once per account, and never on your own map. Tallies are in
--   Moderation_v1 R_<mapId>.
-- * Auto-hide at 5 counted reports, or more than 10% of finishers once 20 have finished
--   (MapStats.shouldHide). A hidden map leaves every browse tab, is listed in the admins' Review tab
--   and shows as "Hidden for review" in its creator's My Maps. The creator can edit and resubmit it once.
-- * Every hide is a creator strike (Moderation_v1 U_<userId>): 3 strikes inside 30 days is a publish
--   ban of 7 days, then 30 days, then for good. The ban is copied into the profile on join; MapService
--   also reads it fresh on every publish, so a ban from another server counts at once.
-- * Admin.Map (DataService.isAdmin only): feature, unfeature, hide, unhide, ban7, ban30, banForever and
--   unban, from the admin row on a browse card. Featured is hand-picked: it replaces a bot check that
--   maps can be finished (every published map was already finished by its creator in TEST).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local MapStats = require(Shared.MapStats)
local Net = require(Shared.Net)

local Services = script.Parent
local DataService = require(Services.DataService)
local MapPlayService = require(Services.MapPlayService)
local MapService = require(Services.MapService)
local MapStore = require(Services.MapStore)

local ModerationService = {}

local REASONS = { Shape = 1, Impossible = 2, Spam = 3 }
local DAY = 86400

local function userKey(userId: number): string
	return "U_" .. tostring(userId)
end

-- Copy a creator's ban into their profile if they are in this server
local function applyBan(userId: number, untilTime: number)
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and DataService.get(player)
	if profile then
		profile.flags.banPublishUntil = untilTime
		DataService.changed(player :: Player)
		if untilTime > os.time() then
			Net.fire("Notice", player :: Player, "publishBanned")
		end
	end
end

-- A strike for the creator; may start a ban
local function strike(userId: number)
	local now = os.time()
	local banUntil = 0
	local ok = MapStore.update(MapStore.MODERATION, userKey(userId), function(old: any)
		local record = if type(old) == "table" then old else { strikes = {}, level = 0, banUntil = 0 }
		local strikes, level, untilTime = MapStats.addStrike(record.strikes or {}, record.level or 0, now)
		record.strikes = strikes
		record.level = level
		if untilTime > 0 then
			record.banUntil = math.max(record.banUntil or 0, untilTime)
		end
		banUntil = record.banUntil or 0
		return record
	end)
	if ok and banUntil > now then
		applyBan(userId, banUntil)
	end
end

local function setBan(userId: number, untilTime: number)
	local ok = MapStore.update(MapStore.MODERATION, userKey(userId), function(old: any)
		local record = if type(old) == "table" then old else { strikes = {}, level = 0, banUntil = 0 }
		record.banUntil = untilTime
		if untilTime == 0 then
			record.strikes = {}
		end
		return record
	end)
	if ok then
		applyBan(userId, untilTime)
	end
	return ok
end

-- Hide a map: off every tab, into Review, a strike for its creator
function ModerationService.hide(mapId: string, why: string): boolean
	local now = os.time()
	local wasHidden = false
	local ok, record = MapService.updateRecord(mapId, function(old)
		wasHidden = old.hidden == true
		if wasHidden then
			return nil
		end
		old.hidden = true
		old.hiddenAt = now
		old.featured = false
		return old
	end)
	if not ok or type(record) ~= "table" or wasHidden then
		return ok and wasHidden
	end
	for _, scope in { "Newest", "Popular", "Featured" } do
		MapStore.indexRemove(scope, mapId)
	end
	MapStore.indexSet("Hidden", mapId, now)
	MapPlayService.dropFromServer(mapId)
	strike(record.owner)
	local owner = Players:GetPlayerByUserId(record.owner)
	if owner then
		Net.fire("Notice", owner, "mapHiddenOwner")
	end
	print(string.format("[Moderation] map %s hidden (%s)", mapId, why))
	return true
end

local function unhide(mapId: string): boolean
	local now = os.time()
	local ok, record = MapService.updateRecord(mapId, function(old)
		old.hidden = false
		old.hiddenAt = nil
		return old
	end)
	if ok and type(record) == "table" then
		MapStore.indexRemove("Hidden", mapId)
		MapStore.indexSet("Newest", mapId, now)
		MapStore.update(MapStore.MODERATION, "R_" .. mapId, function()
			return { count = 0, users = {} }
		end)
	end
	return ok
end

local function onReport(player: Player, mapId: string, reason: string)
	if not MapService.validId(mapId) then
		return
	end
	local profile = DataService.get(player)
	local record = MapService.getRecord(mapId)
	if profile == nil or record == nil then
		return
	end
	-- Every report gets the same thanks, counted or not (nothing to probe)
	Net.fire("Map.Reported", player, mapId, true)
	local finished = profile.tracks[mapId] ~= nil
	if not MapStats.reportCounts(player.AccountAge, finished, record.owner == player.UserId) then
		return
	end
	if record.hidden then
		return
	end
	local key = tostring(player.UserId)
	local count = 0
	local ok = MapStore.update(MapStore.MODERATION, "R_" .. mapId, function(old: any)
		local tally = if type(old) == "table" then old else { count = 0, users = {} }
		tally.users = tally.users or {}
		if tally.users[key] then
			count = tally.count or 0
			return nil
		end
		tally.users[key] = REASONS[reason] or 1
		tally.count = (tally.count or 0) + 1
		count = tally.count
		return tally
	end)
	if not ok then
		return
	end
	local finishers = (record.finishers or 0) + MapPlayService.pendingFinishers(mapId)
	if MapStats.shouldHide(count, finishers) then
		ModerationService.hide(mapId, string.format("%d reports, %d finishers", count, finishers))
	end
end

local ADMIN_ACTIONS: { [string]: (string, MapService.MapRecord) -> boolean } = {
	feature = function(mapId, record)
		if record.hidden then
			return false
		end
		local ok = MapService.updateRecord(mapId, function(old)
			old.featured = true
			return old
		end)
		if ok then
			MapStore.indexSet("Featured", mapId, os.time())
		end
		return ok
	end,
	unfeature = function(mapId)
		local ok = MapService.updateRecord(mapId, function(old)
			old.featured = false
			return old
		end)
		MapStore.indexRemove("Featured", mapId)
		return ok
	end,
	hide = function(mapId)
		return ModerationService.hide(mapId, "admin")
	end,
	unhide = function(mapId)
		return unhide(mapId)
	end,
	ban7 = function(_, record)
		return setBan(record.owner, os.time() + Config.Maps.banDays[1] * DAY)
	end,
	ban30 = function(_, record)
		return setBan(record.owner, os.time() + Config.Maps.banDays[2] * DAY)
	end,
	banForever = function(_, record)
		return setBan(record.owner, Config.Maps.forever)
	end,
	unban = function(_, record)
		return setBan(record.owner, 0)
	end,
}

local function onAdmin(player: Player, mapId: string, action: string)
	if not DataService.isAdmin(player) or not MapService.validId(mapId) then
		return
	end
	local record = MapService.getRecord(mapId, true)
	local run = ADMIN_ACTIONS[action]
	if record == nil or run == nil then
		Net.fire("Notice", player, "adminFailed")
		return
	end
	local ok = run(mapId, record)
	MapStore.forget(MapStore.MAPS, "M_" .. mapId)
	print(string.format("[Moderation] %s: %s on %s (%s)", player.Name, action, mapId, tostring(ok)))
	Net.fire("Notice", player, if ok then "adminDone" else "adminFailed")
end

function ModerationService.init()
	Net.on("Map.Report", onReport)
	Net.on("Admin.Map", onAdmin)
	-- A ban from another server reaches the profile on join
	DataService.Loaded:Connect(function(player: Player, profile)
		task.spawn(function()
			local untilTime = MapService.banUntil(player.UserId)
			if untilTime ~= (profile.flags.banPublishUntil or 0) and player.Parent == Players then
				profile.flags.banPublishUntil = untilTime
				DataService.changed(player)
			end
		end)
	end)
end

return ModerationService
