-- MeshDents: real dents in the body shell, on top of the panel swaps (spec: Mesh deformation).
-- The shell is rebuilt on this device as an EditableMesh (a subdivided box the size of the body shell part,
-- under 1,500 vertices) and every hit pushes its vertices in (DamageModel.dent). Only the player's own car
-- and cars within 60 studs get one, at most 4 per client. Repairs reset the vertices.
-- On join a 5 s silent benchmark turns dents off on devices averaging under 45 fps; the Dents setting
-- (Full / Panels only) can turn them off too. If EditableMesh is not available (limits, memory budget or
-- creator eligibility, all marked verify in the spec), everything here quietly stays off.
--
-- The shell part is "Body_Shell" when the real models exist; the blockouts use "Panel_Floor".

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local DamageModel = require(Shared.DamageModel)

local MeshDents = {}

-- If dented shells render inside out in Studio, flip this (EditableMesh triangle winding).
local FLIP_WINDING = false

type Shell = {
	model: Model,
	source: BasePart,
	part: MeshPart?,
	mesh: any, -- EditableMesh
	ids: { number },
	rest: { number },
	offsets: { number },
	building: boolean,
}

local shells: { [Model]: Shell } = {}
local setting = "Full" -- "Full" or "PanelsOnly"
local deviceAllows = true
local available = true
local benchmarkDone = false
local warned = false

local function warnOnce(message: string)
	if not warned then
		warned = true
		warn("[MeshDents] " .. message .. " Dents fall back to panel swaps only.")
	end
end

function MeshDents.isEnabled(): boolean
	return available and deviceAllows and setting == "Full"
end

function MeshDents.setSetting(value: string)
	setting = if value == "PanelsOnly" then "PanelsOnly" else "Full"
	if not MeshDents.isEnabled() then
		for model in shells do
			MeshDents.release(model)
		end
	end
end

function MeshDents.getSetting(): string
	return setting
end

-- Grid points on one face of a box. Returns vertex positions as a flat list and the triangles.
local function addFace(
	positions: { number },
	triangles: { number },
	origin: Vector3,
	u: Vector3,
	v: Vector3,
	nu: number,
	nv: number
)
	local start = #positions // 3
	for j = 0, nv do
		for i = 0, nu do
			local p = origin + u * (i / nu) + v * (j / nv)
			table.insert(positions, p.X)
			table.insert(positions, p.Y)
			table.insert(positions, p.Z)
		end
	end
	local row = nu + 1
	for j = 0, nv - 1 do
		for i = 0, nu - 1 do
			local a = start + j * row + i + 1
			local b = a + 1
			local c = a + row
			local d = c + 1
			if FLIP_WINDING then
				table.insert(triangles, a)
				table.insert(triangles, c)
				table.insert(triangles, b)
				table.insert(triangles, b)
				table.insert(triangles, c)
				table.insert(triangles, d)
			else
				table.insert(triangles, a)
				table.insert(triangles, b)
				table.insert(triangles, c)
				table.insert(triangles, b)
				table.insert(triangles, d)
				table.insert(triangles, c)
			end
		end
	end
end

-- A box of the given size, subdivided about every `spacing` studs, kept under the vertex budget.
local function boxGrid(size: Vector3, spacing: number, budget: number): ({ number }, { number })
	local positions, triangles
	repeat
		local nx = math.max(1, math.ceil(size.X / spacing))
		local ny = math.max(1, math.ceil(size.Y / spacing))
		local nz = math.max(1, math.ceil(size.Z / spacing))
		positions, triangles = {}, {}
		local h = size / 2
		local X, Y, Z = Vector3.xAxis * size.X, Vector3.yAxis * size.Y, Vector3.zAxis * size.Z
		-- Each face is wound counter-clockwise seen from outside
		addFace(positions, triangles, Vector3.new(-h.X, h.Y, -h.Z), Z, X, nz, nx) -- top
		addFace(positions, triangles, Vector3.new(-h.X, -h.Y, -h.Z), X, Z, nx, nz) -- bottom
		addFace(positions, triangles, Vector3.new(-h.X, -h.Y, -h.Z), Y, X, ny, nx) -- front (-Z)
		addFace(positions, triangles, Vector3.new(-h.X, -h.Y, h.Z), X, Y, nx, ny) -- rear (+Z)
		addFace(positions, triangles, Vector3.new(-h.X, -h.Y, -h.Z), Z, Y, nz, ny) -- left (-X)
		addFace(positions, triangles, Vector3.new(h.X, -h.Y, -h.Z), Y, Z, ny, nz) -- right (+X)
		spacing *= 1.25
	until #positions // 3 <= budget
	return positions, triangles
end

local function shellPart(model: Model): BasePart?
	local body = model:FindFirstChild("Body")
	if not body then
		return nil
	end
	return (body:FindFirstChild("Body_Shell") or body:FindFirstChild("Panel_Floor")) :: BasePart?
end

local function build(shell: Shell)
	local source = shell.source
	local cfg = Config.Damage.deform
	local positions, triangles = boxGrid(source.Size, cfg.vertexSpacing, cfg.maxVertices)
	local ok, result = pcall(function()
		local mesh = (AssetService :: any):CreateEditableMesh()
		local ids = {}
		for i = 1, #positions, 3 do
			table.insert(ids, mesh:AddVertex(Vector3.new(positions[i], positions[i + 1], positions[i + 2])))
		end
		for i = 1, #triangles, 3 do
			mesh:AddTriangle(ids[triangles[i]], ids[triangles[i + 1]], ids[triangles[i + 2]])
		end
		local part = (AssetService :: any):CreateMeshPartAsync(
			(Content :: any).fromObject(mesh),
			{ CollisionFidelity = Enum.CollisionFidelity.Box }
		) :: MeshPart
		return { mesh = mesh, ids = ids, part = part }
	end)
	if not ok or not result then
		available = false
		warnOnce("EditableMesh unavailable (" .. tostring(result) .. ").")
		return
	end
	if shells[shell.model] ~= shell or source.Parent == nil then
		result.part:Destroy()
		return
	end
	local part = result.part
	part.Name = "DentShell"
	part.Size = source.Size
	part.Color = source.Color
	part.Material = source.Material
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CFrame = source.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = source
	weld.Part1 = part
	weld.Parent = part
	part.Parent = source.Parent
	source.LocalTransparencyModifier = 1
	shell.mesh = result.mesh
	shell.ids = result.ids
	shell.part = part
	shell.rest = positions
	shell.offsets = table.create(#positions, 0)
	shell.building = false
end

-- Give a car a dentable shell (no-op when off, already attached or over the 4-car cap)
function MeshDents.attach(model: Model)
	if not MeshDents.isEnabled() or shells[model] then
		return
	end
	local count = 0
	for _ in shells do
		count += 1
	end
	if count >= Config.Damage.deform.maxCars then
		return
	end
	local source = shellPart(model)
	if not source then
		return
	end
	local shell: Shell = {
		model = model,
		source = source,
		part = nil,
		mesh = nil,
		ids = {},
		rest = {},
		offsets = {},
		building = true,
	}
	shells[model] = shell
	task.spawn(build, shell)
end

function MeshDents.release(model: Model)
	local shell = shells[model]
	if not shell then
		return
	end
	shells[model] = nil
	if shell.part then
		shell.part:Destroy()
	end
	if shell.mesh then
		pcall(function()
			shell.mesh:Destroy()
		end)
	end
	if shell.source.Parent then
		shell.source.LocalTransparencyModifier = 0
	end
end

function MeshDents.has(model: Model): boolean
	local shell = shells[model]
	return shell ~= nil and shell.part ~= nil
end

local function push(shell: Shell)
	local mesh, ids, rest, offsets = shell.mesh, shell.ids, shell.rest, shell.offsets
	pcall(function()
		for index, id in ids do
			local i = index * 3 - 2
			mesh:SetPosition(
				id,
				Vector3.new(rest[i] + offsets[i], rest[i + 1] + offsets[i + 1], rest[i + 2] + offsets[i + 2])
			)
		end
	end)
end

-- A hit at a world point, pushing along a world direction (into the car), with Impact I.
function MeshDents.dent(model: Model, worldPoint: Vector3, worldDirection: Vector3, impact: number)
	local shell = shells[model]
	if not shell or not shell.part then
		return
	end
	local cf = shell.source.CFrame
	local p = cf:PointToObjectSpace(worldPoint)
	-- Pull the contact onto the shell so a hit on the bumper still dents the body behind it
	local half = shell.source.Size / 2
	p = Vector3.new(
		math.clamp(p.X, -half.X, half.X),
		math.clamp(p.Y, -half.Y, half.Y),
		math.clamp(p.Z, -half.Z, half.Z)
	)
	local d = cf:VectorToObjectSpace(worldDirection)
	local moved =
		DamageModel.dent(shell.rest, shell.offsets, p.X, p.Y, p.Z, d.X, d.Y, d.Z, impact, Config.Damage)
	if moved > 0 then
		push(shell)
	end
end

function MeshDents.reset(model: Model)
	local shell = shells[model]
	if not shell or not shell.part then
		return
	end
	table.clear(shell.offsets)
	shell.offsets = table.create(#shell.rest, 0)
	push(shell)
end

-- Keep the 4-car budget on the nearest cars: own car first, then others within 60 studs
function MeshDents.refresh(ownModel: Model?, others: { Model })
	if not MeshDents.isEnabled() then
		return
	end
	local cfg = Config.Damage.deform
	local center = ownModel and ownModel.PrimaryPart and ownModel.PrimaryPart.Position
		or workspace.CurrentCamera.CFrame.Position
	local wanted: { [Model]: boolean } = {}
	if ownModel then
		wanted[ownModel] = true
	end
	local candidates = {}
	for _, model in others do
		local root = model.PrimaryPart
		if root then
			local distance = (root.Position - center).Magnitude
			if distance <= cfg.range then
				table.insert(candidates, { model = model, distance = distance })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)
	for index, entry in candidates do
		if index > cfg.maxCars - (if ownModel then 1 else 0) then
			break
		end
		wanted[entry.model] = true
	end
	for model in shells do
		if not wanted[model] or model.Parent == nil then
			MeshDents.release(model)
		end
	end
	if ownModel then
		MeshDents.attach(ownModel)
	end
	for model in wanted do
		MeshDents.attach(model)
	end
end

-- 5 s silent benchmark on join: devices averaging under 45 fps start with dents off. Device memory is not
-- readable from a game script, so the player's own graphics quality choice stands in for it: a manual
-- quality under level 4 also starts with dents off.
function MeshDents.runBenchmark(onDone: ((boolean) -> ())?)
	if benchmarkDone then
		return
	end
	benchmarkDone = true
	task.spawn(function()
		local cfg = Config.Damage.deform
		local frames, elapsed = 0, 0
		local connection
		connection = RunService.RenderStepped:Connect(function(dt)
			frames += 1
			elapsed += dt
		end)
		task.wait(cfg.benchmarkTime)
		connection:Disconnect()
		local fps = if elapsed > 0 then frames / elapsed else 60
		local quality = 21
		pcall(function()
			local level = UserSettings():GetService("UserGameSettings").SavedQualityLevel
			if level ~= Enum.SavedQualitySetting.Automatic then
				quality = level.Value
			end
		end)
		deviceAllows = fps >= cfg.benchmarkMinFps and quality >= cfg.minQualityLevel
		if not deviceAllows then
			for model in shells do
				MeshDents.release(model)
			end
		end
		if onDone then
			onDone(deviceAllows)
		end
	end)
end

function MeshDents.status(): string
	if not available then
		return "unavailable"
	elseif not benchmarkDone then
		return "waiting"
	elseif not deviceAllows then
		return "off (slow device)"
	end
	return if setting == "Full" then "on" else "off (setting)"
end

-- For the dev panel: force on after a slow benchmark (Studio testing)
function MeshDents.forceAllow()
	deviceAllows = true
end

return MeshDents
