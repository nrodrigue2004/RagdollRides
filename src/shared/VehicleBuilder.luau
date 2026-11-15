-- VehicleBuilder: builds a drivable vehicle model from Config (server side).
-- The car is one physics assembly: an invisible box "Chassis" carries all the mass and collides; every
-- visual part is massless, welded and has no collision. Wheels are visual only: Motor6Ds whose Transform the
-- clients set each frame from the suspension (so the spec's raycast suspension, not Roblox wheel
-- constraints, does the driving).
--
-- PLACEHOLDER ART: the bodies below are toy-foam blockouts so the physics can be tested. The real vehicle
-- models (20 to 30 parts, 3 looks per panel) are built in Studio later; keep the part names, since damage
-- (milestone 1b) finds panels by name: Panel_Front, Panel_Rear, Panel_Left, Panel_Right, Panel_Roof,
-- Bumper_Front, Bumper_Rear, Glass_*.

local Config = require(script.Parent.Config)

local VehicleBuilder = {}

VehicleBuilder.WHEEL_NAMES = { "FL", "FR", "RL", "RR" }

type PartSpec = {
	name: string,
	size: { number },
	pos: { number },
	color: string, -- "paint" | "trim" | "glass" | "dark" | "light" | "seat"
	shape: string?, -- "Block" (default), "Wedge", "Cylinder", "Ball"
	rot: { number }?, -- degrees x, y, z
	transparency: number?,
	material: string?,
}

-- Body blockouts per class, in chassis space (car faces -Z).
local BODIES: { [string]: { PartSpec } } = {
	Buggy = {
		{ name = "Panel_Floor", size = { 4.2, 0.7, 7 }, pos = { 0, -0.35, 0 }, color = "paint" },
		{ name = "Panel_Front", size = { 3.6, 1.0, 1.9 }, pos = { 0, 0.1, -3.35 }, color = "paint" },
		{ name = "Bumper_Front", size = { 4.6, 0.6, 0.6 }, pos = { 0, -0.3, -4.4 }, color = "trim" },
		{ name = "Panel_Rear", size = { 3.4, 1.3, 1.8 }, pos = { 0, 0.4, 3.1 }, color = "trim" },
		{ name = "Bumper_Rear", size = { 4.6, 0.6, 0.6 }, pos = { 0, -0.3, 4.3 }, color = "trim" },
		{ name = "Panel_Left", size = { 0.6, 0.9, 4 }, pos = { -2.2, 0.15, 0 }, color = "paint" },
		{ name = "Panel_Right", size = { 0.6, 0.9, 4 }, pos = { 2.2, 0.15, 0 }, color = "paint" },
		{
			name = "Panel_Roof",
			size = { 3.9, 0.3, 2.7 },
			pos = { 0, 3.45, 0.4 },
			color = "trim",
			transparency = 0,
		},
		{ name = "Cage_FL", size = { 0.3, 3.2, 0.3 }, pos = { -1.8, 1.85, -0.9 }, color = "trim" },
		{ name = "Cage_FR", size = { 0.3, 3.2, 0.3 }, pos = { 1.8, 1.85, -0.9 }, color = "trim" },
		{ name = "Cage_RL", size = { 0.3, 3.2, 0.3 }, pos = { -1.8, 1.85, 1.7 }, color = "trim" },
		{ name = "Cage_RR", size = { 0.3, 3.2, 0.3 }, pos = { 1.8, 1.85, 1.7 }, color = "trim" },
		{ name = "SeatBack", size = { 2, 1.8, 0.4 }, pos = { 0, 1.0, 1.35 }, color = "seat" },
		{
			name = "SteeringWheel",
			size = { 0.2, 1.1, 1.1 },
			pos = { 0, 1.35, -1.2 },
			color = "dark",
			shape = "Cylinder",
			rot = { 0, 90, 60 },
		},
	},
	Sedan = {
		{ name = "Panel_Floor", size = { 6, 1.4, 10.6 }, pos = { 0, -0.3, 0 }, color = "paint" },
		{ name = "Panel_Front", size = { 5.7, 0.5, 3.4 }, pos = { 0, 0.65, -3.5 }, color = "paint" },
		{ name = "Panel_Rear", size = { 5.7, 0.5, 2.4 }, pos = { 0, 0.65, 4.0 }, color = "paint" },
		{ name = "Panel_Left", size = { 0.3, 1.3, 4.2 }, pos = { -3.05, 0.25, 0.2 }, color = "paint" },
		{ name = "Panel_Right", size = { 0.3, 1.3, 4.2 }, pos = { 3.05, 0.25, 0.2 }, color = "paint" },
		{ name = "Panel_Roof", size = { 5.2, 0.35, 4.0 }, pos = { 0, 2.85, 0.3 }, color = "paint" },
		{ name = "Pillar_FL", size = { 0.35, 2.0, 0.35 }, pos = { -2.55, 1.8, -1.6 }, color = "trim" },
		{ name = "Pillar_FR", size = { 0.35, 2.0, 0.35 }, pos = { 2.55, 1.8, -1.6 }, color = "trim" },
		{ name = "Pillar_RL", size = { 0.35, 2.0, 0.35 }, pos = { -2.55, 1.8, 2.2 }, color = "trim" },
		{ name = "Pillar_RR", size = { 0.35, 2.0, 0.35 }, pos = { 2.55, 1.8, 2.2 }, color = "trim" },
		{
			name = "Glass_Front",
			size = { 4.8, 2.1, 0.15 },
			pos = { 0, 1.8, -1.75 },
			color = "glass",
			rot = { -20, 0, 0 },
			transparency = 0.55,
		},
		{
			name = "Glass_Rear",
			size = { 4.8, 2.0, 0.15 },
			pos = { 0, 1.8, 2.35 },
			color = "glass",
			rot = { 18, 0, 0 },
			transparency = 0.55,
		},
		{ name = "Bumper_Front", size = { 6.3, 0.8, 0.7 }, pos = { 0, -0.55, -5.55 }, color = "trim" },
		{ name = "Bumper_Rear", size = { 6.3, 0.8, 0.7 }, pos = { 0, -0.55, 5.55 }, color = "trim" },
		{
			name = "Light_FL",
			size = { 1.2, 0.5, 0.2 },
			pos = { -2.1, 0.15, -5.32 },
			color = "light",
			material = "Neon",
		},
		{
			name = "Light_FR",
			size = { 1.2, 0.5, 0.2 },
			pos = { 2.1, 0.15, -5.32 },
			color = "light",
			material = "Neon",
		},
		{ name = "SeatBack", size = { 1.8, 1.8, 0.4 }, pos = { -1.1, 0.8, 1.2 }, color = "seat" },
	},
	Truck = {
		{ name = "Panel_Floor", size = { 7, 1.4, 13 }, pos = { 0, -0.5, 0 }, color = "trim" },
		{ name = "Panel_Front", size = { 6.6, 1.4, 3.4 }, pos = { 0, 0.85, -4.7 }, color = "paint" },
		{ name = "Panel_Left", size = { 0.3, 2.6, 3.4 }, pos = { -3.4, 1.0, -1.9 }, color = "paint" },
		{ name = "Panel_Right", size = { 0.3, 2.6, 3.4 }, pos = { 3.4, 1.0, -1.9 }, color = "paint" },
		{ name = "Panel_Roof", size = { 6.6, 0.4, 3.4 }, pos = { 0, 3.55, -1.9 }, color = "paint" },
		{
			name = "Glass_Front",
			size = { 6.0, 2.2, 0.15 },
			pos = { 0, 2.3, -3.6 },
			color = "glass",
			rot = { -12, 0, 0 },
			transparency = 0.55,
		},
		{ name = "Panel_Rear", size = { 6.8, 1.5, 6.4 }, pos = { 0, 0.85, 3.2 }, color = "paint" },
		{ name = "Bed_Floor", size = { 6.2, 0.3, 6.0 }, pos = { 0, 1.5, 3.2 }, color = "dark" },
		{ name = "Bumper_Front", size = { 7.4, 0.9, 0.8 }, pos = { 0, -0.6, -6.6 }, color = "dark" },
		{ name = "Bumper_Rear", size = { 7.4, 0.9, 0.8 }, pos = { 0, -0.6, 6.6 }, color = "dark" },
		{
			name = "Light_FL",
			size = { 1.3, 0.6, 0.2 },
			pos = { -2.4, 0.9, -6.42 },
			color = "light",
			material = "Neon",
		},
		{
			name = "Light_FR",
			size = { 1.3, 0.6, 0.2 },
			pos = { 2.4, 0.9, -6.42 },
			color = "light",
			material = "Neon",
		},
		{ name = "SeatBack", size = { 2.2, 2.0, 0.4 }, pos = { -1.3, 1.1, -1.4 }, color = "seat" },
	},
	Bus = {
		{ name = "Panel_Floor", size = { 7.5, 1.4, 20 }, pos = { 0, -1.8, 0 }, color = "trim" },
		{ name = "Panel_Front", size = { 7.3, 2.6, 0.5 }, pos = { 0, -0.6, -9.8 }, color = "paint" },
		{ name = "Panel_Rear", size = { 7.3, 4.4, 0.5 }, pos = { 0, 0.3, 9.8 }, color = "paint" },
		{ name = "Panel_Left", size = { 0.3, 2.4, 19.6 }, pos = { -3.7, -0.7, 0 }, color = "paint" },
		{ name = "Panel_Right", size = { 0.3, 2.4, 19.6 }, pos = { 3.7, -0.7, 0 }, color = "paint" },
		{ name = "Panel_Roof", size = { 7.5, 0.5, 20 }, pos = { 0, 2.75, 0 }, color = "paint" },
		{
			name = "Glass_Left",
			size = { 0.2, 2.0, 17 },
			pos = { -3.7, 1.5, 0.8 },
			color = "glass",
			transparency = 0.55,
		},
		{
			name = "Glass_Right",
			size = { 0.2, 2.0, 17 },
			pos = { 3.7, 1.5, 0.8 },
			color = "glass",
			transparency = 0.55,
		},
		{
			name = "Glass_Front",
			size = { 7.0, 2.0, 0.15 },
			pos = { 0, 1.5, -9.85 },
			color = "glass",
			transparency = 0.55,
		},
		{ name = "Stripe", size = { 7.6, 0.4, 20.1 }, pos = { 0, 0.3, 0 }, color = "trim" },
		{ name = "Bumper_Front", size = { 7.8, 0.9, 0.7 }, pos = { 0, -2.1, -10.2 }, color = "dark" },
		{ name = "Bumper_Rear", size = { 7.8, 0.9, 0.7 }, pos = { 0, -2.1, 10.2 }, color = "dark" },
		{
			name = "Light_FL",
			size = { 1.3, 0.7, 0.2 },
			pos = { -2.6, -1.2, -10.08 },
			color = "light",
			material = "Neon",
		},
		{
			name = "Light_FR",
			size = { 1.3, 0.7, 0.2 },
			pos = { 2.6, -1.2, -10.08 },
			color = "light",
			material = "Neon",
		},
		{ name = "SeatBack", size = { 2.2, 2.0, 0.4 }, pos = { -2, -0.5, -6.6 }, color = "seat" },
	},
}

local FIXED_COLORS = {
	glass = Color3.fromRGB(170, 220, 255),
	dark = Color3.fromRGB(40, 40, 46),
	light = Color3.fromRGB(255, 250, 220),
	seat = Color3.fromRGB(60, 60, 70),
	tyre = Color3.fromRGB(32, 32, 36),
}

local function quietPart(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function weldTo(part0: BasePart, part1: BasePart, c0: CFrame)
	local weld = Instance.new("Weld")
	weld.Name = "Weld_" .. part1.Name
	weld.Part0 = part0
	weld.Part1 = part1
	weld.C0 = c0
	weld.C1 = CFrame.identity
	weld.Parent = part1
	return weld
end

local function makePart(spec: PartSpec, colors: { [string]: Color3 }): BasePart
	local part: BasePart
	if spec.shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if spec.shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif spec.shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		end
		part = p
	end
	part.Name = spec.name
	part.Size = Config.vec3(spec.size)
	part.Color = colors[spec.color] or FIXED_COLORS[spec.color] or Color3.new(1, 1, 1)
	part.Material = if spec.material
		then (Enum.Material :: any)[spec.material]
		else Enum.Material.SmoothPlastic
	part.Transparency = spec.transparency or 0
	quietPart(part)
	return part
end

-- Wheel mount positions in chassis space, in FL, FR, RL, RR order.
function VehicleBuilder.mountOffsets(class: Config.ClassStats): { Vector3 }
	return {
		Vector3.new(-class.halfTrack, class.mountY, class.frontAxleZ),
		Vector3.new(class.halfTrack, class.mountY, class.frontAxleZ),
		Vector3.new(-class.halfTrack, class.mountY, class.rearAxleZ),
		Vector3.new(class.halfTrack, class.mountY, class.rearAxleZ),
	}
end

function VehicleBuilder.chassisMass(class: Config.ClassStats): number
	return class.relativeMass * Config.Driving.baseMass
end

function VehicleBuilder.build(vehicleId: string, ownerUserId: number): Model
	local def = Config.Vehicles[vehicleId]
	assert(def, "Unknown vehicle " .. tostring(vehicleId))
	local class = Config.Classes[def.class]
	assert(class, "Unknown class " .. tostring(def.class))

	local colors = {
		paint = Config.color3(def.paint),
		trim = Config.color3(def.trim),
	}

	local model = Instance.new("Model")
	model.Name = "Vehicle_" .. ownerUserId
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("ClassId", class.id)
	model:SetAttribute("OwnerUserId", ownerUserId)

	-- Chassis: the only collider and the only mass
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = Config.vec3(class.colliderSize)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CanTouch = true
	chassis.CanQuery = true
	chassis.Anchored = false
	chassis.CollisionGroup = "Vehicles"
	local volume = chassis.Size.X * chassis.Size.Y * chassis.Size.Z
	local density = math.clamp(VehicleBuilder.chassisMass(class) / volume, 0.01, 100)
	-- Low friction so a car sliding on its roof or side scrapes along; elasticity weight keeps hits dead.
	chassis.CustomPhysicalProperties = PhysicalProperties.new(density, 0.25, 0, 1, 100)
	chassis.Parent = model
	model.PrimaryPart = chassis

	local center = Instance.new("Attachment")
	center.Name = "Center"
	center.Parent = chassis

	local seat = Instance.new("Attachment")
	seat.Name = "Seat"
	seat.Position = Config.vec3(class.seatOffset)
	seat.Parent = chassis

	-- Body panels
	local body = Instance.new("Folder")
	body.Name = "Body"
	body.Parent = model
	for _, spec in BODIES[class.id] do
		local part = makePart(spec, colors)
		local rot = spec.rot or { 0, 0, 0 }
		local offset = CFrame.new(Config.vec3(spec.pos))
			* CFrame.Angles(math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3]))
		part.CFrame = chassis.CFrame * offset
		weldTo(chassis, part, offset)
		part.Parent = body
	end

	-- Wheels (visual). Motor6D C0 sits at the suspension mount; clients drop the wheel by the extension.
	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = model
	for index, mount in VehicleBuilder.mountOffsets(class) do
		local name = VehicleBuilder.WHEEL_NAMES[index]
		local mountAttachment = Instance.new("Attachment")
		mountAttachment.Name = "Mount_" .. name
		mountAttachment.Position = mount
		mountAttachment.Parent = chassis

		local wheel = Instance.new("Part")
		wheel.Name = "Wheel_" .. name
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(class.wheelWidth, class.wheelRadius * 2, class.wheelRadius * 2)
		wheel.Color = FIXED_COLORS.tyre
		wheel.Material = Enum.Material.SmoothPlastic
		quietPart(wheel)
		wheel.CFrame = chassis.CFrame * CFrame.new(mount)
		wheel.Parent = wheels

		local hub = Instance.new("Part")
		hub.Name = "Hub"
		hub.Shape = Enum.PartType.Cylinder
		hub.Size = Vector3.new(class.wheelWidth + 0.1, class.wheelRadius, class.wheelRadius)
		hub.Color = colors.trim
		hub.Material = Enum.Material.SmoothPlastic
		quietPart(hub)
		hub.CFrame = wheel.CFrame
		hub.Parent = wheel
		weldTo(wheel, hub, CFrame.identity)

		-- A spoke so wheel spin reads on screen
		local spoke = Instance.new("Part")
		spoke.Name = "Spoke"
		spoke.Size = Vector3.new(class.wheelWidth + 0.14, 0.3, class.wheelRadius * 1.6)
		spoke.Color = colors.paint
		spoke.Material = Enum.Material.SmoothPlastic
		quietPart(spoke)
		spoke.CFrame = wheel.CFrame
		spoke.Parent = wheel
		weldTo(wheel, spoke, CFrame.identity)

		local motor = Instance.new("Motor6D")
		motor.Name = "WheelMotor_" .. name
		motor.Part0 = chassis
		motor.Part1 = wheel
		motor.C0 = CFrame.new(mount)
		motor.C1 = CFrame.identity
		motor.Parent = chassis
	end

	return model
end

return VehicleBuilder
