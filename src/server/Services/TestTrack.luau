-- TestTrack: the milestone 1 test track, built from code so it lives in git. From milestone 2 players
-- start on the starter maps; Studio and admins reach this track from the dev panel (Map.Go "test_track").
-- It holds one of everything the feel and crash tests need: a long flat strip with distance marks and a
-- crash wall, ramps and a kicker, a 20-stud drop tower, a hill for air time, a bouncer and a speed pad,
-- loose foam cubes to knock around, a sand patch for dust, and checkpoints.
-- PLACEHOLDER ART: plain parts in the toy-foam palette. Pip's Hill and the real maps come in milestone 2.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local TestTrack = {}

local PALETTE = {
	ground = Color3.fromRGB(122, 204, 120),
	road = Color3.fromRGB(70, 74, 86),
	line = Color3.fromRGB(245, 245, 245),
	ramp = Color3.fromRGB(255, 166, 77),
	kicker = Color3.fromRGB(255, 92, 92),
	tower = Color3.fromRGB(160, 140, 255),
	wall = Color3.fromRGB(170, 170, 178),
	foam = {
		Color3.fromRGB(255, 120, 160),
		Color3.fromRGB(110, 200, 255),
		Color3.fromRGB(255, 220, 90),
		Color3.fromRGB(150, 230, 130),
	},
	bouncer = Color3.fromRGB(60, 160, 255),
	speed = Color3.fromRGB(255, 230, 60),
	flag = Color3.fromRGB(60, 220, 130),
	spawn = Color3.fromRGB(255, 255, 255),
	sand = Color3.fromRGB(230, 205, 140),
}

local root: Model

local function block(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = root
	return part
end

-- A slab ramp whose top surface runs from `low` to `high` (both top-surface edge centres).
local function ramp(name: string, low: Vector3, high: Vector3, width: number, color: Color3): Part
	local thickness = 2
	local length = (high - low).Magnitude
	local mid = (low + high) / 2
	local cf = CFrame.lookAt(mid, high) * CFrame.new(0, -thickness / 2, 0)
	-- Extend slightly at the low end so there is no lip where it meets the ground
	return block(name, Vector3.new(width, thickness, length + 1), cf * CFrame.new(0, 0, 0.5), color)
end

local function label(part: BasePart, text: string, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.Parent = part
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextScaled = true
	textLabel.Font = Enum.Font.FredokaOne
	textLabel.TextColor3 = Color3.fromRGB(40, 40, 50)
	textLabel.Parent = gui
end

local function checkpoint(index: number, groundCenter: Vector3, facing: Vector3)
	local height = 12
	local cf = CFrame.lookAt(groundCenter, groundCenter + facing) + Vector3.new(0, height / 2, 0)
	local trigger = block("Checkpoint_" .. index, Vector3.new(34, height, 2), cf, PALETTE.flag)
	trigger.Transparency = 1
	trigger.CanCollide = false
	trigger.CanQuery = false
	trigger.CanTouch = true
	trigger:SetAttribute("Index", index)
	trigger:SetAttribute("GroundOffset", height / 2)
	CollectionService:AddTag(trigger, "Checkpoint")
	for _, side in { -1, 1 } do
		local pole = block(
			"FlagPole",
			Vector3.new(0.6, 10, 0.6),
			cf * CFrame.new(side * 17, -height / 2 + 5, 0),
			Color3.fromRGB(240, 240, 240)
		)
		pole.CanCollide = false
	end
	local banner = block(
		"FlagBanner",
		Vector3.new(34, 2, 0.4),
		cf * CFrame.new(0, -height / 2 + 9, 0),
		PALETTE.flag,
		Enum.Material.SmoothPlastic
	)
	banner.CanCollide = false
	label(banner, "CHECKPOINT " .. index, Enum.NormalId.Back)
	label(banner, "CHECKPOINT " .. index, Enum.NormalId.Front)
end

local function pad(name: string, tag: string, center: Vector3, facing: Vector3, color: Color3)
	local cf = CFrame.lookAt(center, center + facing)
	local visual =
		block(name, Vector3.new(16, 0.6, 16), cf + Vector3.new(0, 0.3, 0), color, Enum.Material.Neon)
	visual.CanCollide = false
	visual.CanQuery = false
	visual.CanTouch = false
	-- The chassis rides well above the ground, so the trigger is a tall invisible volume over the pad
	local trigger = block(name .. "Trigger", Vector3.new(16, 6, 16), cf + Vector3.new(0, 3, 0), color)
	trigger.Transparency = 1
	trigger.CanCollide = false
	trigger.CanQuery = false
	trigger.CanTouch = true
	CollectionService:AddTag(trigger, tag)
	return trigger
end

function TestTrack.spawnCFrame(slot: number): CFrame
	local column = (slot - 1) % 12
	local row = math.floor((slot - 1) / 12)
	local position = Vector3.new(-44 + column * 8, 0, 60 + row * 14)
	return CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
end

-- The dev panel's scripted tests use the spots in Config.TestTrack (accel strip start, open ground, drop
-- spot); keep this layout clear around them.
TestTrack.CRASH_WALL_Z = Config.TestTrack.crashWallZ

function TestTrack.build()
	root = Instance.new("Model")
	root.Name = "TestTrack"
	root.ModelStreamingMode = Enum.ModelStreamingMode.Default

	-- Ground
	block("Ground", Vector3.new(1400, 4, 1400), CFrame.new(0, -2, -200), PALETTE.ground)

	-- Spawn row
	for slot = 1, 12 do
		local cf = TestTrack.spawnCFrame(slot)
		local mark = block("SpawnMark", Vector3.new(6, 0.1, 10), cf + Vector3.new(0, 0.05, 0), PALETTE.spawn)
		mark.CanCollide = false
		mark.Transparency = 0.4
	end

	-- Accel strip: 800 studs of road, a line every 100 studs, crash wall at the end
	block(
		"AccelStrip",
		Vector3.new(40, 0.2, 820),
		CFrame.new(0, 0.1, -350),
		PALETTE.road,
		Enum.Material.Asphalt
	)
	for i = 0, 7 do
		local z = 30 - i * 100
		local line =
			block("Mark_" .. i * 100, Vector3.new(40, 0.05, 1), CFrame.new(0, 0.225, z), PALETTE.line)
		line.CanCollide = false
		local sign = block("Sign_" .. i * 100, Vector3.new(6, 4, 0.5), CFrame.new(24, 4, z), PALETTE.line)
		label(sign, tostring(i * 100), Enum.NormalId.Back)
		label(sign, tostring(i * 100), Enum.NormalId.Front)
	end
	local wall = block(
		"CrashWall",
		Vector3.new(60, 20, 4),
		CFrame.new(0, 10, TestTrack.CRASH_WALL_Z - 2),
		PALETTE.wall,
		Enum.Material.Concrete
	)
	label(wall, "CRASH WALL", Enum.NormalId.Back)

	-- Ramp zone (x = 140)
	ramp("RampSmall", Vector3.new(140, 0, -100), Vector3.new(140, 4, -120), 24, PALETTE.ramp)
	ramp("RampBig", Vector3.new(140, 0, -200), Vector3.new(140, 10, -245), 24, PALETTE.ramp)
	ramp("Kicker", Vector3.new(140, 0, -330), Vector3.new(140, 6, -338), 16, PALETTE.kicker)

	-- Drop tower (x = -160): a long ramp up to a 20-stud platform that ends in a sheer drop
	ramp("TowerRamp", Vector3.new(-160, 0, 0), Vector3.new(-160, 20, -120), 40, PALETTE.tower)
	block("TowerTop", Vector3.new(40, 20, 40), CFrame.new(-160, 10, -140), PALETTE.tower)

	-- Air-time hill (x = -160)
	ramp("HillUp", Vector3.new(-160, 0, -360), Vector3.new(-160, 12, -400), 32, PALETTE.ramp)
	block("HillTop", Vector3.new(32, 12, 20), CFrame.new(-160, 6, -410), PALETTE.ramp)
	ramp("HillDown", Vector3.new(-160, 0, -460), Vector3.new(-160, 12, -420), 32, PALETTE.ramp)

	-- Pads (x = 220)
	pad("Bouncer", "Bouncer", Vector3.new(220, 0, -150), Vector3.new(0, 0, -1), PALETTE.bouncer)
	pad("SpeedPad", "SpeedPad", Vector3.new(220, 0, -260), Vector3.new(0, 0, -1), PALETTE.speed)

	-- Crash zone: anchored foam blocks and loose foam cubes
	for i = 0, 5 do
		block(
			"FoamBlock",
			Vector3.new(8, 6, 8),
			CFrame.new(-60 + i * 12, 3, -620),
			PALETTE.foam[i % #PALETTE.foam + 1],
			Enum.Material.SmoothPlastic
		)
	end
	for i = 0, 9 do
		local cube = block(
			"FoamCube",
			Vector3.new(4, 4, 4),
			CFrame.new(60 + (i % 5) * 5, 2 + math.floor(i / 5) * 4, -520),
			PALETTE.foam[i % #PALETTE.foam + 1]
		)
		cube.Anchored = false
		cube.CustomPhysicalProperties = PhysicalProperties.new(0.2, 0.5, 0.2)
	end

	-- Sand patch for dust puffs
	block("Sand", Vector3.new(80, 0.2, 80), CFrame.new(-40, 0.1, -540), PALETTE.sand, Enum.Material.Sand)

	-- Checkpoints
	checkpoint(1, Vector3.new(0, 0, -300), Vector3.new(0, 0, -1))
	checkpoint(2, Vector3.new(140, 0, -400), Vector3.new(0, 0, -1))
	checkpoint(3, Vector3.new(-160, 20, -140), Vector3.new(0, 0, -1))

	-- Welcome sign
	local sign = block("WelcomeBanner", Vector3.new(44, 5, 1), CFrame.new(0, 15, -40), PALETTE.line)
	sign.CanCollide = false
	label(sign, "RAGDOLL RIDES TEST TRACK", Enum.NormalId.Back)

	root.Parent = workspace
end

return TestTrack
