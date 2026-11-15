--!strict
-- Quests: daily and weekly quests and the login streak (spec: Progression > Quests and streaks).
-- Pure, so tests/run.luau checks it in Lune.
--   Daily: 3 a day from a pool of 24 (one per mode while every mode is live; until Bumper Brawl and
--   Highway Havoc ship, all 3 come from Tracks and the builder). Rewards 60 / 80 / 100 coins by tier.
--   All 3 claimed opens the daily chest. Weekly: 3 a week, 300 coins each, 5 stars for all 3.
--   Picks are seeded by the day (or week) and the player, so a rejoin never rerolls them.
--   Login streak: a 7-day loop. Each missed day steps the next claim back one day, never below day 1.
-- Quest text is ours (preset), never player text. Events are counted on the server only.

local Quests = {}

export type Def = {
	id: string,
	mode: string, -- "tracks" | "brawl" | "highway"
	tier: number, -- daily: 1, 2, 3 (60, 80, 100 coins); weekly quests have tier 0
	text: string, -- "%d" is the target
	event: string,
	target: number,
	distinct: boolean?, -- counts each key once (different maps)
}

export type State = { id: string, progress: number, claimed: boolean, keys: { string }? }

Quests.DAILY = {
	-- Tracks and builder (10)
	{ id = "d_finish3", mode = "tracks", tier = 1, text = "Finish %d runs", event = "finish", target = 3 },
	{
		id = "d_coins20",
		mode = "tracks",
		tier = 1,
		text = "Grab %d trail coins",
		event = "trailCoins",
		target = 20,
	},
	{ id = "d_rate1", mode = "tracks", tier = 1, text = "Rate %d player map", event = "rate", target = 1 },
	{
		id = "d_starter2",
		mode = "tracks",
		tier = 1,
		text = "Finish %d starter maps",
		event = "finishStarter",
		target = 2,
		distinct = true,
	},
	{
		id = "d_player2",
		mode = "tracks",
		tier = 2,
		text = "Finish %d player maps",
		event = "playerMapFinish",
		target = 2,
		distinct = true,
	},
	{
		id = "d_best1",
		mode = "tracks",
		tier = 2,
		text = "Beat your best time %d time",
		event = "best",
		target = 1,
	},
	{ id = "d_finish8", mode = "tracks", tier = 2, text = "Finish %d runs", event = "finish", target = 8 },
	{ id = "d_gold1", mode = "tracks", tier = 3, text = "Get Gold on %d map", event = "gold", target = 1 },
	{
		id = "d_test1",
		mode = "tracks",
		tier = 3,
		text = "Build a map and finish it in TEST",
		event = "test",
		target = 1,
	},
	{
		id = "d_player5",
		mode = "tracks",
		tier = 3,
		text = "Finish %d player maps",
		event = "playerMapFinish",
		target = 5,
		distinct = true,
	},
	-- Bumper Brawl (7; milestone 7 sends these events)
	{
		id = "d_brawl3",
		mode = "brawl",
		tier = 1,
		text = "Play %d Brawl rounds",
		event = "brawlRound",
		target = 3,
	},
	{ id = "d_bump30", mode = "brawl", tier = 1, text = "Bump cars %d times", event = "bump", target = 30 },
	{ id = "d_ko2", mode = "brawl", tier = 1, text = "Knock out %d cars", event = "brawlKO", target = 2 },
	{ id = "d_ko5", mode = "brawl", tier = 2, text = "Knock out %d cars", event = "brawlKO", target = 5 },
	{
		id = "d_survive3",
		mode = "brawl",
		tier = 2,
		text = "Survive to the end of %d rounds",
		event = "brawlSurvive",
		target = 3,
	},
	{ id = "d_win1", mode = "brawl", tier = 3, text = "Win %d Brawl round", event = "brawlWin", target = 1 },
	{ id = "d_ko8", mode = "brawl", tier = 3, text = "Knock out %d cars", event = "brawlKO", target = 8 },
	-- Highway Havoc (7; milestone 8 sends these events)
	{
		id = "d_hw2",
		mode = "highway",
		tier = 1,
		text = "Do %d Highway runs",
		event = "highwayRun",
		target = 2,
	},
	{ id = "d_pile1", mode = "highway", tier = 1, text = "Cause %d pile-up", event = "pileup", target = 1 },
	{ id = "d_bones5", mode = "highway", tier = 1, text = "Break %d bones", event = "bones", target = 5 },
	{
		id = "d_score10k",
		mode = "highway",
		tier = 2,
		text = "Score %d in one run",
		event = "highwayScore",
		target = 10000,
	},
	{ id = "d_pile3", mode = "highway", tier = 2, text = "Cause %d pile-ups", event = "pileup", target = 3 },
	{ id = "d_bones15", mode = "highway", tier = 3, text = "Break %d bones", event = "bones", target = 15 },
	{
		id = "d_score25k",
		mode = "highway",
		tier = 3,
		text = "Score %d in one run",
		event = "highwayScore",
		target = 25000,
	},
} :: { Def }

Quests.WEEKLY = {
	{ id = "w_finish25", mode = "tracks", tier = 0, text = "Finish %d runs", event = "finish", target = 25 },
	{
		id = "w_player10",
		mode = "tracks",
		tier = 0,
		text = "Finish %d player maps",
		event = "playerMapFinish",
		target = 10,
		distinct = true,
	},
	{ id = "w_gold3", mode = "tracks", tier = 0, text = "Get Gold on %d maps", event = "gold", target = 3 },
	{ id = "w_rate5", mode = "tracks", tier = 0, text = "Rate %d player maps", event = "rate", target = 5 },
	{
		id = "w_best5",
		mode = "tracks",
		tier = 0,
		text = "Beat your best time %d times",
		event = "best",
		target = 5,
	},
	{
		id = "w_brawl15",
		mode = "brawl",
		tier = 0,
		text = "Play %d Brawl rounds",
		event = "brawlRound",
		target = 15,
	},
	{ id = "w_ko20", mode = "brawl", tier = 0, text = "Knock out %d cars", event = "brawlKO", target = 20 },
	{
		id = "w_hw10",
		mode = "highway",
		tier = 0,
		text = "Do %d Highway runs",
		event = "highwayRun",
		target = 10,
	},
	{ id = "w_bones50", mode = "highway", tier = 0, text = "Break %d bones", event = "bones", target = 50 },
} :: { Def }

-- Events where the amount is a single run's value to reach, not a count to add up
local PEAK_EVENTS = { highwayScore = true }

Quests.byId = {} :: { [string]: Def }
for _, list in { Quests.DAILY, Quests.WEEKLY } do
	for _, def in list do
		Quests.byId[def.id] = def
	end
end

-- A small seeded random generator (Park-Miller), the same in Lune and Roblox
function Quests.rng(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % 2147483646 + 1
	return function(): number
		state = (state * 48271) % 2147483647
		return (state - 1) / 2147483646
	end
end

-- Weeks start on Monday (UTC). Day 0 (1970-01-01) was a Thursday.
function Quests.weekOf(day: number): number
	return math.floor((day + 3) / 7)
end

local function pickOne(list: { Def }, random: () -> number): Def?
	if #list == 0 then
		return nil
	end
	return list[math.floor(random() * #list) + 1]
end

local function fresh(def: Def): State
	return { id = def.id, progress = 0, claimed = false, keys = if def.distinct then {} else nil }
end

-- Today's 3 daily quests: tiers 1, 2 and 3, one per live mode where it can (modes: the live ones)
function Quests.pickDaily(seed: number, modes: { string }): { State }
	local random = Quests.rng(seed)
	local order = table.clone(modes)
	for i = #order, 2, -1 do
		local j = math.floor(random() * i) + 1
		order[i], order[j] = order[j], order[i]
	end
	local picked: { State } = {}
	local used: { [string]: boolean } = {}
	for tier = 1, 3 do
		local mode = order[(tier - 1) % #order + 1]
		local options = {}
		for _, def in Quests.DAILY do
			if def.mode == mode and def.tier == tier and not used[def.event] then
				table.insert(options, def)
			end
		end
		local def = pickOne(options, random)
		if def then
			used[def.event] = true
			table.insert(picked, fresh(def))
		end
	end
	return picked
end

function Quests.pickWeekly(seed: number, modes: { string }): { State }
	local random = Quests.rng(seed)
	local options = {}
	for _, def in Quests.WEEKLY do
		if table.find(modes, def.mode) then
			table.insert(options, def)
		end
	end
	local picked: { State } = {}
	while #picked < 3 and #options > 0 do
		local index = math.floor(random() * #options) + 1
		table.insert(picked, fresh(table.remove(options, index) :: Def))
	end
	return picked
end

-- Count an event toward a list of quests. key: what makes a distinct quest count (a map id).
-- Returns the quests that just reached their target.
function Quests.apply(list: { State }, event: string, amount: number, key: string?): { State }
	local finished = {}
	for _, state in list do
		local def = Quests.byId[state.id]
		if def == nil or def.event ~= event or state.claimed or state.progress >= def.target then
			continue
		end
		local before = state.progress
		if def.distinct then
			local keys = state.keys or {}
			state.keys = keys
			if key == nil or table.find(keys, key) then
				continue
			end
			table.insert(keys, key)
			state.progress = #keys
		elseif PEAK_EVENTS[event] then
			state.progress = math.max(state.progress, amount)
		else
			state.progress += amount
		end
		state.progress = math.min(state.progress, def.target)
		if before < def.target and state.progress >= def.target then
			table.insert(finished, state)
		end
	end
	return finished
end

function Quests.isDone(state: State): boolean
	local def = Quests.byId[state.id]
	return def ~= nil and state.progress >= def.target
end

function Quests.text(state: State): string
	local def = Quests.byId[state.id]
	if def == nil then
		return ""
	end
	return (string.format(def.text, def.target))
end

-- The coins a claimed quest pays (weekly or daily by tier)
function Quests.reward(state: State, cfg: { [string]: any }): number
	local def = Quests.byId[state.id]
	if def == nil then
		return 0
	end
	if def.tier == 0 then
		return cfg.weeklyReward
	end
	return cfg.dailyRewards[def.tier] or 0
end

function Quests.allClaimed(list: { State }): boolean
	if #list == 0 then
		return false
	end
	for _, state in list do
		if not state.claimed then
			return false
		end
	end
	return true
end

-- Login streak: the day (1..7) the next claim pays, and whether it can be claimed today.
-- streakDay: the last day claimed (0 = never); lastClaim: the UTC day of that claim.
function Quests.streakNext(streakDay: number, lastClaim: number, today: number): (number, boolean)
	if streakDay <= 0 or lastClaim <= 0 then
		return 1, true
	end
	if lastClaim >= today then
		return streakDay, false
	end
	if streakDay >= 7 then
		return 1, true -- the loop starts again after day 7, missed days or not
	end
	local missed = today - lastClaim - 1
	local nextDay = streakDay + 1 - missed
	nextDay = math.max(1, nextDay)
	if nextDay > 7 then
		nextDay = 1
	end
	return nextDay, true
end

return Quests
