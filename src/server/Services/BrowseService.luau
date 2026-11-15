-- BrowseService: the browse screen's lists (spec: Browse). Map.Browse(tab, page) answers with Map.List,
-- a page of 9 cards: preset name, creator, rating (or "New" under 10 ratings), plays, tags and the map's
-- pieces (the card draws a top-down sketch from them, so there are no thumbnails to render or store).
-- Tabs: Featured (hand-picked by admins), Popular (MapStats.popularScore), Newest, Friends (maps by
-- your Roblox friends), My Maps (yours, hidden ones marked "Hidden for review") and Review (admins:
-- maps hidden by reports). The starter maps tab is built on the client (it needs no server).
-- Sponsored slots are deferred to Update 2 (nate's decision, 2026-11-13).

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

local BrowseService = {}

local SCOPES = { featured = "Featured", popular = "Popular", newest = "Newest", review = "Hidden" }

local tabCache: { [string]: { ids: { string }, time: number } } = {}
local friendCache: { [Player]: { ids: { string }, time: number } } = {}

local function fresh(entry: { time: number }?): boolean
	return entry ~= nil and os.clock() - entry.time < Config.Maps.listCache
end

local function indexIds(tab: string): { string }
	local cached = tabCache[tab]
	if fresh(cached) then
		return (cached :: any).ids
	end
	local ok, ids = MapStore.indexTop(SCOPES[tab], Config.Maps.listLength)
	if ok then
		tabCache[tab] = { ids = ids, time = os.clock() }
		return ids
	end
	return if cached then cached.ids else {}
end

-- Run fn over items at the same time (each may yield on a store read) and wait for all
local function each<T>(items: { T }, fn: (number, T) -> ())
	local left = #items
	if left == 0 then
		return
	end
	local thread = coroutine.running()
	local waiting = false
	for index, item in items do
		task.spawn(function()
			local ok, err = pcall(fn, index, item)
			if not ok then
				warn("[Browse] " .. tostring(err))
			end
			left -= 1
			-- Resume only if we really yielded (cached reads can all finish before the loop ends)
			if left == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end
	if left > 0 then
		waiting = true
		coroutine.yield()
	end
end

local function friendIds(player: Player): { string }
	local cached = friendCache[player]
	if fresh(cached) then
		return (cached :: any).ids
	end
	local friends = {}
	pcall(function()
		local pages = Players:GetFriendsAsync(player.UserId)
		for _, friend in pages:GetCurrentPage() do
			table.insert(friends, friend.Id)
			if #friends >= Config.Maps.friendsChecked then
				break
			end
		end
	end)
	local lists: { { string } } = {}
	each(friends, function(index, userId)
		local ok, value = MapStore.get(MapStore.MAPS, "C_" .. tostring(userId))
		lists[index] = if ok and type(value) == "table" then value else {}
	end)
	-- Each friend's newest maps first, taking turns so one busy builder can't fill the tab
	local ids = {}
	local depth = 0
	local added = true
	while added and #ids < Config.Maps.listLength do
		added = false
		depth += 1
		for index = 1, #friends do
			local list = lists[index] or {}
			local id = list[#list - depth + 1]
			if id then
				table.insert(ids, id)
				added = true
			end
		end
	end
	friendCache[player] = { ids = ids, time = os.clock() }
	return ids
end

local function idsFor(player: Player, tab: string, profile: { [string]: any }): { string }
	if tab == "mine" then
		local ids = {}
		for i = #profile.maps.published, 1, -1 do
			table.insert(ids, profile.maps.published[i])
		end
		return ids
	elseif tab == "friends" then
		return friendIds(player)
	end
	return indexIds(tab)
end

local function card(record: MapService.MapRecord, mapId: string, player: Player): { [string]: any }
	return {
		mapId = mapId,
		name = MapService.displayName(record),
		creator = MapPlayService.creatorName(record.owner),
		owner = record.owner,
		mine = record.owner == player.UserId,
		rating = MapStats.shownRating(record.ratingSum or 0, record.ratingCount or 0),
		ratingCount = record.ratingCount or 0,
		plays = record.plays or 0,
		tags = record.tags or 0,
		data = record.data,
		creatorMs = record.creatorMs,
		hidden = record.hidden == true,
		featured = record.featured == true,
		resubmitted = (record.resubmits or 0) > 0,
	}
end

local function onBrowse(player: Player, tab: string, page: number)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local admin = DataService.isAdmin(player)
	if tab == "review" and not admin then
		return
	end
	local ids = idsFor(player, tab, profile)
	local size = Config.Maps.pageSize
	local pages = math.max(1, math.ceil(#ids / size))
	page = math.clamp(page, 1, pages)
	local first, last = MapStats.pageRange(#ids, page, size)
	local slice = {}
	for i = first, last do
		table.insert(slice, ids[i])
	end
	local cards: { [number]: { [string]: any } } = {}
	local showHidden = tab == "mine" or tab == "review"
	each(slice, function(index, mapId)
		local record = MapService.getRecord(mapId)
		if record and (showHidden or not record.hidden) then
			cards[index] = card(record, mapId, player)
		end
	end)
	local list = {}
	for index = 1, #slice do
		if cards[index] then
			table.insert(list, cards[index])
		end
	end
	if player.Parent == Players then
		Net.fire("Map.List", player, { tab = tab, page = page, pages = pages, cards = list, admin = admin })
	end
end

function BrowseService.init()
	Net.on("Map.Browse", onBrowse)
	Players.PlayerRemoving:Connect(function(player)
		friendCache[player] = nil
	end)
end

return BrowseService
