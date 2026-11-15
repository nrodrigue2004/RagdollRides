-- Movers: moving and hazard pieces, described once and used by both sides (spec: moving pieces animate on
-- each client from the server clock, workspace:GetServerTimeNow(), so everyone sees the same phase and the
-- server never simulates them).
-- * MapBuilder makes a part for each described part; moving ones are tagged "Mover" with their motion in
--   attributes (Pivot, Offset, Motion, Phase, Speed, Period, Amount).
-- * TracksClient moves every Mover part each frame and tests the parts marked `hit` against the car:
--   "eject" throws the rider (spinner bars, hammer heads, hazard bars), "push" shoves the car (pistons).
-- Motions: spinY / spinX (degrees per second), swing (pendulum about the road's forward axis), punch
-- (out and back along the piece's left), tilt (rock about the road's forward axis).

local MapSpace = require(script.Parent.MapSpace)
local PieceCatalog = require(script.Parent.PieceCatalog)

local Movers = {}

export type MoverPart = {
	name: string,
	size: Vector3,
	offset: CFrame, -- from the pivot at rest
	motion: string?, -- nil = static
	hit: string?, -- "eject" or "push"
	cylinder: boolean?,
	collide: boolean?, -- a surface the car drives on (the tilt deck); moved by each client
}

export type Motion = {
	motion: string,
	phase: number, -- 0..1 of a cycle
	speed: number, -- spins: degrees per second
	period: number, -- seconds per cycle
	amount: number, -- swing or tilt degrees, punch studs
}

local SPINNER_HEIGHT = 7 -- spinners sit this far above the road (StarterMaps and PieceCatalog place them so)
local HAZARD_BAR_HEIGHT = 6 -- a hazard bar's centre above its floor (PieceCatalog)

-- The parts of a mover piece and its motion, or nil for any other kind
function Movers.describe(piece: PieceCatalog.Piece): ({ MoverPart }?, Motion?)
	local kind = piece.kind
	local phase = piece.phase or 0
	if kind == "Spinner" then
		local speed = piece.speed or PieceCatalog.MOTION.spinner.speed
		if piece.axis == "across" then
			-- A roller across the road on two posts (Pip's Hill: a guaranteed-hit Hazard volume does the hit)
			local height = SPINNER_HEIGHT + piece.sy / 2
			return {
				{
					name = "Spinner",
					size = Vector3.new(piece.sx, piece.sy, piece.sy),
					offset = CFrame.identity,
					motion = "spinX",
					cylinder = true,
				},
				{
					name = "SpinnerPost",
					size = Vector3.new(1.5, height, 1.5),
					offset = CFrame.new(-(piece.sx / 2 + 1), -SPINNER_HEIGHT + height / 2, 0),
				},
				{
					name = "SpinnerPost",
					size = Vector3.new(1.5, height, 1.5),
					offset = CFrame.new(piece.sx / 2 + 1, -SPINNER_HEIGHT + height / 2, 0),
				},
			}, { motion = "spinX", phase = phase, speed = speed, period = 0, amount = 0 }
		end
		local hubHeight = SPINNER_HEIGHT + piece.sy / 2
		return {
			{
				name = "Spinner",
				size = Vector3.new(piece.sx, piece.sy, piece.sz),
				offset = CFrame.identity,
				motion = "spinY",
				hit = "eject",
			},
			{
				name = "SpinnerHub",
				size = Vector3.new(2.5, hubHeight, 2.5),
				offset = CFrame.new(0, -SPINNER_HEIGHT + hubHeight / 2, 0),
			},
		}, { motion = "spinY", phase = phase, speed = speed, period = 0, amount = 0 }
	elseif kind == "Hammer" then
		local m = PieceCatalog.MOTION.hammer
		local postHeight = m.pivotHeight + piece.sy / 2
		return {
			{
				name = "HammerPost",
				size = Vector3.new(1.5, postHeight, 1.5),
				offset = CFrame.new(-(piece.sx / 2 - 1), -m.pivotHeight + postHeight / 2, 0),
			},
			{
				name = "HammerPost",
				size = Vector3.new(1.5, postHeight, 1.5),
				offset = CFrame.new(piece.sx / 2 - 1, -m.pivotHeight + postHeight / 2, 0),
			},
			{
				name = "HammerFrame",
				size = Vector3.new(piece.sx, piece.sy, piece.sz),
				offset = CFrame.identity,
			},
			{
				name = "HammerArm",
				size = Vector3.new(1, m.armLength, 1),
				offset = CFrame.new(0, -m.armLength / 2, 0),
				motion = "swing",
			},
			{
				name = "HammerHead",
				size = Vector3.new(8, 6, 6),
				offset = CFrame.new(0, -m.armLength - 3, 0),
				motion = "swing",
				hit = "eject",
			},
		}, { motion = "swing", phase = phase, speed = 0, period = m.period, amount = m.swing }
	elseif kind == "Piston" then
		local m = PieceCatalog.MOTION.piston
		-- The housing sits on the right edge; the pusher punches out to the left across the road
		return {
			-- At rest the head blocks the right lane; punched out it sweeps the left lane (time it)
			{ name = "PistonBase", size = Vector3.new(8, 8, 8), offset = CFrame.new(piece.sx / 2 - 4, 0, 0) },
			{
				name = "PistonHead",
				size = Vector3.new(12, 6, 6),
				offset = CFrame.new(piece.sx / 2 - 14, -1, 0),
				motion = "punch",
				hit = "push",
			},
		}, { motion = "punch", phase = phase, speed = 0, period = m.period, amount = m.reach }
	elseif kind == "TiltPlatform" then
		local m = PieceCatalog.MOTION.tilt
		return {
			{ name = "TiltBase", size = Vector3.new(6, 4, piece.sz), offset = CFrame.new(0, -2, 0) },
			{
				name = "TiltDeck",
				size = Vector3.new(piece.sx, piece.sy, piece.sz),
				offset = CFrame.new(0, piece.sy / 2, 0),
				motion = "tilt",
				collide = true,
			},
		}, { motion = "tilt", phase = phase, speed = 0, period = m.period, amount = m.angle }
	elseif kind == "HazardBar" then
		-- A bar across the road on two posts: jump it or get thrown (PieceCatalog puts its centre 6 up)
		local postHeight = HAZARD_BAR_HEIGHT + piece.sy / 2
		return {
			{
				name = "HazardPost",
				size = Vector3.new(1.5, postHeight, 1.5),
				offset = CFrame.new(-(piece.sx / 2 + 1), -postHeight / 2 + piece.sy / 2, 0),
			},
			{
				name = "HazardPost",
				size = Vector3.new(1.5, postHeight, 1.5),
				offset = CFrame.new(piece.sx / 2 + 1, -postHeight / 2 + piece.sy / 2, 0),
			},
			{
				name = "HazardBar",
				size = Vector3.new(piece.sx, piece.sy, piece.sz),
				offset = CFrame.identity,
				hit = "eject",
			},
		},
			nil
	end
	return nil, nil
end

-- The punch curve: out fast, hold, back, rest (fraction of the cycle -> 0..1 of the reach)
function Movers.punch(f: number): number
	if f < 0.12 then
		local u = f / 0.12
		return 1 - (1 - u) * (1 - u)
	elseif f < 0.42 then
		return 1
	elseif f < 0.72 then
		return 1 - (f - 0.42) / 0.3
	end
	return 0
end

-- The motion at server time t, as a transform applied at the pivot
function Movers.transform(motion: Motion?, t: number): CFrame
	if motion == nil then
		return CFrame.identity
	end
	local kind = motion.motion
	if kind == "spinY" or kind == "spinX" then
		local angle = (math.rad(motion.speed) * t + motion.phase * 2 * math.pi) % (2 * math.pi)
		return if kind == "spinY" then CFrame.Angles(0, angle, 0) else CFrame.Angles(angle, 0, 0)
	end
	local cycle = (t / math.max(motion.period, 0.1) + motion.phase) % 1
	if kind == "swing" then
		return CFrame.Angles(0, 0, math.rad(motion.amount) * math.sin(cycle * 2 * math.pi))
	elseif kind == "tilt" then
		return CFrame.Angles(0, 0, math.rad(motion.amount) * math.sin(cycle * 2 * math.pi))
	elseif kind == "punch" then
		return CFrame.new(-motion.amount * Movers.punch(cycle), 0, 0)
	end
	return CFrame.identity
end

-- Is the punch moving outward right now (pistons only shove while they extend)
function Movers.extending(motion: Motion?, t: number): boolean
	if motion == nil or motion.motion ~= "punch" then
		return false
	end
	local cycle = (t / math.max(motion.period, 0.1) + motion.phase) % 1
	return cycle < 0.12
end

function Movers.partCFrame(pivot: CFrame, part: MoverPart, motion: Motion?, t: number): CFrame
	if part.motion then
		return pivot * Movers.transform(motion, t) * part.offset
	end
	return pivot * part.offset
end

export type Hit = {
	pivot: CFrame,
	part: MoverPart,
	motion: Motion?,
}

-- Every part of a map that can hit the car (for TracksClient's per-frame test)
function Movers.hits(map: any): { Hit }
	local out = {}
	for _, piece in map.pieces do
		local parts, motion = Movers.describe(piece)
		if parts then
			local pivot = MapSpace.pieceCFrame(map, piece)
			for _, part in parts do
				if part.hit then
					table.insert(out, { pivot = pivot, part = part, motion = motion })
				end
			end
		end
	end
	return out
end

-- Does the car (chassis centre) touch this part now? Tested in the part's own frame (a swinging head is
-- rotated), grown by the car's half size, and down to where the rider sits (the same box milestone 2
-- tuned for the sweeping bar: 1.5 along its length, 2.5 across, 5 below, 1 above).
function Movers.touches(hit: Hit, t: number, position: Vector3): boolean
	local cf = Movers.partCFrame(hit.pivot, hit.part, hit.motion, t)
	local p = cf:PointToObjectSpace(position)
	local size = hit.part.size
	return math.abs(p.X) <= size.X / 2 + 1.5
		and math.abs(p.Z) <= size.Z / 2 + 2.5
		and p.Y >= -size.Y / 2 - 5
		and p.Y <= size.Y / 2 + 1
end

-- Which way a push shoves the car (world space): along the punch, a little up
function Movers.pushVelocity(hit: Hit, t: number): Vector3
	local cf = hit.pivot * Movers.transform(hit.motion, t)
	return -cf.RightVector * 45 + Vector3.new(0, 10, 0)
end

return Movers
