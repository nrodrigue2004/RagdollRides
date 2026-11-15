--!strict
-- Score: Highway Havoc point maths (spec: Highway Havoc > Destruction Score; Bone breaks; Scripts:
-- "Score, pure, shared so the server can recompute"). The server keeps one Run per player and is the
-- only one that pays; the client uses the same maths to pop points the moment a hit lands.
-- * Points per hit = base x speed factor x combo x break multiplier; speed factor = clamp(I / 40, 0.5, 2.5).
-- * Combo: a hit within 3 s keeps it alive; x2 at 2 hits, x3 at 4, ... x8 at 30. Near misses keep it
--   alive (25 points). A 3 s gap resets it.
-- * Chains: a wrecked car hitting another pays the originator 50 / 25 / 12.5% for links 1 to 3.
-- * Pile-up: 5+ traffic cars wrecked within 4 s of each other; paid when the 4 s run out:
--   1,000 + 250 per car past 5, times the combo it reached.
-- * Bone breaks: +0.1 to the break multiplier each (1.0 to 2.2) and a 150-point Crack bonus x combo.
-- * Server caps: 2,000 points in any second, 3,000 for one event.

local Score = {}

export type ScoreConfig = {
	speedDiv: number,
	speedMin: number,
	speedMax: number,
	comboWindow: number,
	comboSteps: { number },
	nearMiss: { points: number, gap: number, speed: number },
	air: { points: number, every: number, maxSeconds: number },
	flip: { points: number, max: number },
	chain: { number },
	pileup: { cars: number, window: number, base: number, per: number },
	crack: number,
	breakStep: number,
	perSecond: number,
	perEvent: number,
	maxImpact: number,
	player: { base: number, pairCooldown: number },
	coopRadius: number,
}

export type Run = {
	score: number,
	combo: number, -- hits in the live combo
	comboUntil: number,
	bestMultiplier: number,
	breaks: number,
	pileups: number,
	wrecks: { number }, -- recent wreck times (the pile-up window)
	pileCount: number, -- cars in the pile-up being built (0: none)
	pileLast: number,
	pileMultiplier: number,
	recent: { { t: number, points: number } }, -- the last second's points (the per-second cap)
}

function Score.newRun(): Run
	return {
		score = 0,
		combo = 0,
		comboUntil = -math.huge,
		bestMultiplier = 1,
		breaks = 0,
		pileups = 0,
		wrecks = {},
		pileCount = 0,
		pileLast = -math.huge,
		pileMultiplier = 1,
		recent = {},
	}
end

function Score.speedFactor(impact: number, cfg: ScoreConfig): number
	return math.clamp(impact / cfg.speedDiv, cfg.speedMin, cfg.speedMax)
end

-- The multiplier for a combo of `count` hits: x1, then x2 at the first step ... x8
function Score.multiplier(count: number, steps: { number }): number
	local m = 1
	for _, need in steps do
		if count >= need then
			m += 1
		end
	end
	return m
end

function Score.breakMultiplier(breaks: number, cfg: ScoreConfig): number
	return 1 + breaks * cfg.breakStep
end

function Score.comboAlive(run: Run, now: number): boolean
	return now <= run.comboUntil
end

-- The multiplier showing right now (x1 once the combo ran out)
function Score.currentMultiplier(run: Run, now: number, cfg: ScoreConfig): number
	if not Score.comboAlive(run, now) then
		return 1
	end
	return Score.multiplier(run.combo, cfg.comboSteps)
end

-- Keep at most perEvent for one event and perSecond in any second; returns what is allowed
function Score.cap(run: Run, now: number, points: number, cfg: ScoreConfig): number
	local keep = {}
	local used = 0
	for _, entry in run.recent do
		if now - entry.t < 1 then
			table.insert(keep, entry)
			used += entry.points
		end
	end
	run.recent = keep
	local allowed = math.max(0, math.min(points, cfg.perEvent, cfg.perSecond - used))
	allowed = math.floor(allowed + 0.5)
	if allowed > 0 then
		table.insert(run.recent, { t = now, points = allowed })
	end
	return allowed
end

local function add(run: Run, now: number, points: number, cfg: ScoreConfig): number
	local got = Score.cap(run, now, points, cfg)
	run.score += got
	return got
end

-- Points a hit would score, without changing anything (the client's pop uses this too)
function Score.hitValue(
	base: number,
	impact: number,
	multiplier: number,
	breaks: number,
	cfg: ScoreConfig
): number
	return base * Score.speedFactor(impact, cfg) * multiplier * Score.breakMultiplier(breaks, cfg)
end

-- A hit by you (link 0) or by a car you sent flying (links 1 to 3). Your own hits move the combo on;
-- chain hits pay their share at the combo you are on. Returns the points scored.
function Score.hit(
	run: Run,
	now: number,
	base: number,
	impact: number,
	link: number,
	cfg: ScoreConfig
): number
	impact = math.clamp(impact, 0, cfg.maxImpact)
	if link <= 0 then
		if Score.comboAlive(run, now) then
			run.combo += 1
		else
			run.combo = 1
		end
		run.comboUntil = now + cfg.comboWindow
		local m = Score.multiplier(run.combo, cfg.comboSteps)
		run.bestMultiplier = math.max(run.bestMultiplier, m)
		return add(run, now, Score.hitValue(base, impact, m, run.breaks, cfg), cfg)
	end
	local share = cfg.chain[link]
	if share == nil then
		return 0
	end
	local m = Score.currentMultiplier(run, now, cfg)
	return add(run, now, Score.hitValue(base, impact, m, run.breaks, cfg) * share, cfg)
end

-- A near miss: 25 points and the combo stays alive (it does not step up)
function Score.nearMiss(run: Run, now: number, cfg: ScoreConfig): number
	if Score.comboAlive(run, now) then
		run.comboUntil = now + cfg.comboWindow
	end
	return add(run, now, cfg.nearMiss.points, cfg)
end

-- Air time (25 per 0.5 s) and flips landed on the wheels (300 each); flat points
function Score.airPoints(seconds: number, cfg: ScoreConfig): number
	local s = math.clamp(seconds, 0, cfg.air.maxSeconds)
	return math.floor(s / cfg.air.every) * cfg.air.points
end

function Score.flipPoints(flips: number, cfg: ScoreConfig): number
	return math.clamp(math.floor(flips), 0, cfg.flip.max) * cfg.flip.points
end

function Score.trick(run: Run, now: number, points: number, cfg: ScoreConfig): number
	return add(run, now, points, cfg)
end

-- A bone break: the break multiplier steps up and the Crack bonus pays at the current combo
function Score.boneBreak(run: Run, now: number, cfg: ScoreConfig): number
	run.breaks += 1
	return add(run, now, cfg.crack * Score.currentMultiplier(run, now, cfg), cfg)
end

-- A traffic car wrecked. Returns true when this wreck starts a pile-up (the 5th inside the window).
function Score.wreck(run: Run, now: number, cfg: ScoreConfig): boolean
	local p = cfg.pileup
	local m = Score.currentMultiplier(run, now, cfg)
	if run.pileCount > 0 and now - run.pileLast <= p.window then
		run.pileCount += 1
		run.pileLast = now
		run.pileMultiplier = math.max(run.pileMultiplier, m)
		return false
	end
	local keep = {}
	for _, t in run.wrecks do
		if now - t <= p.window then
			table.insert(keep, t)
		end
	end
	table.insert(keep, now)
	run.wrecks = keep
	if #keep >= p.cars then
		run.pileCount = #keep
		run.pileLast = now
		run.pileMultiplier = m
		run.wrecks = {}
		return true
	end
	return false
end

-- A pile-up's bonus once its window has run out (nil while it is still building or none is going).
-- eventMultiplier: Pile-up Friday pays double. Returns the points (before caps) and the car count.
function Score.pileupDue(run: Run, now: number, eventMultiplier: number, cfg: ScoreConfig): (number?, number)
	local p = cfg.pileup
	if run.pileCount <= 0 or now - run.pileLast <= p.window then
		return nil, 0
	end
	local cars = run.pileCount
	local points = (p.base + p.per * (cars - p.cars)) * run.pileMultiplier * eventMultiplier
	run.pileCount = 0
	run.pileMultiplier = 1
	run.pileups += 1
	return points, cars
end

-- Pile-up bonuses are one big event: they skip the per-second cap but keep a sane ceiling
function Score.addBonus(run: Run, points: number, ceiling: number): number
	local got = math.floor(math.clamp(points, 0, ceiling) + 0.5)
	run.score += got
	return got
end

function Score.coins(score: number, cfg: { per: number, max: number }): number
	return math.clamp(math.floor(score / cfg.per), 0, cfg.max)
end

---------------------------------------------------------------------------
-- Bones: 12 cartoon bones on the rider's 6 pieces, each breaks once per run
---------------------------------------------------------------------------

Score.PIECES = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
Score.BONES = {
	{ "Noggin" },
	{ "Ribs", "Spine", "Pelvis" },
	{ "Left upper arm", "Left forearm" },
	{ "Right upper arm", "Right forearm" },
	{ "Left thigh", "Left shin" },
	{ "Right thigh", "Right shin" },
}

-- The pieces an impact side reaches, in order: front: head then torso; sides: that arm then leg;
-- roof: head; rear: torso; a hard landing: the legs
local SIDES: { [string]: { number } } = {
	Front = { 1, 2 },
	Roof = { 1 },
	Left = { 3, 5 },
	Right = { 4, 6 },
	Rear = { 2 },
	Bottom = { 5, 6 },
}

function Score.piecesFor(side: string): { number }
	return SIDES[side] or { 2 }
end

-- The piece that takes the next break: the first preferred piece with bones left, else the next piece
-- in the list after it that has one. broken[piece] = bones broken. nil when all 12 are gone.
function Score.pickPiece(broken: { [number]: number }, preferred: { number }): number?
	for _, piece in preferred do
		if (broken[piece] or 0) < #Score.BONES[piece] then
			return piece
		end
	end
	local start = preferred[#preferred] or 1
	for offset = 1, #Score.PIECES do
		local piece = (start + offset - 1) % #Score.PIECES + 1
		if (broken[piece] or 0) < #Score.BONES[piece] then
			return piece
		end
	end
	return nil
end

-- Break the next bone on a piece; returns the bone's name
function Score.breakOn(broken: { [number]: number }, piece: number): string
	local n = (broken[piece] or 0) + 1
	broken[piece] = n
	return Score.BONES[piece][n]
end

function Score.bonesLeft(broken: { [number]: number }): number
	local left = 0
	for piece, bones in Score.BONES do
		left += #bones - (broken[piece] or 0)
	end
	return left
end

-- Should one more break be allowed now? (0.5 s apart, at most 3 from one crash: breaks within 1.5 s)
export type BreakLimits = { cooldown: number, perCrash: number, crashWindow: number }
export type BreakClock = { last: number, crashStart: number, inCrash: number }

function Score.newBreakClock(): BreakClock
	return { last = -math.huge, crashStart = -math.huge, inCrash = 0 }
end

function Score.mayBreak(clock: BreakClock, now: number, limits: BreakLimits): boolean
	if now - clock.last < limits.cooldown then
		return false
	end
	if now - clock.last <= limits.crashWindow and clock.inCrash >= limits.perCrash then
		return false
	end
	return true
end

function Score.noteBreak(clock: BreakClock, now: number, limits: BreakLimits)
	if now - clock.last > limits.crashWindow then
		clock.crashStart = now
		clock.inCrash = 0
	end
	clock.inCrash += 1
	clock.last = now
end

return Score
