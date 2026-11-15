-- ExplosionFx: the cartoon explosion (spec: Explosions; Juice table > Explosion).
-- Fireball (a Roblox Explosion used as a visual only: BlastPressure 0, no joints broken), a neon glow ball
-- instead of a dynamic light, a shockwave ring and smoke puffs. Each client plays at most 2 full explosions
-- at once; extras show as a small pop with a smoke puff. Cosmetic styles (confetti, paint splash, foam)
-- plug in through STYLES and change only the colours here (and the sound, through JuiceService).
-- PLACEHOLDER ART: built-in particle textures and neon parts until the VFX pass.

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local ExplosionFx = {}

local STYLES = {
	Classic = {
		glow = Color3.fromRGB(255, 170, 60),
		ring = Color3.fromRGB(255, 235, 180),
		smoke = Color3.fromRGB(60, 58, 64),
	},
}

local active = 0
local folder: Folder? = nil

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = workspace:FindFirstChild("LocalDebris") :: Folder?
	if not f then
		f = Instance.new("Folder")
		f.Name = "LocalDebris"
		f.Parent = workspace
	end
	folder = f
	return f :: Folder
end

local function fxPart(name: string, shape: Enum.PartType, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.one
	return part
end

local function smokeBurst(position: Vector3, color: Color3, count: number, size: number)
	local holder = fxPart("Smoke", Enum.PartType.Block, color)
	holder.Transparency = 1
	holder.Size = Vector3.new(size, size * 0.5, size)
	holder.CFrame = CFrame.new(position)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size * 0.5),
		NumberSequenceKeypoint.new(1, size * 1.4),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(4, 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 8, 0)
	emitter.Rate = 0
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.Parent = holder
	holder.Parent = getFolder()
	emitter:Emit(count)
	task.delay(1.6, function()
		holder:Destroy()
	end)
end

-- Play an explosion. Returns true if it was a full explosion, false if it became a small pop.
function ExplosionFx.play(position: Vector3, styleName: string?): boolean
	local style = STYLES[styleName or "Classic"] or STYLES.Classic
	if active >= Config.Damage.maxFullExplosions then
		ExplosionFx.pop(position)
		return false
	end
	active += 1
	task.delay(1.0, function()
		active -= 1
	end)

	local blast = Instance.new("Explosion")
	blast.Position = position
	blast.BlastPressure = 0
	blast.BlastRadius = 8
	blast.DestroyJointRadiusPercent = 0
	blast.ExplosionType = Enum.ExplosionType.NoCraters
	blast.Parent = getFolder()

	local glow = fxPart("Glow", Enum.PartType.Ball, style.glow)
	glow.CFrame = CFrame.new(position)
	glow.Transparency = 0.15
	glow.Parent = getFolder()
	TweenService:Create(
		glow,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 16, Transparency = 1 }
	):Play()

	local ringSize = Config.Damage.shockwave.radius * 2
	local ring = fxPart("Shockwave", Enum.PartType.Cylinder, style.ring)
	ring.CFrame = CFrame.new(position - Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.Transparency = 0.3
	ring.Parent = getFolder()
	TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.3, ringSize, ringSize), Transparency = 1 }
	):Play()

	smokeBurst(position + Vector3.new(0, 1, 0), style.smoke, 14, 4)
	task.delay(0.6, function()
		glow:Destroy()
		ring:Destroy()
	end)
	return true
end

-- The small version: a pop and one smoke puff
function ExplosionFx.pop(position: Vector3)
	local glow = fxPart("Pop", Enum.PartType.Ball, STYLES.Classic.glow)
	glow.CFrame = CFrame.new(position)
	glow.Transparency = 0.2
	glow.Parent = getFolder()
	TweenService:Create(glow, TweenInfo.new(0.25), { Size = Vector3.one * 5, Transparency = 1 }):Play()
	smokeBurst(position, STYLES.Classic.smoke, 5, 2.5)
	task.delay(0.3, function()
		glow:Destroy()
	end)
end

function ExplosionFx.activeCount(): number
	return active
end

return ExplosionFx
