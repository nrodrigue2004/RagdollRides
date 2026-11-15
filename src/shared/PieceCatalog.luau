--!strict
-- PieceCatalog: the map builder's 20 pieces (spec: Map builder > Piece set) and how each one becomes
-- MapBuilder pieces (pure, unit tested). A builder map is a list of entries, never parts or code:
--   entry = { t = type id, x, z = 2-stud grid units, y = studs, r = yaw in 15 degree steps (0..23),
--             tilt = 0 none, 1..3 quarter turns on X, 4..6 quarter turns on Z, s = size 0..2 (S, M, L),
--             c = colour 0..23 (0 = the piece's own colour), p = moving-piece phase 0..255 }
-- Road-like pieces are anchored at the middle of their entry edge and run forward (yaw 0 = -Z), so a
-- piece placed at another's exit joins it. Everything else is anchored at the middle of its footprint.
-- Positions in map space: x = entry.x * 2, z = entry.z * 2, y = entry.y (the road surface or the floor).
-- Part costs are the parts MapBuilder really makes (placeholder art). The spec's lower numbers assume
-- single-mesh prefabs from the art pass (notes/Decisions.md).

local PieceCatalog = {}

PieceCatalog.GRID = 2 -- studs per grid unit (the normal grid snaps every 2 units = 4 studs)
PieceCatalog.NORMAL_STEP = 2 -- grid units per snap without the VIP fine grid
PieceCatalog.YAW_STEP = 15
PieceCatalog.ROAD_WIDTH = 32
PieceCatalog.ROAD_THICK = 2

export type Entry = {
	t: number,
	x: number,
	y: number,
	z: number,
	r: number,
	tilt: number,
	s: number,
	c: number,
	p: number,
}

export type Def = {
	id: number,
	key: string,
	label: string, -- at most 2 words (spec: UI labels)
	cost: number, -- parts
	sizes: number, -- 1 or 3
	anchor: string, -- "entry" or "center"
	tilt: boolean, -- X/Z quarter turns allowed
	moving: boolean,
	group: string?, -- "start", "finish", "checkpoint", "pad" (limit groups)
	footprint: { number }, -- x, z studs for the placement ghost and bounds, per size (S, M, L)
}

-- Colour swatches: 1..12 for everyone, 13..24 for VIP (spec: Colors). 0 = the piece's own colour.
PieceCatalog.PALETTE = {
	{ 255, 92, 92 },
	{ 255, 166, 77 },
	{ 255, 214, 10 },
	{ 120, 220, 110 },
	{ 60, 200, 170 },
	{ 86, 170, 255 },
	{ 150, 120, 255 },
	{ 255, 120, 200 },
	{ 255, 255, 255 },
	{ 170, 170, 182 },
	{ 96, 104, 132 },
	{ 50, 50, 60 },
	-- VIP
	{ 255, 200, 180 },
	{ 200, 120, 70 },
	{ 255, 240, 160 },
	{ 190, 255, 120 },
	{ 170, 240, 255 },
	{ 40, 90, 200 },
	{ 120, 60, 160 },
	{ 255, 60, 140 },
	{ 230, 230, 140 },
	{ 140, 90, 60 },
	{ 80, 140, 90 },
	{ 20, 20, 24 },
}
PieceCatalog.FREE_COLOURS = 12

local W = PieceCatalog.ROAD_WIDTH

local DEFS: { Def } = {
	{
		id = 1,
		key = "start",
		label = "Start",
		cost = 4,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		group = "start",
		footprint = { W, 4 },
	},
	{
		id = 2,
		key = "finish",
		label = "Finish",
		cost = 5,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		group = "finish",
		footprint = { W + 4, 4 },
	},
	{
		id = 3,
		key = "checkpoint",
		label = "Checkpoint",
		cost = 4,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		group = "checkpoint",
		footprint = { W, 4 },
	},
	{
		id = 4,
		key = "road",
		label = "Road",
		cost = 1,
		sizes = 3,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { W, 16, W, 32, W, 64 },
	},
	{
		id = 5,
		key = "curve45",
		label = "Curve 45",
		cost = 2,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { 64, 64 },
	},
	{
		id = 6,
		key = "curve90",
		label = "Curve 90",
		cost = 3,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { 96, 96 },
	},
	{
		id = 7,
		key = "slope",
		label = "Slope",
		cost = 1,
		sizes = 3,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { W, 32, W, 32, W, 32 },
	},
	{
		id = 8,
		key = "rampSmall",
		label = "Ramp",
		cost = 1,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { 24, 16 },
	},
	{
		id = 9,
		key = "rampBig",
		label = "Big ramp",
		cost = 2,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { 24, 32 },
	},
	{
		id = 10,
		key = "kicker",
		label = "Kicker",
		cost = 1,
		sizes = 1,
		anchor = "entry",
		tilt = false,
		moving = false,
		footprint = { 16, 8 },
	},
	{
		id = 11,
		key = "block",
		label = "Block",
		cost = 1,
		sizes = 3,
		anchor = "center",
		tilt = true,
		moving = false,
		footprint = { 8, 8, 16, 16, 32, 32 },
	},
	{
		id = 12,
		key = "wall",
		label = "Wall",
		cost = 1,
		sizes = 3,
		anchor = "center",
		tilt = true,
		moving = false,
		footprint = { 16, 2, 32, 2, 64, 2 },
	},
	{
		id = 13,
		key = "platform",
		label = "Platform",
		cost = 1,
		sizes = 3,
		anchor = "center",
		tilt = true,
		moving = false,
		footprint = { 16, 16, 32, 32, 64, 64 },
	},
	{
		id = 14,
		key = "bouncer",
		label = "Bouncer",
		cost = 2,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = false,
		group = "pad",
		footprint = { 16, 16 },
	},
	{
		id = 15,
		key = "speedPad",
		label = "Speed pad",
		cost = 2,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = false,
		group = "pad",
		footprint = { 16, 16 },
	},
	{
		id = 16,
		key = "spinner",
		label = "Spinner",
		cost = 2,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = true,
		footprint = { 30, 30 },
	},
	{
		id = 17,
		key = "hammer",
		label = "Hammer",
		cost = 5,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = true,
		footprint = { 36, 8 },
	},
	{
		id = 18,
		key = "piston",
		label = "Piston",
		cost = 2,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = true,
		footprint = { 40, 8 },
	},
	{
		id = 19,
		key = "tilt",
		label = "Tilt deck",
		cost = 2,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = true,
		footprint = { 32, 32 },
	},
	{
		id = 20,
		key = "hazardBar",
		label = "Hazard bar",
		cost = 3,
		sizes = 1,
		anchor = "center",
		tilt = false,
		moving = false,
		footprint = { W, 2 },
	},
}

PieceCatalog.defs = DEFS
PieceCatalog.byKey = {} :: { [string]: Def }
for _, def in DEFS do
	PieceCatalog.byKey[def.key] = def
end

function PieceCatalog.get(id: number): Def?
	return DEFS[id]
end

-- Size-dependent numbers
local ROAD_LENGTHS = { 16, 32, 64 }
local SLOPE_RISES = { 6, 12, 18 } -- over a 32-stud run: about 10, 20 and 30 degrees
local BLOCK_SIZES = { { 8, 8, 8 }, { 16, 8, 16 }, { 32, 8, 32 } }
local WALL_LENGTHS = { 16, 32, 64 }
local PLATFORM_SIZES = { 16, 32, 64 }
PieceCatalog.CURVE_RADIUS = 48 -- centreline radius: a 90 degree curve exits on the grid

-- Moving pieces (spec: Spinner 90 deg/s, Hammer every 2.5 s, Piston every 2 s, Tilt +-15 deg every 3 s)
PieceCatalog.MOTION = {
	spinner = { speed = 90 },
	hammer = { period = 2.5, swing = 60, pivotHeight = 20, armLength = 12 },
	piston = { period = 2, reach = 16 },
	tilt = { period = 3, angle = 15 },
}

export type Piece = {
	kind: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	pitch: number,
	roll: number?,
	sx: number,
	sy: number,
	sz: number,
	index: number?,
	speed: number?,
	axis: string?,
	color: number?,
	phase: number?,
	motion: string?,
}

function PieceCatalog.size(entry: Entry): number
	local def = DEFS[entry.t]
	if def == nil or def.sizes == 1 then
		return 1
	end
	return math.clamp(entry.s, 0, 2) + 1
end

function PieceCatalog.yaw(entry: Entry): number
	return (entry.r % 24) * PieceCatalog.YAW_STEP
end

-- Pitch and roll in degrees from the tilt field
function PieceCatalog.tiltAngles(entry: Entry): (number, number)
	local tilt = entry.tilt
	if tilt >= 1 and tilt <= 3 then
		return tilt * 90, 0
	elseif tilt >= 4 and tilt <= 6 then
		return 0, (tilt - 3) * 90
	end
	return 0, 0
end

-- The anchor in map space (studs)
function PieceCatalog.anchor(entry: Entry): (number, number, number)
	return entry.x * PieceCatalog.GRID, entry.y, entry.z * PieceCatalog.GRID
end

-- A point d studs forward, o right and h up from the anchor, along the entry's yaw
local function frame(entry: Entry)
	local ax, ay, az = PieceCatalog.anchor(entry)
	local yaw = PieceCatalog.yaw(entry)
	local fx, fz = -math.sin(math.rad(yaw)), -math.cos(math.rad(yaw))
	local rx, rz = -fz, fx
	return function(d: number, o: number, h: number): (number, number, number)
		return ax + fx * d + rx * o, ay + h, az + fz * d + rz * o
	end,
		yaw
end

local function piece(
	kind: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	sx: number,
	sy: number,
	sz: number,
	extra: { [string]: any }?
): Piece
	local p: Piece = { kind = kind, x = x, y = y, z = z, yaw = yaw, pitch = 0, sx = sx, sy = sy, sz = sz }
	if extra then
		for k, v in extra do
			(p :: any)[k] = v
		end
	end
	return p
end

-- A road climbing `rise` over a horizontal `run` from the anchor (top surface centre in the middle)
local function sloped(
	kind: string,
	at,
	yaw: number,
	run: number,
	rise: number,
	width: number,
	color: number?
): Piece
	local x, y, z = at(run / 2, 0, rise / 2)
	local p = piece(
		kind,
		x,
		y,
		z,
		yaw,
		width,
		PieceCatalog.ROAD_THICK,
		math.sqrt(run * run + rise * rise) + 0.2,
		{ color = color }
	)
	p.pitch = math.deg(math.atan2(rise, run))
	return p
end

-- Road segments along a left-hand arc of `degrees` (a right turn is the same piece driven the other way)
local function curve(entry: Entry, degrees: number, segments: number, color: number?): { Piece }
	local ax, ay, az = PieceCatalog.anchor(entry)
	local yaw = PieceCatalog.yaw(entry)
	local fx, fz = -math.sin(math.rad(yaw)), -math.cos(math.rad(yaw))
	local rx, rz = -fz, fx
	local radius = PieceCatalog.CURVE_RADIUS
	-- Turn centre to the left of the entry
	local cx, cz = ax - rx * radius, az - rz * radius
	local function point(phi: number): (number, number)
		local c, s = math.cos(math.rad(phi)), math.sin(math.rad(phi))
		return cx + rx * radius * c + fx * radius * s, cz + rz * radius * c + fz * radius * s
	end
	local out = {}
	local step = degrees / segments
	-- Each segment is as long as the arc's outer edge chord, so the outside never gaps (the inside overlaps)
	local outer = radius + W / 2
	local length = 2 * outer * math.sin(math.rad(step / 2)) + 0.4
	for i = 0, segments - 1 do
		local x0, z0 = point(i * step)
		local x1, z1 = point((i + 1) * step)
		table.insert(
			out,
			piece(
				"Road",
				(x0 + x1) / 2,
				ay,
				(z0 + z1) / 2,
				yaw + (i + 0.5) * step,
				W,
				PieceCatalog.ROAD_THICK,
				length,
				{ color = color }
			)
		)
	end
	return out
end

-- Where a road-like piece ends (map space) and its heading: for joining the next piece on
function PieceCatalog.exit(entry: Entry): (number?, number?, number?, number?)
	local def = DEFS[entry.t]
	if def == nil or def.anchor ~= "entry" then
		return nil
	end
	local at, yaw = frame(entry)
	local key = def.key
	if key == "road" then
		local x, y, z = at(ROAD_LENGTHS[PieceCatalog.size(entry)], 0, 0)
		return x, y, z, yaw
	elseif key == "slope" then
		local x, y, z = at(32, 0, SLOPE_RISES[PieceCatalog.size(entry)])
		return x, y, z, yaw
	elseif key == "curve45" or key == "curve90" then
		local degrees = if key == "curve45" then 45 else 90
		local ax, ay, az = PieceCatalog.anchor(entry)
		local fx, fz = -math.sin(math.rad(yaw)), -math.cos(math.rad(yaw))
		local rx, rz = -fz, fx
		local radius = PieceCatalog.CURVE_RADIUS
		local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
		local cx, cz = ax - rx * radius, az - rz * radius
		return cx + rx * radius * c + fx * radius * s,
			ay,
			cz + rz * radius * c + fz * radius * s,
			yaw + degrees
	end
	return nil
end

-- One entry as MapBuilder pieces (map space). checkpointIndex numbers checkpoints in placement order.
function PieceCatalog.expand(entry: Entry, checkpointIndex: number?): { Piece }
	local def = DEFS[entry.t]
	if def == nil then
		return {}
	end
	local at, yaw = frame(entry)
	local size = PieceCatalog.size(entry)
	local color = if entry.c > 0 then entry.c else nil
	local phase = entry.p / 256
	local key = def.key
	local pitch, roll = PieceCatalog.tiltAngles(entry)
	-- Tilted pieces turn about their centre, then sit back down so their lowest face is on entry.y
	local function tilted(p: Piece, base: number): Piece
		if def.tilt and entry.tilt ~= 0 then
			p.pitch, p.roll = pitch, roll
			local height = if pitch % 180 == 90 then p.sz elseif roll % 180 == 90 then p.sx else p.sy
			p.y = base + height / 2
		end
		return p
	end

	if key == "start" then
		local x, y, z = at(0, 0, 0)
		return { piece("Start", x, y, z, yaw, W, 12, 2) }
	elseif key == "finish" then
		local x, y, z = at(0, 0, 7)
		return { piece("Finish", x, y, z, yaw, W + 4, 14, 4) }
	elseif key == "checkpoint" then
		local x, y, z = at(0, 0, 6)
		return { piece("Checkpoint", x, y, z, yaw, W, 12, 4, { index = checkpointIndex or 1 }) }
	elseif key == "road" then
		local length = ROAD_LENGTHS[size]
		local x, y, z = at(length / 2, 0, 0)
		return { piece("Road", x, y, z, yaw, W, PieceCatalog.ROAD_THICK, length + 0.2, { color = color }) }
	elseif key == "curve45" then
		return curve(entry, 45, 2, color)
	elseif key == "curve90" then
		return curve(entry, 90, 3, color)
	elseif key == "slope" then
		return { sloped("Road", at, yaw, 32, SLOPE_RISES[size], W, color) }
	elseif key == "rampSmall" then
		return { sloped("Ramp", at, yaw, 16, 4, 24, color) }
	elseif key == "rampBig" then
		local ramp = sloped("Ramp", at, yaw, 32, 10, 24, color)
		local x, y, z = at(30, 0, 5)
		return { ramp, piece("Block", x, y, z, yaw, 24, 10, 4, { color = color }) }
	elseif key == "kicker" then
		return { sloped("Ramp", at, yaw, 8, 5, 16, color) }
	elseif key == "block" then
		local s = BLOCK_SIZES[size]
		local x, y, z = at(0, 0, s[2] / 2)
		return { tilted(piece("Block", x, y, z, yaw, s[1], s[2], s[3], { color = color }), entry.y) }
	elseif key == "wall" then
		local x, y, z = at(0, 0, 6)
		return { tilted(piece("Wall", x, y, z, yaw, WALL_LENGTHS[size], 12, 2, { color = color }), entry.y) }
	elseif key == "platform" then
		-- Flat: the piece position is the top surface (like a road). Tilted: a slab stood on its edge.
		local s = PLATFORM_SIZES[size]
		if entry.tilt ~= 0 then
			local x, y, z = at(0, 0, 0)
			return {
				tilted(
					piece("Block", x, y, z, yaw, s, PieceCatalog.ROAD_THICK, s, { color = color }),
					entry.y
				),
			}
		end
		local x, y, z = at(0, 0, 0)
		return { piece("Road", x, y, z, yaw, s, PieceCatalog.ROAD_THICK, s, { color = color }) }
	elseif key == "bouncer" then
		local x, y, z = at(0, 0, 0.2)
		return { piece("Bouncer", x, y, z, yaw, 16, 0.4, 16) }
	elseif key == "speedPad" then
		local x, y, z = at(0, 0, 0.2)
		return { piece("SpeedPad", x, y, z, yaw, 16, 0.4, 16) }
	elseif key == "spinner" then
		local x, y, z = at(0, 0, 7)
		return {
			piece(
				"Spinner",
				x,
				y,
				z,
				yaw,
				30,
				3,
				3,
				{ speed = PieceCatalog.MOTION.spinner.speed, axis = "up", phase = phase, color = color }
			),
		}
	elseif key == "hammer" then
		local m = PieceCatalog.MOTION.hammer
		local x, y, z = at(0, 0, m.pivotHeight)
		return { piece("Hammer", x, y, z, yaw, 36, 2, 2, { phase = phase, color = color }) }
	elseif key == "piston" then
		local x, y, z = at(0, 0, 4)
		return { piece("Piston", x, y, z, yaw, 40, 8, 8, { phase = phase, color = color }) }
	elseif key == "tilt" then
		local x, y, z = at(0, 0, 4)
		return { piece("TiltPlatform", x, y, z, yaw, 32, 2, 32, { phase = phase, color = color }) }
	elseif key == "hazardBar" then
		local x, y, z = at(0, 0, 6)
		return { piece("HazardBar", x, y, z, yaw, W, 2, 2, { color = color }) }
	end
	return {}
end

-- A builder map as a map definition (the StarterMaps.MapDef shape), so MapBuilder, TracksClient and
-- TracksService drive it exactly like a starter map. Checkpoints are numbered in placement order (the
-- builder shows each one's number).
function PieceCatalog.toMapDef(entries: { Entry }, fields: { [string]: any }): { [string]: any }
	local pieces = {}
	local checkpoints = 0
	for _, entry in entries do
		local def = DEFS[entry.t]
		local index = nil
		if def and def.group == "checkpoint" then
			checkpoints += 1
			index = checkpoints
		end
		for _, p in PieceCatalog.expand(entry, index) do
			table.insert(pieces, p)
		end
	end
	return {
		id = fields.id,
		name = fields.name or "",
		order = 0,
		creatorTime = fields.creatorTime or 0,
		coinValue = 0,
		offset = fields.offset or { 0, 0, 0 },
		pieces = pieces,
		checkpoints = checkpoints,
		coins = 0,
		custom = true,
		fullDamage = fields.fullDamage == true,
	}
end

return PieceCatalog
