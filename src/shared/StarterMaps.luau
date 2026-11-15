--!strict
-- StarterMaps: the 5 starter maps as piece lists (pure data, unit tested). Spec: Onboarding (Pip's Hill beat
-- sheet), Tracks, Milestone 2 "5 maps". Built with the same piece kinds the map builder will use
-- (milestone 3), laid out by a small path builder so roads join up.
--
-- Map space: start at the origin, driving toward -Z, +X is right, +Y up. Each map sits at its own
-- world offset. Piece fields: kind, x, y, z (centre of the piece; for roads the centre of the top surface),
-- yaw and pitch in degrees, sx, sy, sz size, plus kind-specific fields.
-- PLACEHOLDER ART: plain foam-coloured parts; the art pass reskins pieces by kind.

local StarterMaps = {}

export type Piece = {
	kind: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	sx: number,
	sy: number,
	sz: number,
	index: number?, -- checkpoints
	speed: number?, -- spinners (degrees per second)
	axis: string?, -- spinners: "up" (a sweeping bar, the default) or "across" (a roller across the road)
	label: string?, -- preset sign text (ours, never player text)
	material: string?,
	color: string?,
}

export type MapDef = {
	id: string,
	name: string,
	order: number,
	creatorTime: number, -- seconds (Gold < x 1.1, Silver < x 1.5)
	tut: string?, -- onboarding flag this map sets on first finish
	assist: boolean?, -- steering assist forced to High (first 2 tracks)
	autoRespawn: number?, -- seconds after a hazard throws the rider (Pip's Hill: 1 s)
	coinValue: number, -- coins per trail coin, paid at the finish
	reward: { coins: number, stars: number }?, -- a fixed first-finish reward (Pip's Hill: 100 coins, 1 star)
	offset: { number },
	pieces: { Piece },
	checkpoints: number,
	coins: number,
}

local ROAD_WIDTH = 30
local ROAD_THICK = 2
local WALL_HEIGHT = 14

local function rad(d: number): number
	return math.rad(d)
end

-- A path builder: a cursor with a position and a heading that lays road pieces end to end.
local function newPath(pieces: { Piece })
	local path = { x = 0, y = 0, z = 0, yaw = 0, pieces = pieces, width = ROAD_WIDTH, walls = true }

	local function forward(yaw: number): (number, number)
		-- yaw 0 faces -Z; positive yaw turns left (counter-clockwise seen from above)
		return -math.sin(rad(yaw)), -math.cos(rad(yaw))
	end

	function path.add(piece: Piece)
		table.insert(pieces, piece)
	end

	-- A point d studs ahead and o studs to the right of the cursor, h above it
	function path.at(d: number, o: number, h: number): (number, number, number)
		local fx, fz = forward(path.yaw)
		local rx, rz = -fz, fx -- right of forward
		return path.x + fx * d + rx * o, path.y + h, path.z + fz * d + rz * o
	end

	-- Straight road, optionally climbing (pitch > 0) or dropping
	function path.straight(length: number, pitch: number?, material: string?)
		local p = pitch or 0
		local run = length * math.cos(rad(p))
		local rise = length * math.sin(rad(p))
		local cx, cy, cz = path.at(run / 2, 0, rise / 2)
		path.add({
			kind = "Road",
			x = cx,
			y = cy,
			z = cz,
			yaw = path.yaw,
			pitch = p,
			sx = path.width,
			sy = ROAD_THICK,
			sz = length + 0.6, -- a little overlap so joints never gap
			material = material,
		})
		if path.walls then
			for _, side in { -1, 1 } do
				local wx, wy, wz = path.at(run / 2, side * (path.width / 2 + 1), rise / 2 + WALL_HEIGHT / 2)
				path.add({
					kind = "SoftWall",
					x = wx,
					y = wy,
					z = wz,
					yaw = path.yaw,
					pitch = p,
					sx = 2,
					sy = WALL_HEIGHT,
					sz = length + 0.6,
				})
			end
		end
		local fx, fz = forward(path.yaw)
		path.x += fx * run
		path.z += fz * run
		path.y += rise
	end

	-- Turn in place: a round pad fills the joint, then the heading changes
	function path.turn(degrees: number)
		path.add({
			kind = "Joint",
			x = path.x,
			y = path.y,
			z = path.z,
			yaw = 0,
			pitch = 0,
			sx = ROAD_THICK,
			sy = path.width,
			sz = path.width,
		})
		path.yaw += degrees
	end

	-- A gentle bend made of short straights
	function path.bend(degrees: number, steps: number, stepLength: number)
		for _ = 1, steps do
			path.turn(degrees / steps)
			path.straight(stepLength)
		end
	end

	-- A ramp on the road ahead: a slab rising rise studs over length, on top of a normal stretch of road
	-- (so a car beside a narrow ramp still has ground). The cursor ends below the lip, at road level.
	function path.ramp(length: number, rise: number, width: number?)
		local w = width or path.width
		local cx, cy, cz = path.at(length / 2, 0, rise / 2)
		path.add({
			kind = "Ramp",
			x = cx,
			y = cy,
			z = cz,
			yaw = path.yaw,
			pitch = math.deg(math.atan2(rise, length)),
			sx = w,
			sy = ROAD_THICK,
			sz = math.sqrt(length * length + rise * rise),
		})
		path.straight(length)
	end

	-- Skip a gap (a jump), dropping by drop studs
	function path.gap(length: number, drop: number?)
		local fx, fz = forward(path.yaw)
		path.x += fx * length
		path.z += fz * length
		path.y -= drop or 0
	end

	-- A trigger or prop placed relative to the cursor
	function path.place(
		kind: string,
		d: number,
		o: number,
		h: number,
		sx: number,
		sy: number,
		sz: number,
		extra: { [string]: any }?
	)
		local px, py, pz = path.at(d, o, h)
		local piece: Piece = {
			kind = kind,
			x = px,
			y = py,
			z = pz,
			yaw = path.yaw,
			pitch = 0,
			sx = sx,
			sy = sy,
			sz = sz,
		}
		if extra then
			for k, v in extra do
				(piece :: any)[k] = v
			end
		end
		path.add(piece)
		return piece
	end

	function path.start()
		path.place("Start", 6, 0, 0, path.width, 12, 2)
	end

	function path.checkpoint(index: number)
		path.place("Checkpoint", 0, 0, 6, path.width, 12, 4, { index = index })
	end

	function path.finish()
		path.place("Finish", 0, 0, 7, path.width + 4, 14, 4)
	end

	-- A line of coins along the racing line (centre), every spacing studs, starting d ahead
	function path.coinTrail(count: number, d: number, spacing: number, height: number?)
		for i = 0, count - 1 do
			path.place("Coin", d + i * spacing, 0, height or 3, 2, 2, 0.4)
		end
	end

	return path
end

local function countKinds(pieces: { Piece }, kind: string): number
	local n = 0
	for _, piece in pieces do
		if piece.kind == kind then
			n += 1
		end
	end
	return n
end

---------------------------------------------------------------------------
-- 1. Pip's Hill: the first 30 seconds (beat sheet)
---------------------------------------------------------------------------
local function pipsHill(): { Piece }
	local pieces = {}
	local p = newPath(pieces)
	-- 0:00 spawn on a 6 degree slope; the finish arch is in sight down the hill
	p.y = 44
	p.start()
	p.straight(140, -6)
	-- 0:03 coin trail of 8 coins on the racing line
	p.coinTrail(8, 10, 16, 3)
	p.straight(160)
	-- 0:08 one wide ramp; JUMP pulses 1 s before the lip (about 70 studs ahead at this speed)
	p.place("JumpCue", 0, 0, 6, p.width, 12, 20)
	p.straight(40)
	p.ramp(30, 10, 24)
	-- coin arc in the air, 5 coins
	for i = 1, 5 do
		local t = i / 6
		p.place("Coin", 8 + t * 40, 0, 12 + 10 * math.sin(t * math.pi), 2, 2, 0.4)
	end
	p.gap(4)
	-- 0:12 landing zone, 3 x the jump length, walled so a miss rolls back
	p.straight(130)
	p.checkpoint(1)
	p.bend(-30, 3, 30)
	-- 0:18 slow soft spinner across the line: the hit is guaranteed; respawn just past it
	p.straight(60)
	-- A foam roller spinning across the whole road at rider height: there is no way past it untouched
	p.place("Spinner", 0, 0, 7, p.width, 4, 4, { speed = 90, axis = "across" })
	p.place("Hazard", 0, 0, 4, p.width, 8, 6)
	p.straight(40)
	p.checkpoint(2)
	p.bend(30, 3, 30)
	p.straight(160)
	-- 0:28 finish arch, confetti
	p.finish()
	p.straight(40)
	return pieces
end

---------------------------------------------------------------------------
-- 2. Lean Ledge: teaches LEAN (lean back to land the big drop on your wheels)
---------------------------------------------------------------------------
local function leanLedge(): { Piece }
	local pieces = {}
	local p = newPath(pieces)
	p.y = 30
	p.start()
	p.straight(120)
	p.coinTrail(6, 10, 18, 3)
	p.straight(120)
	p.place("LeanCue", 0, 0, 6, p.width, 12, 30)
	p.straight(40)
	p.ramp(26, 12)
	for i = 1, 4 do
		p.place("Coin", 10 + i * 12, 0, 16, 2, 2, 0.4)
	end
	p.gap(60, 16)
	p.straight(140)
	p.checkpoint(1)
	p.bend(40, 4, 28)
	p.straight(80)
	p.ramp(20, 8)
	p.gap(40, 8)
	p.straight(120)
	p.checkpoint(2)
	p.bend(-40, 4, 28)
	p.straight(100)
	p.finish()
	p.straight(40)
	return pieces
end

---------------------------------------------------------------------------
-- 3. Bounce Basin: bouncers and speed pads
---------------------------------------------------------------------------
local function bounceBasin(): { Piece }
	local pieces = {}
	local p = newPath(pieces)
	p.y = 20
	p.start()
	p.straight(100)
	p.place("SpeedPad", 30, 0, 0.2, 14, 0.4, 14)
	p.straight(140)
	p.coinTrail(5, 20, 20, 3)
	p.place("Bouncer", 110, 0, 0.2, 18, 0.4, 18)
	p.straight(130)
	p.gap(50, 0)
	p.straight(120)
	p.checkpoint(1)
	p.bend(-60, 5, 26)
	p.place("SpeedPad", 20, -6, 0.2, 12, 0.4, 12)
	p.place("SpeedPad", 60, 6, 0.2, 12, 0.4, 12)
	p.straight(160)
	p.place("Bouncer", -30, 0, 0.2, 18, 0.4, 18)
	p.gap(60, 0)
	p.straight(100)
	p.checkpoint(2)
	p.bend(60, 5, 26)
	p.coinTrail(6, 10, 15, 3)
	p.straight(140)
	p.finish()
	p.straight(40)
	return pieces
end

---------------------------------------------------------------------------
-- 4. Dune Run: sand, humps and kickers
---------------------------------------------------------------------------
local function duneRun(): { Piece }
	local pieces = {}
	local p = newPath(pieces)
	p.y = 20
	p.start()
	p.straight(100)
	for _ = 1, 3 do
		p.straight(30, 10, "Sand")
		p.straight(30, -10, "Sand")
		p.straight(30)
	end
	p.checkpoint(1)
	p.coinTrail(6, 10, 14, 3)
	p.bend(-45, 3, 30)
	p.straight(60)
	p.ramp(16, 5)
	p.gap(20, 0)
	p.straight(60)
	p.ramp(16, 5)
	p.gap(20, 0)
	p.straight(80)
	p.checkpoint(2)
	p.bend(45, 3, 30)
	p.straight(80, 0, "Sand")
	p.straight(40, 12)
	p.straight(60)
	p.straight(40, -12)
	p.straight(80)
	p.checkpoint(3)
	p.straight(60)
	p.finish()
	p.straight(40)
	return pieces
end

---------------------------------------------------------------------------
-- 5. Tumble Gulch: twisty, gaps and spinners (the hardest starter map)
---------------------------------------------------------------------------
local function tumbleGulch(): { Piece }
	local pieces = {}
	local p = newPath(pieces)
	p.y = 60
	p.start()
	p.straight(80, -8)
	p.bend(50, 4, 24)
	p.straight(60)
	p.ramp(20, 8)
	p.gap(44, 6)
	p.straight(80)
	p.checkpoint(1)
	p.bend(-70, 5, 24)
	p.straight(40)
	-- A real skill test here: only the bar itself throws the rider (no guaranteed-hit volume)
	p.place("Spinner", 0, 0, 7, p.width, 4, 4, { speed = 120 })
	p.straight(60)
	p.checkpoint(2)
	p.coinTrail(5, 10, 14, 3)
	p.straight(80)
	p.ramp(24, 10)
	p.gap(56, 10)
	p.straight(100)
	p.checkpoint(3)
	p.bend(70, 5, 24)
	p.straight(40, -6)
	p.place("Bouncer", 50, 0, 0.2, 16, 0.4, 16)
	p.straight(70)
	p.gap(40, 0)
	p.straight(80)
	p.checkpoint(4)
	p.bend(-50, 4, 24)
	p.straight(120)
	p.finish()
	p.straight(40)
	return pieces
end

local function define(def: { [string]: any }, pieces: { Piece }): MapDef
	def.pieces = pieces
	def.checkpoints = countKinds(pieces, "Checkpoint")
	def.coins = countKinds(pieces, "Coin")
	return (def :: any) :: MapDef
end

StarterMaps.maps = {
	define({
		id = "pips_hill",
		name = "Pip's Hill",
		order = 1,
		creatorTime = 22,
		tut = "pipHill",
		assist = true,
		autoRespawn = 1,
		coinValue = 0, -- the fixed 100-coin reward covers it
		reward = { coins = 100, stars = 1 },
		offset = { 3000, 0, 0 },
	}, pipsHill()),
	define({
		id = "lean_ledge",
		name = "Lean Ledge",
		order = 2,
		creatorTime = 24,
		tut = "lean",
		assist = true,
		coinValue = 1,
		offset = { 6000, 0, 0 },
	}, leanLedge()),
	define({
		id = "bounce_basin",
		name = "Bounce Basin",
		order = 3,
		creatorTime = 26,
		coinValue = 1,
		offset = { 9000, 0, 0 },
	}, bounceBasin()),
	define({
		id = "dune_run",
		name = "Dune Run",
		order = 4,
		creatorTime = 28,
		coinValue = 1,
		offset = { 12000, 0, 0 },
	}, duneRun()),
	define({
		id = "tumble_gulch",
		name = "Tumble Gulch",
		order = 5,
		creatorTime = 32,
		coinValue = 1,
		offset = { 15000, 0, 0 },
	}, tumbleGulch()),
}

StarterMaps.byId = {} :: { [string]: MapDef }
for _, map in StarterMaps.maps do
	StarterMaps.byId[map.id] = map
end

StarterMaps.FIRST_MAP = "pips_hill"

-- The map after this one in the starter order (wraps to the first)
function StarterMaps.nextMap(id: string): string
	local current = StarterMaps.byId[id]
	if not current then
		return StarterMaps.FIRST_MAP
	end
	local nextOrder = current.order % #StarterMaps.maps + 1
	for _, map in StarterMaps.maps do
		if map.order == nextOrder then
			return map.id
		end
	end
	return StarterMaps.FIRST_MAP
end

-- How far past a hazard the rider respawns (Pip's Hill: "respawn just past it")
StarterMaps.HAZARD_RESPAWN_PAST = 14

-- Forward (x, z) for a yaw in degrees; yaw 0 faces -Z
function StarterMaps.forward(yaw: number): (number, number)
	return -math.sin(math.rad(yaw)), -math.cos(math.rad(yaw))
end

-- A map-space point in world space
function StarterMaps.toWorld(map: MapDef, x: number, y: number, z: number): (number, number, number)
	return map.offset[1] + x, map.offset[2] + y, map.offset[3] + z
end

-- The ground point (map space) where the rider respawns after a hazard: past the piece, on the road
function StarterMaps.hazardRespawn(piece: Piece): (number, number, number)
	local fx, fz = StarterMaps.forward(piece.yaw)
	local d = piece.sz / 2 + StarterMaps.HAZARD_RESPAWN_PAST
	return piece.x + fx * d, piece.y - piece.sy / 2, piece.z + fz * d
end

-- Every point a car can be put back to on this map (map space, ground level): the start, each
-- checkpoint and each hazard's respawn. The server's speed check lets a jump to one of these through.
function StarterMaps.respawnPoints(map: MapDef): { { number } }
	local points = {}
	for _, piece in map.pieces do
		if piece.kind == "Start" then
			table.insert(points, { piece.x, piece.y, piece.z })
		elseif piece.kind == "Checkpoint" then
			table.insert(points, { piece.x, piece.y - piece.sy / 2, piece.z })
		elseif piece.kind == "Hazard" then
			local x, y, z = StarterMaps.hazardRespawn(piece)
			table.insert(points, { x, y, z })
		end
	end
	return points
end

-- The map's extent in map space: min and max corners over every piece centre
function StarterMaps.bounds(map: MapDef): ({ number }, { number })
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, piece in map.pieces do
		lo[1], hi[1] = math.min(lo[1], piece.x), math.max(hi[1], piece.x)
		lo[2], hi[2] = math.min(lo[2], piece.y), math.max(hi[2], piece.y)
		lo[3], hi[3] = math.min(lo[3], piece.z), math.max(hi[3], piece.z)
	end
	return lo, hi
end

-- Falling this far below the map's lowest road resets the car (map space Y)
StarterMaps.KILL_BELOW = 30

function StarterMaps.killY(map: MapDef): number
	local lo = StarterMaps.bounds(map)
	return lo[2] - StarterMaps.KILL_BELOW
end

-- The piece of a kind with an index (checkpoints), or the first of the kind
function StarterMaps.find(map: MapDef, kind: string, index: number?): Piece?
	for _, piece in map.pieces do
		if piece.kind == kind and (index == nil or piece.index == index) then
			return piece
		end
	end
	return nil
end

-- The start piece of a map (spawn there, facing along it)
function StarterMaps.startPiece(map: MapDef): Piece?
	for _, piece in map.pieces do
		if piece.kind == "Start" then
			return piece
		end
	end
	return nil
end

return StarterMaps
