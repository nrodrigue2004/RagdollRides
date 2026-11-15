--!strict
-- DamageModel: the 9 damage numbers per vehicle and everything derived from them (pure, unit tested).
-- Spec: Damage zones, Damage by mode, Explosions, Repairs, Mesh deformation.
--
-- A vehicle's damage is 9 zone health values: Front (holds the engine), Rear, Left, Right, Roof and the 4
-- wheels (FL, FR, RL, RR, the same order as VehicleBuilder.WHEEL_NAMES). Every look, detach, handling
-- effect and fire is derived from those numbers, so every device draws the same car from the 10-byte
-- Damage.State message (9 zone bytes plus a flags byte).
--
-- Positions here are in the car's local space: the car faces -Z, +X is its right side, +Y is up.

local DamageModel = {}

DamageModel.ZONES = { "Front", "Rear", "Left", "Right", "Roof", "FL", "FR", "RL", "RR" }
DamageModel.FRONT, DamageModel.REAR, DamageModel.LEFT, DamageModel.RIGHT, DamageModel.ROOF = 1, 2, 3, 4, 5
DamageModel.WHEEL_ZONES = { 6, 7, 8, 9 }
DamageModel.BODY_ZONES = { 1, 2, 3, 4, 5 }

-- Look per zone: 0 clean, 1 dented, 2 crushed, 3 destroyed (health 0)
DamageModel.CLEAN, DamageModel.DENTED, DamageModel.CRUSHED, DamageModel.DESTROYED = 0, 1, 2, 3

DamageModel.FLAG_FIRE = 1
DamageModel.FLAG_EXPLODED = 2
DamageModel.FLAG_WRECKED = 4
DamageModel.STATE_SIZE = 10

local ZONE_INDEX: { [string]: number } = {}
for index, name in DamageModel.ZONES do
	ZONE_INDEX[name] = index
end
DamageModel.ZONE_INDEX = ZONE_INDEX

-- 25% of a body hit spills to each adjacent zone
local ADJACENT: { [number]: { number } } = {
	[1] = { 3, 4 }, -- front: left, right
	[2] = { 3, 4 }, -- rear: left, right
	[3] = { 1, 2 }, -- left: front, rear
	[4] = { 1, 2 }, -- right: front, rear
	[5] = { 3, 4 }, -- roof: left, right
}

export type DamageConfig = {
	bodyHealth: number,
	wheelHealth: number,
	impactOffset: number,
	impactScale: number,
	spillFraction: number,
	wheelShare: number,
	landingWheelSpeed: number,
	dentedBelow: number,
	crushedBelow: number,
	handling: {
		frontDentedTopSpeed: number,
		frontCrushedTopSpeed: number,
		wheelDentedPull: number,
		wheelCrushedPull: number,
		maxPull: number,
		wheelCrushedGrip: number,
		wheelLostDrive: number,
		axleDragG: number,
	},
	fireTime: number,
	wreckWheels: number,
	shockwave: { radius: number, push: number, up: number, damage: number },
	deform: {
		radiusBase: number,
		radiusPerImpact: number,
		pushPerImpact: number,
		maxPush: number,
		maxTotal: number,
	},
	[string]: any,
}

export type ModeRules = { looks: boolean, handling: boolean, explosion: boolean, health: number }

export type State = {
	hp: { number },
	max: { number },
	fire: boolean,
	fireTime: number,
	exploded: boolean,
}

export type Handling = {
	topSpeed: number, -- multiplier
	drive: number, -- multiplier
	engineDead: boolean,
	steerPull: number, -- degrees, + pulls right
	grip: { number }, -- per wheel multiplier
	lost: { boolean }, -- per wheel
	smoke: number, -- 0 none, 1 light, 2 heavy
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

function DamageModel.new(healthMultiplier: number, cfg: DamageConfig): State
	local hp, max = {}, {}
	for index = 1, 9 do
		local base = if index <= 5 then cfg.bodyHealth else cfg.wheelHealth
		max[index] = base * healthMultiplier
		hp[index] = max[index]
	end
	return { hp = hp, max = max, fire = false, fireTime = 0, exploded = false }
end

function DamageModel.repair(state: State)
	for index = 1, 9 do
		state.hp[index] = state.max[index]
	end
	state.fire = false
	state.fireTime = 0
	state.exploded = false
end

-- Heal every zone by an amount (Brawl Wrench 50, Highway Pit Wrench 30). A lost wheel stays lost unless
-- remount is set, which brings back one lost wheel (the Pit Wrench), at the heal amount.
function DamageModel.heal(state: State, amount: number, remountOne: boolean?)
	local remounted = false
	for index = 1, 9 do
		local isWheel = index >= 6
		if state.hp[index] <= 0 and isWheel then
			if remountOne and not remounted then
				remounted = true
				state.hp[index] = math.min(state.max[index], amount)
			end
		elseif state.hp[index] <= 0 and index == 1 and state.exploded then
			continue -- a blown engine stays blown until a full repair
		else
			state.hp[index] = math.min(state.max[index], state.hp[index] + amount)
		end
	end
	if state.hp[1] > 0 then
		state.fire = false
		state.fireTime = 0
	end
end

local function hurt(state: State, index: number, amount: number)
	if amount > 0 then
		state.hp[index] = math.max(0, state.hp[index] - amount)
	end
end

-- Direct damage to one zone (shockwaves, tests)
function DamageModel.applyToZone(state: State, index: number, amount: number)
	hurt(state, index, amount)
end

-- Damage from one impact (spec: damage to the hit zone = max(0, I - 15) x 1.2, 25% spills to each adjacent
-- zone, wheels take 50% of front or side damage on that corner).
-- side comes from Damage.contactSide; lx, lz is the contact point in car space; halfX, halfZ are the car's
-- half width and half length. Returns the damage dealt to the hit zone.
function DamageModel.applyImpact(
	state: State,
	side: string,
	impact: number,
	lx: number,
	lz: number,
	halfX: number,
	halfZ: number,
	cfg: DamageConfig
): number
	if side == "Bottom" then
		return 0 -- landings damage wheels through applyLanding
	end
	local zone = ZONE_INDEX[side]
	if zone == nil then
		return 0
	end
	local damage = math.max(0, impact - cfg.impactOffset) * cfg.impactScale
	if damage <= 0 then
		return 0
	end
	hurt(state, zone, damage)
	for _, neighbour in ADJACENT[zone] do
		hurt(state, neighbour, damage * cfg.spillFraction)
	end

	-- Corner wheels: weight between the two wheels on that end or side by where the hit landed
	local share = damage * cfg.wheelShare
	if side == "Front" or side == "Rear" then
		local right = math.clamp(0.5 + 0.5 * lx / math.max(halfX, 1e-3), 0, 1)
		local leftWheel, rightWheel = if side == "Front" then 6 else 8, if side == "Front" then 7 else 9
		hurt(state, leftWheel, share * (1 - right))
		hurt(state, rightWheel, share * right)
	elseif side == "Left" or side == "Right" then
		-- front is -Z
		local rear = math.clamp(0.5 + 0.5 * lz / math.max(halfZ, 1e-3), 0, 1)
		local frontWheel, rearWheel = if side == "Left" then 6 else 7, if side == "Left" then 8 else 9
		hurt(state, frontWheel, share * (1 - rear))
		hurt(state, rearWheel, share * rear)
	end
	return damage
end

-- A landing: wheels that touched down take max(0, fall speed - 50) x 1.2 each.
function DamageModel.applyLanding(
	state: State,
	fallSpeed: number,
	touched: { boolean },
	cfg: DamageConfig
): number
	local damage = math.max(0, fallSpeed - cfg.landingWheelSpeed) * cfg.impactScale
	if damage <= 0 then
		return 0
	end
	for i, zone in DamageModel.WHEEL_ZONES do
		if touched[i] then
			hurt(state, zone, damage)
		end
	end
	return damage
end

---------------------------------------------------------------------------
-- Looks and events
---------------------------------------------------------------------------

function DamageModel.lookOf(fraction: number, cfg: DamageConfig): number
	if fraction <= 0 then
		return DamageModel.DESTROYED
	elseif fraction < cfg.crushedBelow then
		return DamageModel.CRUSHED
	elseif fraction < cfg.dentedBelow then
		return DamageModel.DENTED
	end
	return DamageModel.CLEAN
end

function DamageModel.fractions(state: State): { number }
	local out = {}
	for index = 1, 9 do
		out[index] = state.hp[index] / state.max[index]
	end
	return out
end

function DamageModel.looksFromFractions(fractions: { number }, cfg: DamageConfig): { number }
	local out = {}
	for index = 1, 9 do
		out[index] = DamageModel.lookOf(fractions[index], cfg)
	end
	return out
end

function DamageModel.looks(state: State, cfg: DamageConfig): { number }
	return DamageModel.looksFromFractions(DamageModel.fractions(state), cfg)
end

function DamageModel.wheelsLost(looks: { number }): number
	local count = 0
	for _, zone in DamageModel.WHEEL_ZONES do
		if looks[zone] == DamageModel.DESTROYED then
			count += 1
		end
	end
	return count
end

function DamageModel.isWrecked(state: State, cfg: DamageConfig): boolean
	return state.exploded or DamageModel.wheelsLost(DamageModel.looks(state, cfg)) >= cfg.wreckWheels
end

export type Event = { kind: string, zone: number?, part: string? }

-- What changed between two sets of looks, as visual events. Every device derives the same events from
-- the zone numbers, so the owner and everyone watching see the same car.
--   look        the zone changes look (zone; the new look is in part, as "1", "2" or "3")
--   crackGlass  the zone's glass cracks (zone turned dented)
--   shatterGlass  glass shatters: the zone's glass when crushed; all glass when the roof is crushed
--   detach      a part tears off and flies (part)
--   doorLoose   a side panel swings loose (zone)
--   wheelLost   a wheel pops off (zone)
-- Looks only get worse between repairs; a repair is handled as a reset, not as events.
function DamageModel.diff(old: { number }, new: { number }): { Event }
	local events: { Event } = {}
	local function add(kind: string, zone: number?, part: string?)
		table.insert(events, { kind = kind, zone = zone, part = part })
	end
	for index = 1, 9 do
		local from, to = old[index], new[index]
		if to <= from then
			continue
		end
		if index >= 6 then
			if to == DamageModel.DESTROYED then
				add("wheelLost", index)
			end
			add("look", index, tostring(to))
			continue
		end
		add("look", index, tostring(to))
		if from < DamageModel.DENTED and to >= DamageModel.DENTED and index ~= DamageModel.ROOF then
			add("crackGlass", index)
		end
		if from < DamageModel.CRUSHED and to >= DamageModel.CRUSHED then
			if index == DamageModel.FRONT then
				add("detach", index, "Bumper_Front")
			elseif index == DamageModel.REAR then
				add("detach", index, "Bumper_Rear")
			elseif index == DamageModel.LEFT or index == DamageModel.RIGHT then
				add("doorLoose", index)
			end
			if index == DamageModel.ROOF then
				add("shatterGlass", nil)
			else
				add("shatterGlass", index)
			end
		end
		if from < DamageModel.DESTROYED and to == DamageModel.DESTROYED then
			if index == DamageModel.FRONT then
				add("detach", index, "Panel_Front") -- hood tears off
			elseif index == DamageModel.REAR then
				add("detach", index, "Panel_Rear")
			elseif index == DamageModel.LEFT then
				add("detach", index, "Panel_Left") -- door tears off
			elseif index == DamageModel.RIGHT then
				add("detach", index, "Panel_Right")
			end
			-- the roof stays on, crushed
		end
	end
	return events
end

---------------------------------------------------------------------------
-- Handling (only where the mode's damage table says damage affects handling)
---------------------------------------------------------------------------

function DamageModel.handling(looks: { number }, rules: ModeRules, cfg: DamageConfig): Handling
	local h: Handling = {
		topSpeed = 1,
		drive = 1,
		engineDead = false,
		steerPull = 0,
		grip = { 1, 1, 1, 1 },
		lost = { false, false, false, false },
		smoke = 0,
	}
	local front = looks[DamageModel.FRONT]
	-- Smoke is a look, so it shows in every mode
	if front == DamageModel.DENTED then
		h.smoke = 1
	elseif front >= DamageModel.CRUSHED then
		h.smoke = 2
	end
	if not rules.handling then
		return h
	end
	local hc = cfg.handling
	if front == DamageModel.DENTED then
		h.topSpeed = hc.frontDentedTopSpeed
	elseif front == DamageModel.CRUSHED then
		h.topSpeed = hc.frontCrushedTopSpeed
	elseif front == DamageModel.DESTROYED then
		h.topSpeed = hc.frontCrushedTopSpeed
		h.engineDead = true
	end
	local pull = 0
	for i, zone in DamageModel.WHEEL_ZONES do
		local look = looks[zone]
		local direction = if i == 1 or i == 3 then -1 else 1 -- left wheels pull left
		if look == DamageModel.DENTED then
			pull += direction * hc.wheelDentedPull
		elseif look == DamageModel.CRUSHED then
			pull += direction * hc.wheelCrushedPull
			h.grip[i] = hc.wheelCrushedGrip
		elseif look == DamageModel.DESTROYED then
			h.lost[i] = true
			h.grip[i] = 0
			h.drive -= hc.wheelLostDrive
		end
	end
	h.steerPull = math.clamp(pull, -hc.maxPull, hc.maxPull)
	h.drive = math.max(0, h.drive)
	return h
end

---------------------------------------------------------------------------
-- Fire and explosion
---------------------------------------------------------------------------

-- Advance the fire. Returns "fire" on the frame the fire starts and "explode" on the frame it blows.
function DamageModel.tick(state: State, dt: number, rules: ModeRules, cfg: DamageConfig): string?
	if state.exploded or not rules.explosion then
		return nil
	end
	if state.hp[DamageModel.FRONT] > 0 then
		return nil
	end
	if not state.fire then
		state.fire = true
		state.fireTime = 0
		return "fire"
	end
	state.fireTime += dt
	if state.fireTime >= cfg.fireTime then
		state.fire = false
		state.exploded = true
		return "explode"
	end
	return nil
end

-- Shockwave from an explosion at a distance: outward speed change, upward speed change and damage.
function DamageModel.shockwave(distance: number, cfg: DamageConfig): (number, number, number)
	local sw = cfg.shockwave
	if distance >= sw.radius then
		return 0, 0, 0
	end
	local falloff = 1 - math.max(0, distance) / sw.radius
	return sw.push * falloff, sw.up, sw.damage * falloff
end

-- Which zone faces a direction given in car space (for shockwave damage): the hit side, from where the
-- blast came from.
function DamageModel.zoneFacing(dx: number, dy: number, dz: number): number
	if dy > 0.7 then
		return DamageModel.ROOF
	end
	if math.abs(dz) >= math.abs(dx) then
		return if dz < 0 then DamageModel.FRONT else DamageModel.REAR
	end
	return if dx < 0 then DamageModel.LEFT else DamageModel.RIGHT
end

---------------------------------------------------------------------------
-- Network form: 9 zone bytes (health fraction x 255) plus a flags byte
---------------------------------------------------------------------------

function DamageModel.flags(state: State, cfg: DamageConfig): number
	local flags = 0
	if state.fire then
		flags += DamageModel.FLAG_FIRE
	end
	if state.exploded then
		flags += DamageModel.FLAG_EXPLODED
	end
	if DamageModel.isWrecked(state, cfg) then
		flags += DamageModel.FLAG_WRECKED
	end
	return flags
end

local function toByte(fraction: number): number
	local byte = math.floor(math.clamp(fraction, 0, 1) * 255 + 0.5)
	-- Never round a damaged zone up to full or a living zone down to 0
	if fraction > 0 and byte == 0 then
		byte = 1
	elseif fraction < 1 and byte == 255 then
		byte = 254
	end
	return byte
end

function DamageModel.encode(state: State, cfg: DamageConfig): buffer
	local b = buffer.create(DamageModel.STATE_SIZE)
	for index = 1, 9 do
		buffer.writeu8(b, index - 1, toByte(state.hp[index] / state.max[index]))
	end
	buffer.writeu8(b, 9, DamageModel.flags(state, cfg))
	return b
end

export type Decoded = { fractions: { number }, flags: number }

function DamageModel.decode(b: buffer): Decoded?
	if buffer.len(b) ~= DamageModel.STATE_SIZE then
		return nil
	end
	local fractions = {}
	for index = 1, 9 do
		fractions[index] = buffer.readu8(b, index - 1) / 255
	end
	return { fractions = fractions, flags = buffer.readu8(b, 9) }
end

function DamageModel.isPristine(state: State): boolean
	for index = 1, 9 do
		if state.hp[index] < state.max[index] then
			return false
		end
	end
	return not state.fire and not state.exploded
end

---------------------------------------------------------------------------
-- Mesh deformation (spec: a hit pushes vertices within r = 1.5 + I / 40 along the impact direction by up
-- to min(0.8, I / 100) studs with smooth falloff; total displacement per vertex capped at 1.2 studs).
-- Vertices are given as flat arrays (x, y, z per vertex) of rest positions and current offsets, so the
-- maths stays free of Roblox types. Returns how many vertices moved.
---------------------------------------------------------------------------

function DamageModel.dent(
	rest: { number },
	offsets: { number },
	px: number,
	py: number,
	pz: number,
	dx: number,
	dy: number,
	dz: number,
	impact: number,
	cfg: DamageConfig
): number
	local d = cfg.deform
	local radius = d.radiusBase + impact * d.radiusPerImpact
	local push = math.min(d.maxPush, impact * d.pushPerImpact)
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if push <= 0 or length < 1e-6 then
		return 0
	end
	dx, dy, dz = dx / length, dy / length, dz / length
	local radius2 = radius * radius
	local moved = 0
	for i = 1, #rest, 3 do
		local vx, vy, vz = rest[i] + offsets[i], rest[i + 1] + offsets[i + 1], rest[i + 2] + offsets[i + 2]
		local ex, ey, ez = vx - px, vy - py, vz - pz
		local dist2 = ex * ex + ey * ey + ez * ez
		if dist2 < radius2 then
			local t = 1 - dist2 / radius2
			local amount = push * t * t -- smooth falloff, 1 at the centre and 0 at the edge
			local ox, oy, oz =
				offsets[i] + dx * amount, offsets[i + 1] + dy * amount, offsets[i + 2] + dz * amount
			local total = math.sqrt(ox * ox + oy * oy + oz * oz)
			if total > d.maxTotal then
				local scale = d.maxTotal / total
				ox, oy, oz = ox * scale, oy * scale, oz * scale
			end
			offsets[i], offsets[i + 1], offsets[i + 2] = ox, oy, oz
			moved += 1
		end
	end
	return moved
end

-- The Impact that would have dealt a given amount of hit-zone damage (used to dent other players' cars,
-- for which only the zone numbers arrive).
function DamageModel.impactForDamage(damage: number, cfg: DamageConfig): number
	return damage / cfg.impactScale + cfg.impactOffset
end

return DamageModel
