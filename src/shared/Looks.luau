-- Looks: cosmetics on a car and its rider (spec: Progression, Garage). Looks only: nothing here
-- touches mass, collision or handling (design pillar: nothing sold changes stats).
-- * Vehicle (server, on spawn and when the player equips something): paint recolours the body's paint
--   panels, rims recolour the hubs, a part or decal adds a massless, non-colliding look part. Trail,
--   second trail (VIP), horn and explosion style are model attributes the clients read (Fx/LookFx,
--   ExplosionFx).
-- * Rider (each client builds riders locally): the outfit recolours the suit, the hat sits on the
--   helmet. The server copies the rider's choices onto the car model (RiderOutfit, RiderHat).
-- PLACEHOLDER ART: look parts and hats are simple blocks and cylinders until the art pass.

local Shared = script.Parent
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)

local Looks = {}

export type VehicleLooks = {
	paint: string?,
	rims: string?,
	trail: string?,
	trail2: string?,
	horn: string?,
	explosion: string?,
	decal: string?,
	part: string?,
}

local function itemColor(id: string?): (Color3?, Enum.Material?)
	local item = id and Catalog.byId[id]
	if item == nil or item.color == nil then
		return nil, nil
	end
	local material = if item.material then (Enum.Material :: any)[item.material] else nil
	return Config.color3(item.color), material
end

local function lookPart(
	model: Model,
	chassis: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3
)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = chassis.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = chassis
	weld.Part1 = part
	weld.Parent = part
	part.Parent = model:FindFirstChild("Body") or model
	return part
end

-- The shapes of the look parts and decals, sized from the car's collider
local SHAPES: { [string]: (Vector3) -> { { size: Vector3, offset: CFrame } } } = {
	part_spoiler = function(c)
		return {
			{ size = Vector3.new(c.X * 0.9, 0.2, 1.2), offset = CFrame.new(0, c.Y * 0.5 + 1.6, c.Z * 0.45) },
			{
				size = Vector3.new(0.2, 1.4, 0.3),
				offset = CFrame.new(-c.X * 0.3, c.Y * 0.5 + 0.9, c.Z * 0.45),
			},
			{
				size = Vector3.new(0.2, 1.4, 0.3),
				offset = CFrame.new(c.X * 0.3, c.Y * 0.5 + 0.9, c.Z * 0.45),
			},
		}
	end,
	part_bullbar = function(c)
		return {
			{ size = Vector3.new(c.X * 0.85, 0.3, 0.3), offset = CFrame.new(0, 0.6, -c.Z * 0.5 - 0.5) },
			{ size = Vector3.new(c.X * 0.85, 0.3, 0.3), offset = CFrame.new(0, -0.2, -c.Z * 0.5 - 0.5) },
			{ size = Vector3.new(0.3, 1.1, 0.3), offset = CFrame.new(-c.X * 0.3, 0.2, -c.Z * 0.5 - 0.5) },
			{ size = Vector3.new(0.3, 1.1, 0.3), offset = CFrame.new(c.X * 0.3, 0.2, -c.Z * 0.5 - 0.5) },
		}
	end,
	part_roofrack = function(c)
		return {
			{ size = Vector3.new(c.X * 0.7, 0.2, c.Z * 0.35), offset = CFrame.new(0, c.Y * 0.5 + 2.4, 0.3) },
		}
	end,
	part_fins = function(c)
		return {
			{
				size = Vector3.new(0.2, 1.2, 1.4),
				offset = CFrame.new(-c.X * 0.35, c.Y * 0.5 + 1.0, c.Z * 0.35),
			},
			{
				size = Vector3.new(0.2, 1.2, 1.4),
				offset = CFrame.new(c.X * 0.35, c.Y * 0.5 + 1.0, c.Z * 0.35),
			},
		}
	end,
	-- Decals as thin strips on the body
	decal_stripes = function(c)
		return {
			{ size = Vector3.new(0.5, 0.06, c.Z * 0.9), offset = CFrame.new(-0.5, c.Y * 0.5 + 0.55, 0) },
			{ size = Vector3.new(0.5, 0.06, c.Z * 0.9), offset = CFrame.new(0.5, c.Y * 0.5 + 0.55, 0) },
		}
	end,
	decal_number = function(c)
		return {
			{ size = Vector3.new(0.06, 1.0, 1.0), offset = CFrame.new(-c.X * 0.5 - 0.05, 0.4, 0) },
			{ size = Vector3.new(0.06, 1.0, 1.0), offset = CFrame.new(c.X * 0.5 + 0.05, 0.4, 0) },
		}
	end,
	decal_flames = function(c)
		return {
			{
				size = Vector3.new(0.06, 0.5, c.Z * 0.45),
				offset = CFrame.new(-c.X * 0.5 - 0.05, 0.2, -c.Z * 0.2),
			},
			{
				size = Vector3.new(0.06, 0.5, c.Z * 0.45),
				offset = CFrame.new(c.X * 0.5 + 0.05, 0.2, -c.Z * 0.2),
			},
		}
	end,
	decal_stars = function(c)
		return {
			{ size = Vector3.new(0.7, 0.06, 0.7), offset = CFrame.new(0, c.Y * 0.5 + 0.55, -c.Z * 0.3) },
		}
	end,
	-- Ranked season reward: a bolt badge on the bonnet and both doors
	decal_bronze_bolt = function(c)
		return {
			{ size = Vector3.new(0.6, 0.06, 1.1), offset = CFrame.new(0, c.Y * 0.5 + 0.55, -c.Z * 0.3) },
			{ size = Vector3.new(0.06, 0.9, 0.5), offset = CFrame.new(-c.X * 0.5 - 0.05, 0.4, 0) },
			{ size = Vector3.new(0.06, 0.9, 0.5), offset = CFrame.new(c.X * 0.5 + 0.05, 0.4, 0) },
		}
	end,
	mastery_badge = function(c)
		return {
			{ size = Vector3.new(0.8, 0.06, 0.8), offset = CFrame.new(0, c.Y * 0.5 + 0.55, -c.Z * 0.3) },
		}
	end,
	mastery_flames = function(c)
		return {
			{
				size = Vector3.new(0.06, 0.6, c.Z * 0.5),
				offset = CFrame.new(-c.X * 0.5 - 0.05, 0.2, -c.Z * 0.2),
			},
			{
				size = Vector3.new(0.06, 0.6, c.Z * 0.5),
				offset = CFrame.new(c.X * 0.5 + 0.05, 0.2, -c.Z * 0.2),
			},
		}
	end,
}

-- Put a car's looks on it (also takes old look parts off). looks may be nil for the defaults.
function Looks.vehicle(model: Model, looks: VehicleLooks?)
	local chassis = model.PrimaryPart
	local vehicleId = model:GetAttribute("VehicleId")
	local def = vehicleId and Config.Vehicles[vehicleId]
	if chassis == nil or def == nil then
		return
	end
	looks = looks or {}
	local paint, paintMaterial = itemColor(looks.paint)
	local rims, rimsMaterial = itemColor(looks.rims)
	local basePaint = Config.color3(def.paint)
	local baseTrim = Config.color3(def.trim)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("ColorRole")
			if role == "paint" or d.Name == "Spoke" then
				d.Color = paint or basePaint
				d.Material = paintMaterial or Enum.Material.SmoothPlastic
				-- The clean look, for the damage looks to darken from and repairs to go back to (the
				-- client writes Color locally while dented, so it can't read the paint back from Color)
				d:SetAttribute("BaseColor", d.Color)
				d:SetAttribute("BaseMaterial", d.Material.Name)
			elseif d.Name == "Hub" then
				d.Color = rims or baseTrim
				d.Material = rimsMaterial or Enum.Material.SmoothPlastic
				d:SetAttribute("BaseColor", d.Color)
				d:SetAttribute("BaseMaterial", d.Material.Name)
			elseif d:GetAttribute("LookPart") then
				d:Destroy()
			end
		end
	end
	local size = chassis.Size
	for _, id in { looks.part, looks.decal } do
		local shape = id and SHAPES[id]
		local color = itemColor(id)
		if shape and color then
			for index, spec in shape(size) do
				local p =
					lookPart(model, chassis, "Look_" .. id .. "_" .. index, spec.size, spec.offset, color)
				p:SetAttribute("LookPart", true)
			end
		end
	end
	model:SetAttribute("Trail", looks.trail)
	model:SetAttribute("Trail2", looks.trail2)
	model:SetAttribute("Horn", looks.horn)
	model:SetAttribute("ExplosionStyle", looks.explosion)
end

-- A rider's outfit and hat (client: parts from RagdollClient's rig, s = the rider's scale)
function Looks.rider(parts: { [string]: BasePart }, outfitId: string?, hatId: string?, s: number)
	local suit = itemColor(outfitId)
	if suit then
		for _, name in { "Torso", "LeftArm", "RightArm" } do
			if parts[name] then
				parts[name].Color = suit
			end
		end
	end
	local head = parts.Head
	local hatColor = itemColor(hatId)
	if head == nil or hatColor == nil or hatId == nil then
		return
	end
	local hat = Instance.new("Part")
	hat.Name = "Hat"
	hat.Color = hatColor
	hat.Material = Enum.Material.SmoothPlastic
	hat.CanCollide = false
	hat.CanTouch = false
	hat.CanQuery = false
	hat.Massless = true
	hat.CastShadow = false
	local top = head.Size.Y / 2
	if hatId == "hat_cone" then
		hat.Shape = Enum.PartType.Cylinder
		hat.Size = Vector3.new(1.4 * s, 0.9 * s, 0.9 * s)
		hat.CFrame = head.CFrame * CFrame.new(0, top + 0.5 * s, 0) * CFrame.Angles(0, 0, math.rad(90))
	elseif hatId == "hat_crown" or hatId == "hat_chef" or hatId == "hat_apex_crown" then
		hat.Shape = Enum.PartType.Cylinder
		hat.Size = Vector3.new(0.8 * s, 1.1 * s, 1.1 * s)
		hat.CFrame = head.CFrame * CFrame.new(0, top + 0.25 * s, 0) * CFrame.Angles(0, 0, math.rad(90))
	else
		hat.Size = Vector3.new(1.2 * s, 0.35 * s, 1.3 * s)
		hat.CFrame = head.CFrame * CFrame.new(0, top + 0.05 * s, -0.1 * s)
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = head
	weld.Part1 = hat
	weld.Parent = hat
	hat.Parent = head.Parent
end

-- The looks saved for a vehicle in a profile (server)
function Looks.fromProfile(entry: { [string]: any }?): VehicleLooks
	if entry == nil then
		return {}
	end
	return {
		paint = entry.paint,
		rims = entry.rims,
		trail = entry.trail,
		trail2 = entry.trail2,
		horn = entry.horn,
		explosion = entry.explosion,
		decal = entry.decal,
		part = entry.parts and entry.parts[1] or nil,
	}
end

return Looks
