-- Debris: flying parts from crashes and explosions (spec: Damage zones > detached parts).
-- A detached part becomes local debris: a simple unanchored copy on this device only, in the Debris
-- collision group (it bounces off the world but never touches players' cars or riders). It fades from
-- 2.5 s and is gone at 3.0 s. At most 12 pieces per client: a new piece retires the oldest.
-- Glass shatters as a glitter burst (particles only, no extra parts).

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local Debris = {}

type Piece = {
	root: BasePart,
	parts: { { part: BasePart, base: number } },
	born: number,
}

local folder: Folder
local pieces: { Piece } = {}
local random = Random.new()
local glitter: ParticleEmitter
local glitterHolder: Part

local KEEP_CLASSES = {
	SpecialMesh = true,
	Decal = true,
	Texture = true,
	SurfaceAppearance = true,
	Weld = true,
	WeldConstraint = true,
	Motor6D = true,
}

local function retire(piece: Piece)
	piece.root:Destroy()
end

local function isInside(instance: Instance?, root: Instance): boolean
	return instance ~= nil and (instance == root or instance:IsDescendantOf(root))
end

-- Copy a part (and its welded sub-parts, such as a wheel's hub) as a loose physics piece.
local function makeCopy(source: BasePart): (BasePart, { { part: BasePart, base: number } })
	local archivable = source.Archivable
	source.Archivable = true
	local copy = source:Clone()
	source.Archivable = archivable
	local parts = {}
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BasePart") then
			continue
		end
		if not KEEP_CLASSES[descendant.ClassName] then
			descendant:Destroy()
		elseif descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			-- Keep only joints inside the copy (a wheel's hub and spoke); drop the ones to the car
			local joint = descendant :: any
			if not (isInside(joint.Part0, copy) and isInside(joint.Part1, copy)) then
				descendant:Destroy()
			end
		end
	end
	local all = { copy }
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(all, descendant)
		end
	end
	for index, part in all do
		part.Anchored = false
		part.CanTouch = false
		part.CanQuery = false
		part.CollisionGroup = "Debris"
		part.CanCollide = index == 1
		part.Massless = index ~= 1
		part.LocalTransparencyModifier = 0
		table.insert(parts, { part = part, base = part.Transparency })
	end
	return copy, parts
end

-- Throw a copy of a part. velocity is the car's velocity; the piece also gets a random outward kick.
function Debris.spawnFrom(source: BasePart, velocity: Vector3, outward: Vector3?, sparkTrail: boolean?)
	local cfg = Config.Damage.debris
	while #pieces >= cfg.max do
		retire(table.remove(pieces, 1) :: Piece)
	end
	local copy, parts = makeCopy(source)
	copy.CFrame = source.CFrame
	if sparkTrail then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.2, 0)
		a0.Parent = copy
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.2, 0)
		a1.Parent = copy
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.35
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 120, 40))
		trail.Transparency = NumberSequence.new(0.1, 1)
		trail.WidthScale = NumberSequence.new(1, 0.2)
		trail.Parent = copy
	end
	copy.Parent = folder
	local direction = outward or random:NextUnitVector()
	if direction.Magnitude < 1e-3 then
		direction = Vector3.yAxis
	end
	local kick = direction.Unit * cfg.speed * random:NextNumber(0.6, 1.2) + Vector3.new(0, cfg.up, 0)
	copy.AssemblyLinearVelocity = velocity + kick
	copy.AssemblyAngularVelocity = random:NextUnitVector() * cfg.spin
	table.insert(pieces, { root = copy, parts = parts, born = os.clock() })
	return copy
end

-- Glass shatter: a glitter burst where the glass was
function Debris.glitter(position: Vector3, size: Vector3?)
	glitterHolder.CFrame = CFrame.new(position)
	glitterHolder.Size = size or Vector3.new(2, 1, 2)
	glitter:Emit(24)
end

function Debris.count(): number
	return #pieces
end

-- Seconds the oldest live piece has existed, for the dev panel's debris check
function Debris.oldestAge(): number
	local first = pieces[1]
	return if first then os.clock() - first.born else 0
end

function Debris.clear()
	for _, piece in pieces do
		retire(piece)
	end
	table.clear(pieces)
end

local function update()
	local cfg = Config.Damage.debris
	local now = os.clock()
	local index = 1
	while index <= #pieces do
		local piece = pieces[index]
		local age = now - piece.born
		if age >= cfg.lifetime or piece.root.Parent == nil then
			retire(piece)
			table.remove(pieces, index)
			continue
		end
		if age > cfg.fadeAt then
			local alpha = (age - cfg.fadeAt) / (cfg.lifetime - cfg.fadeAt)
			for _, entry in piece.parts do
				entry.part.Transparency = entry.base + (1 - entry.base) * alpha
			end
		end
		index += 1
	end
end

function Debris.init()
	-- Created in init so the car controller's raycasts can ignore it from the first frame
	folder = workspace:FindFirstChild("LocalDebris") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "LocalDebris"
		folder.Parent = workspace
	end
	glitterHolder = Instance.new("Part")
	glitterHolder.Name = "GlitterEmitter"
	glitterHolder.Anchored = true
	glitterHolder.CanCollide = false
	glitterHolder.CanQuery = false
	glitterHolder.CanTouch = false
	glitterHolder.Transparency = 1
	glitterHolder.Parent = folder
	glitter = Instance.new("ParticleEmitter")
	glitter.Name = "Glitter" -- PLACEHOLDER ART: default sparkle texture, tinted glass blue
	glitter.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	glitter.LightEmission = 0.6
	glitter.Size = NumberSequence.new(0.35, 0)
	glitter.Lifetime = NumberRange.new(0.5, 0.9)
	glitter.Speed = NumberRange.new(6, 14)
	glitter.SpreadAngle = Vector2.new(180, 180)
	glitter.Acceleration = Vector3.new(0, -60, 0)
	glitter.Rate = 0
	glitter.Shape = Enum.ParticleEmitterShape.Box
	glitter.Parent = glitterHolder
end

function Debris.start()
	RunService.Heartbeat:Connect(update)
end

return Debris
