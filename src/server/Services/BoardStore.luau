-- BoardStore: the OrderedDataStore side of every leaderboard (map times in MapTimes_v1, mode boards such
-- as Highway scores in Boards_v1). One board is one store scope. Shared/Boards builds the tabs and rows.
-- * post keeps each player's best value (lower or higher wins, per board).
-- * read returns the top entries, cached for a minute (Config.Boards.cacheSeconds).
-- * names: Roblox display names for user ids (cached); friendsOf: a player's Roblox friends (first 200,
--   once a session).
-- * In Studio without API access the boards live in memory for the session (DataService memory mode).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local UserService = game:GetService("UserService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Boards = require(Shared.Boards)
local Config = require(Shared.Config)

local DataService = require(script.Parent.DataService)

local BoardStore = {}

local cfg = Config.Boards

local stores: { [string]: OrderedDataStore } = {}
local memory: { [string]: { [number]: number } } = {}
local cache: { [string]: { time: number, entries: { Boards.Entry } } } = {}
local names: { [number]: string } = {}
local friendSets: { [Player]: { [number]: boolean } } = {}

local function storeFor(storeName: string, scope: string): OrderedDataStore?
	local key = storeName .. "/" .. scope
	if stores[key] == nil then
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(storeName, scope)
		end)
		if ok then
			stores[key] = store
		end
	end
	return stores[key]
end

local function better(value: number, old: number?, higher: boolean): boolean
	if old == nil then
		return true
	end
	return if higher then value > old else value < old
end

-- Keep this player's best value on a board (higher: bigger is better; else smaller is better)
function BoardStore.post(storeName: string, scope: string, userId: number, value: number, higher: boolean)
	local prefix = storeName .. "/" .. scope .. "#"
	-- Your own new value shows on your next look (the cache would hide it for a minute)
	for key in cache do
		if string.sub(key, 1, #prefix) == prefix then
			cache[key] = nil
		end
	end
	if DataService.isMemoryMode() then
		local board = memory[storeName .. "/" .. scope] or {}
		memory[storeName .. "/" .. scope] = board
		if better(value, board[userId], higher) then
			board[userId] = value
		end
		return
	end
	local store = storeFor(storeName, scope)
	if store == nil then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(store :: OrderedDataStore):UpdateAsync(tostring(userId), function(old: number?)
				if not better(value, old, higher) then
					return nil -- keep the better value
				end
				return value
			end)
		end)
		if not ok then
			warn("[Boards] post failed: " .. tostring(err))
		end
	end)
end

-- The best `count` entries on a board (cached for a minute)
function BoardStore.read(storeName: string, scope: string, count: number, higher: boolean): { Boards.Entry }
	local key = storeName .. "/" .. scope .. "#" .. count
	local hit = cache[key]
	if hit and os.clock() - hit.time < cfg.cacheSeconds then
		return hit.entries
	end
	local entries: { Boards.Entry } = {}
	if DataService.isMemoryMode() then
		for userId, value in memory[storeName .. "/" .. scope] or {} do
			table.insert(entries, { userId = userId, ms = value })
		end
		table.sort(entries, function(a, b)
			if higher then
				return a.ms > b.ms
			end
			return a.ms < b.ms
		end)
		while #entries > count do
			table.remove(entries)
		end
	else
		local store = storeFor(storeName, scope)
		if store then
			local ok, pages = pcall(function()
				return (store :: OrderedDataStore):GetSortedAsync(not higher, math.min(count, 100))
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

-- Fill the name cache for these ids; returns it
function BoardStore.names(userIds: { number }): { [number]: string }
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
	if #missing > 0 then
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and infos then
			for _, info in infos do
				names[info.Id] = info.DisplayName
			end
		end
	end
	return names
end

-- A player's Roblox friends (first 200), read once a session
function BoardStore.friendsOf(player: Player): { [number]: boolean }
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

function BoardStore.init()
	Players.PlayerRemoving:Connect(function(player)
		friendSets[player] = nil
	end)
end

return BoardStore
