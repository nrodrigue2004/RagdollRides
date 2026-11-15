-- DamageVisuals: draws one car's damage from DamageModel events (spec: Damage zones > Look).
-- Works the same for the local car and for other players' cars, so everyone sees the same wreck.
--   look          each zone's panel shows clean, dented or crushed
--   crackGlass    the zone's glass cracks; shatterGlass: it bursts into glitter and disappears
--   detach        a bumper, hood, door or trunk tears off as local debris with a spark trail
--   doorLoose     a side panel swings loose on its front edge
--   wheelLost     the wheel pops off and rolls away
-- Front damage smokes (light when dented, heavy when crushed) and burns when the engine is gone.
--
-- PLACEHOLDER ART: dented and crushed looks are made by pushing the blockout panel in, tilting and
-- darkening it. When the real panel models exist, put them in ReplicatedStorage.Assets.PanelLooks as
-- <VehicleId>/<PanelName>_Dented and _Crushed (same pivot as the clean panel) and they are swapped in
-- automatically. Every change here is local to this device and undone by reset().

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DamageModel = require(Shared.DamageModel)

local DamageVisuals = {}
DamageVisuals.__index = DamageVisuals

-- Body parts each zone moves with, and the zone's outward direction in car space (car faces -Z)
local ZONE_PARTS: { [number]: { string } } = {
	[1] = { "Panel_Front", "Bumper_Front", "Light_FL", "Light_FR" },
	[2] = { "Panel_Rear", "Bumper_Rear" },
	[3] = { "Panel_Left" },
	[4] = { "Panel_Right" },
	[5] = { "Panel_Roof" },
}
local ZONE_GLASS: { [number]: { string } } = {
	[1] = { "Glass_Front" },
	[2] = { "Glass_Rear" },
	[3] = { "Glass_Left" },
	[4] = { "Glass_Right" },
}
local OUTWARD: { [number]: Vector3 } = {
	[1] = Vector3.new(0, 0, -1),
	[2] = Vector3.new(0, 0, 1),
	[3] = Vector3.new(-1, 0, 0),
	[4] = Vector3.new(1, 0, 0),
	[5] = Vector3.new(0, 1, 0),
}
-- inset (studs), tilt (degrees), darken (0..1) per look
local LOOK_SHAPE = {
	[1] = { inset = 0.12, tilt = 4, darken = 0.12 },
	[2] = { inset = 0.32, tilt = 10, darken = 0.28 },
	[3] = { inset = 0.45, tilt = 14, darken = 0.4 },
}
local DOOR_SWING = 20 -- degrees
local CAMBER = { [0] = 0, [1] = 3, [2] = 8, [3] = 0 } -- wheel tilt per look, degrees
-- Parts thrown when the car explodes, in order (4 to 6 of those still attached)
local BLAST_ORDER = {
	"Panel_Front",
	"Panel_Roof",
	"Panel_Left",
	"Panel_Right",
	"Bumper_Front",
	"Panel_Rear",
	"Bumper_Rear",
	"Glass_Front",
}

type Original = {
	part: BasePart,
	weld: Weld?,
	c0: CFrame,
	color: Color3,
	transparency: number,
	material: Enum.Material,
}

local function hashAngle(name: string, salt: number): number
	-- A stable pseudo-random -1..1 per part, so a dent leans the same way every time
	local h = salt
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 1000003
	end
	return (h % 2000) / 1000 - 1
end

local function emitterOn(
	parent: Instance,
	name: string,
	texture: string,
	color: Color3,
	rate: number,
	size: number
)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size * 0.6),
		NumberSequenceKeypoint.new(1, size * 1.8),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(2, 5)
	emitter.SpreadAngle = Vector2.new(20, 20)
	emitter.Acceleration = Vector3.new(0, 6, 0)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rate = rate
	emitter.Enabled = false
	emitter.Parent = parent
	return emitter
end

function DamageVisuals.attach(model: Model, debris: any, juice: any?)
	local chassis = model:WaitForChild("Chassis", 10) :: BasePart
	local body = model:WaitForChild("Body", 10) :: Folder
	local wheels = model:WaitForChild("Wheels", 10) :: Folder
	local self = setmetatable({
		model = model,
		chassis = chassis,
		debris = debris,
		juice = juice,
		vehicleId = model:GetAttribute("VehicleId"),
		originals = {} :: { [string]: Original },
		swapped = {} :: { [string]: BasePart },
		hidden = {} :: { [BasePart]: boolean },
		looks = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
		cracked = {} :: { [string]: boolean },
		camber = { 0, 0, 0, 0 },
		fire = false,
	}, DamageVisuals)
	if not chassis or not body or not wheels then
		return self
	end
	for _, part in body:GetChildren() do
		if part:IsA("BasePart") then
			local weld = part:FindFirstChildOfClass("Weld")
			self.originals[part.Name] = {
				part = part,
				weld = weld,
				c0 = if weld then weld.C0 else chassis.CFrame:ToObjectSpace(part.CFrame),
				color = part.Color,
				transparency = part.Transparency,
				material = part.Material,
			}
		end
	end
	self.wheelParts = {}
	for index, name in { "FL", "FR", "RL", "RR" } do
		self.wheelParts[index] = wheels:FindFirstChild("Wheel_" .. name)
	end

	-- Smoke and fire at the engine (the front panel)
	local front = self.originals.Panel_Front
	local attachment = Instance.new("Attachment")
	attachment.Name = "EngineFx"
	local frontOffset = if front then front.c0.Position else Vector3.new(0, 0.5, -chassis.Size.Z / 2)
	attachment.Position = frontOffset + Vector3.new(0, 0.6, 0)
	attachment.Parent = chassis
	self.engineFx = attachment
	self.smokeLight = emitterOn(
		attachment,
		"SmokeLight",
		"rbxasset://textures/particles/smoke_main.dds",
		Color3.fromRGB(200, 200, 205),
		6,
		1.2
	)
	self.smokeHeavy = emitterOn(
		attachment,
		"SmokeHeavy",
		"rbxasset://textures/particles/smoke_main.dds",
		Color3.fromRGB(45, 45, 50),
		16,
		2
	)
	self.flames = emitterOn(
		attachment,
		"Flames",
		"rbxasset://textures/particles/fire_main.dds",
		Color3.fromRGB(255, 140, 40),
		30,
		1.6
	)
	self.flames.LightEmission = 1
	self.flames.Lifetime = NumberRange.new(0.3, 0.6)
	self.flames.Speed = NumberRange.new(4, 8)
	return self
end

local function setHidden(self, part: BasePart, hidden: boolean)
	if hidden then
		self.hidden[part] = true
		part.LocalTransparencyModifier = 1
		for _, child in part:GetDescendants() do
			if child:IsA("BasePart") then
				child.LocalTransparencyModifier = 1
			end
		end
	else
		self.hidden[part] = nil
		part.LocalTransparencyModifier = 0
		for _, child in part:GetDescendants() do
			if child:IsA("BasePart") then
				child.LocalTransparencyModifier = 0
			end
		end
	end
end

local function variantFor(self, name: string, look: number): BasePart?
	if look < 1 or look > 2 then
		return nil
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local looks = assets and assets:FindFirstChild("PanelLooks")
	local perVehicle = looks and looks:FindFirstChild(tostring(self.vehicleId))
	local variant = perVehicle
		and perVehicle:FindFirstChild(name .. (if look == 1 then "_Dented" else "_Crushed"))
	return if variant and variant:IsA("BasePart") then variant else nil
end

-- Show a part's look: an authored variant if one exists, otherwise the procedural placeholder
local function shapePart(self, name: string, zone: number, look: number)
	local original = self.originals[name]
	if not original or self.hidden[original.part] then
		return
	end
	local part = original.part
	local old = self.swapped[name]
	if old then
		old:Destroy()
		self.swapped[name] = nil
	end
	local variant = variantFor(self, name, look)
	if variant then
		local copy = variant:Clone()
		copy.Anchored = false
		copy.CanCollide = false
		copy.CanQuery = false
		copy.CanTouch = false
		copy.Massless = true
		copy.CFrame = self.chassis.CFrame * original.c0
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = self.chassis
		weld.Part1 = copy
		weld.Parent = copy
		copy.Parent = part.Parent
		self.swapped[name] = copy
		part.LocalTransparencyModifier = 1
		return
	end
	part.LocalTransparencyModifier = 0
	if look == 0 then
		if original.weld then
			original.weld.C0 = original.c0
		end
		part.Color = original.color
		return
	end
	local shape = LOOK_SHAPE[look]
	local tilt = math.rad(shape.tilt)
	local rotation =
		CFrame.Angles(hashAngle(name, 1) * tilt, hashAngle(name, 2) * tilt * 0.5, hashAngle(name, 3) * tilt)
	local c0 = CFrame.new(-OUTWARD[zone] * shape.inset) * original.c0 * rotation
	if original.weld then
		original.weld.C0 = c0
	end
	part.Color = original.color:Lerp(Color3.new(0, 0, 0), shape.darken)
end

local function detach(self, name: string, velocity: Vector3, outward: Vector3?)
	local original = self.originals[name]
	if not original or self.hidden[original.part] then
		return
	end
	local visible = self.swapped[name] or original.part
	if original.transparency < 1 then
		self.debris.spawnFrom(visible, velocity, outward, true)
	end
	local swapped = self.swapped[name]
	if swapped then
		swapped:Destroy()
		self.swapped[name] = nil
	end
	setHidden(self, original.part, true)
	if self.juice then
		self.juice.fire("PanelTear", { point = original.part.Position })
	end
end

local function crackGlass(self, name: string)
	local original = self.originals[name]
	if not original or self.cracked[name] or self.hidden[original.part] then
		return
	end
	self.cracked[name] = true
	-- PLACEHOLDER ART: cracked glass is frosted and milky until the cracked-glass decal exists
	original.part.Material = Enum.Material.Glass
	original.part.Transparency = math.max(0.15, original.transparency - 0.3)
	original.part.Color = original.color:Lerp(Color3.new(1, 1, 1), 0.5)
end

local function shatterGlass(self, name: string)
	local original = self.originals[name]
	if not original or self.hidden[original.part] then
		return
	end
	self.debris.glitter(original.part.Position, original.part.Size)
	setHidden(self, original.part, true)
	if self.juice then
		self.juice.fire("GlassShatter", { point = original.part.Position })
	end
end

local function chassisVelocity(self): Vector3
	return self.chassis.AssemblyLinearVelocity
end

-- Apply the events from DamageModel.diff, then remember the new looks.
function DamageVisuals:apply(events: { DamageModel.Event }, looks: { number })
	if not self.chassis or not self.chassis.Parent then
		return
	end
	local velocity = chassisVelocity(self)
	local cf = self.chassis.CFrame
	for _, event in events do
		local zone = event.zone
		if event.kind == "look" and zone then
			local look = tonumber(event.part) or 0
			if zone <= 5 then
				for _, name in ZONE_PARTS[zone] do
					shapePart(self, name, zone, look)
				end
			else
				self.camber[zone - 5] = CAMBER[look] or 0
			end
		elseif event.kind == "crackGlass" and zone then
			for _, name in ZONE_GLASS[zone] or {} do
				crackGlass(self, name)
			end
		elseif event.kind == "shatterGlass" then
			if zone then
				for _, name in ZONE_GLASS[zone] or {} do
					shatterGlass(self, name)
				end
			else
				for name in self.originals do
					if string.sub(name, 1, 6) == "Glass_" then
						shatterGlass(self, name)
					end
				end
			end
		elseif event.kind == "detach" and event.part then
			local outward = if zone and OUTWARD[zone] then cf:VectorToWorldSpace(OUTWARD[zone]) else nil
			detach(self, event.part, velocity, outward)
		elseif event.kind == "doorLoose" and zone then
			local name = if zone == 3 then "Panel_Left" else "Panel_Right"
			local original = self.originals[name]
			if original and original.weld and not self.hidden[original.part] then
				local half = original.part.Size.Z / 2
				local angle = math.rad(if zone == 3 then -DOOR_SWING else DOOR_SWING)
				original.weld.C0 = original.weld.C0
					* CFrame.new(0, 0, -half)
					* CFrame.Angles(0, angle, 0)
					* CFrame.new(0, 0, half)
			end
		elseif event.kind == "wheelLost" and zone then
			local wheel = self.wheelParts[zone - 5]
			if wheel and not self.hidden[wheel] then
				local side = if zone == 6 or zone == 8 then -1 else 1
				self.debris.spawnFrom(wheel, velocity, cf.RightVector * side, true)
				setHidden(self, wheel, true)
				if self.juice then
					self.juice.fire("PanelTear", { point = wheel.Position })
				end
			end
		end
	end
	self.looks = table.clone(looks)
	-- Smoke follows the front look; fire is set separately from the fire flag
	local front = looks[1]
	self.smokeLight.Enabled = front == 1
	self.smokeHeavy.Enabled = front >= 2
end

function DamageVisuals:setFire(on: boolean)
	if self.fire == on or not self.flames then
		return
	end
	self.fire = on
	self.flames.Enabled = on
	if on and self.juice then
		self.juice.fire("FireStart", { point = self.engineFx.WorldPosition })
	end
end

-- The explosion: 4 to 6 parts still attached fly off outward and up
function DamageVisuals:explode(count: number)
	if not self.chassis or not self.chassis.Parent then
		return
	end
	self:setFire(false)
	self.smokeHeavy.Enabled = true
	local velocity = chassisVelocity(self)
	local center = self.chassis.Position
	local thrown = 0
	for _, name in BLAST_ORDER do
		if thrown >= count then
			break
		end
		local original = self.originals[name]
		if original and not self.hidden[original.part] then
			local outward = original.part.Position - center
			detach(self, name, velocity, outward + Vector3.new(0, 2, 0))
			thrown += 1
		end
	end
end

function DamageVisuals:getCamber(index: number): number
	return self.camber[index] or 0
end

-- Repair: everything back to the clean car
function DamageVisuals:reset()
	for name, original in self.originals do
		local swapped = self.swapped[name]
		if swapped then
			swapped:Destroy()
		end
		if original.weld then
			original.weld.C0 = original.c0
		end
		original.part.Color = original.color
		original.part.Transparency = original.transparency
		original.part.Material = original.material
		setHidden(self, original.part, false)
	end
	table.clear(self.swapped)
	table.clear(self.cracked)
	for _, wheel in self.wheelParts or {} do
		setHidden(self, wheel, false)
	end
	self.camber = { 0, 0, 0, 0 }
	self.looks = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	if self.flames then
		self.fire = false
		self.flames.Enabled = false
		self.smokeLight.Enabled = false
		self.smokeHeavy.Enabled = false
	end
end

function DamageVisuals:Destroy()
	for _, swapped in self.swapped do
		swapped:Destroy()
	end
	if self.engineFx then
		self.engineFx:Destroy()
	end
end

return DamageVisuals
