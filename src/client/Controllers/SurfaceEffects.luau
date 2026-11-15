-- SurfaceEffects: skid marks, dust puffs and sparks for one vehicle (spec: Weight cues > Surface).
-- Skid marks are Trails on the rear wheels (Roblox pools and fades the segments), shown above 8 studs/s
-- of lateral slip. Dust puffs on dirt-like materials. Sparks are emitted on demand at a contact point.
-- Works for the local car (real wheel data) and remote cars (wheel data rebuilt from Vehicle.Pose).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local SurfaceEffects = {}

local DUST = {}
for _, name in Config.Surface.dustMaterials do
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and material then
		DUST[material] = true
	end
end

local Effects = {}
Effects.__index = Effects

local function makeTrail(chassis: BasePart, width: number)
	local a0 = Instance.new("Attachment")
	a0.Name = "SkidA"
	a0.Parent = chassis
	local a1 = Instance.new("Attachment")
	a1.Name = "SkidB"
	a1.Parent = chassis
	local trail = Instance.new("Trail")
	trail.Name = "Skid"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = false
	trail.Lifetime = Config.Surface.skidLifetime
	trail.MinLength = 0.25
	trail.LightEmission = 0
	trail.LightInfluence = 1
	trail.Color = ColorSequence.new(Color3.fromRGB(30, 30, 34))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.7, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Enabled = false
	trail.Parent = chassis
	return { a0 = a0, a1 = a1, trail = trail, width = width }
end

local function makeDust(chassis: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Name = "Dust"
	attachment.Parent = chassis
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DustPuff"
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(220, 196, 140))
	emitter.Size =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 4) })
	emitter.Transparency =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Speed = NumberRange.new(2, 6)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Rate = 24
	emitter.LightInfluence = 1
	emitter.Enabled = false
	emitter.Parent = attachment
	return { attachment = attachment, emitter = emitter }
end

function SurfaceEffects.attach(model: Model, class)
	local chassis = model:WaitForChild("Chassis") :: BasePart
	local self = setmetatable({
		chassis = chassis,
		class = class,
		skids = { makeTrail(chassis, class.wheelWidth), makeTrail(chassis, class.wheelWidth) },
		dust = { makeDust(chassis), makeDust(chassis) },
		instances = {},
	}, Effects)

	local sparkAttachment = Instance.new("Attachment")
	sparkAttachment.Name = "Sparks"
	sparkAttachment.Parent = chassis
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "SparkEmitter"
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 140, 40))
	sparks.LightEmission = 1
	sparks.Size =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparks.Lifetime = NumberRange.new(0.25, 0.5)
	sparks.Speed = NumberRange.new(18, 36)
	sparks.SpreadAngle = Vector2.new(70, 70)
	sparks.Acceleration = Vector3.new(0, -workspace.Gravity * 0.5, 0)
	sparks.Drag = 2
	sparks.Rate = 0
	sparks.Enabled = true
	sparks.Parent = sparkAttachment
	self.sparkAttachment = sparkAttachment
	self.sparks = sparks

	for _, skid in self.skids do
		table.insert(self.instances, skid.a0)
		table.insert(self.instances, skid.a1)
		table.insert(self.instances, skid.trail)
	end
	for _, dust in self.dust do
		table.insert(self.instances, dust.attachment)
	end
	table.insert(self.instances, sparkAttachment)
	return self
end

-- wheels: list of { grounded, contact (world), lateralSlip, material, rear } in FL, FR, RL, RR order
function Effects:update(_dt: number, wheels, forwardSpeed: number, _groundedCount: number)
	local chassis = self.chassis
	local cf = chassis.CFrame
	for index = 1, 2 do
		local w = wheels[index + 2]
		local skid = self.skids[index]
		local dust = self.dust[index]
		if w and w.grounded then
			local localContact = cf:PointToObjectSpace(w.contact + Vector3.new(0, 0.06, 0))
			skid.a0.Position = localContact - Vector3.new(skid.width / 2, 0, 0)
			skid.a1.Position = localContact + Vector3.new(skid.width / 2, 0, 0)
			skid.trail.Enabled = math.abs(w.lateralSlip) > Config.Surface.skidSlipSpeed
			dust.attachment.Position = localContact
			dust.emitter.Enabled = DUST[w.material] == true and math.abs(forwardSpeed) > 15
		else
			skid.trail.Enabled = false
			dust.emitter.Enabled = false
		end
	end
end

function Effects:emitSparks(worldPoint: Vector3, count: number)
	if count <= 0 then
		return
	end
	self.sparkAttachment.WorldPosition = worldPoint
	self.sparks:Emit(math.min(count, 30))
end

function Effects:Destroy()
	for _, instance in self.instances do
		instance:Destroy()
	end
	table.clear(self.instances)
end

return SurfaceEffects
