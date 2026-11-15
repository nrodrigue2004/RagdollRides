-- BrawlArena: the Cinder Cove world for Bumper Brawl (spec: Game modes > Bumper Brawl; Brawl screens >
-- Lobby; Asset list > Cinder Cove arenas). Server side; the clients draw the warnings and the falls.
-- * The foam pit: one soft floor under everything. A car that lands in it is out (BrawlService).
-- * The pen: a walled foam-ball pen to drive around while the next round fills (the lobby).
-- * Arenas: 72 hex tiles from Shared/BrawlMath (inner, middle, outer rings in 3 colours). One arena is
--   built per round, in turn, and taken down after it. Geyser Ring has a foam geyser in its middle hole.
-- * Practice arenas: a 19-tile disc per first-time player, off to the side.
-- * Tile drops: warn(tile, warnAt, dropAt) puts the server times on the tile (attributes WarnAt and
--   DropAt; tag "BrawlTile"). Every client flashes it and drops it locally at DropAt, so the floor goes
--   at the same moment for everyone; the server turns its collision off at DropAt too (bots and the
--   KO check) and hides it a moment later.
-- Tiles are hexagons made once with a union of 3 blocks and cloned; if the union fails (it needs the
-- Roblox CSG service) they fall back to round foam pads.
-- PLACEHOLDER ART: tiles, pit, pen, geyser and the carnival posts are plain foam-coloured parts.

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local BrawlMath = require(Shared.BrawlMath)
local Config = require(Shared.Config)

local BrawlArena = {}

local cfg = Config.Brawl
local SQRT3 = math.sqrt(3)
local FOAM = Color3.fromRGB(255, 244, 222)
local PIT = Color3.fromRGB(255, 196, 214)
local SOFT = PhysicalProperties.new(0.7, 1, 0, 100, 100)

export type Arena = {
	id: string,
	name: string,
	layout: BrawlMath.Layout,
	origin: Vector3, -- the centre of the tile tops
	folder: Model,
	tiles: { BasePart },
	state: { [number]: string }, -- "warn" | "gone" (nil = standing)
	practice: boolean,
}

local world: Folder
local template: BasePart? = nil

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanTouch = false
	p.Parent = parent
	return p
end

-- One hex tile (flats facing +-X, points toward +-Z), made once and cloned
local function tileTemplate(): BasePart
	if template then
		return template
	end
	local width = cfg.tileSpacing - 0.1 -- a hairline seam between tiles
	local side = width / SQRT3
	local h = cfg.tileHeight
	local made: BasePart? = nil
	local ok = pcall(function()
		local holder = Instance.new("Folder")
		holder.Parent = Workspace
		local blocks = {}
		for i = 0, 2 do
			local b = Instance.new("Part")
			b.Anchored = true
			b.Size = Vector3.new(width, h, side)
			b.CFrame = CFrame.Angles(0, math.rad(60 * i), 0) + Vector3.new(0, -5000, 0)
			b.Parent = holder
			table.insert(blocks, b)
		end
		local union = blocks[1]:UnionAsync({ blocks[2], blocks[3] }, Enum.CollisionFidelity.Hull)
		union.Parent = nil
		holder:Destroy()
		made = union
	end)
	if not ok or made == nil then
		-- Fallback: a round pad a little wider than the flats so neighbours overlap (no gaps)
		local pad = Instance.new("Part")
		pad.Shape = Enum.PartType.Cylinder
		pad.Size = Vector3.new(h, width * 1.08, width * 1.08)
		made = pad
	end
	local t = made :: BasePart
	if t:IsA("UnionOperation") then
		t.UsePartColor = true -- ring colours and the warning flash set Color
	end
	t.Anchored = true
	t.Material = Enum.Material.SmoothPlastic
	t.CanTouch = false
	t.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.9, 0, 1, 1)
	t.Name = "Tile"
	t.Parent = ServerStorage
	template = t
	return t
end

local function tileCFrame(origin: Vector3, tile: BrawlMath.Tile): CFrame
	local cf = CFrame.new(origin + Vector3.new(tile.x, -cfg.tileHeight / 2, tile.z))
	if (template :: BasePart):IsA("Part") and (template :: Part).Shape == Enum.PartType.Cylinder then
		cf *= CFrame.Angles(0, 0, math.rad(90))
	end
	return cf
end

---------------------------------------------------------------------------
-- The fixed world: pit, pen, dressing
---------------------------------------------------------------------------

local function buildWorld()
	world = Instance.new("Folder")
	world.Name = "CinderCove"
	local origin = vec(cfg.origin)
	local pen = cfg.pen
	local penOrigin = vec(pen.origin)
	local practiceOrigin = vec(cfg.practice.origin)
	-- The foam pit: one soft floor under the arena, the pen and the practice discs
	local minX = math.min(origin.X, penOrigin.X, practiceOrigin.X) - 300
	local maxX = math.max(origin.X, penOrigin.X, practiceOrigin.X + cfg.practice.spacing * cfg.practice.slots)
		+ 300
	local minZ = math.min(origin.Z, penOrigin.Z, practiceOrigin.Z) - 300
	local maxZ = math.max(origin.Z, penOrigin.Z, practiceOrigin.Z) + 300
	local pit = part(
		world,
		"FoamPit",
		Vector3.new(maxX - minX, 6, maxZ - minZ),
		CFrame.new((minX + maxX) / 2, origin.Y - cfg.pitDepth - 3, (minZ + maxZ) / 2),
		PIT
	)
	pit.Material = Enum.Material.Fabric
	pit.CustomPhysicalProperties = SOFT
	pit:SetAttribute("FoamPit", true)

	-- The pen: a floor, foam walls and foam balls to shove about
	local size = pen.size
	local floor = part(
		world,
		"PenFloor",
		Vector3.new(size, 4, size),
		CFrame.new(penOrigin - Vector3.new(0, 2, 0)),
		FOAM
	)
	floor.Material = Enum.Material.SmoothPlastic
	local half = size / 2
	for _, side in
		{ { 0, -half, size, 2 }, { 0, half, size, 2 }, { -half, 0, 2, size }, { half, 0, 2, size } }
	do
		part(
			world,
			"PenWall",
			Vector3.new(side[3] + 2, 7, side[4] + 2),
			CFrame.new(penOrigin + Vector3.new(side[1], 3.5, side[2])),
			Color3.fromRGB(255, 170, 120)
		)
	end
	local colors = { { 255, 120, 90 }, { 120, 200, 255 }, { 255, 214, 80 }, { 140, 230, 120 } }
	for i = 1, pen.balls do
		local angle = (i / pen.balls) * math.pi * 2
		local ball = Instance.new("Part")
		ball.Name = "FoamBall"
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.one * pen.ballSize
		ball.Color = Config.color3(colors[(i % #colors) + 1])
		ball.Material = Enum.Material.SmoothPlastic
		ball.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.4, 0.6, 1, 1)
		ball.CFrame =
			CFrame.new(penOrigin + Vector3.new(math.cos(angle) * 35, pen.ballSize, math.sin(angle) * 35))
		ball:SetAttribute("Home", ball.CFrame)
		ball.Parent = world
	end
	-- A sign over the pen
	local sign = part(
		world,
		"PenSign",
		Vector3.new(40, 8, 1.5),
		CFrame.new(penOrigin + Vector3.new(0, 16, -half - 2)),
		Color3.fromRGB(255, 120, 90)
	)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = "NEXT ROUND"
	label.TextColor3 = Color3.fromRGB(35, 35, 45)
	label.Parent = gui
	-- Carnival posts round the arena pit
	local radius = 95
	for i = 1, 12 do
		local angle = (i / 12) * math.pi * 2
		local base = origin + Vector3.new(math.cos(angle) * radius, -cfg.pitDepth, math.sin(angle) * radius)
		part(world, "Post", Vector3.new(2, 46, 2), CFrame.new(base + Vector3.new(0, 23, 0)), FOAM)
		local flag = Instance.new("WedgePart")
		flag.Name = "Flag"
		flag.Anchored = true
		flag.CanTouch = false
		flag.CanCollide = false
		flag.Size = Vector3.new(0.4, 5, 7)
		flag.CFrame = CFrame.new(base + Vector3.new(0, 43, 0)) * CFrame.Angles(0, -angle, 0)
		flag.Color = Config.color3(colors[(i % #colors) + 1])
		flag.Material = Enum.Material.SmoothPlastic
		flag.Parent = world
	end
	world.Parent = Workspace
end

-- Where the pen's cars sit (a loose grid), index from 1
function BrawlArena.penSpawn(index: number): CFrame
	local pen = cfg.pen
	local o = vec(pen.origin)
	local column = (index - 1) % 4
	local row = math.floor((index - 1) / 4) % 3
	local position = o + Vector3.new((column - 1.5) * 18, 0, 30 + row * 16)
	return CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
end

function BrawlArena.penOrigin(): Vector3
	return vec(cfg.pen.origin)
end

-- Put pen balls that rolled out back home (a ball in the pit)
function BrawlArena.tidyPen()
	local floorY = cfg.pen.origin[2]
	for _, child in world:GetChildren() do
		if child.Name == "FoamBall" and child:IsA("BasePart") then
			if child.Position.Y < floorY - 10 then
				child.AssemblyLinearVelocity = Vector3.zero
				child.CFrame = child:GetAttribute("Home") :: CFrame
			end
		end
	end
end

---------------------------------------------------------------------------
-- Arenas
---------------------------------------------------------------------------

local function build(id: string, name: string, shape: string, origin: Vector3, practice: boolean): Arena
	local layout = BrawlMath.layout(shape, cfg.tileSpacing)
	local folder = Instance.new("Model")
	folder.Name = if practice then "PracticeArena" else "Arena_" .. id
	folder.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	folder:SetAttribute("ArenaId", id)
	folder:SetAttribute("Origin", origin)
	local t = tileTemplate()
	local tiles = {}
	for index, tile in layout.tiles do
		local p = t:Clone()
		p.Name = "Tile_" .. index
		p.CFrame = tileCFrame(origin, tile)
		local color = if practice then cfg.ringColors[1] else cfg.ringColors[tile.ring]
		p.Color = Config.color3(color)
		p:SetAttribute("Tile", index)
		p:SetAttribute("Ring", tile.ring)
		p:SetAttribute("Home", p.CFrame)
		CollectionService:AddTag(p, "BrawlTile")
		p.Parent = folder
		tiles[index] = p
	end
	if shape == "ring" then
		-- The foam geyser in the middle hole (looks only)
		local spout = part(
			folder,
			"Geyser",
			Vector3.new(6, 4, 6),
			CFrame.new(origin + Vector3.new(0, -cfg.pitDepth + 2, 0)),
			Color3.fromRGB(255, 255, 255)
		)
		spout.CanCollide = false
		local emitter = Instance.new("ParticleEmitter")
		emitter.Rate = 18
		emitter.Lifetime = NumberRange.new(1.2, 1.8)
		emitter.Speed = NumberRange.new(24, 32)
		emitter.SpreadAngle = Vector2.new(8, 8)
		emitter.Size =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 5) })
		emitter.Transparency =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		emitter.Acceleration = Vector3.new(0, -30, 0)
		emitter.Parent = spout
	end
	folder.Parent = world
	return {
		id = id,
		name = name,
		layout = layout,
		origin = origin,
		folder = folder,
		tiles = tiles,
		state = {},
		practice = practice,
	}
end

-- Build a round's arena (arenas take turns by round number)
function BrawlArena.buildRound(roundNumber: number): Arena
	local def = cfg.arenas[((roundNumber - 1) % #cfg.arenas) + 1]
	return build(def.id, def.name, def.shape, vec(cfg.origin), false)
end

-- A practice disc in its slot (0-based)
function BrawlArena.buildPractice(slot: number): Arena
	local origin = vec(cfg.practice.origin) + Vector3.new(slot * cfg.practice.spacing, 0, 0)
	return build("practice", "Practice", "practice", origin, true)
end

function BrawlArena.destroy(arena: Arena)
	arena.folder:Destroy()
end

-- World position of a tile's top centre
function BrawlArena.tileTop(arena: Arena, index: number): Vector3
	local tile = arena.layout.tiles[index]
	return arena.origin + Vector3.new(tile.x, 0, tile.z)
end

-- The tile under a world position (nil over the pit)
function BrawlArena.tileUnder(arena: Arena, position: Vector3): number?
	local offset = position - arena.origin
	return BrawlMath.tileAt(arena.layout, offset.X, offset.Z)
end

-- Standing (not warned, not gone) at this position
function BrawlArena.isSafe(arena: Arena, position: Vector3): boolean
	local index = BrawlArena.tileUnder(arena, position)
	return index ~= nil and arena.state[index] == nil
end

function BrawlArena.isGone(arena: Arena, index: number): boolean
	return arena.state[index] == "gone"
end

-- Tiles still standing (not warned)
function BrawlArena.standing(arena: Arena): { number }
	local list = {}
	for index in arena.layout.tiles do
		if arena.state[index] == nil then
			table.insert(list, index)
		end
	end
	return list
end

function BrawlArena.warn(arena: Arena, index: number, warnAt: number, dropAt: number)
	local p = arena.tiles[index]
	if p == nil or arena.state[index] ~= nil then
		return
	end
	arena.state[index] = "warn"
	p:SetAttribute("WarnAt", warnAt)
	p:SetAttribute("DropAt", dropAt)
end

function BrawlArena.drop(arena: Arena, index: number)
	local p = arena.tiles[index]
	if p == nil or arena.state[index] == "gone" then
		return
	end
	arena.state[index] = "gone"
	p.CanCollide = false
	p.CanQuery = false
	task.delay(2, function()
		if p.Parent then
			p.Transparency = 1
		end
	end)
end

function BrawlArena.init()
	buildWorld()
	tileTemplate()
end

return BrawlArena
