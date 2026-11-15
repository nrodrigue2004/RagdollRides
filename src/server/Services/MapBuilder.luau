-- MapBuilder: turns a map's piece list (Shared/StarterMaps, later player maps) into anchored parts.
-- Each piece kind has one look and one set of tags; gameplay reads the tags and attributes, never names:
--   Checkpoint  trigger, attributes MapId, Index, GroundOffset (VehicleController respawns there)
--   Finish      trigger, attribute MapId
--   Hazard      trigger, attributes MapId, RespawnCFrame (throws the rider; respawn just past it)
--   Coin        visual only, attributes MapId, CoinIndex (pickup is a client-side distance check)
--   Spinner     visual only, attributes MapId, PieceIndex, Speed, Axis (clients spin it and test hits)
--   Bouncer / SpeedPad  tall invisible trigger over a glowing pad (same as the test track)
--   SoftWall    collider; a low solid bumper shows where the edge is
-- Map space has the start at the origin, driving toward -Z (see StarterMaps).
-- PLACEHOLDER ART: plain parts in the toy-foam palette; the art pass reskins each kind.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapSpace = require(Shared.MapSpace)
local StarterMaps = require(Shared.StarterMaps)

local MapBuilder = {}

local PALETTE = {
	road = Color3.fromRGB(96, 104, 132),
	sand = Color3.fromRGB(232, 205, 140),
	ramp = Color3.fromRGB(255, 166, 77),
	joint = Color3.fromRGB(96, 104, 132),
	wall = Color3.fromRGB(170, 225, 255),
	bumper = Color3.fromRGB(255, 120, 160),
	start = Color3.fromRGB(255, 255, 255),
	checkpoint = Color3.fromRGB(60, 220, 130),
	finish = Color3.fromRGB(255, 214, 10),
	coin = Color3.fromRGB(255, 205, 40),
	spinner = Color3.fromRGB(255, 92, 92),
	post = Color3.fromRGB(240, 240, 240),
	bouncer = Color3.fromRGB(60, 160, 255),
	speed = Color3.fromRGB(255, 230, 60),
	ground = Color3.fromRGB(122, 204, 120),
	text = Color3.fromRGB(40, 40, 50),
}

local GROUND_BELOW = 45 -- the decorative ground sits this far under the lowest road (below the kill height)
local GROUND_MARGIN = 500
local SPINNER_HEIGHT = 7 -- spinners sit this far above the road (StarterMaps places them so)

local folder: Folder? = nil
local built: { [string]: Model } = {}

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
	p.Parent = parent
	return p
end

local function visualOnly(p: BasePart)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
end

local function trigger(p: BasePart)
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = true
	p.CastShadow = false
end

local function label(p: BasePart, text: string, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.Parent = p
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextScaled = true
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.TextColor3 = PALETTE.text
	textLabel.Parent = gui
end

MapBuilder.pieceCFrame = MapSpace.pieceCFrame
MapBuilder.startCFrame = MapSpace.startCFrame

local function arch(model: Model, cf: CFrame, width: number, height: number, color: Color3, text: string)
	-- cf is the arch centre at ground level, facing along the road
	for _, side in { -1, 1 } do
		local pole = part(
			model,
			"ArchPole",
			Vector3.new(1.2, height, 1.2),
			cf * CFrame.new(side * (width / 2 + 0.6), height / 2, 0),
			PALETTE.post
		)
		visualOnly(pole)
	end
	local banner = part(
		model,
		"ArchBanner",
		Vector3.new(width + 2.4, 3, 0.6),
		cf * CFrame.new(0, height - 1.5, 0),
		color
	)
	visualOnly(banner)
	label(banner, text, Enum.NormalId.Front)
	label(banner, text, Enum.NormalId.Back)
	return banner
end

local BUILDERS: { [string]: (Model, StarterMaps.MapDef, StarterMaps.Piece, CFrame, number) -> () } = {}

-- Road and ramp: the piece position is the centre of the top surface
BUILDERS.Road = function(model, _map, piece, cf)
	local isSand = piece.material == "Sand"
	local road = part(
		model,
		"Road",
		Vector3.new(piece.sx, piece.sy, piece.sz),
		cf * CFrame.new(0, -piece.sy / 2, 0),
		if isSand then PALETTE.sand else PALETTE.road
	)
	if isSand then
		road.Material = Enum.Material.Sand
	end
end

BUILDERS.Ramp = function(model, _map, piece, cf)
	part(
		model,
		"Ramp",
		Vector3.new(piece.sx, piece.sy, piece.sz),
		cf * CFrame.new(0, -piece.sy / 2, 0),
		PALETTE.ramp
	)
end

-- A round pad that fills the joint where the road turns (sx is the thickness, sy and sz the diameter)
BUILDERS.Joint = function(model, _map, piece, cf)
	local disc = part(
		model,
		"Joint",
		Vector3.new(piece.sx, piece.sy, piece.sz),
		cf * CFrame.new(0, -piece.sx / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		PALETTE.joint
	)
	disc.Shape = Enum.PartType.Cylinder
end

BUILDERS.SoftWall = function(model, _map, piece, cf)
	local wall = part(model, "SoftWall", Vector3.new(piece.sx, piece.sy, piece.sz), cf, PALETTE.wall)
	wall.Transparency = 0.8
	wall.CastShadow = false
	wall.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.2, 0.35, 1, 1)
	CollectionService:AddTag(wall, "SoftWall")
	local bumperHeight = 3
	local bumper = part(
		model,
		"Bumper",
		Vector3.new(piece.sx + 0.2, bumperHeight, piece.sz),
		cf * CFrame.new(0, -piece.sy / 2 + bumperHeight / 2, 0),
		PALETTE.bumper
	)
	visualOnly(bumper)
end

BUILDERS.Start = function(model, map, piece, cf)
	-- The start piece sits at ground level
	arch(model, cf, piece.sx, 12, PALETTE.start, "START")
	local mark =
		part(model, "StartLine", Vector3.new(piece.sx, 0.1, 1.2), cf * CFrame.new(0, 0.05, 0), PALETTE.start)
	visualOnly(mark)
	mark:SetAttribute("MapId", map.id)
end

BUILDERS.Checkpoint = function(model, map, piece, cf)
	local t = part(
		model,
		"Checkpoint_" .. tostring(piece.index),
		Vector3.new(piece.sx, piece.sy, piece.sz),
		cf,
		PALETTE.checkpoint
	)
	trigger(t)
	t:SetAttribute("MapId", map.id)
	t:SetAttribute("Index", piece.index or 0)
	t:SetAttribute("GroundOffset", piece.sy / 2)
	CollectionService:AddTag(t, "Checkpoint")
	arch(model, cf * CFrame.new(0, -piece.sy / 2, 0), piece.sx, 11, PALETTE.checkpoint, "CHECKPOINT")
end

BUILDERS.Finish = function(model, map, piece, cf)
	local t = part(model, "Finish", Vector3.new(piece.sx, piece.sy, piece.sz), cf, PALETTE.finish)
	trigger(t)
	t:SetAttribute("MapId", map.id)
	CollectionService:AddTag(t, "Finish")
	local ground = cf * CFrame.new(0, -piece.sy / 2, 0)
	arch(model, ground, piece.sx, 13, PALETTE.finish, "FINISH")
	-- Checker line across the road
	for i = 0, 9 do
		local tile = part(
			model,
			"Checker",
			Vector3.new(piece.sx / 10, 0.1, 2),
			ground * CFrame.new(-piece.sx / 2 + piece.sx / 20 + i * piece.sx / 10, 0.05, 0),
			if i % 2 == 0 then Color3.new(1, 1, 1) else Color3.fromRGB(35, 35, 45)
		)
		visualOnly(tile)
	end
end

BUILDERS.Coin = function(model, map, _piece, cf, index)
	-- A disc standing up and facing the driver (a cylinder's axis is its X: turn it to face along the road)
	local coin =
		part(model, "Coin", Vector3.new(0.5, 3, 3), cf * CFrame.Angles(0, math.rad(90), 0), PALETTE.coin)
	coin.Shape = Enum.PartType.Cylinder
	coin.Material = Enum.Material.Neon
	coin.CastShadow = false
	visualOnly(coin)
	coin:SetAttribute("MapId", map.id)
	coin:SetAttribute("CoinIndex", index)
	CollectionService:AddTag(coin, "Coin")
end

BUILDERS.Spinner = function(model, map, piece, cf, index)
	local axis = piece.axis or "up"
	local bar: Part
	if axis == "across" then
		-- A foam roller across the road, on two posts
		bar = part(model, "Spinner", Vector3.new(piece.sx, piece.sy, piece.sy), cf, PALETTE.spinner)
		bar.Shape = Enum.PartType.Cylinder
		local height = SPINNER_HEIGHT + piece.sy / 2
		for _, side in { -1, 1 } do
			local post = part(
				model,
				"SpinnerPost",
				Vector3.new(1.5, height, 1.5),
				cf * CFrame.new(side * (piece.sx / 2 + 1), -SPINNER_HEIGHT + height / 2, 0),
				PALETTE.post
			)
			visualOnly(post)
		end
	else
		-- A sweeping bar on a hub post in the middle of the road
		bar = part(model, "Spinner", Vector3.new(piece.sx, piece.sy, piece.sz), cf, PALETTE.spinner)
		local hubHeight = SPINNER_HEIGHT + piece.sy / 2
		local hub = part(
			model,
			"SpinnerHub",
			Vector3.new(2.5, hubHeight, 2.5),
			cf * CFrame.new(0, -SPINNER_HEIGHT + hubHeight / 2, 0),
			PALETTE.post
		)
		visualOnly(hub)
	end
	bar.Material = Enum.Material.SmoothPlastic
	visualOnly(bar)
	bar:SetAttribute("MapId", map.id)
	bar:SetAttribute("PieceIndex", index)
	bar:SetAttribute("Speed", piece.speed or 90)
	bar:SetAttribute("Axis", axis)
	bar:SetAttribute("BaseCFrame", bar.CFrame)
	CollectionService:AddTag(bar, "Spinner")
end

BUILDERS.Hazard = function(model, map, piece, cf)
	local t = part(model, "Hazard", Vector3.new(piece.sx, piece.sy, piece.sz), cf, PALETTE.spinner)
	trigger(t)
	t:SetAttribute("MapId", map.id)
	local x, y, z = StarterMaps.hazardRespawn(piece)
	local wx, wy, wz = StarterMaps.toWorld(map, x, y, z)
	t:SetAttribute("RespawnCFrame", CFrame.new(wx, wy, wz) * CFrame.Angles(0, math.rad(piece.yaw), 0))
	CollectionService:AddTag(t, "Hazard")
end

local function pad(
	model: Model,
	map: StarterMaps.MapDef,
	piece: StarterMaps.Piece,
	cf: CFrame,
	tag: string,
	color: Color3
)
	local visual = part(model, tag, Vector3.new(piece.sx, 0.4, piece.sz), cf, color)
	visual.Material = Enum.Material.Neon
	visualOnly(visual)
	-- The chassis rides well above the ground, so the trigger is a tall invisible volume over the pad
	local t =
		part(model, tag .. "Trigger", Vector3.new(piece.sx, 6, piece.sz), cf * CFrame.new(0, 3, 0), color)
	trigger(t)
	t:SetAttribute("MapId", map.id)
	CollectionService:AddTag(t, tag)
end

BUILDERS.Bouncer = function(model, map, piece, cf)
	pad(model, map, piece, cf, "Bouncer", PALETTE.bouncer)
end

BUILDERS.SpeedPad = function(model, map, piece, cf)
	pad(model, map, piece, cf, "SpeedPad", PALETTE.speed)
end

-- Cues are read by the client from the map data (a box test), so they have no parts
BUILDERS.JumpCue = function() end
BUILDERS.LeanCue = function() end

function MapBuilder.build(map: StarterMaps.MapDef): Model
	if built[map.id] then
		return built[map.id]
	end
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = "Maps"
		f.Parent = workspace
		folder = f
	end
	local model = Instance.new("Model")
	model.Name = map.id
	model:SetAttribute("MapId", map.id)
	model:SetAttribute("MapName", map.name)
	local coinIndex = 0
	for index, piece in map.pieces do
		local builder = BUILDERS[piece.kind]
		if builder == nil then
			warn(string.format("[MapBuilder] %s: no builder for piece kind %s", map.id, piece.kind))
			continue
		end
		local cf = MapBuilder.pieceCFrame(map, piece)
		if piece.kind == "Coin" then
			coinIndex += 1
			builder(model, map, piece, cf, coinIndex)
		else
			builder(model, map, piece, cf, index)
		end
	end

	-- Decorative ground far enough below that a car falling off resets before it lands
	local lo, hi = StarterMaps.bounds(map)
	local gx, gy, gz =
		StarterMaps.toWorld(map, (lo[1] + hi[1]) / 2, lo[2] - GROUND_BELOW, (lo[3] + hi[3]) / 2)
	local ground = part(
		model,
		"Ground",
		Vector3.new(hi[1] - lo[1] + GROUND_MARGIN * 2, 4, hi[3] - lo[3] + GROUND_MARGIN * 2),
		CFrame.new(gx, gy - 2, gz),
		PALETTE.ground
	)
	ground.Material = Enum.Material.Grass
	model.Parent = folder
	built[map.id] = model
	return model
end

function MapBuilder.get(mapId: string): Model?
	return built[mapId]
end

return MapBuilder
