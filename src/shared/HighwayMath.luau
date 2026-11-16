--!strict
-- HighwayMath: the Sunny Pass road and everything on it, from a seed (spec: Highway Havoc > Road,
-- Traffic; Network model: traffic is simulated locally from a server seed and time). Pure, so the server
-- rebuilds exactly what each device shows, and tests/run.luau checks it in Lune.
-- * The road starts at origin (s = 0) and runs toward -Z. Its heading is a sum of two slow sine waves
--   (phases from the seed), so it bends gently and endlessly; the centreline is integrated in small
--   steps and cached. s is distance along the road; lateral is studs to the right of the centreline.
-- * Lanes: lane 1 is the slow lane on the right, the last lane the fast lane on the left.
-- * Traffic: each lane moves at its own speed. Car slots sit on a grid that moves with the lane
--   (one slot per grid studs, jittered), some slots empty; a slot's car type comes from the seed.
--   Slot ids pack the lane and index: id = index * 8 + lane.
-- * Ramps, Pit Wrenches and roadside props sit at seeded spots along the road.
-- * Daily events come from the UTC weekday.

local HighwayMath = {}

local TAU = 2 * math.pi
local M = 2147483647

export type CurveTerm = { amp: number, wave: number }
export type RoadConfig = {
	origin: { number },
	laneWidth: number,
	lanes: number,
	shoulder: number,
	step: number,
	curves: { CurveTerm },
}
export type Road = {
	seed: number,
	origin: { number },
	lanes: number,
	laneWidth: number,
	halfWidth: number, -- centreline to the outer edge of the shoulder
	step: number,
	terms: { { amp: number, k: number, phase: number } },
	xs: { [number]: number },
	zs: { [number]: number },
	lo: number,
	hi: number,
}

---------------------------------------------------------------------------
-- Seeded numbers (the same in Lune and Roblox)
---------------------------------------------------------------------------

-- One Park-Miller step after an xorshift scramble (the scramble keeps neighbouring inputs unrelated)
local function step(state: number): number
	local x = state % 4294967296
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return ((x % (M - 1)) + 1) * 48271 % M
end

-- A number in [0, 1) from a seed and up to three integers (any sign)
function HighwayMath.hash(seed: number, a: number, b: number?, c: number?): number
	local state = (math.floor(math.abs(seed)) % (M - 1)) + 1
	state = step(state + (math.floor(a) % M))
	state = step(state + (math.floor(b or 0) % M))
	state = step(state + (math.floor(c or 0) % M))
	state = step(state)
	return (state - 1) / (M - 1)
end

---------------------------------------------------------------------------
-- The road
---------------------------------------------------------------------------

export type RoadOverrides = { origin: { number }?, lanes: number? }

function HighwayMath.road(seed: number, cfg: RoadConfig, overrides: RoadOverrides?): Road
	local o: RoadOverrides = overrides or {}
	local lanes = o.lanes or cfg.lanes
	local terms = {}
	for index, term in cfg.curves do
		table.insert(terms, {
			amp = term.amp,
			k = TAU / term.wave,
			phase = HighwayMath.hash(seed, 7001, index) * TAU,
		})
	end
	local origin = o.origin or cfg.origin
	return {
		seed = seed,
		origin = origin,
		lanes = lanes,
		laneWidth = cfg.laneWidth,
		halfWidth = lanes * cfg.laneWidth / 2 + cfg.shoulder,
		step = cfg.step,
		terms = terms,
		xs = { [0] = origin[1] },
		zs = { [0] = origin[3] },
		lo = 0,
		hi = 0,
	}
end

-- Heading at s (radians; 0 = straight toward -Z, positive bends toward +X)
function HighwayMath.heading(road: Road, s: number): number
	local h = 0
	for _, term in road.terms do
		h += term.amp * math.sin(term.k * s + term.phase)
	end
	return h
end

local function extendTo(road: Road, k: number)
	local h = road.step
	while road.hi < k do
		local i = road.hi
		local mid = HighwayMath.heading(road, (i + 0.5) * h)
		road.xs[i + 1] = road.xs[i] + math.sin(mid) * h
		road.zs[i + 1] = road.zs[i] - math.cos(mid) * h
		road.hi = i + 1
	end
	while road.lo > k do
		local i = road.lo
		local mid = HighwayMath.heading(road, (i - 0.5) * h)
		road.xs[i - 1] = road.xs[i] - math.sin(mid) * h
		road.zs[i - 1] = road.zs[i] + math.cos(mid) * h
		road.lo = i - 1
	end
end

-- The centreline at s: x, z and the heading
function HighwayMath.at(road: Road, s: number): (number, number, number)
	local k = math.floor(s / road.step)
	extendTo(road, k + 1)
	extendTo(road, k)
	local f = s / road.step - k
	local x = road.xs[k] + (road.xs[k + 1] - road.xs[k]) * f
	local z = road.zs[k] + (road.zs[k + 1] - road.zs[k]) * f
	return x, z, HighwayMath.heading(road, s)
end

-- A point lateral studs to the right of the centreline at s
function HighwayMath.place(road: Road, s: number, lateral: number): (number, number, number)
	local x, z, h = HighwayMath.at(road, s)
	return x + math.cos(h) * lateral, z + math.sin(h) * lateral, h
end

-- The lateral offset of a lane's centre (lane 1 on the right)
function HighwayMath.laneOffset(road: Road, lane: number): number
	return ((road.lanes + 1) / 2 - lane) * road.laneWidth
end

-- The lane nearest a lateral offset
function HighwayMath.laneAt(road: Road, lateral: number): number
	local lane = math.floor((road.lanes + 1) / 2 - lateral / road.laneWidth + 0.5)
	return math.clamp(lane, 1, road.lanes)
end

-- Where a world point is on the road: s and lateral. z falls steadily with s (the heading never turns
-- past 90 degrees), so a search on z finds the step, then a projection finishes it.
function HighwayMath.locate(road: Road, x: number, z: number): (number, number)
	local h = road.step
	-- A first guess from the distance travelled along -Z, then widen until it brackets z
	local guess = math.floor((road.origin[3] - z) / h)
	local lo, hi = guess - 4, guess + 4
	extendTo(road, hi)
	extendTo(road, lo)
	while road.zs[lo] < z do
		lo -= 16
		extendTo(road, lo)
	end
	while road.zs[hi] > z do
		hi += 16
		extendTo(road, hi)
	end
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if road.zs[mid] >= z then
			lo = mid
		else
			hi = mid
		end
	end
	local s0 = lo * h
	local cx, cz = road.xs[lo], road.zs[lo]
	local heading = HighwayMath.heading(road, s0 + h / 2)
	local fx, fz = math.sin(heading), -math.cos(heading)
	local dx, dz = x - cx, z - cz
	local along = dx * fx + dz * fz
	local lateral = dx * math.cos(heading) + dz * math.sin(heading)
	return s0 + along, lateral
end

---------------------------------------------------------------------------
-- Traffic
---------------------------------------------------------------------------

export type TrafficType = {
	id: string,
	base: number,
	size: { number },
	mass: number,
	weight: number,
	color: { number },
}
export type TrafficConfig = {
	laneSpeeds: { number },
	grid: number,
	jitter: number,
	empty: number,
	types: { TrafficType },
}
export type EventDef = { id: string, spacing: number?, tankers: number?, buses: number?, ramps: boolean? }
-- ramp: the ride gets harder. Each slot's emptiness is decided by where its car was when the ride began
-- (t0, server seconds since the road's epoch) against the ride's start s0: slots further ahead at the start
-- are fuller. A slot never flips between empty and full during a ride, so cars never pop in or out.
export type RampOpts = { s0: number, t0: number, start: number, finish: number, over: number }
export type TrafficOpts = { event: EventDef?, quiet: number?, ramp: RampOpts? }
export type Car = { id: number, lane: number, index: number, s: number, speed: number, kind: TrafficType }

function HighwayMath.slotId(lane: number, index: number): number
	return index * 8 + lane
end

function HighwayMath.slotOf(id: number): (number, number)
	local lane = id % 8
	return lane, (id - lane) // 8
end

local function spacingOf(opts: TrafficOpts?): number
	local spacing = 1
	if opts and opts.event and opts.event.spacing then
		spacing *= opts.event.spacing
	end
	if opts and opts.quiet then
		spacing *= opts.quiet
	end
	return spacing
end

local function typeFor(
	road: Road,
	lane: number,
	index: number,
	cfg: TrafficConfig,
	opts: TrafficOpts?
): TrafficType
	local event = opts and opts.event
	local total = 0
	local weights = {}
	for i, kind in cfg.types do
		local w = kind.weight
		if event and event.tankers and kind.id == "foamTanker" then
			w *= event.tankers
		elseif event and event.buses and kind.id == "partyBus" then
			w *= event.buses
		end
		weights[i] = w
		total += w
	end
	local pick = HighwayMath.hash(road.seed, lane * 977 + 13, index, 2) * total
	for i, kind in cfg.types do
		pick -= weights[i]
		if pick < 0 then
			return kind
		end
	end
	return cfg.types[#cfg.types]
end

-- One slot's car at road time t (server seconds since the road's epoch), or nil for an empty slot
function HighwayMath.car(road: Road, id: number, t: number, cfg: TrafficConfig, opts: TrafficOpts?): Car?
	local lane, index = HighwayMath.slotOf(id)
	if lane < 1 or lane > road.lanes then
		return nil
	end
	local spacing = spacingOf(opts)
	local jitter = (HighwayMath.hash(road.seed, lane * 977 + 13, index, 3) * 2 - 1) * cfg.jitter
	local speed = cfg.laneSpeeds[lane] or cfg.laneSpeeds[#cfg.laneSpeeds]
	local base = (index * cfg.grid + jitter) * spacing
	local empty = cfg.empty
	local ramp = opts and opts.ramp
	if ramp then
		local f = math.clamp((base + speed * ramp.t0 - ramp.s0) / ramp.over, 0, 1)
		empty = ramp.start + (ramp.finish - ramp.start) * f
	end
	if HighwayMath.hash(road.seed, lane * 977 + 13, index, 1) < empty then
		return nil
	end
	return {
		id = id,
		lane = lane,
		index = index,
		s = base + speed * t,
		speed = speed,
		kind = typeFor(road, lane, index, cfg, opts),
	}
end

-- Every car with s in [from, to] at time t, nearest to `near` first
function HighwayMath.carsBetween(
	road: Road,
	from: number,
	to: number,
	t: number,
	cfg: TrafficConfig,
	opts: TrafficOpts?,
	near: number?
): { Car }
	local list = {}
	local spacing = spacingOf(opts)
	local grid = cfg.grid * spacing
	for lane = 1, road.lanes do
		local speed = cfg.laneSpeeds[lane] or cfg.laneSpeeds[#cfg.laneSpeeds]
		local first = math.floor((from - speed * t) / grid) - 1
		local last = math.ceil((to - speed * t) / grid) + 1
		for index = first, last do
			local car = HighwayMath.car(road, HighwayMath.slotId(lane, index), t, cfg, opts)
			if car and car.s >= from and car.s <= to then
				table.insert(list, car)
			end
		end
	end
	local centre = near or (from + to) / 2
	table.sort(list, function(a, b)
		local da, db = math.abs(a.s - centre), math.abs(b.s - centre)
		if da == db then
			return a.id < b.id
		end
		return da < db
	end)
	return list
end

---------------------------------------------------------------------------
-- Ramps, Pit Wrenches, props
---------------------------------------------------------------------------

export type Ramp = { index: number, s: number, lane: number } -- covers lane and lane + 1
export type RampConfig = { grid: number, jitter: number, rampDayGrid: number, lanes: number }

function HighwayMath.ramp(road: Road, index: number, cfg: RampConfig, event: EventDef?): Ramp
	local rampDay = event ~= nil and event.ramps == true
	local grid = if rampDay then cfg.rampDayGrid else cfg.grid
	local jitter = if rampDay then 0 else (HighwayMath.hash(road.seed, 31337, index, 1) * 2 - 1) * cfg.jitter
	local span = math.max(1, road.lanes - cfg.lanes + 1)
	local lane = 1 + math.floor(HighwayMath.hash(road.seed, 31337, index, 2) * span)
	return { index = index, s = index * grid + jitter, lane = lane }
end

function HighwayMath.rampsBetween(
	road: Road,
	from: number,
	to: number,
	cfg: RampConfig,
	event: EventDef?
): { Ramp }
	local rampDay = event ~= nil and event.ramps == true
	local grid = if rampDay then cfg.rampDayGrid else cfg.grid
	local list = {}
	for index = math.floor(from / grid) - 1, math.ceil(to / grid) + 1 do
		if index >= 1 then
			local r = HighwayMath.ramp(road, index, cfg, event)
			if r.s >= from and r.s <= to then
				table.insert(list, r)
			end
		end
	end
	return list
end

export type Wrench = { index: number, s: number, lane: number }

function HighwayMath.wrenchesBetween(road: Road, from: number, to: number, every: number): { Wrench }
	if every <= 0 then
		return {}
	end
	local list = {}
	for index = math.floor(from / every) - 1, math.ceil(to / every) + 1 do
		local s = index * every + every / 2
		if index >= 0 and s >= from and s <= to then
			local lane = 1 + math.floor(HighwayMath.hash(road.seed, 4242, index) * road.lanes)
			table.insert(list, { index = index, s = s, lane = lane })
		end
	end
	return list
end

export type PropKind = { id: string, base: number, weight: number }
export type PropConfig = { slot: number, empty: number, kinds: { PropKind } }
export type Prop = { id: number, s: number, side: number, lateral: number, kind: PropKind }

-- Prop ids pack the slot and side: id = slot * 2 + (1 on the right, 0 on the left)
function HighwayMath.prop(road: Road, id: number, cfg: PropConfig): Prop?
	local right = id % 2
	local slot = (id - right) // 2
	local side = if right == 1 then 1 else -1
	if HighwayMath.hash(road.seed, 5151, slot, right) < cfg.empty then
		return nil
	end
	local total = 0
	for _, kind in cfg.kinds do
		total += kind.weight
	end
	local pick = HighwayMath.hash(road.seed, 5151, slot, right + 2) * total
	local chosen = cfg.kinds[#cfg.kinds]
	for _, kind in cfg.kinds do
		pick -= kind.weight
		if pick < 0 then
			chosen = kind
			break
		end
	end
	local jitter = (HighwayMath.hash(road.seed, 5151, slot, right + 4) * 2 - 1) * cfg.slot * 0.2
	-- On the shoulder's outer edge; billboards stand back on the grass
	local out = road.halfWidth - 2 + (if chosen.id == "billboard" then 16 else 0)
	return { id = id, s = slot * cfg.slot + jitter, side = side, lateral = side * out, kind = chosen }
end

function HighwayMath.propsBetween(road: Road, from: number, to: number, cfg: PropConfig): { Prop }
	local list = {}
	for slot = math.floor(from / cfg.slot) - 1, math.ceil(to / cfg.slot) + 1 do
		for right = 0, 1 do
			local p = HighwayMath.prop(road, slot * 2 + right, cfg)
			if p and p.s >= from and p.s <= to then
				table.insert(list, p)
			end
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Daily events and runs
---------------------------------------------------------------------------

-- The event for a UTC day number (days since 1970-01-01, a Thursday): one per weekday, Sunday first
function HighwayMath.weekday(day: number): number
	return (day + 4) % 7 -- 0 = Sunday
end

function HighwayMath.eventFor<E>(day: number, events: { E }): E
	return events[HighwayMath.weekday(day) + 1]
end

-- Where a new run starts: behind the last car of the pack, or at the start when the road is empty or
-- the pack is too far out
function HighwayMath.startS(others: { number }, behind: number, maxS: number): number
	local last: number? = nil
	for _, s in others do
		if last == nil or s < last then
			last = s
		end
	end
	if last == nil or last - behind > maxS or last - behind < 0 then
		return 0
	end
	return last - behind
end

-- A start spot with no car in your lane within `gap` studs and none right beside you (a ride must never
-- begin inside a car): steps forward a gap at a time. The ride's density ramp depends on the start, so
-- each try builds its own options.
function HighwayMath.clearStart(
	road: Road,
	s0: number,
	lane: number,
	t0: number,
	cfg: TrafficConfig,
	density: { start: number, finish: number, over: number },
	event: EventDef?,
	quiet: number?,
	gap: number
): number
	local s = s0
	for _ = 1, 40 do
		local opts = HighwayMath.runOpts(event, quiet, s, t0, density)
		local blocked = false
		for _, c in HighwayMath.carsBetween(road, s - gap, s + gap, t0, cfg, opts) do
			local d = math.abs(c.s - s)
			if (c.lane == lane and d < gap) or (math.abs(c.lane - lane) == 1 and d < 8) then
				blocked = true
				break
			end
		end
		if not blocked then
			return s
		end
		s += gap
	end
	return s
end

-- The traffic options for one ride: the day's event (or the tutorial's quiet road) and the ramp that
-- thickens traffic from where the ride began. The server and the device build the same table.
function HighwayMath.runOpts(
	event: EventDef?,
	quiet: number?,
	s0: number,
	t0: number,
	density: { start: number, finish: number, over: number }
): TrafficOpts
	return {
		event = event,
		quiet = quiet,
		ramp = { s0 = s0, t0 = t0, start = density.start, finish = density.finish, over = density.over },
	}
end

return HighwayMath
