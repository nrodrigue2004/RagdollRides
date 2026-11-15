--!strict
-- RaceMath: quick race rules (spec: Tracks: quick race). Pure, so tests/run.luau checks it in Lune.
-- * Places by finish time (the server's clock); everyone who did not finish is a DNF, after them.
-- * Pay: 80 / 60 / 45 / 35 / 25 / 20 / 15 / 10 coins by place, a DNF 10 (counts toward the Tracks
--   daily cap; EconomyService applies it). A race with one finisher among one racer still pays place 1.
-- * The start grid: 4 across and 2 deep on the start line, places 1 to 4 in the front row.
-- * Race maps: the starter maps after Pip's Hill (the tutorial stays a tutorial), in turn per server.

local RaceMath = {}

export type Racer = { userId: number, time: number? } -- time in seconds, nil = did not finish
export type Placing = { userId: number, place: number, time: number?, dnf: boolean }

-- Places: finishers by time (ties by userId so every server agrees), then DNFs
function RaceMath.places(racers: { Racer }): { Placing }
	local finished, dnf = {}, {}
	for _, r in racers do
		if r.time ~= nil then
			table.insert(finished, r)
		else
			table.insert(dnf, r)
		end
	end
	table.sort(finished, function(a, b)
		if a.time ~= b.time then
			return (a.time :: number) < (b.time :: number)
		end
		return a.userId < b.userId
	end)
	table.sort(dnf, function(a, b)
		return a.userId < b.userId
	end)
	local out: { Placing } = {}
	for index, r in finished do
		table.insert(out, { userId = r.userId, place = index, time = r.time, dnf = false })
	end
	for _, r in dnf do
		table.insert(out, { userId = r.userId, place = #out + 1, time = nil, dnf = true })
	end
	return out
end

function RaceMath.coins(placing: Placing, cfg: { placeCoins: { number }, dnfCoins: number }): number
	if placing.dnf then
		return cfg.dnfCoins
	end
	return cfg.placeCoins[placing.place] or cfg.placeCoins[#cfg.placeCoins]
end

-- Grid slot `index` (1 = pole) as a map-space offset from the start (right, forward), in studs
function RaceMath.gridOffset(index: number, spacing: number): (number, number)
	local column = (index - 1) % 4 -- 0..3, left to right
	local row = math.floor((index - 1) / 4) -- 0 = front
	local right = (column - 1.5) * spacing
	local forward = if row == 0 then 12 else 0
	return right, forward
end

-- The ordinal for a place ("1st", "2nd", ...)
function RaceMath.ordinal(place: number): string
	local tens = place % 100
	if tens >= 11 and tens <= 13 then
		return place .. "th"
	end
	local last = place % 10
	if last == 1 then
		return place .. "st"
	elseif last == 2 then
		return place .. "nd"
	elseif last == 3 then
		return place .. "rd"
	end
	return place .. "th"
end

-- The next race map from a list, in turn (the list of map ids; `count` races run so far)
function RaceMath.pickMap(list: { string }, count: number): string?
	if #list == 0 then
		return nil
	end
	return list[count % #list + 1]
end

-- Live order during a race: by checkpoints reached, then the time they were reached (earlier first)
export type Progress = { userId: number, checkpoints: number, at: number, finished: number? }
function RaceMath.liveOrder(list: { Progress }): { number }
	local copy = table.clone(list)
	table.sort(copy, function(a, b)
		if (a.finished ~= nil) ~= (b.finished ~= nil) then
			return a.finished ~= nil
		end
		if a.finished and b.finished and a.finished ~= b.finished then
			return a.finished < b.finished
		end
		if a.checkpoints ~= b.checkpoints then
			return a.checkpoints > b.checkpoints
		end
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.userId < b.userId
	end)
	local out = {}
	for _, p in copy do
		table.insert(out, p.userId)
	end
	return out
end

return RaceMath
