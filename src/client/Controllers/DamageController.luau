-- DamageController: crashes damage cars (spec: Crashes, damage and explosions).
-- Own car: every impact and hard landing becomes zone damage (DamageModel), which drives the panel looks,
-- debris, smoke, fire, the explosion and, where the mode allows, handling. The 9 zone numbers plus a flags
-- byte go to everyone through Damage.State (on change, at most 4 per second, resent while damaged), and
-- every device draws every car from those numbers. Respawns repair the car for free.
-- Other players' cars: their Damage.State drives the same visuals here; when one explodes near us, our
-- own client applies the shockwave to our own car (the owner always moves its own car).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local DamageModel = require(Shared.DamageModel)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local Fx = script.Parent.Parent:WaitForChild("Fx")
local DamageVisuals = require(Fx:WaitForChild("DamageVisuals"))
local ExplosionFx = require(Fx:WaitForChild("ExplosionFx"))
local MeshDents = require(Fx:WaitForChild("MeshDents"))

local LocalPlayer = Players.LocalPlayer
local DC = Config.Damage

local DamageController = {}

DamageController.Changed = Signal.new() -- (fractions, flags) for the HUD silhouette
DamageController.Exploded = Signal.new() -- ()
DamageController.Wrecked = Signal.new() -- (wrecked: boolean)

type Own = {
	model: Model,
	chassis: BasePart,
	damage: DamageModel.State,
	looks: { number },
	visuals: any,
	rules: DamageModel.ModeRules,
	dirty: boolean,
	lastSend: number,
	lastFullSend: number,
	wrecked: boolean,
}

type Remote = {
	model: Model,
	visuals: any,
	looks: { number },
	fractions: { number },
	flags: number,
	maxHealth: { number },
}

local controllers: any = nil
local own: Own? = nil
local remotes: { [Model]: Remote } = {}
local random = Random.new()

-- The damage rules: the player's own (a quick race: TracksRace, or TracksFullDamage on a Full damage
-- map) or the place's mode
local function mode(): string
	return LocalPlayer:GetAttribute("DamageMode") or workspace:GetAttribute("Mode") or "TestTrack"
end

local function rulesFor(modeName: string): DamageModel.ModeRules
	return DC.modes[modeName] or DC.modes.TestTrack
end

local function classFor(model: Model)
	return Config.Classes[model:GetAttribute("ClassId") or "Buggy"] or Config.Classes.Buggy
end

local function healthMultiplier(model: Model): number
	return classFor(model).zoneHealthMultiplier * rulesFor(mode()).health
end

local function juice(event: string, data: any?)
	if controllers.Juice then
		controllers.Juice.fire(event, data)
	end
end

---------------------------------------------------------------------------
-- Own car
---------------------------------------------------------------------------

local function sendState(o: Own)
	o.dirty = false
	o.lastSend = os.clock()
	o.lastFullSend = o.lastSend
	Net.send("Damage.State", DamageModel.encode(o.damage, DC))
end

local function refresh(o: Own)
	local looks = DamageModel.looks(o.damage, DC)
	local events = DamageModel.diff(o.looks, looks)
	if #events > 0 then
		o.visuals:apply(events, looks)
	end
	o.looks = looks
	controllers.Vehicle.setHandling(DamageModel.handling(looks, o.rules, DC))
	local wrecked = DamageModel.isWrecked(o.damage, DC)
	if wrecked ~= o.wrecked then
		o.wrecked = wrecked
		DamageController.Wrecked:Fire(wrecked)
	end
	o.dirty = true
	DamageController.Changed:Fire(DamageModel.fractions(o.damage), DamageModel.flags(o.damage, DC))
end

local function explode(o: Own)
	local position = o.chassis.Position
	ExplosionFx.play(position, o.model:GetAttribute("ExplosionStyle"))
	local count = random:NextInteger(DC.explosionPanels[1], DC.explosionPanels[2])
	o.visuals:explode(count)
	juice("Explosion", { scale = 1, point = position })
	-- The rider is thrown clear upward, unharmed; the wreck hops
	local vehicle = controllers.Vehicle.getState()
	if vehicle and vehicle.driverPresent then
		controllers.Vehicle.ejectRider(DC.riderBlastUp)
	end
	controllers.Vehicle.applyKick(Vector3.new(0, DC.ownExplosionHop, 0), random:NextUnitVector() * 2)
	refresh(o)
	sendState(o)
	DamageController.Exploded:Fire()
end

local function onImpact(info)
	local o = own
	if not o or not o.rules.looks or o.damage.exploded then
		return
	end
	local cf = o.chassis.CFrame
	local half = o.chassis.Size / 2
	local localPoint = cf:PointToObjectSpace(info.point)
	local dealt = DamageModel.applyImpact(
		o.damage,
		info.side,
		info.impact,
		localPoint.X,
		localPoint.Z,
		half.X,
		half.Z,
		DC
	)
	if dealt > 0 then
		MeshDents.dent(o.model, info.point, o.chassis.Position - info.point, info.impact)
		refresh(o)
	end
end

local function onLanded(fallSpeed: number)
	local o = own
	local vehicle = controllers.Vehicle.getState()
	if not o or not vehicle or not o.rules.looks or o.damage.exploded then
		return
	end
	local touched = {}
	for index, wheel in vehicle.wheels do
		touched[index] = wheel.grounded
	end
	if DamageModel.applyLanding(o.damage, fallSpeed, touched, DC) > 0 then
		refresh(o)
	end
end

local function repairOwn()
	local o = own
	if not o then
		return
	end
	local wasPristine = DamageModel.isPristine(o.damage)
	DamageModel.repair(o.damage)
	o.visuals:reset()
	MeshDents.reset(o.model)
	o.looks = DamageModel.looks(o.damage, DC)
	refresh(o)
	if not wasPristine then
		juice("Repair")
		sendState(o)
	end
end

local function setupOwn(model: Model)
	if own and own.model == model then
		return
	end
	if own and own.visuals then
		own.visuals:Destroy()
		MeshDents.release(own.model)
	end
	local chassis = model:WaitForChild("Chassis", 10) :: BasePart
	if not chassis then
		return
	end
	local o: Own = {
		model = model,
		chassis = chassis,
		damage = DamageModel.new(healthMultiplier(model), DC),
		looks = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
		visuals = DamageVisuals.attach(model, controllers.Debris, controllers.Juice),
		rules = rulesFor(mode()),
		dirty = false,
		lastSend = 0,
		lastFullSend = 0,
		wrecked = false,
	}
	own = o
	controllers.Vehicle.setHandling(nil)
	MeshDents.attach(model)
	DamageController.Changed:Fire(DamageModel.fractions(o.damage), 0)
end

local function updateOwn(dt: number)
	local o = own
	if not o or o.model.Parent == nil then
		return
	end
	local rules = rulesFor(mode())
	if rules ~= o.rules then
		o.rules = rules
		refresh(o)
	end
	local result = DamageModel.tick(o.damage, dt, o.rules, DC)
	if result == "fire" then
		o.visuals:setFire(true)
		o.dirty = true
		DamageController.Changed:Fire(DamageModel.fractions(o.damage), DamageModel.flags(o.damage, DC))
	elseif result == "explode" then
		explode(o)
	end
	local now = os.clock()
	local due = o.dirty and now - o.lastSend >= 1 / DC.sendMaxRate
	local resend = not DamageModel.isPristine(o.damage) and now - o.lastFullSend >= DC.resendInterval
	if due or resend then
		sendState(o)
	end
end

---------------------------------------------------------------------------
-- Other players' cars
---------------------------------------------------------------------------

local function remoteFor(model: Model): Remote
	local remote = remotes[model]
	if remote then
		return remote
	end
	local healthMax = DamageModel.new(healthMultiplier(model), DC).max
	remote = {
		model = model,
		visuals = DamageVisuals.attach(model, controllers.Debris, nil),
		looks = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
		fractions = { 1, 1, 1, 1, 1, 1, 1, 1, 1 },
		flags = 0,
		maxHealth = healthMax,
	}
	remotes[model] = remote
	return remote
end

-- An explosion near our car: we move our own car (spec: Shockwave)
local function shockwaveFrom(position: Vector3)
	local o = own
	if not o or not o.chassis.Parent then
		return
	end
	local offset = o.chassis.Position - position
	local distance = offset.Magnitude
	local listen = 1 - math.clamp(distance / 60, 0, 1)
	if listen > 0 then
		juice("Explosion", { scale = listen, point = position })
	end
	local push, up, damage = DamageModel.shockwave(distance, DC)
	if push <= 0 then
		return
	end
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local outward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.xAxis
	local knock = classFor(o.model).knockbackTakenMultiplier or 1
	controllers.Vehicle.applyKick(outward * push * knock + Vector3.new(0, up, 0))
	if o.rules.looks and not o.damage.exploded then
		local towardBlast = o.chassis.CFrame:VectorToObjectSpace(-offset)
		DamageModel.applyToZone(
			o.damage,
			DamageModel.zoneFacing(towardBlast.X, towardBlast.Y, towardBlast.Z),
			damage
		)
		refresh(o)
	end
end

local function onRemoteState(userId: number, data: buffer)
	if type(userId) ~= "number" or type(data) ~= "buffer" or userId == LocalPlayer.UserId then
		return
	end
	local folder = workspace:FindFirstChild("Vehicles")
	local model = folder and folder:FindFirstChild("Vehicle_" .. userId)
	if not model or not model:IsA("Model") then
		return
	end
	local decoded = DamageModel.decode(data)
	if not decoded then
		return
	end
	local remote = remoteFor(model)
	local looks = DamageModel.looksFromFractions(decoded.fractions, DC)
	-- Repaired (any zone got better): redraw from clean
	local repaired = false
	for index = 1, 9 do
		if decoded.fractions[index] > remote.fractions[index] + 1e-3 then
			repaired = true
		end
	end
	if repaired then
		remote.visuals:reset()
		MeshDents.reset(model)
		remote.looks = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	else
		-- Dent their shell where each body zone lost health
		local chassis = model.PrimaryPart
		if chassis then
			for zone = 1, 5 do
				local drop = (remote.fractions[zone] - decoded.fractions[zone]) * remote.maxHealth[zone]
				if drop > 1 then
					local outward = ({
						Vector3.new(0, 0, -1),
						Vector3.new(0, 0, 1),
						Vector3.new(-1, 0, 0),
						Vector3.new(1, 0, 0),
						Vector3.new(0, 1, 0),
					})[zone]
					local half = chassis.Size / 2
					local point = chassis.CFrame:PointToWorldSpace(outward * half)
					local direction = chassis.CFrame:VectorToWorldSpace(-outward)
					MeshDents.dent(model, point, direction, DamageModel.impactForDamage(drop, DC))
				end
			end
		end
	end
	local events = DamageModel.diff(remote.looks, looks)
	if #events > 0 then
		remote.visuals:apply(events, looks)
	end
	remote.looks = looks
	remote.fractions = decoded.fractions
	local wasExploded = bit32.band(remote.flags, DamageModel.FLAG_EXPLODED) ~= 0
	local exploded = bit32.band(decoded.flags, DamageModel.FLAG_EXPLODED) ~= 0
	remote.visuals:setFire(bit32.band(decoded.flags, DamageModel.FLAG_FIRE) ~= 0)
	if exploded and not wasExploded and model.PrimaryPart then
		local position = model.PrimaryPart.Position
		ExplosionFx.play(position, model:GetAttribute("ExplosionStyle"))
		remote.visuals:explode(random:NextInteger(DC.explosionPanels[1], DC.explosionPanels[2]))
		shockwaveFrom(position)
	end
	remote.flags = decoded.flags
end

local function untrack(model: Instance)
	local remote = remotes[model :: Model]
	if remote then
		remote.visuals:Destroy()
		remotes[model :: Model] = nil
	end
	MeshDents.release(model :: Model)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Wheel camber from damage, for the wheel animation (index 1..4 = FL, FR, RL, RR)
function DamageController.camber(model: Model, index: number): number
	if own and own.model == model then
		return own.visuals:getCamber(index)
	end
	local remote = remotes[model]
	return if remote then remote.visuals:getCamber(index) else 0
end

function DamageController.getFractions(): { number }?
	return if own then DamageModel.fractions(own.damage) else nil
end

function DamageController.getLooks(): { number }?
	return if own then table.clone(own.looks) else nil
end

function DamageController.getState(): DamageModel.State?
	return if own then own.damage else nil
end

function DamageController.isWrecked(): boolean
	return own ~= nil and own.wrecked
end

-- Dev tools: damage a zone directly, repair, set the Dents setting
function DamageController.damageZone(zone: number, amount: number)
	if own then
		DamageModel.applyToZone(own.damage, zone, amount)
		refresh(own)
	end
end

function DamageController.repair()
	repairOwn()
end

function DamageController.setDents(value: string)
	MeshDents.setSetting(value)
	if own and MeshDents.isEnabled() then
		MeshDents.attach(own.model)
	end
end

function DamageController.dentStatus(): string
	return MeshDents.status() .. (if own and MeshDents.has(own.model) then ", own car dented" else "")
end

function DamageController.forceDents()
	MeshDents.forceAllow()
	DamageController.setDents("Full")
end

function DamageController.init(all)
	controllers = all
end

function DamageController.start()
	local Vehicle = controllers.Vehicle
	Vehicle.Spawned:Connect(setupOwn)
	Vehicle.Impact:Connect(onImpact)
	Vehicle.Landed:Connect(onLanded)
	-- Every respawn is a free, instant, full repair (spec: Repairs)
	Vehicle.Respawned:Connect(repairOwn)
	local current = Vehicle.getState()
	if current then
		setupOwn(current.model)
	end

	Net.listen("Damage.State", onRemoteState)
	local folder = workspace:WaitForChild("Vehicles")
	folder.ChildRemoved:Connect(untrack)

	RunService.Heartbeat:Connect(updateOwn)

	MeshDents.runBenchmark(function()
		if own and MeshDents.isEnabled() then
			MeshDents.attach(own.model)
		end
	end)
	-- Keep the dent budget on the nearest 4 cars
	task.spawn(function()
		while true do
			task.wait(0.5)
			local others = {}
			for _, model in folder:GetChildren() do
				if model:IsA("Model") and (not own or model ~= own.model) then
					table.insert(others, model)
				end
			end
			MeshDents.refresh(if own then own.model else nil, others)
		end
	end)
end

return DamageController
