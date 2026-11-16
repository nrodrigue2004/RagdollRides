-- BrawlService: Bumper Brawl in Cinder Cove (spec: Game modes > Bumper Brawl; Session units > Brawl
-- round; Brawl screens; Onboarding > Brawl practice; Network model; Anti-exploit > Brawl hit spoofing).
-- Runs only in the Brawl places (Shared/Place). One round at a time per server, on the shared round
-- state machine (RoundManager):
-- * Lobby: everyone not in practice waits in the foam-ball pen (and is queued). The round starts
--   botFill s (10 casual, 20 ranked) after the first player is in, or at once with 8 players. Bots
--   (Captain Hiccup and friends, labelled BOT) fill the empty slots up to 8 cars.
-- * Countdown: the round's arena is built (arenas take turns), every car is put on its spawn tile
--   facing the middle, held for 3 s.
-- * Play, 120 s: tiles warn and drop on the BrawlMath plan; sudden death to 150 s. A car is out when
--   it falls under the tiles into the foam or explodes. KO credit: the last car that bumped it within
--   4 s (an explosion: the last bumper this round). The round ends with one car left, when no player
--   is left on the arena, or at 150 s (most KOs wins, then most damage dealt).
-- * Bumps: the hitter's device reports (Brawl.Hit); the server checks the pair cooldown, the distance
--   between the two cars and the speed, then sends the capped knockback to the hit car's owner
--   (Brawl.Result). Bots' bumps are found here. Bots are pushed here.
-- * Powerups: Gully the Gull drops one every 12 s on a standing tile; drive over it to hold it, ACTION
--   (Brawl.Powerup) to use it: Spring Bumper, Bubble Shield, Pit Wrench, Honk Wave.
-- * Results: places, KOs, coins (20 + 5 per KO, max 4, + 40 for a win; 900 a day; idle rounds earn
--   nothing), mastery (1 per bump, 10 for surviving), quests, stats and ranked points. Queue next
--   skips the card. Out drivers go back to the pen at once and can watch and cheer the finalists.
-- * Practice (first visit to Cinder Cove Casual): a small disc with a slow bot 3 car lengths ahead,
--   knockback x1.5; knock it off for 20 coins, then a second bot, then into the pen. Skippable.
-- * Ranked (Cinder Cove Ranked): points after every round (BrawlMath), quitting mid-round costs the
--   quit penalty, the season soft reset and rewards on arrival.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local BrawlMath = require(Shared.BrawlMath)
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Damage = require(Shared.Damage)
local DamageModel = require(Shared.DamageModel)
local Net = require(Shared.Net)
local Place = require(Shared.Place)
local ShopMath = require(Shared.ShopMath)
local TracksMath = require(Shared.TracksMath)

local Services = script.Parent
local Analytics = require(Services.Analytics)
local BrawlArena = require(Services.BrawlArena)
local BrawlBots = require(Services.BrawlBots)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local LiveCounts = require(Services.LiveCounts)
local QuestService = require(Services.QuestService)
local RoundManager = require(Services.RoundManager)
local ShopService = require(Services.ShopService)
local TeleportHub = require(Services.TeleportHub)
local VehicleService = require(Services.VehicleService)

local BrawlService = {}

local cfg = Config.Brawl
local DC = Config.Damage
local ranked = false
local round: any = nil
local nextBotId = -1000
local random = Random.new()

-- An entrant: a player or a bot in this round
type Entrant = {
	id: number,
	name: string,
	player: Player?,
	bot: BrawlBots.Bot?,
	vehicleId: string,
	outAt: number?,
	how: string?,
	kos: number,
	damage: number,
	bumps: number,
	lastBy: number?,
	lastAt: number?,
	distance: number,
	lastPos: Vector3?,
	powerup: string?,
	springLeft: number,
	springUntil: number,
	shieldUntil: number,
	skipped: boolean,
	quit: boolean,
}

type Practice = {
	slot: number,
	arena: BrawlArena.Arena,
	bot: BrawlBots.Bot?,
	knocked: number,
	lastHit: number,
	done: boolean,
}

local practices: { [Player]: Practice } = {}
local inPen: { [Player]: boolean } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function vehicleFor(player: Player): string
	local profile = DataService.get(player)
	if profile and VehicleService.mayDrive(player, profile.equippedVehicle) then
		return profile.equippedVehicle
	end
	return Config.DefaultVehicle
end

local function chassisOf(e: Entrant): BasePart?
	if e.bot then
		local chassis = e.bot.chassis
		return if chassis.Parent then chassis else nil
	end
	local model = e.player and VehicleService.getVehicle(e.player :: Player)
	return model and model.PrimaryPart
end

local function classOf(e: Entrant): Config.ClassStats
	local def = Config.Vehicles[e.vehicleId] or Config.Vehicles[Config.DefaultVehicle]
	return Config.Classes[def.class]
end

local function event(payload: { [string]: any })
	Net.fireAll("Brawl.Event", payload)
end

local function setModelAttribute(e: Entrant, name: string, value: any)
	local chassis = chassisOf(e)
	local model = chassis and chassis.Parent
	if model then
		model:SetAttribute(name, value)
	end
end

---------------------------------------------------------------------------
-- The pen
---------------------------------------------------------------------------

local penIndex = 0
local function toPen(player: Player)
	if player.Parent ~= Players then
		return
	end
	penIndex += 1
	inPen[player] = true
	player:SetAttribute("BrawlState", "pen")
	VehicleService.spawn(player, vehicleFor(player), BrawlArena.penSpawn(penIndex))
end

---------------------------------------------------------------------------
-- Bumps
---------------------------------------------------------------------------

local function data(): { [string]: any }
	return round.data
end

local function entrantById(id: number): Entrant?
	local d = data()
	return d.entrants and d.entrants[id]
end

local function entrantOf(player: Player): Entrant?
	return entrantById(player.UserId)
end

local function alive(e: Entrant?): boolean
	return e ~= nil and e.outAt == nil and not e.quit
end

local function knock(target: Entrant, dv: Vector3, by: number, t: number)
	if target.bot then
		BrawlBots.knock(target.bot :: BrawlBots.Bot, dv, t)
	elseif target.player then
		Net.fire("Brawl.Result", target.player, { kind = "knock", dv = dv, by = by })
	end
	target.lastBy = by
	target.lastAt = t
end

-- An accepted bump: knockback on the car that was hit, credit and counts for the hitter
local function applyBump(a: Entrant, t: Entrant, closing: number, at: number, extra: number?)
	local pa, pt = chassisOf(a), chassisOf(t)
	if pa == nil or pt == nil then
		return
	end
	local d = data()
	d.pairTimes[a.id .. ":" .. t.id] = at
	if at < t.shieldUntil then
		-- Bubble Shield: immune to knockback (the hitter still bumped)
		event({ kind = "shieldBlock", id = t.id })
		return
	end
	local ca, ct = classOf(a), classOf(t)
	local mult = extra or 1
	if a.springLeft > 0 and at < a.springUntil then
		mult *= cfg.spring.mult
		a.springLeft -= 1
		if a.springLeft <= 0 then
			setModelAttribute(a, "BrawlSpring", nil)
		end
	end
	local power = BrawlMath.knockback(
		closing,
		ca.relativeMass,
		ct.relativeMass,
		ct.knockbackTakenMultiplier,
		mult,
		cfg.knockback
	)
	local direction = flat(pt.Position - pa.Position)
	direction = if direction.Magnitude > 1e-3 then direction.Unit else flat(pa.CFrame.LookVector).Unit
	local dv = direction * power + Vector3.new(0, power * cfg.knockback.up, 0)
	knock(t, dv, a.id, at)
	-- Damage dealt (the tiebreak): the impact this bump made on the car that was hit
	local impact = Damage.impact(closing, Damage.massFactor(ct.relativeMass, ca.relativeMass, Config.Impact))
	a.damage += impact
	a.bumps += 1
	if t.bot then
		BrawlBots.hurt(t.bot :: BrawlBots.Bot, pa.Position, impact)
	end
	if a.player then
		Net.fire("Brawl.Result", a.player, { kind = "hit", target = t.id, power = power })
		ShopService.addMastery(a.player, Config.Progression.masteryPoints.bump)
		QuestService.event(a.player, "bump", 1)
	end
end

-- The edge-to-edge gap between two cars (a circle the size of each car's average half extent)
local function radius(part: BasePart): number
	return (part.Size.X + part.Size.Z) / 4
end

local function onHit(player: Player, targetId: number, speed: number, _normal: Vector3)
	local practice = practices[player]
	if practice then
		local bot = practice.bot
		if bot and bot.id == targetId and not bot.out then
			local chassis = VehicleService.getVehicle(player)
			local pa = chassis and chassis.PrimaryPart
			if pa == nil then
				return
			end
			local gap = (flat(pa.Position) - flat(bot.chassis.Position)).Magnitude
				- radius(pa)
				- radius(bot.chassis)
			local closing = BrawlMath.checkHit({
				reported = speed,
				attackerTop = Config.Classes[Config.Vehicles[vehicleFor(player)].class].topSpeed,
				targetSpeed = bot.chassis.AssemblyLinearVelocity.Magnitude,
				gap = gap,
				sinceLast = now() - practice.lastHit,
			}, {
				speedSlack = cfg.hitCheck.speedSlack,
				gap = cfg.hitCheck.gap,
				pairCooldown = cfg.knockback.pairCooldown,
			})
			if closing then
				practice.lastHit = now()
				local class = Config.Classes[Config.Vehicles[vehicleFor(player)].class]
				local power = BrawlMath.knockback(
					closing,
					class.relativeMass,
					bot.class.relativeMass,
					bot.class.knockbackTakenMultiplier,
					cfg.practice.knockbackBonus,
					cfg.knockback
				)
				local direction = flat(bot.chassis.Position - pa.Position)
				direction = if direction.Magnitude > 1e-3 then direction.Unit else Vector3.zAxis
				BrawlBots.knock(bot, direction * power + Vector3.new(0, power * cfg.knockback.up, 0), now())
				Net.fire("Brawl.Result", player, { kind = "hit", target = bot.id, power = power })
			end
		end
		return
	end
	if round == nil or round:phase() ~= "Play" then
		return
	end
	local a, t = entrantOf(player), entrantById(targetId)
	if not alive(a) or not alive(t) or a == t then
		return
	end
	local attacker, target = a :: Entrant, t :: Entrant
	local pa, pt = chassisOf(attacker), chassisOf(target)
	if pa == nil or pt == nil then
		return
	end
	local at = now()
	local gap = (flat(pa.Position) - flat(pt.Position)).Magnitude - radius(pa) - radius(pt)
	local closing, why = BrawlMath.checkHit({
		reported = speed,
		attackerTop = classOf(attacker).topSpeed,
		targetSpeed = pt.AssemblyLinearVelocity.Magnitude,
		gap = gap,
		sinceLast = at - (data().pairTimes[attacker.id .. ":" .. target.id] or -math.huge),
	}, {
		speedSlack = cfg.hitCheck.speedSlack,
		gap = cfg.hitCheck.gap,
		pairCooldown = cfg.knockback.pairCooldown,
	})
	if closing == nil then
		if why ~= "cooldown" then
			data().ignored += 1
		end
		return
	end
	applyBump(attacker, target, closing, at)
end

-- Bots are the hitters the server sees itself (30 times a second)
local function botContacts(list: { Entrant }, at: number)
	local d = data()
	for _, a in list do
		if a.bot == nil or not alive(a) then
			continue
		end
		local pa = chassisOf(a)
		if pa == nil then
			continue
		end
		for _, t in list do
			if t == a or not alive(t) then
				continue
			end
			local pt = chassisOf(t)
			if pt == nil then
				continue
			end
			local offset = flat(pt.Position - pa.Position)
			local distance = offset.Magnitude
			if distance < 1e-3 or distance > radius(pa) + radius(pt) + 0.75 then
				continue
			end
			if math.abs(pt.Position.Y - pa.Position.Y) > 4 then
				continue
			end
			local direction = offset / distance
			local own = pa.AssemblyLinearVelocity:Dot(direction)
			local closing = own - pt.AssemblyLinearVelocity:Dot(direction)
			if own < cfg.knockback.minClosing or closing < cfg.knockback.minClosing then
				continue
			end
			if at - (d.pairTimes[a.id .. ":" .. t.id] or -math.huge) < cfg.knockback.pairCooldown then
				continue
			end
			applyBump(a, t, closing, at)
		end
	end
end

---------------------------------------------------------------------------
-- Powerups
---------------------------------------------------------------------------

local function clearPowerupParts()
	local d = data()
	for _, p in d.powerups or {} do
		if p.part.Parent then
			p.part:Destroy()
		end
	end
	d.powerups = {}
end

local function spawnPowerup(at: number)
	local d = data()
	local arena = d.arena :: BrawlArena.Arena
	local taken = {}
	for _, p in d.powerups do
		taken[p.tile] = true
	end
	local choices = {}
	for _, index in BrawlArena.standing(arena) do
		if not taken[index] then
			table.insert(choices, index)
		end
	end
	if #choices == 0 then
		return
	end
	local tile = choices[random:NextInteger(1, #choices)]
	local kinds = cfg.powerups.kinds
	local kind = kinds[random:NextInteger(1, #kinds)]
	local part = Instance.new("Part")
	part.Name = "Powerup"
	part.Size = Vector3.new(3.5, 3.5, 3.5)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Transparency = 0.15
	part.CFrame = CFrame.new(BrawlArena.tileTop(arena, tile) + Vector3.new(0, 2.5, 0))
	part:SetAttribute("Kind", kind)
	part:SetAttribute("LandAt", at + cfg.powerups.dropTime)
	game:GetService("CollectionService"):AddTag(part, "BrawlPowerup")
	part.Parent = arena.folder
	table.insert(d.powerups, { part = part, kind = kind, tile = tile, landAt = at + cfg.powerups.dropTime })
	event({ kind = "gully", at = part.Position, powerup = kind })
end

local function grabPowerups(list: { Entrant }, at: number)
	local d = data()
	local keep = {}
	for _, p in d.powerups do
		local taken = false
		if at >= p.landAt and p.part.Parent then
			for _, e in list do
				if alive(e) and e.powerup == nil then
					local chassis = chassisOf(e)
					if
						chassis
						and (chassis.Position - p.part.Position).Magnitude <= cfg.powerups.pickupRadius
					then
						e.powerup = p.kind
						if e.bot then
							local bot = e.bot :: BrawlBots.Bot
							bot.powerup = p.kind
							bot.useAt = at + random:NextNumber(cfg.bots.useDelay[1], cfg.bots.useDelay[2])
						end
						if e.player then
							Net.fire("Brawl.Event", e.player, { kind = "held", powerup = p.kind })
						end
						event({ kind = "grab", id = e.id, powerup = p.kind, at = p.part.Position })
						taken = true
						break
					end
				end
			end
		end
		if taken or BrawlArena.isGone(d.arena, p.tile) or d.arena.state[p.tile] == "warn" then
			p.part:Destroy()
		else
			table.insert(keep, p)
		end
	end
	d.powerups = keep
end

local function usePowerup(e: Entrant)
	local kind = e.powerup
	if kind == nil or not alive(e) then
		return
	end
	local at = now()
	e.powerup = nil
	if e.bot then
		(e.bot :: BrawlBots.Bot).powerup = nil
	end
	local chassis = chassisOf(e)
	if kind == "spring" then
		e.springLeft = cfg.spring.bumps
		e.springUntil = at + cfg.spring.seconds
		setModelAttribute(e, "BrawlSpring", e.springUntil)
	elseif kind == "shield" then
		e.shieldUntil = at + cfg.shield.seconds
		setModelAttribute(e, "BrawlShield", e.shieldUntil)
	elseif kind == "wrench" then
		if e.bot then
			BrawlBots.heal(e.bot :: BrawlBots.Bot, cfg.wrench.heal)
		elseif e.player then
			Net.fire("Brawl.Result", e.player, { kind = "heal", amount = cfg.wrench.heal })
		end
	elseif kind == "honk" and chassis then
		for _, other in data().order do
			local t = entrantById(other)
			if t and t ~= e and alive(t) and at >= t.shieldUntil then
				local pt = chassisOf(t)
				if pt then
					local offset = flat(pt.Position - chassis.Position)
					if offset.Magnitude <= cfg.honk.radius then
						local direction = if offset.Magnitude > 1e-3 then offset.Unit else Vector3.xAxis
						knock(
							t,
							direction * cfg.honk.speed + Vector3.new(0, cfg.honk.speed * 0.2, 0),
							e.id,
							at
						)
					end
				end
			end
		end
	end
	event({ kind = "used", id = e.id, powerup = kind, at = chassis and chassis.Position or nil })
end

---------------------------------------------------------------------------
-- KOs
---------------------------------------------------------------------------

-- An explosion's shockwave on the bots near it (players' devices push their own cars)
local function shockwave(position: Vector3, from: Entrant)
	local at = now()
	for _, id in data().order or {} do
		local t = entrantById(id)
		if t and t ~= from and t.bot and alive(t) then
			local bot = t.bot :: BrawlBots.Bot
			local offset = bot.chassis.Position - position
			local push, up, damage = DamageModel.shockwave(offset.Magnitude, DC)
			if push > 0 then
				local outward = flat(offset)
				outward = if outward.Magnitude > 1e-3 then outward.Unit else Vector3.xAxis
				knock(
					t,
					outward * push * bot.class.knockbackTakenMultiplier + Vector3.new(0, up, 0),
					from.id,
					at
				)
				BrawlBots.hurt(bot, position, DamageModel.impactForDamage(damage, DC))
			end
		end
	end
end

local function eliminate(e: Entrant, how: string)
	if not alive(e) then
		return
	end
	local at = now()
	e.outAt = at
	e.how = how
	local window = if how == "exploded" then nil else cfg.knockback.koWindow
	local creditId = BrawlMath.koCredit(e.lastBy, e.lastAt, at, window)
	local killer = creditId and entrantById(creditId)
	if killer and killer ~= e then
		killer.kos += 1
		if killer.player then
			QuestService.event(killer.player, "brawlKO", 1)
		end
	end
	local chassis = chassisOf(e)
	if how == "exploded" and chassis then
		shockwave(chassis.Position, e)
	end
	event({
		kind = "ko",
		id = e.id,
		by = if killer and killer ~= e then killer.id else nil,
		how = how,
		at = chassis and chassis.Position or nil,
	})
	if e.player then
		local player = e.player :: Player
		player:SetAttribute("BrawlState", "out")
		task.delay(2, function()
			if player.Parent == Players and player:GetAttribute("BrawlState") == "out" then
				toPen(player)
			end
		end)
	elseif e.bot then
		local bot = e.bot :: BrawlBots.Bot
		bot.out = true
		task.delay(2.5, function()
			if bot.model.Parent then
				BrawlBots.despawn(bot)
			end
		end)
	end
	round:broadcast()
end

local function list(): { Entrant }
	local out = {}
	for _, id in data().order or {} do
		table.insert(out, data().entrants[id])
	end
	return out
end

local function checkOver()
	local d = data()
	local carsLeft, playersLeft = 0, 0
	for _, e in list() do
		if alive(e) then
			carsLeft += 1
			if e.player then
				playersLeft += 1
			end
		end
	end
	if carsLeft <= 1 or playersLeft == 0 then
		d.over = true
	end
end

---------------------------------------------------------------------------
-- The round (RoundManager mode)
---------------------------------------------------------------------------

local mode = {}

function mode.init(r)
	local d = r.data
	table.clear(d)
	d.entrants = {}
	d.order = {}
	d.pairTimes = {}
	d.powerups = {}
	d.ignored = 0
	d.over = false
	d.seed = (os.time() + r.state.round * 7919) % 2147483646 + 1
	local arena = BrawlArena.buildRound(r.state.round)
	d.arena = arena
	d.plan = BrawlMath.dropPlan(arena.layout, d.seed, cfg)
	d.planIndex = 1
	d.pending = {}
	-- Players first, then bots to fill the slots
	local entrants: { Entrant } = {}
	for _, player in r.players do
		if #entrants >= cfg.maxPlayers then
			break
		end
		if player.Parent == Players and DataService.get(player) and practices[player] == nil then
			table.insert(entrants, {
				id = player.UserId,
				name = player.DisplayName,
				player = player,
				bot = nil,
				vehicleId = vehicleFor(player),
				kos = 0,
				damage = 0,
				bumps = 0,
				distance = 0,
				springLeft = 0,
				springUntil = 0,
				shieldUntil = 0,
				skipped = false,
				quit = false,
			})
		end
	end
	local humans = #entrants
	local spawns = BrawlMath.spawnTiles(arena.layout, math.max(cfg.fillTo, humans))
	local function spawnCFrame(i: number): CFrame
		local top = BrawlArena.tileTop(arena, spawns[i])
		local toward = flat(arena.origin - top)
		local look = if toward.Magnitude > 1e-3 then toward.Unit else Vector3.new(0, 0, -1)
		return CFrame.lookAt(top, top + look)
	end
	for i, e in entrants do
		local player = e.player :: Player
		inPen[player] = nil
		player:SetAttribute("BrawlState", "arena")
		VehicleService.spawn(player, e.vehicleId, spawnCFrame(i))
	end
	local botIndex = random:NextInteger(0, #cfg.bots.names - 1)
	for i = humans + 1, cfg.fillTo do
		nextBotId -= 1
		botIndex += 1
		local bot = BrawlBots.spawn(nextBotId, botIndex, spawnCFrame(i), false)
		table.insert(entrants, {
			id = bot.id,
			name = bot.name,
			player = nil,
			bot = bot,
			vehicleId = bot.vehicleId,
			kos = 0,
			damage = 0,
			bumps = 0,
			distance = 0,
			springLeft = 0,
			springUntil = 0,
			shieldUntil = 0,
			skipped = false,
			quit = false,
		})
	end
	for _, e in entrants do
		d.entrants[e.id] = e
		table.insert(d.order, e.id)
	end
	d.bots = humans < #entrants
	d.botCount = #entrants - humans
end

function mode.start(r)
	local d = r.data
	d.goAt = now()
	for _, player in r.players do
		Analytics.modeStep(player, Analytics.MODE.roundStart)
	end
	d.nextPowerupAt = d.goAt + cfg.powerups.firstAt
	for _, e in list() do
		local chassis = chassisOf(e)
		e.lastPos = chassis and chassis.Position or nil
	end
	if ranked then
		for _, e in list() do
			if e.player then
				local profile = DataService.get(e.player)
				if profile and not profile.tut.ranked then
					profile.tut.ranked = true
					DataService.changed(e.player)
				end
			end
		end
	end
end

-- 10 times a second while playing
function mode.tick(r, _dt)
	local d = r.data
	local at = now()
	local arena = d.arena :: BrawlArena.Arena
	local elapsed = at - d.goAt
	-- Warnings, then drops
	while d.plan[d.planIndex] and elapsed >= d.plan[d.planIndex].at - cfg.warnTime do
		local drop = d.plan[d.planIndex]
		BrawlArena.warn(arena, drop.tile, d.goAt + drop.at - cfg.warnTime, d.goAt + drop.at)
		table.insert(d.pending, drop)
		d.planIndex += 1
	end
	local still = {}
	for _, drop in d.pending do
		if elapsed >= drop.at then
			BrawlArena.drop(arena, drop.tile)
		else
			table.insert(still, drop)
		end
	end
	d.pending = still
	if not d.suddenDeath and elapsed >= cfg.roundLength then
		d.suddenDeath = true
		event({ kind = "suddenDeath" })
		r:broadcast()
	end
	-- Out: under the tiles, or blown up
	local koY = arena.origin.Y - cfg.koDepth
	for _, e in list() do
		if not alive(e) then
			continue
		end
		local chassis = chassisOf(e)
		if chassis == nil then
			if e.player and e.player.Parent ~= Players then
				eliminate(e, "left")
			end
			continue
		end
		local position = chassis.Position
		if position.Y < koY then
			eliminate(e, "fell")
			continue
		end
		if e.bot and e.bot.damage.exploded then
			eliminate(e, "exploded")
			continue
		end
		if e.lastPos then
			e.distance += (flat(position) - flat(e.lastPos)).Magnitude
		end
		e.lastPos = position
	end
	-- Gully's drops
	if at >= d.nextPowerupAt then
		d.nextPowerupAt += cfg.powerups.every
		if #d.powerups < cfg.powerups.maxOnArena then
			spawnPowerup(at)
		end
	end
	grabPowerups(list(), at)
	checkOver()
end

local function idle(e: Entrant): boolean
	return e.distance < cfg.afkDistance and e.bumps == 0
end

local function rankView(record: BrawlMath.Ranked): { [string]: any }
	local tier = BrawlMath.tierOf(record.points, cfg.ranked)
	return {
		points = record.points,
		tier = tier,
		tierName = BrawlMath.tierName(tier, cfg.ranked),
		progress = (record.points % cfg.ranked.tierSize) / cfg.ranked.tierSize,
		placementsLeft = record.placementsLeft,
	}
end

function mode.finish(r)
	local d = r.data
	if d.order == nil then
		return
	end
	local entrants = list()
	local placings = BrawlMath.placements(entrants)
	local winner = placings[1] and entrantById(placings[1].id)
	local botWon = winner ~= nil and winner.bot ~= nil
	local places = {}
	local placeOf: { [number]: number } = {}
	for _, p in placings do
		local e = entrantById(p.id) :: Entrant
		placeOf[p.id] = p.place
		table.insert(places, { id = e.id, name = e.name, bot = e.bot ~= nil, place = p.place, kos = e.kos })
	end
	local duration = now() - (d.goAt or now())
	for _, e in entrants do
		local player = e.player
		if player == nil or player.Parent ~= Players or e.quit then
			continue
		end
		local profile = DataService.get(player)
		if profile == nil then
			continue
		end
		local place = placeOf[e.id]
		local wasIdle = idle(e)
		local survived = e.outAt == nil
		-- Coins: boosts, then the Brawl daily cap (it rises with rebirths)
		local want = BrawlMath.coins(place, e.kos, wasIdle, cfg.coins)
		local cap = math.floor(cfg.dailyCap * ShopMath.capMultiplier(profile.rebirths) + 0.5)
		local boost = EconomyService.boostFor(player)
		local coins = TracksMath.applyCap(want, boost, profile.daily.coinsByMode.brawl or 0, cap)
		local got = EconomyService.grantCoins(player, coins, "brawl", "Brawl_round")
		local capped = got < math.floor(want * (1 + boost) + 0.5)
		if not wasIdle then
			profile.stats.brawlRounds = (profile.stats.brawlRounds or 0) + 1
			QuestService.event(player, "brawlRound", 1)
		end
		profile.stats.kos = (profile.stats.kos or 0) + e.kos
		if place == 1 then
			profile.stats.brawlWins = (profile.stats.brawlWins or 0) + 1
			QuestService.event(player, "brawlWin", 1)
		end
		if survived and not wasIdle then
			ShopService.addMastery(player, Config.Progression.masteryPoints.brawlRound)
			QuestService.event(player, "brawlSurvive", 1)
		end
		profile.flags.lastMode = "brawl"
		local rankedView = nil
		if ranked then
			local delta = BrawlMath.rankedDelta(place, #placings, wasIdle, botWon, cfg.ranked)
			local record, applied, rankUp = BrawlMath.applyRanked(profile.ranked, delta, cfg.ranked)
			profile.ranked = record
			rankedView = rankView(record)
			rankedView.delta = applied
			rankedView.rankUp = rankUp
			rankedView.botWon = botWon
		end
		DataService.changed(player)
		Net.fire("Brawl.Round", player, {
			arena = d.arena and d.arena.name or "",
			places = places,
			mine = {
				place = place,
				count = #placings,
				kos = e.kos,
				coins = got,
				capped = capped,
				idle = wasIdle,
				survived = survived,
				ranked = rankedView,
			},
			seconds = cfg.results,
		})
		Analytics.modeStep(player, Analytics.MODE.roundEnd)
		pcall(function()
			game:GetService("AnalyticsService"):LogCustomEvent(player, "brawl_round", place, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tostring(e.kos),
				[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = if ranked then "ranked" else "casual",
				[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = string.format(
					"bots %d / %ds",
					d.botCount or 0,
					math.floor(duration)
				),
			})
		end)
	end
	if d.ignored > 0 then
		print(string.format("[Brawl] round %d: %d bump reports ignored", r.state.round, d.ignored))
	end
	clearPowerupParts()
end

function mode.cleanup(r)
	local d = r.data
	for _, e in list() do
		if e.bot then
			if e.bot.model.Parent then
				BrawlBots.despawn(e.bot)
			end
		elseif e.player and e.player.Parent == Players and practices[e.player] == nil then
			toPen(e.player)
		end
	end
	clearPowerupParts()
	if d.arena then
		BrawlArena.destroy(d.arena)
	end
	table.clear(d)
end

function mode.counts(r)
	local phase = r:phase()
	local d = r.data
	if phase == "Lobby" or phase == "Requeue" then
		return { players = #r.players }
	end
	local humans, skipped = 0, 0
	for _, e in list() do
		if e.player and e.player.Parent == Players and not e.quit then
			humans += 1
			if e.skipped then
				skipped += 1
			end
		end
	end
	if phase == "Play" then
		return { players = 1, finished = if d.over then 1 else 0 }
	elseif phase == "Results" then
		return { players = humans, skipped = skipped }
	end
	return { players = humans }
end

function mode.info(r, player: Player)
	local d = r.data
	local out: { [string]: any } = { ranked = ranked, lobbyFill = r.rules.lobbyFill }
	if d.order then
		local entrants = {}
		local left = 0
		for _, e in list() do
			table.insert(entrants, {
				id = e.id,
				name = e.name,
				bot = e.bot ~= nil,
				out = not alive(e),
				kos = e.kos,
			})
			if alive(e) then
				left += 1
			end
		end
		out.entrants = entrants
		out.left = left
		out.goAt = d.goAt
		out.roundLength = cfg.roundLength
		out.maxLength = cfg.maxLength
		out.suddenDeath = d.suddenDeath == true
		out.arena = d.arena and { id = d.arena.id, name = d.arena.name, origin = d.arena.origin } or nil
		local mine = d.entrants[player.UserId]
		out.entrant = mine ~= nil
		out.out = mine ~= nil and not alive(mine)
	else
		local names = {}
		for _, p in r.players do
			table.insert(names, p.DisplayName)
		end
		out.waiting = names
	end
	return out
end

---------------------------------------------------------------------------
-- Practice (first visit)
---------------------------------------------------------------------------

local function practiceSpot(practice: Practice): CFrame
	local o = practice.arena.origin
	local position = o + Vector3.new(0, 0, cfg.practice.botAhead / 2)
	return CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
end

local function practiceBot(player: Player, practice: Practice)
	nextBotId -= 1
	local o = practice.arena.origin
	local position = o + Vector3.new(0, 0, -cfg.practice.botAhead / 2)
	local bot = BrawlBots.spawn(
		nextBotId,
		practice.knocked + 1,
		CFrame.lookAt(position, position + Vector3.xAxis),
		true
	)
	practice.bot = bot
	Net.fire("Brawl.Event", player, {
		kind = "practice",
		step = practice.knocked + 1,
		of = cfg.practice.botsToKnock,
		bot = bot.id,
	})
end

local function endPractice(player: Player, finished: boolean)
	local practice = practices[player]
	if practice == nil then
		return
	end
	practices[player] = nil
	if practice.bot and practice.bot.model.Parent then
		BrawlBots.despawn(practice.bot)
	end
	BrawlArena.destroy(practice.arena)
	local profile = DataService.get(player)
	if profile and not profile.tut.brawl then
		profile.tut.brawl = true
		DataService.changed(player)
		if finished then
			EconomyService.funnel(player, 10, "Brawl practice")
		end
	end
	if player.Parent == Players then
		Net.fire("Brawl.Event", player, { kind = "practiceDone", skipped = not finished })
		toPen(player)
		round:add(player)
	end
end

local function startPractice(player: Player)
	local used = {}
	for _, p in practices do
		used[p.slot] = true
	end
	local slot = 0
	while used[slot] do
		slot += 1
	end
	if slot >= cfg.practice.slots then
		-- Every disc is busy: straight to the pen (the practice is offered next visit)
		toPen(player)
		round:add(player)
		return
	end
	local practice: Practice = {
		slot = slot,
		arena = BrawlArena.buildPractice(slot),
		bot = nil,
		knocked = 0,
		lastHit = -math.huge,
		done = false,
	}
	practices[player] = practice
	player:SetAttribute("BrawlState", "practice")
	VehicleService.spawn(player, vehicleFor(player), practiceSpot(practice))
	practiceBot(player, practice)
end

local function tickPractice(player: Player, practice: Practice)
	local bot = practice.bot
	if practice.done or bot == nil then
		return
	end
	local koY = practice.arena.origin.Y - cfg.koDepth
	if bot.chassis.Position.Y < koY and not bot.out then
		bot.out = true
		practice.knocked += 1
		Net.fire(
			"Brawl.Event",
			player,
			{ kind = "ko", id = bot.id, by = player.UserId, how = "fell", at = bot.chassis.Position }
		)
		task.delay(2, function()
			if bot.model.Parent then
				BrawlBots.despawn(bot)
			end
		end)
		if practice.knocked == 1 then
			-- 20-coin pop, then the second bot (spec: Brawl practice)
			local profile = DataService.get(player)
			if profile then
				local got = EconomyService.grantCoins(player, cfg.practice.coins, "brawl", "Brawl_practice")
				Net.fire("Brawl.Event", player, { kind = "practiceCoins", coins = got })
			end
		end
		if practice.knocked >= cfg.practice.botsToKnock then
			practice.done = true
			task.delay(2, endPractice, player, true)
		else
			task.delay(1.2, function()
				if practices[player] == practice then
					practiceBot(player, practice)
				end
			end)
		end
	end
	-- Fell off the disc yourself: straight back on (never a fail)
	local model = VehicleService.getVehicle(player)
	local chassis = model and model.PrimaryPart
	if chassis and chassis.Position.Y < koY then
		VehicleService.spawn(player, vehicleFor(player), practiceSpot(practice))
	end
end

---------------------------------------------------------------------------
-- Arrival, leaving, seasons
---------------------------------------------------------------------------

local function seasonRoll(player: Player, profile: { [string]: any })
	local record, rewards = BrawlMath.seasonRoll(profile.ranked, cfg.ranked.season, cfg.ranked)
	profile.ranked = record
	if #rewards == 0 then
		return
	end
	local items = cfg.ranked.seasonRewards
	local coins = 0
	local given = {}
	for _, tier in rewards do
		local itemId = items[math.min(tier + 1, #items)]
		if itemId and Catalog.byId[itemId] and profile.inventory[itemId] == nil then
			ShopService.giveItem(profile, itemId)
			table.insert(given, itemId)
		else
			coins += cfg.ranked.seasonOwnedCoins
		end
	end
	if coins > 0 then
		EconomyService.grantCoins(player, coins, nil, "Ranked_season")
	end
	DataService.changed(player)
	Net.fire("Brawl.Event", player, { kind = "season", items = given, coins = coins, season = record.season })
end

local function onArrive(player: Player)
	local profile = DataService.waitFor(player)
	if player.Parent ~= Players or profile == nil then
		return
	end
	seasonRoll(player, profile)
	profile.flags.lastMode = "brawl"
	DataService.changed(player)
	if ranked and not TeleportHub.rankedOpen(player) and not DataService.isAdmin(player) then
		Net.fire("Notice", player, "rankedLocked")
		toPen(player)
		task.delay(3, function()
			if player.Parent == Players then
				TeleportHub.home(player)
			end
		end)
		return
	end
	if not ranked and not profile.tut.brawl then
		startPractice(player)
	else
		toPen(player)
		round:add(player)
	end
	LiveCounts.bump()
end

-- Quitting a ranked round costs the quit penalty (applied before the last save)
local function onLeaving(player: Player, profile: { [string]: any })
	if round == nil then
		return
	end
	local phase = round:phase()
	local e = entrantOf(player)
	if alive(e) and (phase == "Countdown" or phase == "Play") then
		local entrant = e :: Entrant
		entrant.quit = true
		entrant.outAt = now()
		if ranked then
			local delta = BrawlMath.rankedDelta(0, 0, true, false, cfg.ranked)
			profile.ranked = BrawlMath.applyRanked(profile.ranked, delta, cfg.ranked)
		end
	end
end

local function onRemoving(player: Player)
	inPen[player] = nil
	if practices[player] then
		local practice = practices[player]
		practices[player] = nil
		if practice.bot and practice.bot.model.Parent then
			BrawlBots.despawn(practice.bot)
		end
		BrawlArena.destroy(practice.arena)
	end
	if round then
		round:remove(player)
		if round:phase() == "Play" then
			checkOver()
			round:broadcast()
		end
	end
end

---------------------------------------------------------------------------
-- Every frame: bots and bot bumps; 10 Hz: the round
---------------------------------------------------------------------------

local function arenaContext(arena: BrawlArena.Arena, cars: { BrawlBots.Car }, at: number): BrawlBots.Context
	local sum, count = Vector3.zero, 0
	for _, index in BrawlArena.standing(arena) do
		sum += BrawlArena.tileTop(arena, index)
		count += 1
	end
	return {
		now = at,
		arena = arena,
		centre = if count > 0 then sum / count else arena.origin,
		cars = cars,
		onExplode = function(bot: BrawlBots.Bot)
			event({ kind = "botBoom", id = bot.id, at = bot.chassis.Position })
		end,
		onUse = function(bot: BrawlBots.Bot)
			local e = entrantById(bot.id)
			if e then
				usePowerup(e)
			end
		end,
	}
end

local centreCache: { arena: any, ctx: BrawlBots.Context?, at: number } = { arena = nil, ctx = nil, at = 0 }

local function stepBots(dt: number)
	local at = now()
	-- The round's bots
	if round and round.data.order and (round:phase() == "Countdown" or round:phase() == "Play") then
		local d = round.data
		local cars: { BrawlBots.Car } = {}
		local bots: { BrawlBots.Bot } = {}
		for _, e in list() do
			if alive(e) then
				local chassis = chassisOf(e)
				if chassis then
					table.insert(cars, {
						id = e.id,
						position = chassis.Position,
						velocity = chassis.AssemblyLinearVelocity,
						bot = e.bot ~= nil,
					})
				end
			end
			if e.bot and e.bot.model.Parent then
				table.insert(bots, e.bot)
			end
		end
		-- The middle of what is left changes only when tiles warn: work it out 4 times a second
		local ctx = centreCache.ctx
		if centreCache.arena ~= d.arena or at - centreCache.at > 0.25 or ctx == nil then
			ctx = arenaContext(d.arena, cars, at)
			centreCache.arena = d.arena
			centreCache.ctx = ctx
			centreCache.at = at
		end
		local c = ctx :: BrawlBots.Context
		c.now = at
		c.cars = cars
		-- Held on the start tiles during the countdown like everyone else
		c.hold = round:phase() == "Countdown"
		BrawlBots.step(bots, dt, c)
		if round:phase() == "Play" then
			d.contactClock = (d.contactClock or 0) + dt
			if d.contactClock >= 1 / 30 then
				d.contactClock = 0
				botContacts(list(), at)
			end
		end
	end
	-- Practice bots
	for _, practice in practices do
		local bot = practice.bot
		if bot and bot.model.Parent then
			BrawlBots.step({ bot }, dt, arenaContext(practice.arena, {}, at))
		end
	end
end

function BrawlService.init()
	ranked = Place.isRanked()
	Workspace:SetAttribute("Mode", "Brawl")
	Workspace:SetAttribute("BrawlRanked", ranked)
	BrawlArena.init()
	round = RoundManager.new("brawl", {
		minPlayers = 1,
		maxPlayers = cfg.maxPlayers,
		lobbyFill = if ranked then cfg.botFillRanked else cfg.botFillCasual,
		countdown = cfg.countdown,
		playMax = cfg.maxLength,
		afterFirstFinish = nil,
		results = cfg.results,
		requeue = cfg.requeue,
	}, mode)

	VehicleService.onJoin = function(player: Player)
		task.spawn(onArrive, player)
	end
	VehicleService.homeFor = function(player: Player): CFrame?
		local practice = practices[player]
		if practice then
			return practiceSpot(practice)
		end
		return BrawlArena.penSpawn(1)
	end
	VehicleService.equipLocked = function(player: Player): boolean
		local phase = round:phase()
		return (phase == "Countdown" or phase == "Play") and alive(entrantOf(player))
	end
	-- An exploded car is out
	VehicleService.DamageChanged:Connect(function(player: Player, state: buffer)
		if round:phase() ~= "Play" then
			return
		end
		local e = entrantOf(player)
		local decoded = DamageModel.decode(state)
		if alive(e) and decoded and bit32.band(decoded.flags, DamageModel.FLAG_EXPLODED) ~= 0 then
			eliminate(e :: Entrant, "exploded")
		end
	end)
	DataService.Leaving:Connect(onLeaving)
	Players.PlayerRemoving:Connect(onRemoving)

	Net.on("Brawl.Hit", onHit)
	Net.on("Brawl.Powerup", function(player: Player)
		if round:phase() == "Play" then
			local e = entrantOf(player)
			if e then
				usePowerup(e)
			end
		end
	end)
	Net.on("Brawl.Queue", function(player: Player)
		local e = entrantOf(player)
		if e and round:phase() == "Results" then
			e.skipped = true
			Analytics.modeStep(player, Analytics.MODE.requeue)
		end
	end)
	Net.on("Brawl.Leave", function(player: Player)
		local ok, reason = TeleportHub.home(player)
		if not ok and reason then
			Net.fire("Notice", player, reason)
		end
	end)
	Net.on("Brawl.Practice", function(player: Player)
		if practices[player] then
			endPractice(player, false)
		end
	end)
	Net.on("Cheer", function(player: Player, targetId: number)
		local target = entrantById(targetId)
		if round:phase() == "Play" and alive(target) and round:has(player) then
			Net.fireAll("Cheer", player.UserId, targetId)
		end
	end)

	LiveCounts.start(function()
		return { brawl = #Players:GetPlayers() }
	end)

	local clock = 0
	local tidy = 0
	RunService.Heartbeat:Connect(function(dt)
		stepBots(dt)
		clock += dt
		if clock < 0.1 then
			return
		end
		local step = clock
		clock = 0
		round:step(step)
		for player, practice in practices do
			tickPractice(player, practice)
		end
		-- A pen car that went over the wall goes back in
		tidy += step
		if tidy >= 1 then
			tidy = 0
			BrawlArena.tidyPen()
			local floorY = BrawlArena.penOrigin().Y
			for player in inPen do
				local model = VehicleService.getVehicle(player)
				local chassis = model and model.PrimaryPart
				if chassis and chassis.Position.Y < floorY - 15 then
					toPen(player)
				end
			end
		end
	end)
	print(string.format("[Brawl] Cinder Cove %s ready", if ranked then "Ranked" else "Casual"))
end

return BrawlService
