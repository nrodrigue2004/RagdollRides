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

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Boards = require(Shared.Boards)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)

local Services = script.Parent
local BoardStore = require(Services.BoardStore)
local DataService = require(Services.DataService)
local TracksService = require(Services.TracksService)

local BoardService = {}

local cfg = Config.Boards

-- Map boards: lower times win
local function post(scope: string, userId: number, ms: number)
	BoardStore.post(cfg.storeName, scope, userId, ms, false)
end

local function read(scope: string, count: number): { Boards.Entry }
	return BoardStore.read(cfg.storeName, scope, count, false)
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
	local friends = if tab == "friends" then BoardStore.friendsOf(player) else {}
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
	local names = BoardStore.names(ids)
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
end

return BoardService
