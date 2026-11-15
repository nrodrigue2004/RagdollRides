--!strict
-- TracksMath: Tracks scoring and run validation (pure, unit tested; the server decides, the client shows).
-- Spec: Tracks: free run (stars, coins, caps) and Anti-exploit (fake finish, teleport, time, speed).

local TracksMath = {}

export type TracksConfig = {
	silverFactor: number,
	goldFactor: number,
	coinsStarter: number,
	coinsPlayerMap: number,
	fullPayFinishesPerDay: number,
	reducedCoins: number,
	dailyCap: number,
	minTimeFactor: number,
	minTimeFloor: number,
	[string]: any,
}

-- Star tier for a finish time: 1 Bronze (finished), 2 Silver (under creator x 1.5), 3 Gold (under x 1.1)
function TracksMath.starTier(timeSeconds: number, creatorSeconds: number, cfg: TracksConfig): number
	if timeSeconds < creatorSeconds * cfg.goldFactor then
		return 3
	elseif timeSeconds < creatorSeconds * cfg.silverFactor then
		return 2
	end
	return 1
end

-- Stars paid for reaching a tier: once per tier per map, so only the tiers above the best so far pay.
function TracksMath.starsToPay(newTier: number, previousTier: number): number
	return math.max(0, newTier - previousTier)
end

-- Coins for a finish before boosts and caps: full pay for the first 3 finishes of a map today, then 5.
function TracksMath.finishCoins(isStarter: boolean, finishesToday: number, cfg: TracksConfig): number
	if finishesToday < cfg.fullPayFinishesPerDay then
		return if isStarter then cfg.coinsStarter else cfg.coinsPlayerMap
	end
	return cfg.reducedCoins
end

-- Apply boosts (friends, rebirths), then the daily cap. Returns the coins to grant.
function TracksMath.applyCap(amount: number, boost: number, earnedToday: number, cap: number): number
	local boosted = math.floor(amount * (1 + boost) + 0.5)
	return math.max(0, math.min(boosted, cap - earnedToday))
end

-- Friend boost: +10% per friend in the server, max +50%; rebirth bonus +5% each, max +50%
function TracksMath.boost(friends: number, rebirths: number, economy: { [string]: number }): number
	local friend = math.min(friends * economy.friendBoostPerFriend, economy.friendBoostMax)
	local rebirth = math.min(rebirths * economy.rebirthBonusPer, economy.rebirthBonusMax)
	return friend + rebirth
end

-- The fastest time the server accepts for a map: creator time x 0.6, never under 5 s
function TracksMath.minimumTime(creatorSeconds: number, cfg: TracksConfig): number
	return math.max(cfg.minTimeFloor, creatorSeconds * cfg.minTimeFactor)
end

export type RunRecord = {
	mapId: string,
	startTime: number, -- server clock
	checkpoints: { number }, -- server clock time each checkpoint was reached, by index
	checkpointCount: number,
	speedFlags: number,
}

-- Validate a finish. Times are the server's own clock. Returns ok, reason, the run time in seconds.
function TracksMath.validateFinish(
	run: RunRecord,
	finishTime: number,
	creatorSeconds: number,
	cfg: TracksConfig
): (boolean, string?, number)
	local elapsed = finishTime - run.startTime
	-- every checkpoint, in order, each after the one before
	local last = run.startTime
	for index = 1, run.checkpointCount do
		local t = run.checkpoints[index]
		if t == nil then
			return false, "missed checkpoint " .. index, elapsed
		end
		if t < last then
			return false, "checkpoints out of order", elapsed
		end
		last = t
	end
	if finishTime < last then
		return false, "finish before last checkpoint", elapsed
	end
	if elapsed < TracksMath.minimumTime(creatorSeconds, cfg) then
		return false, "faster than the map allows", elapsed
	end
	if run.speedFlags > 0 then
		return false, "speed check", elapsed
	end
	return true, nil, elapsed
end

-- A checkpoint report is accepted only as the next one in order.
function TracksMath.acceptCheckpoint(run: RunRecord, index: number): boolean
	if index < 1 or index > run.checkpointCount then
		return false
	end
	for i = 1, index - 1 do
		if run.checkpoints[i] == nil then
			return false
		end
	end
	return run.checkpoints[index] == nil
end

-- Speed check over one sample: distance moved / time against the limit (top speed x 1.4 plus launch
-- allowances). Returns true if this sample is too fast.
function TracksMath.tooFast(
	distance: number,
	dt: number,
	topSpeed: number,
	factor: number,
	allowance: number
): boolean
	if dt <= 0 then
		return false
	end
	return distance / dt > topSpeed * factor + allowance
end

-- Split against the best run at a checkpoint: negative is ahead (green), positive behind (red)
function TracksMath.split(currentMs: number, bestMs: number?): number?
	if bestMs == nil then
		return nil
	end
	return currentMs - bestMs
end

-- The spec's fake-finish check: over any 1 s window the car never covered more ground than top speed x
-- 1.25 (plus the speed pad boost). segments = { { time = server clock, distance = horizontal studs } },
-- oldest first. Returns true if the latest window is too fast. Windows shorter than 0.9 s are not judged.
function TracksMath.windowTooFast(
	segments: { { time: number, distance: number } },
	now: number,
	topSpeed: number,
	factor: number,
	allowance: number,
	window: number
): boolean
	local total = 0
	local oldest = now
	for i = #segments, 1, -1 do
		local segment = segments[i]
		if now - segment.time > window then
			break
		end
		total += segment.distance
		oldest = segment.time
	end
	local span = now - oldest
	if span < window * 0.9 then
		return false
	end
	return total > (topSpeed * factor + allowance) * span
end

export type PayoutInput = {
	timeSeconds: number,
	creatorSeconds: number,
	previousTier: number, -- 0 if never finished
	previousBestMs: number?,
	isStarter: boolean,
	finishesToday: number, -- finishes of this map today before this one
	trailCoins: number, -- trail coins picked up (already clamped to the map's count)
	coinValue: number, -- per trail coin
	reward: { coins: number, stars: number }?, -- a fixed first-finish reward (Pip's Hill)
	rewardClaimed: boolean,
	boost: number,
	earnedToday: number, -- Tracks coins already earned today
}

export type Payout = {
	tier: number,
	stars: number,
	coins: number,
	capped: boolean, -- the daily cap cut this payout
	isBest: boolean,
	bestMs: number,
	firstReward: boolean,
}

-- Everything a validated finish pays. Stars pay once per tier per map; coins are boosted then capped.
-- The first-finish reward is a fixed amount (no boost) that replaces the normal pay once.
function TracksMath.payout(input: PayoutInput, cfg: TracksConfig): Payout
	local tier = TracksMath.starTier(input.timeSeconds, input.creatorSeconds, cfg)
	local stars = TracksMath.starsToPay(tier, input.previousTier)
	local ms = math.floor(input.timeSeconds * 1000 + 0.5)
	local isBest = input.previousBestMs == nil or ms < input.previousBestMs
	local base, boost
	local firstReward = input.reward ~= nil and not input.rewardClaimed
	if firstReward then
		local reward = input.reward :: { coins: number, stars: number }
		base, boost = reward.coins, 0
		stars = math.max(stars, reward.stars)
	else
		base = TracksMath.finishCoins(input.isStarter, input.finishesToday, cfg)
			+ math.max(0, input.trailCoins) * input.coinValue
		boost = input.boost
	end
	local wanted = math.floor(base * (1 + boost) + 0.5)
	-- The daily cap rises with the rebirth bonus (spec: Rebirth), so rebirth never shrinks earnings
	local cap = math.floor(cfg.dailyCap * ((input :: any).capMultiplier or 1) + 0.5)
	local coins = TracksMath.applyCap(base, boost, input.earnedToday, cap)
	return {
		tier = tier,
		stars = stars,
		coins = coins,
		capped = coins < wanted,
		isBest = isBest,
		bestMs = if isBest then ms else input.previousBestMs :: number,
		firstReward = firstReward,
	}
end

-- "1:05.32" style time
function TracksMath.formatTime(seconds: number): string
	seconds = math.max(0, seconds)
	local minutes = math.floor(seconds / 60)
	local rest = seconds - minutes * 60
	return string.format("%d:%05.2f", minutes, rest)
end

return TracksMath
