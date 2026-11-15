-- Road: builds the Sunny Pass road on this device around your car, from the run's road (Shared/
-- HighwayMath), and takes it down behind you (spec: Live parts (Highway): 150 road and prop parts,
-- streamed). Every device builds the same road from the same seed.
-- * One asphalt part per 50-stud segment (a stud longer so the bends leave no gaps) with dashed lane
--   lines, a grass plane under it that follows you, ramps across 2 lanes, Pit Wrench pickups and the
--   roadside props (cones, fences, signs, foam barriers, billboards) you can smash.
-- * Props carry the attribute HighwayProp (their id); hitting one is reported by HighwayClient. They do
--   not collide until hit, so a car smashes straight through and sends them flying.
-- PLACEHOLDER ART: plain parts for the road kit, ramps, wrenches and props.

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local HighwayMath = require(Shared.HighwayMath)

local Road = {}
Road.__index = Road

local cfg = Config.Highway

local ASPHALT = Color3.fromRGB(70, 72, 80)
local LINE = Color3.fromRGB(245, 245, 235)
local GRASS = Color3.fromRGB(120, 200, 90)

export type Builder = {
	def: HighwayMath.Road,
	event: HighwayMath.EventDef?,
	folder: Folder,
	segments: { [number]: { BasePart } },
	props: { [number]: { parts: { BasePart }, prop: HighwayMath.Prop } },
	broken: { [number]: boolean },
	ramps: { [number]: BasePart },
	wrenches: { [number]: BasePart },
	taken: { [number]: boolean },
	ground: BasePart,
	groundAt: Vector3,
	extraRamps: { HighwayMath.Ramp },
}

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

-- The CFrame at s, lateral studs to the right, at height y above the road top, facing along the road
function Road.frame(def: HighwayMath.Road, s: number, lateral: number, y: number): CFrame
	local x, z, h = HighwayMath.place(def, s, lateral)
	return CFrame.new(x, def.origin[2] + y, z) * CFrame.Angles(0, -h, 0)
end

-- extraRamps: ramps besides the seeded ones (the tutorial lane's ramp ahead), with negative indexes
function Road.new(
	def: HighwayMath.Road,
	event: HighwayMath.EventDef?,
	extraRamps: { HighwayMath.Ramp }?
): Builder
	local folder = Instance.new("Folder")
	folder.Name = "HighwayRoad"
	folder.Parent = Workspace
	local size = cfg.road.groundSize
	local ground = part(
		folder,
		"Grass",
		Vector3.new(size, 2, size),
		CFrame.new(def.origin[1], def.origin[2] - 1.3, def.origin[3]),
		GRASS
	)
	ground.Material = Enum.Material.Grass
	local self = {
		def = def,
		event = event,
		folder = folder,
		segments = {},
		props = {},
		broken = {},
		ramps = {},
		wrenches = {},
		taken = {},
		ground = ground,
		groundAt = ground.Position,
		extraRamps = extraRamps or {},
	}
	return setmetatable(self, Road) :: any
end

local function buildSegment(self: Builder, k: number): { BasePart }
	local def = self.def
	local seg = cfg.road.segment
	local s = (k + 0.5) * seg
	local width = def.lanes * def.laneWidth + 2 * cfg.road.shoulder
	local thickness = cfg.road.thickness
	local parts = {}
	local road = part(
		self.folder,
		"Road",
		Vector3.new(width, thickness, seg + 1),
		Road.frame(def, s, 0, -thickness / 2),
		ASPHALT
	)
	road.Material = Enum.Material.Asphalt
	table.insert(parts, road)
	-- Dashed lines between the lanes, and the solid edge lines
	for boundary = 1, def.lanes - 1 do
		local lateral = (def.lanes / 2 - boundary) * def.laneWidth
		local dash =
			part(self.folder, "Dash", Vector3.new(0.5, 0.1, 14), Road.frame(def, s, lateral, 0.05), LINE)
		dash.CanCollide = false
		dash.CanQuery = false
		dash.CanTouch = false
		table.insert(parts, dash)
	end
	return parts
end

local PROP_COLORS = {
	cone = Color3.fromRGB(255, 130, 40),
	fence = Color3.fromRGB(250, 250, 250),
	sign = Color3.fromRGB(60, 160, 255),
	barrier = Color3.fromRGB(255, 90, 60),
	billboard = Color3.fromRGB(255, 214, 90),
}

local function buildProp(self: Builder, prop: HighwayMath.Prop): { BasePart }
	local def = self.def
	local kind = prop.kind.id
	local color = PROP_COLORS[kind] or LINE
	local parts = {}
	local function add(name: string, size: Vector3, cf: CFrame, c: Color3?)
		local p = part(self.folder, name, size, cf, c or color)
		p:SetAttribute("HighwayProp", prop.id)
		p.CanCollide = false -- you smash straight through; it collides once it is flying
		p.CustomPhysicalProperties = PhysicalProperties.new(0.3, 0.5, 0.3)
		table.insert(parts, p)
		return p
	end
	local base = Road.frame(def, prop.s, prop.lateral, 0)
	if kind == "cone" then
		add("Cone", Vector3.new(1.4, 2.4, 1.4), base * CFrame.new(0, 1.2, 0))
	elseif kind == "fence" then
		add("Fence", Vector3.new(0.4, 2.6, 7), base * CFrame.new(0, 1.3, 0))
	elseif kind == "sign" then
		add("Post", Vector3.new(0.4, 6, 0.4), base * CFrame.new(0, 3, 0), Color3.fromRGB(180, 180, 190))
		add("Plate", Vector3.new(4, 2.6, 0.3), base * CFrame.new(0, 5.6, 0), color)
	elseif kind == "barrier" then
		local p = add("Barrier", Vector3.new(2.2, 3, 4), base * CFrame.new(0, 1.5, 0))
		p.Material = Enum.Material.Fabric
	elseif kind == "billboard" then
		local legColor = Color3.fromRGB(150, 150, 160)
		add("Leg", Vector3.new(0.8, 9, 0.8), base * CFrame.new(0, 4.5, -6), legColor)
		add("Leg", Vector3.new(0.8, 9, 0.8), base * CFrame.new(0, 4.5, 6), legColor)
		add("Board", Vector3.new(0.6, 8, 18), base * CFrame.new(0, 11, 0))
	end
	return parts
end

local function buildRamp(self: Builder, ramp: HighwayMath.Ramp): BasePart
	local def = self.def
	local r = cfg.ramps
	local lateral = (
		HighwayMath.laneOffset(def, ramp.lane) + HighwayMath.laneOffset(def, ramp.lane + r.lanes - 1)
	) / 2
	local wedge = Instance.new("WedgePart")
	wedge.Name = "Ramp"
	wedge.Anchored = true
	wedge.Size = Vector3.new(def.laneWidth * r.lanes - 1, r.height, r.length)
	-- The wedge's low edge faces the oncoming cars (a WedgePart rises toward its back, so turn it round)
	wedge.CFrame = Road.frame(def, ramp.s, lateral, r.height / 2) * CFrame.Angles(0, math.pi, 0)
	wedge.Color = Color3.fromRGB(255, 200, 60)
	wedge.Material = Enum.Material.SmoothPlastic
	wedge.Parent = self.folder
	return wedge
end

local function buildWrench(self: Builder, wrench: HighwayMath.Wrench): BasePart
	local def = self.def
	local p = part(
		self.folder,
		"PitWrench",
		Vector3.new(2.5, 2.5, 2.5),
		Road.frame(def, wrench.s, HighwayMath.laneOffset(def, wrench.lane), 3),
		Color3.fromRGB(255, 220, 60)
	)
	p.Material = Enum.Material.Neon
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p:SetAttribute("HighwayWrench", wrench.index)
	return p
end

-- Keep the road built from behind to ahead of s; returns nothing
function Road.update(self: Builder, s: number)
	local def = self.def
	local seg = cfg.road.segment
	local from, to = s - cfg.road.behind, s + cfg.road.ahead
	local first, last = math.floor(from / seg), math.floor(to / seg)
	for k, parts in self.segments do
		if k < first or k > last then
			for _, p in parts do
				p:Destroy()
			end
			self.segments[k] = nil
		end
	end
	for k = first, last do
		if self.segments[k] == nil then
			self.segments[k] = buildSegment(self, k)
		end
	end
	-- Props
	local wanted: { [number]: HighwayMath.Prop } = {}
	for _, prop in HighwayMath.propsBetween(def, from, to, cfg.props) do
		if not self.broken[prop.id] then
			wanted[prop.id] = prop
		end
	end
	for id, entry in self.props do
		if wanted[id] == nil and not self.broken[id] then
			for _, p in entry.parts do
				p:Destroy()
			end
			self.props[id] = nil
		end
	end
	for id, prop in wanted do
		if self.props[id] == nil then
			self.props[id] = { parts = buildProp(self, prop), prop = prop }
		end
	end
	-- Ramps
	local seen = {}
	local ramps = HighwayMath.rampsBetween(def, from, to, cfg.ramps, self.event)
	for _, ramp in self.extraRamps do
		if ramp.s >= from and ramp.s <= to then
			table.insert(ramps, ramp)
		end
	end
	for _, ramp in ramps do
		seen[ramp.index] = true
		if self.ramps[ramp.index] == nil then
			self.ramps[ramp.index] = buildRamp(self, ramp)
		end
	end
	for index, p in self.ramps do
		if not seen[index] then
			p:Destroy()
			self.ramps[index] = nil
		end
	end
	-- Pit Wrenches
	local seenWrench = {}
	for _, wrench in HighwayMath.wrenchesBetween(def, from, to, cfg.wrench.every) do
		seenWrench[wrench.index] = true
		if self.wrenches[wrench.index] == nil and not self.taken[wrench.index] then
			self.wrenches[wrench.index] = buildWrench(self, wrench)
		end
	end
	for index, p in self.wrenches do
		if not seenWrench[index] then
			p:Destroy()
			self.wrenches[index] = nil
		end
	end
	-- The grass follows you (it is flat, so moving it is never felt)
	local x, z = HighwayMath.at(def, s)
	if (Vector3.new(x, self.groundAt.Y, z) - self.groundAt).Magnitude > 300 then
		self.groundAt = Vector3.new(x, self.groundAt.Y, z)
		self.ground.CFrame = CFrame.new(self.groundAt)
	end
end

-- Spin the wrenches; returns the index of one within reach of the point, if any
function Road.stepWrenches(self: Builder, t: number, point: Vector3?): number?
	local hit: number? = nil
	for index, p in self.wrenches do
		local base = p.Position
		p.CFrame = CFrame.new(base) * CFrame.Angles(0, t * 2.5, math.rad(20))
		if point and (point - base).Magnitude <= cfg.wrench.radius then
			hit = index
		end
	end
	return hit
end

function Road.takeWrench(self: Builder, index: number)
	self.taken[index] = true
	local p = self.wrenches[index]
	if p then
		p:Destroy()
		self.wrenches[index] = nil
	end
end

-- A prop was hit: it comes loose and flies (it never comes back this run)
function Road.breakProp(self: Builder, id: number, velocity: Vector3)
	local entry = self.props[id]
	if entry == nil or self.broken[id] then
		return
	end
	self.broken[id] = true
	for _, p in entry.parts do
		p.Anchored = false
		p.CanCollide = true
		p.AssemblyLinearVelocity = velocity + Vector3.new(0, 12, 0)
		p.AssemblyAngularVelocity =
			Vector3.new(math.random() * 8 - 4, math.random() * 8 - 4, math.random() * 8 - 4)
	end
	task.delay(4, function()
		for _, p in entry.parts do
			p:Destroy()
		end
		if self.props[id] == entry then
			self.props[id] = nil
		end
	end)
end

function Road.propNear(self: Builder, id: number): boolean
	return self.props[id] ~= nil and not self.broken[id]
end

function Road.destroy(self: Builder)
	self.folder:Destroy()
end

return Road
