--!strict
-- BrawlMath: Bumper Brawl rules (spec: Game modes > Bumper Brawl). Pure, so tests/run.luau checks it in
-- Lune; the server (BrawlService) and the clients (BrawlClient) use the same numbers.
-- * Arenas are hex tiles on an axial grid (pointy top: neighbours 1 spacing apart along X). The two
--   launch arenas have 72 tiles each in 3 rings: inner 18, middle 24, outer 30 (by distance from the
--   centre). "ring" is a circle of tiles round a one-tile foam geyser hole; "pier" is 9 by 8 tiles.
--   Practice is the 19-tile disc.
-- * The drop plan: outer ring at 40 s, middle at 75 s, then one random inner tile every 4 s from 95 s,
--   then one every 1 s in sudden death (120 to 150 s). Each drop warns 3 s before. Seeded, so the plan
--   is the same on every machine.
-- * Knockback: dv = 20 + 0.6 x closing x clamp(mass ratio, 0.6, 1.8), capped at 75, then x the
--   defender's class multiplier (and x1.6 for a Spring Bumper, x1.5 in practice).
-- * Placements: cars still on the arena first (most KOs, then most damage dealt), then the rest by
--   when they went out (later is better; the same moment: KOs, then damage).
-- * Pay, ranked points, tiers and the season soft reset.

local BrawlMath = {}

local SQRT3 = math.sqrt(3)

export type Tile = {
	index: number,
	q: number,
	r: number,
	x: number, -- offset from the arena origin, studs
	z: number,
	ring: number, -- 1 inner, 2 middle, 3 outer (practice: all 1)
}

export type Layout = {
	shape: string,
	spacing: number,
	tiles: { Tile },
	byKey: { [string]: number }, -- "q,r" -> tile index
	cx: number, -- the centre, in grid units (x, z before scaling)
	cz: number,
	radius: number, -- the farthest tile edge from the centre, studs
}

local function key(q: number, r: number): string
	return q .. "," .. r
end

-- Grid units: x = q + r/2, z = r x sqrt(3)/2 (adjacent tiles 1 apart)
local function gridXZ(q: number, r: number): (number, number)
	return q + r / 2, r * SQRT3 / 2
end

local function finish(shape: string, spacing: number, cells: { { number } }, rings: boolean): Layout
	-- Centre on the mean position
	local sx, sz = 0, 0
	for _, c in cells do
		local gx, gz = gridXZ(c[1], c[2])
		sx += gx
		sz += gz
	end
	local cx, cz = sx / #cells, sz / #cells
	-- Rings by distance from the centre: the nearest 18 inner, the next 24 middle, the rest outer
	local order = {}
	for i, c in cells do
		local gx, gz = gridXZ(c[1], c[2])
		table.insert(order, { i = i, d = (gx - cx) ^ 2 + (gz - cz) ^ 2 })
	end
	table.sort(order, function(a, b)
		if math.abs(a.d - b.d) > 1e-6 then
			return a.d < b.d
		end
		return a.i < b.i
	end)
	local ringOf = {}
	for rank, entry in order do
		ringOf[entry.i] = if not rings then 1 elseif rank <= 18 then 1 elseif rank <= 42 then 2 else 3
	end
	local tiles: { Tile } = {}
	local byKey: { [string]: number } = {}
	local radius = 0
	for i, c in cells do
		local gx, gz = gridXZ(c[1], c[2])
		local x, z = (gx - cx) * spacing, (gz - cz) * spacing
		local tile: Tile = { index = i, q = c[1], r = c[2], x = x, z = z, ring = ringOf[i] }
		tiles[i] = tile
		byKey[key(c[1], c[2])] = i
		radius = math.max(radius, math.sqrt(x * x + z * z) + spacing / SQRT3)
	end
	return {
		shape = shape,
		spacing = spacing,
		tiles = tiles,
		byKey = byKey,
		cx = cx,
		cz = cz,
		radius = radius,
	}
end

-- An arena layout: "ring" (72), "pier" (72) or "practice" (19)
function BrawlMath.layout(shape: string, spacing: number): Layout
	local cells: { { number } } = {}
	if shape == "pier" then
		for r = 0, 7 do
			for c = 0, 8 do
				table.insert(cells, { c - math.floor(r / 2), r })
			end
		end
		return finish(shape, spacing, cells, true)
	end
	local maxD2 = if shape == "practice" then 4 else 19
	local minD2 = if shape == "practice" then 0 else 1
	for r = -5, 5 do
		for q = -5, 5 do
			local d2 = q * q + q * r + r * r
			if d2 >= minD2 and d2 <= maxD2 then
				table.insert(cells, { q, r })
			end
		end
	end
	return finish(shape, spacing, cells, shape ~= "practice")
end

-- The tile under a point (offset from the arena origin, studs), or nil over a gap or the pit
function BrawlMath.tileAt(layout: Layout, x: number, z: number): number?
	local gz = z / layout.spacing + layout.cz
	local gx = x / layout.spacing + layout.cx
	local rf = gz / (SQRT3 / 2)
	local qf = gx - rf / 2
	-- Cube rounding
	local sf = -qf - rf
	local q, r, s = math.floor(qf + 0.5), math.floor(rf + 0.5), math.floor(sf + 0.5)
	local dq, dr, ds = math.abs(q - qf), math.abs(r - rf), math.abs(s - sf)
	if dq > dr and dq > ds then
		q = -r - s
	elseif dr > ds then
		r = -q - s
	end
	-- + 0 turns -0 into 0 so the key matches
	return layout.byKey[key(q + 0, r + 0)]
end

---------------------------------------------------------------------------
-- A small seeded random (the same on the server and every client)
---------------------------------------------------------------------------

export type Rng = () -> number

function BrawlMath.rng(seed: number): Rng
	local state = math.floor(math.abs(seed)) % 2147483647
	if state == 0 then
		state = 1
	end
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

---------------------------------------------------------------------------
-- The drop plan
---------------------------------------------------------------------------

export type Drop = { tile: number, at: number } -- seconds after GO
export type ScheduleConfig = {
	outerDropAt: number,
	middleDropAt: number,
	innerStart: number,
	innerEvery: number,
	suddenDeathEvery: number,
	roundLength: number,
	maxLength: number,
	warnTime: number,
}

function BrawlMath.dropPlan(layout: Layout, seed: number, cfg: ScheduleConfig): { Drop }
	local plan: { Drop } = {}
	local inner = {}
	for _, tile in layout.tiles do
		if tile.ring == 3 then
			table.insert(plan, { tile = tile.index, at = cfg.outerDropAt })
		elseif tile.ring == 2 then
			table.insert(plan, { tile = tile.index, at = cfg.middleDropAt })
		else
			table.insert(inner, tile.index)
		end
	end
	-- Shuffle the inner ring with the seed
	local random = BrawlMath.rng(seed)
	for i = #inner, 2, -1 do
		local j = math.floor(random() * i) + 1
		inner[i], inner[j] = inner[j], inner[i]
	end
	-- One every 4 s from 95 s until 120 s, then one every 1 s until 150 s
	local times = {}
	local t = cfg.innerStart
	while t < cfg.roundLength do
		table.insert(times, t)
		t += cfg.innerEvery
	end
	t = cfg.roundLength
	while t <= cfg.maxLength do
		table.insert(times, t)
		t += cfg.suddenDeathEvery
	end
	for i, index in inner do
		if times[i] == nil then
			break
		end
		table.insert(plan, { tile = index, at = times[i] })
	end
	table.sort(plan, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.tile < b.tile
	end)
	return plan
end

---------------------------------------------------------------------------
-- Bumps
---------------------------------------------------------------------------

export type KnockConfig = {
	base: number,
	factor: number,
	ratioMin: number,
	ratioMax: number,
	cap: number,
}

-- The speed change a bump gives the car that was hit (studs/s)
function BrawlMath.knockback(
	closing: number,
	attackerMass: number,
	defenderMass: number,
	defenderMultiplier: number,
	extra: number?,
	cfg: KnockConfig
): number
	local ratio = math.clamp(attackerMass / math.max(defenderMass, 1e-3), cfg.ratioMin, cfg.ratioMax)
	local dv = math.min(cfg.cap, cfg.base + cfg.factor * math.max(closing, 0) * ratio)
	return dv * defenderMultiplier * (extra or 1)
end

export type HitReport = {
	reported: number, -- closing speed the hitter's device saw
	attackerTop: number, -- the attacker's class top speed
	targetSpeed: number, -- the target's speed as the server sees it
	gap: number, -- distance between the two cars' edges, as the server sees them
	sinceLast: number, -- seconds since this pair's last accepted bump
}

-- The server's check on a reported bump (spec: Network model; Anti-exploit). Returns the closing speed
-- to use, or nil and why the bump is ignored.
function BrawlMath.checkHit(
	report: HitReport,
	cfg: { speedSlack: number, gap: number, pairCooldown: number }
): (number?, string?)
	if report.sinceLast < cfg.pairCooldown then
		return nil, "cooldown"
	end
	if report.gap > cfg.gap then
		return nil, "far"
	end
	local limit = report.attackerTop * cfg.speedSlack + report.targetSpeed
	if report.reported > limit then
		return nil, "speed"
	end
	return report.reported, nil
end

-- KO credit: the last car to bump you within the window (spec: 4 s). Explosions credit the last
-- bumper at any time this round (window nil).
function BrawlMath.koCredit(lastBy: number?, lastAt: number?, now: number, window: number?): number?
	if lastBy == nil or lastAt == nil then
		return nil
	end
	if window ~= nil and now - lastAt > window then
		return nil
	end
	return lastBy
end

---------------------------------------------------------------------------
-- Placements and pay
---------------------------------------------------------------------------

export type Entrant = {
	id: number,
	outAt: number?, -- nil while on the arena
	kos: number,
	damage: number, -- damage dealt (the impact of every accepted bump)
}

export type Placing = { id: number, place: number, out: boolean }

local function better(a: Entrant, b: Entrant): boolean
	if a.kos ~= b.kos then
		return a.kos > b.kos
	end
	if math.abs(a.damage - b.damage) > 1e-6 then
		return a.damage > b.damage
	end
	return a.id < b.id
end

function BrawlMath.placements(entrants: { Entrant }): { Placing }
	local list = table.clone(entrants)
	table.sort(list, function(a, b)
		local aIn, bIn = a.outAt == nil, b.outAt == nil
		if aIn ~= bIn then
			return aIn
		end
		if not aIn and math.abs((a.outAt :: number) - (b.outAt :: number)) > 0.05 then
			return (a.outAt :: number) > (b.outAt :: number)
		end
		return better(a, b)
	end)
	local out: { Placing } = {}
	for place, e in list do
		table.insert(out, { id = e.id, place = place, out = e.outAt ~= nil })
	end
	return out
end

-- How many cars are still on the arena
function BrawlMath.alive(entrants: { Entrant }): number
	local count = 0
	for _, e in entrants do
		if e.outAt == nil then
			count += 1
		end
	end
	return count
end

export type CoinConfig = { round: number, perKO: number, maxKOs: number, win: number }

-- Coins before boosts and the daily cap (spec: 20 + 5 per KO, max 4, + 40 for a win). An idle
-- round earns nothing.
function BrawlMath.coins(place: number, kos: number, idle: boolean, cfg: CoinConfig): number
	if idle then
		return 0
	end
	local coins = cfg.round + cfg.perKO * math.min(kos, cfg.maxKOs)
	if place == 1 then
		coins += cfg.win
	end
	return coins
end

---------------------------------------------------------------------------
-- Ranked
---------------------------------------------------------------------------

export type RankedConfig = {
	win: number,
	topHalf: number,
	firstOut: number,
	afkOrQuit: number,
	tierSize: number,
	placements: number,
	softResetTiers: number,
	tierNames: { string },
}

export type Ranked = { season: number, points: number, placementsLeft: number, bestTier: number }

-- Points for one ranked round. place 1 = the winner, count = cars in the round (bots included).
-- A bot win gives nobody points (spec); AFK and quitting still cost points.
function BrawlMath.rankedDelta(
	place: number,
	count: number,
	idleOrQuit: boolean,
	botWon: boolean,
	cfg: RankedConfig
): number
	if idleOrQuit then
		return cfg.afkOrQuit
	end
	if botWon then
		return 0
	end
	if place == 1 then
		return cfg.win
	end
	if place <= math.floor(count / 2) then
		return cfg.topHalf
	end
	if place == count then
		return cfg.firstOut
	end
	return 0
end

function BrawlMath.tierOf(points: number, cfg: RankedConfig): number
	return math.floor(math.max(points, 0) / cfg.tierSize)
end

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

-- Bronze Bolt, Silver Spark, Gold Gear, Platinum Piston, Diamond Drift, then Apex I, II, III and up
function BrawlMath.tierName(tier: number, cfg: RankedConfig): string
	local named = cfg.tierNames[tier + 1]
	if named then
		return named
	end
	local apex = tier - #cfg.tierNames + 1
	return "Apex " .. (ROMAN[apex] or tostring(apex))
end

-- Apply one round's points. Returns the new record, the change actually applied and whether the
-- tier went up.
function BrawlMath.applyRanked(record: Ranked, delta: number, cfg: RankedConfig): (Ranked, number, boolean)
	local out = table.clone(record)
	if out.placementsLeft > 0 then
		delta = math.max(delta, 0) -- the first rounds cannot lose points
		out.placementsLeft -= 1
	end
	local before = BrawlMath.tierOf(out.points, cfg)
	local points = math.max(0, out.points + delta) -- Bronze floors at 0
	local applied = points - out.points
	out.points = points
	local tier = BrawlMath.tierOf(points, cfg)
	out.bestTier = math.max(out.bestTier, tier)
	return out, applied, tier > before
end

-- A new season: drop 2 tiers (to the start of that tier) and pay one reward per tier reached last
-- season (tiers 0..bestTier). A first-ever season only stamps the number.
function BrawlMath.seasonRoll(record: Ranked, season: number, cfg: RankedConfig): (Ranked, { number })
	local out = table.clone(record)
	if out.season == season then
		return out, {}
	end
	if out.season == 0 then
		out.season = season
		return out, {}
	end
	local rewards = {}
	for tier = 0, out.bestTier do
		table.insert(rewards, tier)
	end
	local newTier = math.max(0, BrawlMath.tierOf(out.points, cfg) - cfg.softResetTiers)
	out.points = newTier * cfg.tierSize
	out.bestTier = newTier
	out.season = season
	return out, rewards
end

-- Spawn tiles for n cars: evenly round the middle ring (inner ring for practice), facing the centre
function BrawlMath.spawnTiles(layout: Layout, count: number): { number }
	local ring = {}
	local want = if layout.shape == "practice" then 1 else 2
	for _, tile in layout.tiles do
		if tile.ring == want and (tile.x ~= 0 or tile.z ~= 0) then
			table.insert(ring, { index = tile.index, angle = math.atan2(tile.z, tile.x) })
		end
	end
	table.sort(ring, function(a, b)
		if math.abs(a.angle - b.angle) > 1e-6 then
			return a.angle < b.angle
		end
		return a.index < b.index
	end)
	local picks = {}
	if #ring == 0 then
		return picks
	end
	for i = 1, count do
		local slot = math.floor((i - 1) * #ring / count) + 1
		table.insert(picks, ring[slot].index)
	end
	return picks
end

return BrawlMath
