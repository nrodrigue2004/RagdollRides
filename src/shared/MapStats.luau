--!strict
-- MapStats: the numbers behind player maps (spec: Browse and Popular, Moderation, Creator royalties).
-- Pure, so tests/run.luau checks them in Lune. Every tuning number is in Config.Maps.
--   Popular score = plays in the last 7 days x (average rating / 5)^2 x 100. Maps with under 10 ratings
--   count as 3.5 stars, so one early 1-star or 5-star vote can't bury or crown a map.
--   Auto-hide (stricter than the spec, nate 2026-11-15): 15 counted reports AND over 25% of the
--   players who finished it. An auto-hide only takes the map off the tabs until an admin looks.
--   Creator strikes: only an admin-confirmed hide is a strike; 3 in 90 days is a publish ban of 7 days,
--   then 30 days, then for good.
--   Royalties: 5 coins per play by someone else, at most 200 a day per creator.

local Config = if script then require(script.Parent.Config) else (require :: any)("./Config")

local MapStats = {}

local DAY = 86400

-- The rating shown on a card: nil means "New" (too few ratings to mean much)
function MapStats.shownRating(sum: number, count: number): number?
	if count < Config.Maps.ratingsBeforeShown then
		return nil
	end
	return math.floor(sum / count * 10 + 0.5) / 10
end

-- The average the Popular score uses
function MapStats.scoreRating(sum: number, count: number): number
	if count < Config.Maps.ratingsBeforeShown then
		return Config.Maps.newMapRating
	end
	return math.clamp(sum / count, 1, 5)
end

-- Plays in the last `days` days (today included), from { [tostring(day)] = plays }
function MapStats.recentPlays(playsByDay: { [string]: number }, today: number, days: number?): number
	local total = 0
	local window = days or Config.Maps.popularDays
	for key, plays in playsByDay do
		local day = tonumber(key)
		if day and day > today - window and day <= today then
			total += plays
		end
	end
	return total
end

-- Drop days older than the Popular window (keeps the record small)
function MapStats.trimDays(playsByDay: { [string]: number }, today: number)
	for key in playsByDay do
		local day = tonumber(key)
		if day == nil or day <= today - Config.Maps.popularDays then
			playsByDay[key] = nil
		end
	end
end

-- The Popular index score (an integer: OrderedDataStore values are integers)
function MapStats.popularScore(
	playsByDay: { [string]: number },
	today: number,
	sum: number,
	count: number
): number
	local average = MapStats.scoreRating(sum, count)
	return math.floor(MapStats.recentPlays(playsByDay, today) * (average / 5) ^ 2 * 100 + 0.5)
end

-- A rating change: the sum and count deltas for a player moving from `old` (nil = never rated) to `new`
function MapStats.ratingDelta(old: number?, new: number): (number, number)
	if old == nil then
		return new, 1
	end
	return new - old, 0
end

-- Should reports hide this map? (counted reports, players who finished it)
function MapStats.shouldHide(reports: number, finishers: number): boolean
	local cfg = Config.Maps
	return reports >= cfg.reportsToHide and reports > finishers * cfg.reportShare
end

-- Does this player's report count? (account age in days, finished the map, owns it)
function MapStats.reportCounts(accountAge: number, finished: boolean, isOwner: boolean): boolean
	return accountAge >= Config.Maps.reportMinAccountDays and finished and not isOwner
end

-- A new strike: returns the strike list to keep, the new ban level and the ban's end (0 = no new ban).
-- `strikes` are unix times; `level` counts bans so far (0 none, 1 after the 7 day ban, ...).
function MapStats.addStrike(strikes: { number }, level: number, now: number): ({ number }, number, number)
	local cfg = Config.Maps
	local kept = {}
	for _, t in strikes do
		if now - t < cfg.strikeWindowDays * DAY then
			table.insert(kept, t)
		end
	end
	table.insert(kept, now)
	if #kept < cfg.strikesForBan then
		return kept, level, 0
	end
	local nextLevel = math.min(level + 1, #cfg.banDays + 1)
	local days = cfg.banDays[nextLevel]
	local untilTime = if days then now + days * DAY else cfg.forever
	return {}, nextLevel, untilTime
end

-- Royalties: how much of `amount` fits under today's cap, given what this creator already earned today
function MapStats.royaltyRoom(amount: number, earnedToday: number): number
	return math.max(0, math.min(amount, Config.Maps.royaltyDailyCap - earnedToday))
end

-- The world offset of loaded player map slot `index` (1-based), far from the starter maps and plots
function MapStats.slotOffset(index: number): { number }
	local cfg = Config.Maps
	return { cfg.slotOrigin[1], cfg.slotOrigin[2], cfg.slotOrigin[3] - (index - 1) * cfg.slotSpacing }
end

-- A page of a list: items (from, to) for 1-based page `page` of size `size`
function MapStats.pageRange(total: number, page: number, size: number): (number, number)
	local first = (page - 1) * size + 1
	return first, math.min(total, first + size - 1)
end

return MapStats
