-- BoardService: map leaderboards (spec: Leaderboards screen, per map: Friends / Weekly / All-time, own
-- row always pinned; Data model > MapTimes_v1, an OrderedDataStore per map and week). Shared/Boards
-- has the keys and rows.
-- * Writes: every paid finish keeps the weekly best (UpdateAsync, lower wins); a new personal best also
--   goes on the all-time board. Board-banned players (3 rejected runs in 10 minutes) post nothing that
--   day. Builder TEST runs and quick races never post.
-- * Board.Get(mapId, tab) answers Board.Data { mapId, tab, rows = { { rank, userId, name, ms, me,
--   friend } }, mine }. Reads are cached per board for a minute; the Friends tab is your Roblox friends
--   found in the all-time top 100, so it costs no extra reads.
-- * In Studio without API access the boards live in memory for the session (DataService memory mode).
-- Names are Roblox display names (no player text).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local UserService = game:GetService("UserService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Boards = require(Shared.Boards)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)

local Services = script.Parent
local DataService = require(Services.DataService)
local TracksService = require(Services.TracksService)

local BoardService = {}

local cfg = Config.Boards

local stores: { [string]: OrderedDataStore } = {}
local memory: { [string]: { [number]: number } } = {}
local cache: { [string]: { time: number, entries: { Boards.Entry } } } = {}
local names: { [number]: string } = {}
local friendSets: { [Player]: { [number]: boolean } } = {}

local function storeFor(scope: string): OrderedDataStore?
	if stores[scope] == nil then
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(cfg.storeName, scope)
		end)
		if ok then
			stores[scope] = store
		end
	end
	return stores[scope]
end

-- Keep the lower time for this player on a board
local function post(scope: string, userId: number, ms: number)
	-- Your own new time shows on your next look (the cache would hide it for a minute)
	cache[scope .. "#" .. cfg.topCount] = nil
	cache[scope .. "#" .. cfg.friendsPool] = nil
	if DataService.isMemoryMode() then
		local board = memory[scope] or {}
		memory[scope] = board
		if board[userId] == nil or ms < board[userId] then
			board[userId] = ms
		end
		return
	end
	local store = storeFor(scope)
	if store == nil then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(store :: OrderedDataStore):UpdateAsync(tostring(userId), function(old: number?)
				if old ~= nil and old <= ms then
					return nil -- keep the faster time
				end
				return ms
			end)
		end)
		if not ok then
			warn("[Boards] post failed: " .. tostring(err))
		end
	end)
end

-- The fastest `count` entries on a board (cached for a minute)
local function read(scope: string, count: number): { Boards.Entry }
	local key = scope .. "#" .. count
	local hit = cache[key]
	if hit and os.clock() - hit.time < cfg.cacheSeconds then
		return hit.entries
	end
	local entries: { Boards.Entry } = {}
	if DataService.isMemoryMode() then
		for userId, ms in memory[scope] or {} do
			table.insert(entries, { userId = userId, ms = ms })
		end
		table.sort(entries, function(a, b)
			return a.ms < b.ms
		end)
		while #entries > count do
			table.remove(entries)
		end
	else
		local store = storeFor(scope)
		if store then
			local ok, pages = pcall(function()
				return (store :: OrderedDataStore):GetSortedAsync(true, math.min(count, 100))
			end)
			if ok and pages then
				for _, item in (pages :: DataStorePages):GetCurrentPage() do
					local userId = tonumber(item.key)
					if userId then
						table.insert(entries, { userId = userId, ms = item.value })
					end
				end
			end
		end
	end
	cache[key] = { time = os.clock(), entries = entries }
	return entries
end

local function nameOf(userIds: { number })
	local missing = {}
	for _, id in userIds do
		if names[id] == nil then
			local player = Players:GetPlayerByUserId(id)
			if player then
				names[id] = player.DisplayName
			else
				table.insert(missing, id)
			end
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok and infos then
		for _, info in infos do
			names[info.Id] = info.DisplayName
		end
	end
end

-- A player's Roblox friends (first 200), read once a session
local function friendsOf(player: Player): { [number]: boolean }
	local set = friendSets[player]
	if set then
		return set
	end
	set = {}
	friendSets[player] = set
	pcall(function()
		local pages = Players:GetFriendsAsync(player.UserId)
		local seen = 0
		while seen < 200 do
			for _, item in pages:GetCurrentPage() do
				set[item.Id] = true
				seen += 1
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	return set
end

-- The boards a map has (published maps start fresh boards when their creator time moved, boardEpoch)
local function scopes(map: any, day: number): (string, string)
	local epoch = map.boardEpoch
	return Boards.allTimeScope(map.id, epoch), Boards.weeklyScope(map.id, epoch, day)
end

local function boardable(map: any): boolean
	return map ~= nil and not map.testOwner and not map.race
end

local function banned(profile: { [string]: any }): boolean
	return profile.flags.boardBanDay == ProfileSchema.dayKey(os.time())
end

local function onGet(player: Player, mapId: string, tab: string)
	local map = TracksService.getMapDef(mapId) :: any
	local profile = DataService.get(player)
	if not boardable(map) or profile == nil then
		return
	end
	local allTime, weekly = scopes(map, ProfileSchema.dayNumber(os.time()))
	local entries = if tab == "weekly" then read(weekly, cfg.topCount) else read(allTime, cfg.friendsPool)
	local friends = if tab == "friends" then friendsOf(player) else {}
	local entry = profile.tracks[mapId]
	local myMs = if entry then entry.best else nil
	if tab == "weekly" then
		-- Your weekly time is only known when it is on what was read
		myMs = nil
	end
	local list, mine = Boards.rows(tab, entries, player.UserId, myMs, friends, cfg.topCount)
	local ids = {}
	for _, row in list do
		table.insert(ids, row.userId)
	end
	nameOf(ids)
	local rows = {}
	for _, row in list do
		table.insert(rows, {
			rank = row.rank,
			userId = row.userId,
			name = names[row.userId] or "Racer",
			ms = row.ms,
			me = row.me,
			friend = row.friend,
		})
	end
	Net.fire("Board.Data", player, {
		mapId = mapId,
		tab = tab,
		rows = rows,
		mine = if mine then { rank = mine.rank, ms = mine.ms, name = player.DisplayName } else nil,
	})
end

function BoardService.init()
	Net.on("Board.Get", onGet)
	TracksService.Finished:Connect(function(player: Player, map: any, _firstFinish: boolean, info: any)
		local profile = DataService.get(player)
		if not boardable(map) or profile == nil or info == nil or info.ms == nil then
			return
		end
		if not Boards.shouldPost(nil, info.ms, banned(profile)) then
			return
		end
		local allTime, weekly = scopes(map, ProfileSchema.dayNumber(os.time()))
		post(weekly, player.UserId, info.ms)
		if info.isBest then
			post(allTime, player.UserId, info.ms)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		friendSets[player] = nil
	end)
end

return BoardService
