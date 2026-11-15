-- BrawlBots: Captain Hiccup and friends, the labelled bots that fill empty Bumper Brawl slots (spec:
-- Game modes > Bumper Brawl; Onboarding > Brawl practice). Server side.
-- * A bot is a normal car model (VehicleBuilder) the server owns. It does not run the players' raycast
--   suspension: one ray holds it at ride height (a spring force), an AlignOrientation keeps it upright
--   and turns it, and a LinearVelocity in the ground plane drives it. Over a missing tile the ray finds
--   nothing and it drops into the foam like anyone else. Every client draws it like another player's car
--   (wheels, rider, damage), and its name label says BOT.
-- * Brains, 10 times a second: keep off warning tiles and edges (look 0.7 s ahead, head for the middle
--   of what is left), otherwise chase a car (a new pick every 2.5 to 5 s, one of the two nearest) and
--   charge it when close. The crew hiccup now and then (a short stall), so they are beatable.
-- * Practice bots drive slowly round the disc and never chase anyone.
-- * Damage: the server keeps each bot's DamageModel (bumps dent the zone that was hit, a dead engine
--   burns and explodes) and sends it as Damage.State under the bot's id, so it looks like any car.
-- Bot ids are negative (from -1001) so they never clash with a player, even Studio's test players.

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Damage = require(Shared.Damage)
local DamageModel = require(Shared.DamageModel)
local Looks = require(Shared.Looks)
local Net = require(Shared.Net)
local VehicleBuilder = require(Shared.VehicleBuilder)

local BrawlArena = require(script.Parent.BrawlArena)

local BrawlBots = {}

local cfg = Config.Brawl.bots
local DC = Config.Damage

-- Each bot's look (cosmetic only): paint, hat, outfit
local LOOKS = {
	{ paint = "paint_grape", hat = "hat_cap", outfit = "outfit_lifeguard" }, -- Captain Hiccup
	{ paint = "paint_tangerine", hat = "hat_cone", outfit = "outfit_robot" }, -- Dozer Dot
	{ paint = "paint_lava", hat = "hat_chef", outfit = "outfit_knight" }, -- Rusty
	{ paint = "paint_mint", hat = "hat_propeller", outfit = "outfit_astro" }, -- Gizmo Gus
	{ paint = "paint_sky", hat = "hat_crown", outfit = "outfit_dino" }, -- Wobble Bot
	{ paint = "paint_lime", hat = "hat_pip_foam", outfit = "outfit_racer" }, -- Pip
	{ paint = "paint_bubblegum", hat = "hat_golden_duck", outfit = "outfit_pajamas" }, -- Kaboom Cloud
}

export type Bot = {
	id: number,
	name: string,
	vehicleId: string,
	class: Config.ClassStats,
	model: Model,
	chassis: BasePart,
	mass: number,
	hover: number,
	lift: VectorForce,
	drive: LinearVelocity,
	align: AlignOrientation,
	heading: number,
	speed: number,
	wantHeading: number,
	wantSpeed: number,
	topSpeed: number,
	stunUntil: number,
	hiccupUntil: number,
	targetId: number?,
	retargetAt: number,
	brainClock: number,
	practice: boolean,
	grounded: boolean,
	out: boolean,
	damage: DamageModel.State,
	damageDirty: boolean,
	lastDamageSend: number,
	powerup: string?,
	useAt: number,
}

export type Car = { id: number, position: Vector3, velocity: Vector3, bot: boolean }

export type Context = {
	now: number,
	arena: BrawlArena.Arena,
	centre: Vector3, -- the middle of the tiles still standing
	cars: { Car }, -- every car still on the arena
	onExplode: (Bot) -> (),
	onUse: (Bot) -> (),
	hold: boolean?, -- the countdown: stay put
}

local random = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

local function forwardOf(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

local function angleDelta(from: number, to: number): number
	local d = (to - from) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

-- A bot's car, put down at cf. index picks the name and look (1 = Captain Hiccup).
function BrawlBots.spawn(id: number, index: number, cf: CFrame, practice: boolean): Bot
	local names = cfg.names
	local name = names[((index - 1) % #names) + 1]
	local vehicleId = if practice then "starter_buggy" else cfg.vehicles[((index - 1) % #cfg.vehicles) + 1]
	local def = Config.Vehicles[vehicleId]
	local class = Config.Classes[def.class]
	local model = VehicleBuilder.build(vehicleId, id)
	local look = LOOKS[((index - 1) % #LOOKS) + 1]
	Looks.vehicle(model, { paint = look.paint })
	model:SetAttribute("RiderOutfit", look.outfit)
	model:SetAttribute("RiderHat", look.hat)
	model:SetAttribute("IsBot", true)
	model:SetAttribute("BotName", name)
	local chassis = model.PrimaryPart :: BasePart
	local center = chassis:FindFirstChild("Center") :: Attachment
	local hover = -class.mountY + 0.7 * class.suspensionTravel + class.wheelRadius
	model:PivotTo(cf + Vector3.new(0, hover + 0.3, 0))

	local lift = Instance.new("VectorForce")
	lift.Name = "BotLift"
	lift.Attachment0 = center
	lift.RelativeTo = Enum.ActuatorRelativeTo.World
	lift.ApplyAtCenterOfMass = true
	lift.Force = Vector3.zero
	lift.Parent = chassis

	local align = Instance.new("AlignOrientation")
	align.Name = "BotAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = center
	align.Responsiveness = 18
	align.MaxTorque = 1e7
	align.CFrame = cf.Rotation
	align.Parent = chassis

	local drive = Instance.new("LinearVelocity")
	drive.Name = "BotDrive"
	drive.Attachment0 = center
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	drive.PrimaryTangentAxis = Vector3.xAxis
	drive.SecondaryTangentAxis = Vector3.zAxis
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.PlaneVelocity = Vector2.zero
	drive.MaxForce = 0
	drive.Parent = chassis

	model.Parent = Workspace:WaitForChild("Vehicles")
	chassis:SetNetworkOwner(nil)
	local heading = yawOf(cf.LookVector)
	local healthMultiplier = class.zoneHealthMultiplier * DC.modes.Brawl.health
	return {
		id = id,
		name = name,
		vehicleId = vehicleId,
		class = class,
		model = model,
		chassis = chassis,
		mass = chassis.AssemblyMass,
		hover = hover,
		lift = lift,
		drive = drive,
		align = align,
		heading = heading,
		speed = 0,
		wantHeading = heading,
		wantSpeed = 0,
		topSpeed = class.topSpeed * (if practice then cfg.practiceSpeed else cfg.speed),
		stunUntil = 0,
		hiccupUntil = 0,
		targetId = nil,
		retargetAt = 0,
		brainClock = random:NextNumber(0, 0.1),
		practice = practice,
		grounded = true,
		out = false,
		damage = DamageModel.new(healthMultiplier, DC),
		damageDirty = false,
		lastDamageSend = 0,
		powerup = nil,
		useAt = 0,
	}
end

function BrawlBots.despawn(bot: Bot)
	bot.out = true
	bot.model:Destroy()
end

-- A bump or shove: the speed change, then a moment coasting before the bot drives again
function BrawlBots.knock(bot: Bot, dv: Vector3, now: number)
	if bot.chassis.Parent == nil then
		return
	end
	bot.chassis.AssemblyLinearVelocity += dv
	bot.stunUntil = now + cfg.stun
end

-- Dent the zone facing `from` (a world position) by an impact value
function BrawlBots.hurt(bot: Bot, from: Vector3, impact: number)
	if bot.damage.exploded then
		return
	end
	local cf = bot.chassis.CFrame
	local toward = cf:PointToObjectSpace(from)
	local flat = Vector3.new(toward.X, 0, toward.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	local normal = -flat.Unit -- from the obstacle toward the car
	local side =
		Damage.contactSide(normal.X, 0, normal.Z, Config.Impact.landingNormalDot, Config.Impact.roofNormalDot)
	local half = bot.chassis.Size / 2
	local point = flat.Unit * math.max(half.X, half.Z)
	if DamageModel.applyImpact(bot.damage, side, impact, point.X, point.Z, half.X, half.Z, DC) > 0 then
		bot.damageDirty = true
	end
end

-- Pit Wrench: +50 health to every zone
function BrawlBots.heal(bot: Bot, amount: number)
	DamageModel.heal(bot.damage, amount)
	bot.damageDirty = true
end

local function sendDamage(bot: Bot, now: number)
	if not bot.damageDirty or now - bot.lastDamageSend < 1 / DC.sendMaxRate then
		return
	end
	bot.damageDirty = false
	bot.lastDamageSend = now
	Net.fireAll("Damage.State", bot.id, DamageModel.encode(bot.damage, DC))
end

---------------------------------------------------------------------------
-- Brains
---------------------------------------------------------------------------

local function pickTarget(bot: Bot, ctx: Context): number?
	local position = bot.chassis.Position
	local list = {}
	for _, car in ctx.cars do
		if car.id ~= bot.id then
			table.insert(list, { id = car.id, d = (car.position - position).Magnitude })
		end
	end
	if #list == 0 then
		return nil
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	return list[random:NextInteger(1, math.min(2, #list))].id
end

local function think(bot: Bot, ctx: Context)
	local now = ctx.now
	local position = bot.chassis.Position
	local velocity = bot.chassis.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local forward = forwardOf(bot.heading)
	local arena = ctx.arena

	if bot.practice then
		-- Slow laps round the middle of the disc
		local offset = position - arena.origin
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local radial = if flat.Magnitude > 1 then flat.Unit else Vector3.xAxis
		local tangent = Vector3.new(-radial.Z, 0, radial.X)
		local pull = (14 - flat.Magnitude) * 0.06
		bot.wantHeading = yawOf((tangent + radial * pull).Unit)
		bot.wantSpeed = bot.topSpeed
		return
	end

	if random:NextNumber() < cfg.hiccupChance * 0.1 then
		bot.hiccupUntil = now + cfg.hiccupTime
	end
	if now < bot.hiccupUntil then
		bot.wantSpeed = 0
		return
	end

	-- Edges and warning tiles first
	local ahead = position
		+ (if flatVelocity.Magnitude > 4 then flatVelocity else forward * 10) * cfg.edgeLook
	local near = position + forward * 8
	if
		not BrawlArena.isSafe(arena, position)
		or not BrawlArena.isSafe(arena, ahead)
		or not BrawlArena.isSafe(arena, near)
	then
		local toCentre = ctx.centre - position
		local flat = Vector3.new(toCentre.X, 0, toCentre.Z)
		if flat.Magnitude > 1 then
			bot.wantHeading = yawOf(flat.Unit)
		end
		-- Brake while facing away from safety, then go
		local facing = forward:Dot(flat.Magnitude > 1 and flat.Unit or forward)
		bot.wantSpeed = if facing > 0.5 then bot.topSpeed * 0.6 else bot.topSpeed * 0.15
		return
	end

	-- Chase
	if bot.targetId == nil or now >= bot.retargetAt then
		bot.targetId = pickTarget(bot, ctx)
		bot.retargetAt = now + random:NextNumber(cfg.retarget[1], cfg.retarget[2])
	end
	local target: Car? = nil
	for _, car in ctx.cars do
		if car.id == bot.targetId then
			target = car
		end
	end
	if target == nil then
		bot.targetId = nil
		bot.wantSpeed = bot.topSpeed * 0.3
		return
	end
	local lead = target.position + target.velocity * 0.3 - position
	local flat = Vector3.new(lead.X, 0, lead.Z)
	if flat.Magnitude > 1 then
		bot.wantHeading = yawOf(flat.Unit)
	end
	local aligned = forward:Dot(if flat.Magnitude > 1 then flat.Unit else forward)
	bot.wantSpeed = if flat.Magnitude < 45 and aligned > 0.8
		then bot.topSpeed
		else bot.topSpeed * (if aligned > 0.3 then 0.75 else 0.35)
	-- Powerups: use one a moment after picking it up
	if bot.powerup and now >= bot.useAt then
		ctx.onUse(bot)
	end
end

---------------------------------------------------------------------------
-- Physics and damage, every frame
---------------------------------------------------------------------------

local function physics(bot: Bot, dt: number, now: number)
	local chassis = bot.chassis
	local position = chassis.Position
	rayParams.FilterDescendantsInstances = { Workspace:FindFirstChild("Vehicles") :: Instance }
	local hit = Workspace:Raycast(position, Vector3.new(0, -(bot.hover + 4), 0), rayParams)
	local grounded = hit ~= nil and hit.Distance <= bot.hover + 1.5
	bot.grounded = grounded
	local velocity = chassis.AssemblyLinearVelocity
	local g = Workspace.Gravity
	if grounded and hit then
		local omega = 2 * math.pi * 2.5
		local accel = g + omega * omega * (bot.hover - hit.Distance) - 2 * 0.8 * omega * velocity.Y
		bot.lift.Force = Vector3.new(0, bot.mass * math.clamp(accel, 0, g * 4), 0)
	else
		bot.lift.Force = Vector3.zero
	end

	local turn = math.rad(cfg.turnRate) * dt
	bot.heading += math.clamp(angleDelta(bot.heading, bot.wantHeading), -turn, turn)
	bot.align.CFrame = CFrame.Angles(0, bot.heading, 0)

	local forward = forwardOf(bot.heading)
	local stunned = now < bot.stunUntil
	if stunned or not grounded or bot.out or bot.damage.exploded then
		bot.drive.MaxForce = 0
		bot.speed = math.max(0, Vector3.new(velocity.X, 0, velocity.Z):Dot(forward))
		return
	end
	local step = cfg.accel * dt
	bot.speed += math.clamp(bot.wantSpeed - bot.speed, -step * 2, step)
	bot.drive.MaxForce = bot.mass * cfg.accel * 3
	local planar = forward * bot.speed
	bot.drive.PlaneVelocity = Vector2.new(planar.X, planar.Z)
end

-- Move every bot on (brains at 10 Hz, physics every frame)
function BrawlBots.step(bots: { Bot }, dt: number, ctx: Context)
	for _, bot in bots do
		if bot.chassis.Parent == nil then
			continue
		end
		bot.brainClock += dt
		if ctx.hold then
			bot.wantSpeed = 0
		elseif bot.brainClock >= 0.1 then
			bot.brainClock = 0
			if not bot.out then
				think(bot, ctx)
			end
		end
		physics(bot, dt, ctx.now)
		-- A dead engine burns, then blows
		local result = DamageModel.tick(bot.damage, dt, DC.modes.Brawl, DC)
		if result then
			bot.damageDirty = true
			if result == "explode" then
				bot.chassis.AssemblyLinearVelocity += Vector3.new(0, DC.ownExplosionHop, 0)
				ctx.onExplode(bot)
			end
		end
		sendDamage(bot, ctx.now)
	end
end

return BrawlBots
