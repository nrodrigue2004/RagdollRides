--!strict
-- Boards: map leaderboard keys and rows (spec: Leaderboards screen; Data model > MapTimes_v1, an
-- OrderedDataStore per map and week, lower is better). Pure, so tests/run.luau checks it in Lune.
-- * Scopes: "<mapId>_A" all-time and "<mapId>_W<week>" weekly (weeks start Monday, as quests). A player
--   map whose creator time moved over 10% on a republish (boardEpoch, milestone 3) starts fresh boards:
--   "<mapId>_E<epoch>_A" and "..._W<week>".
-- * Entries: key = userId, value = best time in ms.
-- * Tabs: Friends (friends found in the all-time top 100, plus you), Weekly, All-time. Your own row is
--   always pinned under the list, with your rank when you are in what was read.

local Boards = {}

Boards.TABS = { "friends", "weekly", "alltime" }

local function weekOf(day: number): number
	return math.floor((day + 3) / 7)
end

local function base(mapId: string, epoch: number?): string
	if epoch and epoch > 0 then
		return string.format("%s_E%d", mapId, epoch)
	end
	return mapId
end

function Boards.allTimeScope(mapId: string, epoch: number?): string
	return base(mapId, epoch) .. "_A"
end

function Boards.weeklyScope(mapId: string, epoch: number?, day: number): string
	return string.format("%s_W%d", base(mapId, epoch), weekOf(day))
end

export type Entry = { userId: number, ms: number }
export type Row = { rank: number?, userId: number, ms: number, me: boolean, friend: boolean }

-- The rows for a tab from what was read (entries sorted fastest first). friends: a set of user ids.
-- Returns the list (at most `count`) and your pinned row (nil when you have no time on this board).
function Boards.rows(
	tab: string,
	entries: { Entry },
	me: number,
	myMs: number?,
	friends: { [number]: boolean },
	count: number
): ({ Row }, Row?)
	local list: { Row } = {}
	local mine: Row? = nil
	local rank = 0
	for _, e in entries do
		rank += 1
		local isMe = e.userId == me
		local isFriend = friends[e.userId] == true
		local row: Row = { rank = rank, userId = e.userId, ms = e.ms, me = isMe, friend = isFriend }
		if isMe then
			mine = row
		end
		if tab ~= "friends" or isMe or isFriend then
			if #list < count then
				table.insert(list, row)
			end
		end
	end
	if tab == "friends" then
		-- Friends ranks count only friends and you
		for index, row in list do
			row.rank = index
		end
	end
	if mine == nil and myMs ~= nil then
		mine = { rank = nil, userId = me, ms = myMs, me = true, friend = false }
	end
	return list, mine
end

-- Mode boards (Boards_v1, higher is better): "<prefix>_D<day>" daily and "<prefix>_W<week>" weekly, e.g.
-- HW_Score_D20406 (days and weeks as Shared/Quests counts them)
function Boards.modeScope(prefix: string, period: string, number: number): string
	return string.format("%s_%s%d", prefix, period, number)
end

-- Best Bone-Break Run: breaks reached, ties by score (one number so the board sorts it)
function Boards.bonesValue(breaks: number, score: number): number
	return breaks * 1000000 + math.clamp(math.floor(score), 0, 999999)
end

function Boards.bonesOf(value: number): (number, number)
	return value // 1000000, value % 1000000
end

-- Should a finish post to the boards? Only a new best (a lower time), and never while board-banned.
function Boards.shouldPost(previousMs: number?, ms: number, banned: boolean): boolean
	if banned or ms <= 0 then
		return false
	end
	return previousMs == nil or ms < previousMs
end

return Boards
