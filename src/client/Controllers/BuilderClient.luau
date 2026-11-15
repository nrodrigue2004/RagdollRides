-- BuilderClient: the map builder on this device (spec: Map builder > Controls, Map settings, Publish rules;
-- Screens and UI > Builder). The map is a list of entries (Shared/PieceCatalog); the preview is built
-- with Shared/MapBuilder, the same code the server uses, so what you build is what gets driven.
-- * Open: BUILD on the Tracks HUD shows the draft slots; a slot opens the builder on your private plot
--   (the server gives the plot). Your car waits at the edge of the plot.
-- * Phone: tap a piece in the tray, tap the plot to place it (it keeps the piece picked, so tapping
--   again places another). Tap a placed piece to select it; drag it to move it. ROTATE (15 degrees),
--   TILT (quarter turns, blocks, walls and platforms), SIZE, COLOUR, UP and DOWN (1 stud), DELETE,
--   DONE. Camera: one finger orbits, two fingers pan and pinch to zoom.
-- * PC: number keys pick pieces (1-0 the first ten, Shift for the next ten), R rotate (Shift: back),
--   T tilt, F size, Q and E down and up, Delete, Ctrl+Z / Ctrl+Y, Esc deselects. Right drag orbits,
--   middle drag or WASD pans, the wheel zooms. A see-through outline shows where the piece will go.
-- * Road pieces placed near the end of another road piece snap onto it (heading and height), so a
--   track joins up without lining it up by hand.
-- * Undo and redo: 50 steps. Autosave every 30 s and on exit; SAVE saves now.
-- * TEST: drive the map from the start gate in under 2 s (the server times it; a finish proves the map
--   can be finished and sets the creator time). With a checkpoint selected, TEST is a practice run from
--   that checkpoint (on this device only). BUILD goes back to the same camera.
-- * MAP: the name word wheels, tags, full damage, the publish checklist and PUBLISH.
-- Funnel steps are logged by the server as drafts are saved and tested.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapBuilder = require(Shared.MapBuilder)
local MapCodec = require(Shared.MapCodec)
local MapNames = require(Shared.MapNames)
local MapRules = require(Shared.MapRules)
local Net = require(Shared.Net)
local PieceCatalog = require(Shared.PieceCatalog)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)

local Client = script.Parent.Parent
local BuilderHud = require(Client:WaitForChild("Ui"):WaitForChild("BuilderHud"))
local Confetti = require(Client:WaitForChild("Fx"):WaitForChild("Confetti"))

local LocalPlayer = Players.LocalPlayer

local BuilderClient = {}

local GRID = PieceCatalog.GRID
local VOLUME = MapRules.LIMITS.volume
local JOIN_DISTANCE = 12 -- studs: a road piece this close to another's end snaps onto it
local DRAG_THRESHOLD = 10 -- px before a press becomes a drag
local PARK = Vector3.new(0, 0, VOLUME[3] / 2 + 40) -- map space: where the car waits while you build

type Snapshot = { pieces: { PieceCatalog.Entry }, flags: number, tags: number, name: { number } }

local controllers: any = nil
local state = "off" -- "off", "build", "loading" (waiting for TEST), "test"
local slot = 0
local map: MapCodec.MapData = MapCodec.empty()
local origin = Vector3.zero
local mapId = ""
local vip = false
local fineGrid = false
local drafts: { [string]: any }? = nil
local testedFingerprint: string? = nil
local dirty = false
local sinceSave = 0
local undoStack: { Snapshot } = {}
local redoStack: { Snapshot } = {}
local picked: number? = nil
local selected: number? = nil
local tool = { r = 0, tilt = 0, s = 1, c = 0 }
local pendingTest: { kind: string, from: number }? = nil
local publishNote: string? = nil
local queuedPublish = false

-- Preview
local previewFolder: Folder? = nil
local pickFolder: Folder? = nil
local entryModels: { Model } = {}
local pickIndex: { [BasePart]: number } = {}
local gridPart: Part? = nil
local ghostPart: Part? = nil
local highlight: SelectionBox? = nil

-- Camera
local cam = { focus = Vector3.zero, yaw = 0, pitch = 0.9, distance = 160 }
local savedCam: typeof(cam)? = nil

-- Pointer and touches
local touches: { [InputObject]: Vector2 } = {}
local press: { position: Vector2, moved: boolean, entry: number?, undoPushed: boolean }? = nil
local orbiting = false
local panning = false

---------------------------------------------------------------------------
-- Map helpers
---------------------------------------------------------------------------

local function options()
	return { vip = vip }
end

local function stub(): StarterMaps.MapDef
	return {
		id = mapId,
		name = "",
		order = 0,
		creatorTime = 0,
		coinValue = 0,
		offset = { origin.X, origin.Y, origin.Z },
		pieces = {},
		checkpoints = 0,
		coins = 0,
		custom = true,
	}
end

local function mapDef(): StarterMaps.MapDef
	return PieceCatalog.toMapDef(map.pieces, {
		id = mapId,
		name = "TEST",
		offset = { origin.X, origin.Y, origin.Z },
		fullDamage = MapCodec.fullDamage(map),
	}) :: any
end

local function copyEntry(e: PieceCatalog.Entry): PieceCatalog.Entry
	return { t = e.t, x = e.x, y = e.y, z = e.z, r = e.r, tilt = e.tilt, s = e.s, c = e.c, p = e.p }
end

local function snapshot(): Snapshot
	local pieces = table.create(#map.pieces)
	for i, e in map.pieces do
		pieces[i] = copyEntry(e)
	end
	return { pieces = pieces, flags = map.flags, tags = map.tags, name = table.clone(map.name) }
end

local function restore(s: Snapshot)
	map.pieces = {}
	for i, e in s.pieces do
		map.pieces[i] = copyEntry(e)
	end
	map.flags, map.tags, map.name = s.flags, s.tags, table.clone(s.name)
end

local function pushUndo()
	table.insert(undoStack, snapshot())
	if #undoStack > Config.Builder.undoSteps then
		table.remove(undoStack, 1)
	end
	table.clear(redoStack)
end

local function checkpointNumbers(): { [number]: number }
	local numbers = {}
	local count = 0
	for index, entry in map.pieces do
		local def = PieceCatalog.get(entry.t)
		if def and def.group == "checkpoint" then
			count += 1
			numbers[index] = count
		end
	end
	return numbers
end

local function step(): number
	return if vip and fineGrid then 1 else PieceCatalog.NORMAL_STEP
end

-- A world point to grid units (x, z in 2-stud units snapped to the step; y in whole studs)
local function snap(world: Vector3): (number, number, number)
	local p = world - origin
	local s = step()
	local gx = math.round(p.X / GRID / s) * s
	local gz = math.round(p.Z / GRID / s) * s
	local gy = math.clamp(math.round(p.Y), 0, VOLUME[2])
	return gx, gy, gz
end

local function piecesFingerprint(): string
	return MapCodec.fingerprint(MapCodec.encode(map), MapCodec.PIECES_FROM)
end

local function isTested(): boolean
	return testedFingerprint ~= nil and testedFingerprint == piecesFingerprint()
end

---------------------------------------------------------------------------
-- Preview
---------------------------------------------------------------------------

local function clearModel(index: number)
	local model = entryModels[index]
	if model then
		for part, i in pickIndex do
			if i == index then
				pickIndex[part] = nil
				part:Destroy()
			end
		end
		model:Destroy()
	end
end

local function buildEntry(index: number, numbers: { [number]: number })
	local entry = map.pieces[index]
	local model = Instance.new("Model")
	model.Name = "Entry" .. index
	MapBuilder.buildPieces(model, stub(), PieceCatalog.expand(entry, numbers[index]), 1)
	model.Parent = previewFolder
	entryModels[index] = model
	-- An invisible box around the piece for taps (most piece parts are visual only)
	local cf, size = model:GetBoundingBox()
	local pick = Instance.new("Part")
	pick.Name = "Pick" .. index
	pick.Anchored = true
	pick.CanCollide = false
	pick.CanTouch = false
	pick.Transparency = 1
	pick.CFrame = cf
	pick.Size = Vector3.new(math.max(size.X, 2), math.max(size.Y, 2), math.max(size.Z, 2))
	pick.Parent = pickFolder
	pickIndex[pick] = index
end

local function rebuildAll()
	for index in entryModels do
		clearModel(index)
	end
	table.clear(entryModels)
	table.clear(pickIndex)
	if pickFolder then
		pickFolder:ClearAllChildren()
	end
	local numbers = checkpointNumbers()
	for index = 1, #map.pieces do
		buildEntry(index, numbers)
	end
end

local function rebuildOne(index: number)
	local def = PieceCatalog.get(map.pieces[index].t)
	if def and def.group == "checkpoint" then
		rebuildAll() -- numbers may move
		return
	end
	clearModel(index)
	buildEntry(index, checkpointNumbers())
end

local function makeGrid()
	local part = Instance.new("Part")
	part.Name = "BuildGrid"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Size = Vector3.new(VOLUME[1], 1, VOLUME[3])
	part.CFrame = CFrame.new(origin + Vector3.new(0, -0.5, 0))
	part.Color = Color3.fromRGB(122, 204, 120)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.15
	part.CastShadow = false
	-- Grid lines every 16 studs (4 snaps), drawn by a SurfaceGui (PLACEHOLDER ART)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 2
	gui.LightInfluence = 0
	gui.Parent = part
	local lines = VOLUME[1] // 16
	for i = 0, lines do
		local major = i % 4 == 0
		for _, vertical in { true, false } do
			local line = Instance.new("Frame")
			line.BorderSizePixel = 0
			line.BackgroundColor3 = Color3.new(1, 1, 1)
			line.BackgroundTransparency = if major then 0.35 else 0.7
			local width = if major then 2 else 1
			if vertical then
				line.Size = UDim2.new(0, width, 1, 0)
				line.Position = UDim2.new(i / lines, -width / 2, 0, 0)
			else
				line.Size = UDim2.new(1, 0, 0, width)
				line.Position = UDim2.new(0, 0, i / lines, -width / 2)
			end
			line.Parent = gui
		end
	end
	part.Parent = workspace
	return part
end

local function setPreviewTesting(testing: boolean)
	if gridPart then
		-- While driving, the plot floor is scenery only: the car falls through to the reset height
		gridPart.CanQuery = not testing
		gridPart.Transparency = if testing then 0.6 else 0.15
	end
	if pickFolder then
		pickFolder.Parent = if testing then nil else workspace
	end
	if ghostPart then
		ghostPart.Parent = nil
	end
	if highlight then
		highlight.Adornee = nil
	end
end

local function destroyPreview()
	for _, item in { previewFolder, pickFolder, gridPart, ghostPart, highlight } :: { Instance? } do
		if item then
			item:Destroy()
		end
	end
	previewFolder, pickFolder, gridPart, ghostPart, highlight = nil, nil, nil, nil, nil
	table.clear(entryModels)
	table.clear(pickIndex)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------

local SIZE_LABELS = { "SIZE: S", "SIZE: M", "SIZE: L" }

local function refreshHud()
	local counts = MapRules.count(map)
	local limits = MapRules.LIMITS
	BuilderHud.setCounts(counts.pieces, limits.pieces, counts.parts, limits.parts)
	local tray = {}
	for _, def in PieceCatalog.defs do
		local ok, reason = MapRules.canAdd(map, def.id)
		table.insert(tray, { id = def.id, label = def.label, cost = def.cost, ok = ok, reason = reason })
	end
	BuilderHud.setTray(tray, picked)
	if counts.starts == 0 then
		BuilderHud.setStatus("Add a START gate")
	elseif counts.finishes == 0 then
		BuilderHud.setStatus("Add a FINISH arch")
	else
		BuilderHud.setStatus(nil)
	end
	BuilderHud.setUndo(#undoStack > 0, #redoStack > 0)
	BuilderHud.setFineGrid(vip, fineGrid)

	local entry = if selected then map.pieces[selected] else nil
	local def = if entry then PieceCatalog.get(entry.t) elseif picked then PieceCatalog.get(picked) else nil
	if def then
		local size = if entry then entry.s else tool.s
		local title = def.label
		if entry and def.group == "checkpoint" then
			title ..= " " .. tostring(checkpointNumbers()[selected :: number] or "")
		end
		BuilderHud.setSelection({
			title = string.upper(title),
			canTilt = def.tilt,
			canSize = def.sizes == 3,
			placing = entry == nil,
			sizeLabel = SIZE_LABELS[math.clamp(size, 0, 2) + 1],
		})
	else
		BuilderHud.setSelection(nil)
	end
	if highlight then
		local model = if selected then entryModels[selected] else nil
		highlight.Adornee = model
	end
end

local function changed()
	dirty = true
	refreshHud()
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

local function selectEntry(index: number?)
	selected = index
	refreshHud()
end

-- The end of the road piece nearest a point (map space), within JOIN_DISTANCE
local function nearestExit(px: number, pz: number): (number?, number?, number?, number?)
	local best, bx, by, bz, byaw = JOIN_DISTANCE, nil, nil, nil, nil
	for _, entry in map.pieces do
		local x, y, z, yaw = PieceCatalog.exit(entry)
		if x and y and z and yaw then
			local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
			if d < best then
				best, bx, by, bz, byaw = d, x, y, z, yaw
			end
		end
	end
	return bx, by, bz, byaw
end

-- The entry a tap at this world point would place (nil if the picked piece cannot go there)
local function placement(world: Vector3): PieceCatalog.Entry?
	local def = picked and PieceCatalog.get(picked)
	if def == nil then
		return nil
	end
	local gx, gy, gz = snap(world)
	local entry: PieceCatalog.Entry = {
		t = def.id,
		x = gx,
		y = gy,
		z = gz,
		r = tool.r,
		tilt = if def.tilt then tool.tilt else 0,
		s = if def.sizes == 3 then tool.s else 0,
		c = if tool.c <= (if vip then #PieceCatalog.PALETTE else PieceCatalog.FREE_COLOURS)
			then tool.c
			else 0,
		p = 0,
	}
	if def.anchor == "entry" then
		local local3 = world - origin
		local x, y, z, yaw = nearestExit(local3.X, local3.Z)
		if x and y and z and yaw then
			local s = step()
			entry.x = math.round(x / GRID / s) * s
			entry.z = math.round(z / GRID / s) * s
			entry.y = math.clamp(math.round(y), 0, VOLUME[2])
			entry.r = math.round(yaw / PieceCatalog.YAW_STEP) % 24
		end
	end
	return entry
end

local function place(world: Vector3)
	local entry = placement(world)
	if entry == nil then
		return
	end
	local ok, reason = MapRules.canAdd(map, entry.t)
	if not ok then
		BuilderHud.toast(reason or "Limit reached")
		return
	end
	local fits, why = MapRules.checkEntry(entry, options())
	if not fits then
		BuilderHud.toast(
			if why == "outside the build area" then "That's outside your plot" else "Can't go there"
		)
		return
	end
	pushUndo()
	table.insert(map.pieces, entry)
	local index = #map.pieces
	local def = PieceCatalog.get(entry.t)
	if def and def.group == "checkpoint" then
		rebuildAll()
	else
		buildEntry(index, checkpointNumbers())
	end
	selected = index
	tool.r = entry.r
	controllers.Juice.fire("BuilderPlace")
	changed()
end

-- Change the selected entry (or the settings for the next placement) with fn(entry)
local function editSelected(fn: (PieceCatalog.Entry) -> ())
	local index = selected
	if index == nil then
		local def = picked and PieceCatalog.get(picked)
		if def then
			local probe = {
				t = def.id,
				x = 0,
				y = 0,
				z = 0,
				r = tool.r,
				tilt = tool.tilt,
				s = tool.s,
				c = tool.c,
				p = 0,
			}
			fn(probe)
			tool.r, tool.tilt, tool.s, tool.c = probe.r, probe.tilt, probe.s, probe.c
			refreshHud()
		end
		return
	end
	local before = copyEntry(map.pieces[index])
	local after = copyEntry(before)
	fn(after)
	if MapRules.checkEntry(after, options()) ~= true then
		BuilderHud.toast("Can't go there")
		return
	end
	pushUndo()
	map.pieces[index] = after
	tool.r, tool.tilt, tool.c = after.r, after.tilt, after.c
	if PieceCatalog.get(after.t) and (PieceCatalog.get(after.t) :: any).sizes == 3 then
		tool.s = after.s
	end
	rebuildOne(index)
	changed()
end

local function rotate(direction: number)
	editSelected(function(e)
		e.r = (e.r + direction) % 24
	end)
end

local function tilt()
	editSelected(function(e)
		local def = PieceCatalog.get(e.t)
		if def and def.tilt then
			e.tilt = (e.tilt + 1) % 7
		end
	end)
end

local function resize()
	editSelected(function(e)
		local def = PieceCatalog.get(e.t)
		if def and def.sizes == 3 then
			e.s = (e.s + 1) % 3
		end
	end)
end

local function colour(index: number)
	local limit = if vip then #PieceCatalog.PALETTE else PieceCatalog.FREE_COLOURS
	if index > limit then
		BuilderHud.toast("VIP colour")
		return
	end
	editSelected(function(e)
		e.c = index
	end)
	BuilderHud.closeSwatches()
end

local function raise(delta: number)
	if selected == nil then
		return
	end
	editSelected(function(e)
		e.y = math.clamp(e.y + delta, 0, VOLUME[2])
	end)
end

local function delete()
	local index = selected
	if index == nil then
		return
	end
	pushUndo()
	table.remove(map.pieces, index)
	selected = nil
	rebuildAll()
	controllers.Juice.fire("BuilderRemove")
	changed()
end

local function undo()
	local s = table.remove(undoStack)
	if s == nil then
		return
	end
	table.insert(redoStack, snapshot())
	restore(s)
	selected = nil
	rebuildAll()
	changed()
end

local function redo()
	local s = table.remove(redoStack)
	if s == nil then
		return
	end
	table.insert(undoStack, snapshot())
	restore(s)
	selected = nil
	rebuildAll()
	changed()
end

local function pick(typeId: number)
	if picked == typeId then
		picked = nil
	else
		local ok, reason = MapRules.canAdd(map, typeId)
		if not ok then
			BuilderHud.toast(reason or "Limit reached")
			return
		end
		picked = typeId
		selected = nil
		local def = PieceCatalog.get(typeId)
		if def and def.sizes == 1 then
			tool.s = 0
		elseif tool.s == 0 then
			tool.s = 1
		end
	end
	refreshHud()
end

local function done()
	picked = nil
	selected = nil
	if ghostPart then
		ghostPart.Parent = nil
	end
	refreshHud()
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------

local function save(manual: boolean?)
	if slot == 0 then
		return
	end
	local b = MapCodec.encode(map)
	Net.send("Map.SaveDraft", slot, b)
	dirty = false
	sinceSave = 0
	if drafts then
		for _, entry in drafts.slots do
			if entry.slot == slot then
				entry.data = GhostCodec.toBase64(b)
				entry.pieces = #map.pieces
			end
		end
	end
	if manual then
		BuilderHud.toast("Saved!")
	end
end

---------------------------------------------------------------------------
-- Camera and input
---------------------------------------------------------------------------

local function clampFocus()
	local p = cam.focus - origin
	cam.focus = origin
		+ Vector3.new(
			math.clamp(p.X, -VOLUME[1] / 2 - 80, VOLUME[1] / 2 + 80),
			math.clamp(p.Y, 0, VOLUME[2]),
			math.clamp(p.Z, -VOLUME[3] / 2 - 80, VOLUME[3] / 2 + 80)
		)
end

local function cameraCFrame(): CFrame
	local offset = CFrame.Angles(0, cam.yaw, 0)
		* CFrame.Angles(-cam.pitch, 0, 0)
		* Vector3.new(0, 0, cam.distance)
	return CFrame.lookAt(cam.focus + offset, cam.focus)
end

local function orbit(delta: Vector2)
	cam.yaw -= delta.X * 0.006
	cam.pitch = math.clamp(cam.pitch + delta.Y * 0.005, 0.15, 1.45)
end

local function pan(delta: Vector2)
	local flat = CFrame.Angles(0, cam.yaw, 0)
	local scale = cam.distance * 0.0016
	cam.focus += (-flat.RightVector * delta.X + flat.LookVector * delta.Y) * scale
	clampFocus()
end

local function zoom(factor: number)
	cam.distance = math.clamp(cam.distance * factor, 30, 800)
end

local function cameraUpdate(dt: number): (CFrame, number)
	-- WASD pans (PC); the right stick orbits, the left pans and the triggers zoom (gamepad)
	local move = Vector2.zero
	if not UserInputService:GetFocusedTextBox() then
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			move += Vector2.new(0, -1)
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			move += Vector2.new(0, 1)
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			move += Vector2.new(-1, 0)
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			move += Vector2.new(1, 0)
		end
	end
	if UserInputService.GamepadEnabled then
		for _, input in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
			local v = input.Position
			if input.KeyCode == Enum.KeyCode.Thumbstick1 and v.Magnitude > 0.15 then
				move += Vector2.new(v.X, -v.Y)
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 and v.Magnitude > 0.15 then
				orbit(Vector2.new(v.X, -v.Y) * 600 * dt)
			elseif input.KeyCode == Enum.KeyCode.ButtonR2 and v.Z > 0.1 then
				zoom(1 - 1.5 * dt * v.Z)
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 and v.Z > 0.1 then
				zoom(1 + 1.5 * dt * v.Z)
			end
		end
	end
	if move.Magnitude > 0 then
		pan(move.Unit * 900 * dt)
	end
	return cameraCFrame(), 70
end

local function rayAt(screen: Vector2): RaycastResult?
	local camera = workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { pickFolder :: Instance, gridPart :: Instance }
	return workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
end

-- Where a ray meets the horizontal plane at height y (world)
local function planeAt(screen: Vector2, y: number): Vector3?
	local ray = workspace.CurrentCamera:ScreenPointToRay(screen.X, screen.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = (y - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then
		return nil
	end
	return ray.Origin + ray.Direction * t
end

-- A tap (no drag): place the picked piece, or select what is under the finger
local function tap(screen: Vector2)
	local hit = rayAt(screen)
	if picked then
		if hit then
			-- On the grid, or stacked on the top of another piece
			local point = hit.Position
			if hit.Instance ~= gridPart then
				point = Vector3.new(
					point.X,
					(hit.Instance :: BasePart).Position.Y + (hit.Instance :: BasePart).Size.Y / 2,
					point.Z
				)
			end
			place(point)
		end
		return
	end
	local index = if hit then pickIndex[hit.Instance :: BasePart] else nil
	selectEntry(index)
end

local function updateGhost(screen: Vector2)
	if picked == nil or state ~= "build" then
		if ghostPart then
			ghostPart.Parent = nil
		end
		return
	end
	local hit = rayAt(screen)
	local entry = if hit then placement(hit.Position) else nil
	local def = entry and PieceCatalog.get(entry.t)
	if entry == nil or def == nil then
		if ghostPart then
			ghostPart.Parent = nil
		end
		return
	end
	if ghostPart == nil then
		local g = Instance.new("Part")
		g.Name = "PlaceGhost"
		g.Anchored = true
		g.CanCollide = false
		g.CanQuery = false
		g.CanTouch = false
		g.Material = Enum.Material.Neon
		g.Color = Color3.fromRGB(86, 170, 255)
		g.Transparency = 0.6
		g.CastShadow = false
		ghostPart = g
	end
	local size = PieceCatalog.size(entry)
	local fx, fz = def.footprint[size * 2 - 1], def.footprint[size * 2]
	local ax, ay, az = PieceCatalog.anchor(entry)
	local yaw = math.rad(PieceCatalog.yaw(entry))
	local base = CFrame.new(origin + Vector3.new(ax, ay + 0.6, az)) * CFrame.Angles(0, yaw, 0)
	local ghost = ghostPart :: Part
	ghost.Size = Vector3.new(fx, 1, fz)
	-- Road pieces start at their anchor and run forward; the rest are centred on it
	ghost.CFrame = if def.anchor == "entry" then base * CFrame.new(0, 0, -fz / 2) else base
	ghost.Parent = workspace
end

local function pointerDown(screen: Vector2)
	local hit = rayAt(screen)
	local index = if hit then pickIndex[hit.Instance :: BasePart] else nil
	press = {
		position = screen,
		moved = false,
		entry = if picked == nil and index ~= nil and index == selected then index else nil,
		undoPushed = false,
	}
end

local function pointerMoved(screen: Vector2, delta: Vector2)
	local p = press
	if p == nil then
		return
	end
	if not p.moved and (screen - p.position).Magnitude < DRAG_THRESHOLD then
		return
	end
	p.moved = true
	if p.entry and map.pieces[p.entry] then
		-- Drag the selected piece along the grid at its own height
		local entry = map.pieces[p.entry]
		local world = planeAt(screen, origin.Y + entry.y)
		if world then
			local gx, _, gz = snap(world)
			if gx ~= entry.x or gz ~= entry.z then
				local moved = copyEntry(entry)
				moved.x, moved.z = gx, gz
				if MapRules.checkEntry(moved, options()) then
					if not p.undoPushed then
						pushUndo()
						p.undoPushed = true
					end
					map.pieces[p.entry] = moved
					rebuildOne(p.entry)
					changed()
				end
			end
		end
	else
		-- On empty space: one finger (or the left button) orbits
		orbit(delta)
	end
end

local function pointerUp(screen: Vector2)
	local p = press
	press = nil
	if p and not p.moved then
		tap(screen)
	end
end

local function touchCount(): number
	local n = 0
	for _ in touches do
		n += 1
	end
	return n
end

local function twoTouches(): (Vector2?, number?)
	local a, b = nil, nil
	for _, position in touches do
		if a == nil then
			a = position
		elseif b == nil then
			b = position
		end
	end
	if a and b then
		return (a + b) / 2, (a - b).Magnitude
	end
	return nil, nil
end

local NUMBER_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

local function onKey(input: InputObject)
	local key = input.KeyCode
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftMeta)
	if ctrl and key == Enum.KeyCode.Z then
		undo()
	elseif ctrl and key == Enum.KeyCode.Y then
		redo()
	elseif ctrl and key == Enum.KeyCode.S then
		save(true)
	elseif NUMBER_KEYS[key] then
		pick(NUMBER_KEYS[key] + (if shift then 10 else 0))
	elseif key == Enum.KeyCode.R then
		rotate(if shift then -1 else 1)
	elseif key == Enum.KeyCode.T then
		tilt()
	elseif key == Enum.KeyCode.F then
		resize()
	elseif key == Enum.KeyCode.E or key == Enum.KeyCode.PageUp then
		raise(1)
	elseif key == Enum.KeyCode.Q or key == Enum.KeyCode.PageDown then
		raise(-1)
	elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then
		delete()
	elseif key == Enum.KeyCode.Escape then
		done()
	end
end

local function connectInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if state ~= "build" or processed or BuilderHud.publishOpen() then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 then
			pointerDown(Vector2.new(input.Position.X, input.Position.Y))
		elseif kind == Enum.UserInputType.MouseButton2 then
			orbiting = true
		elseif kind == Enum.UserInputType.MouseButton3 then
			panning = true
		elseif kind == Enum.UserInputType.Touch then
			touches[input] = Vector2.new(input.Position.X, input.Position.Y)
			if touchCount() == 1 then
				pointerDown(touches[input])
			else
				press = nil -- two fingers: a camera gesture, never a tap
			end
		elseif kind == Enum.UserInputType.Keyboard then
			onKey(input)
		elseif kind == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.ButtonY then
			save(true)
		end
	end)

	UserInputService.InputChanged:Connect(function(input, processed)
		if state ~= "build" then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseWheel then
			if not processed then
				zoom(if input.Position.Z > 0 then 0.88 else 1.14)
			end
		elseif kind == Enum.UserInputType.MouseMovement then
			local screen = Vector2.new(input.Position.X, input.Position.Y)
			local delta = Vector2.new(input.Delta.X, input.Delta.Y)
			if orbiting then
				orbit(delta)
			elseif panning then
				pan(-delta)
			elseif press then
				pointerMoved(screen, delta)
			end
			updateGhost(screen)
		elseif kind == Enum.UserInputType.Touch and touches[input] then
			local before = touches[input]
			local now = Vector2.new(input.Position.X, input.Position.Y)
			local centre0, spread0 = twoTouches()
			touches[input] = now
			local count = touchCount()
			if count == 1 then
				pointerMoved(now, now - before)
			elseif count >= 2 and centre0 and spread0 then
				local centre1, spread1 = twoTouches()
				if centre1 and spread1 then
					pan(-(centre1 - centre0))
					if spread1 > 1 and spread0 > 1 then
						zoom(spread0 / spread1)
					end
				end
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton2 then
			orbiting = false
		elseif kind == Enum.UserInputType.MouseButton3 then
			panning = false
		end
		if state ~= "build" then
			touches[input] = nil
			press = nil
			return
		end
		if kind == Enum.UserInputType.MouseButton1 then
			pointerUp(Vector2.new(input.Position.X, input.Position.Y))
		elseif kind == Enum.UserInputType.Touch and touches[input] then
			local wasOnly = touchCount() == 1
			touches[input] = nil
			if wasOnly then
				pointerUp(Vector2.new(input.Position.X, input.Position.Y))
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Car parking, entering and leaving
---------------------------------------------------------------------------

local function parkCar()
	local Vehicle = controllers.Vehicle
	if controllers.Ragdoll.isRagdolled() then
		controllers.Ragdoll.respawn()
	end
	local at = CFrame.new(origin + PARK + Vector3.new(0, Vehicle.rideHeight() + 0.3, 0))
	Vehicle.runScripted(function()
		if state == "build" or state == "loading" then
			return at
		end
		return nil
	end)
end

local function showBuildView()
	controllers.Hud.setVisible(false)
	controllers.Camera.setOverride(cameraUpdate)
	BuilderHud.setVisible(true)
	BuilderHud.setMode("build")
	BuilderHud.setTestStatus(nil)
	setPreviewTesting(false)
	refreshHud()
end

local function waitForPlot(): Vector3?
	local deadline = os.clock() + 6
	while os.clock() < deadline do
		local value = LocalPlayer:GetAttribute("PlotOrigin")
		if LocalPlayer:GetAttribute("BuildSlot") == slot and typeof(value) == "Vector3" then
			return value
		end
		task.wait(0.1)
	end
	return nil
end

local function enter(newSlot: number)
	if state ~= "off" or drafts == nil then
		return
	end
	local entry = nil
	for _, s in drafts.slots do
		if s.slot == newSlot then
			entry = s
		end
	end
	if entry == nil then
		return
	end
	slot = newSlot
	vip = drafts.vip == true
	map = MapCodec.empty()
	testedFingerprint = nil
	if type(entry.data) == "string" then
		local raw = GhostCodec.fromBase64(entry.data)
		local decoded = if raw then MapCodec.decode(raw) else nil
		if decoded then
			map = decoded
			if entry.tested then
				testedFingerprint = piecesFingerprint()
			end
		end
	end
	state = "loading"
	Net.send("Map.Build", slot)
	local plot = waitForPlot()
	if plot == nil then
		state = "off"
		slot = 0
		controllers.Tracks.toast("No build space free right now. Try again soon!")
		return
	end
	origin = plot
	mapId = "test_" .. tostring(LocalPlayer.UserId)
	state = "build"
	table.clear(undoStack)
	table.clear(redoStack)
	picked, selected = nil, nil
	dirty, sinceSave = false, 0
	publishNote, queuedPublish = nil, false

	destroyPreview()
	local folder = Instance.new("Folder")
	folder.Name = "BuilderPreview"
	folder.Parent = workspace
	previewFolder = folder
	local picks = Instance.new("Folder")
	picks.Name = "BuilderPicks"
	picks.Parent = workspace
	pickFolder = picks
	gridPart = makeGrid()
	local box = Instance.new("SelectionBox")
	box.Color3 = Color3.fromRGB(255, 205, 40)
	box.LineThickness = 0.4
	box.SurfaceTransparency = 0.85
	box.SurfaceColor3 = Color3.fromRGB(255, 205, 40)
	box.Parent = workspace
	highlight = box
	rebuildAll()

	local swatches = {}
	for i, rgb in PieceCatalog.PALETTE do
		swatches[i] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	BuilderHud.setSwatches(swatches, if vip then #PieceCatalog.PALETTE else PieceCatalog.FREE_COLOURS)

	-- Start looking at the start gate if there is one, else the middle of the plot
	local start = nil
	for _, e in map.pieces do
		if e.t == PieceCatalog.byKey.start.id then
			start = e
		end
	end
	local fx, fz = 0, 0
	if start then
		local ax, _, az = PieceCatalog.anchor(start)
		fx, fz = ax, az
	end
	cam = { focus = origin + Vector3.new(fx, 0, fz - 40), yaw = 0, pitch = 0.9, distance = 160 }
	parkCar()
	showBuildView()
end

local function exit()
	if state == "off" then
		return
	end
	if dirty then
		save(false)
	end
	state = "off"
	Net.send("Map.Build", 0)
	controllers.Tracks.setTest(nil)
	controllers.Tracks.setBuilderButtons(false)
	controllers.Tracks.unregisterMap(mapId)
	destroyPreview()
	BuilderHud.closePublish()
	BuilderHud.setVisible(false)
	controllers.Camera.setOverride(nil)
	controllers.Hud.setVisible(true)
	slot = 0
end

---------------------------------------------------------------------------
-- TEST
---------------------------------------------------------------------------

local TEST_REASONS = {
	needStart = "Add a START gate first!",
	needFinish = "Add a FINISH arch first!",
	invalid = "Something in this map isn't allowed.",
	notBuilding = "Open the map again to test it.",
	slotLocked = "That slot needs VIP.",
	notLoaded = "Still loading. Try again in a moment!",
}

local function test()
	if state ~= "build" then
		return
	end
	local ok, reason = MapRules.checkPlayable(map, options())
	if not ok then
		BuilderHud.toast(
			if reason == "needs a start gate"
				then TEST_REASONS.needStart
				elseif reason == "needs a finish arch" then TEST_REASONS.needFinish
				else TEST_REASONS.invalid
		)
		return
	end
	-- A selected checkpoint: practice from it (this device only)
	local kind, from = "test", 0
	local numbers = checkpointNumbers()
	if selected and numbers[selected] then
		kind, from = "practice", numbers[selected]
	end
	local def = mapDef()
	controllers.Tracks.registerMap(def)
	controllers.Tracks.setTest(kind, from)
	savedCam = table.clone(cam)
	pendingTest = { kind = kind, from = from }
	state = "loading"
	dirty = false -- the server saves the draft with the test
	Net.send("Map.Test", slot, MapCodec.encode(map))
	BuilderHud.toast(if kind == "practice" then "Practice from checkpoint " .. from else "TEST!", 1.5)
	-- No answer: back to building rather than leave the player waiting
	local token = pendingTest
	task.delay(Config.Builder.testTimeout + 2, function()
		if state == "loading" and pendingTest == token then
			pendingTest = nil
			state = "build"
			showBuildView()
			BuilderHud.toast("TEST didn't start. Try again!")
		end
	end)
end

local function startDriving()
	local pending = pendingTest
	if pending == nil then
		return
	end
	pendingTest = nil
	state = "test"
	controllers.Input.consume("jump")
	controllers.Input.consume("reset")
	controllers.Input.consume("flip")
	controllers.Camera.setOverride(nil)
	setPreviewTesting(true)
	BuilderHud.setMode("test")
	BuilderHud.closeSwatches()
	controllers.Hud.setVisible(true)
	controllers.Tracks.setBuilderButtons(true)
	if pending.kind == "practice" then
		controllers.Tracks.retry() -- to the checkpoint
		BuilderHud.setTestStatus("PRACTICE from checkpoint " .. pending.from)
	else
		BuilderHud.setTestStatus(
			if isTested()
				then "TEST: your map is ready to publish"
				else "TEST: finish from the start to publish"
		)
	end
end

local function backToBuild()
	if state ~= "test" then
		return
	end
	state = "build"
	Net.send("Map.Build", slot) -- off the test map, back on the plot
	controllers.Tracks.setTest(nil)
	controllers.Tracks.setBuilderButtons(false)
	if savedCam then
		cam = savedCam
	end
	parkCar()
	showBuildView()
end

local function onTestFinished(result: { [string]: any })
	if state ~= "test" then
		return
	end
	local time = if type(result.time) == "number" then TracksMath.formatTime(result.time) else ""
	if result.practice then
		BuilderHud.setTestStatus("Practice " .. time .. ". Finish from the START to publish.")
	elseif result.ok and result.test then
		testedFingerprint = piecesFingerprint()
		BuilderHud.setTestStatus("FINISHED in " .. time .. "! Ready to publish.")
		controllers.Juice.fire("StarEarned")
	elseif result.reason == "faster than the map allows" then
		BuilderHud.setTestStatus("Too short: a map must take at least 5 seconds.")
	else
		BuilderHud.setTestStatus("That run didn't count. Try again!")
	end
	-- No downtime: back to the line for another go
	task.delay(2.5, function()
		if state == "test" then
			controllers.Tracks.retry()
		end
	end)
end

---------------------------------------------------------------------------
-- Map settings and publish
---------------------------------------------------------------------------

local PUBLISH_REASONS = {
	invalid = "Something in this map isn't allowed.",
	badName = "Pick a name with the word wheels.",
	notTested = "Finish your map once from the START gate.",
	banned = "Publishing is paused on your account for now.",
	needRun = "Finish any Tracks map once first.",
	tooMany = "You have the most live maps you can have.",
	storeDown = "Publishing is down right now. Try again soon!",
	notBuilding = "Open the map again to publish it.",
}

local function minutes(seconds: number): string
	local m = math.ceil(seconds / 60)
	return if m == 1 then "1 minute" else tostring(m) .. " minutes"
end

local function linkedMapId(): string?
	if drafts == nil then
		return nil
	end
	for _, s in drafts.slots do
		if s.slot == slot then
			return s.mapId
		end
	end
	return nil
end

local function publishView(): BuilderHud.PublishView
	local words = {}
	local lists = { MapNames.ADJECTIVES, MapNames.NOUNS, MapNames.PLACES }
	for i = 1, 3 do
		words[i] = lists[i][map.name[i]] or "?"
	end
	local tags = {}
	for i, name in MapNames.TAGS do
		table.insert(tags, { name = name, on = bit32.btest(map.tags, bit32.lshift(1, i - 1)) })
	end
	local named = MapNames.valid(map.name[1], map.name[2], map.name[3])
	local tested = isTested()
	local playable = MapRules.checkPlayable(map, options())
	local checks = {
		{ text = "A START gate and a FINISH arch", ok = playable },
		{ text = "Finish your map once to publish", ok = tested },
		{ text = "Pick a name", ok = named },
	}
	if publishNote then
		table.insert(checks, { text = publishNote, ok = false })
	end
	local live = linkedMapId() ~= nil
	return {
		words = words,
		tags = tags,
		fullDamage = MapCodec.fullDamage(map),
		checks = checks,
		canPublish = playable and tested and named and not queuedPublish,
		publishLabel = if queuedPublish then "WHEN READY" elseif live then "UPDATE" else "PUBLISH",
	}
end

local openMapSettings: () -> ()

local publishActions: BuilderHud.PublishActions = {
	onWord = function(index, delta)
		local list = ({ MapNames.ADJECTIVES, MapNames.NOUNS, MapNames.PLACES })[index]
		local current = map.name[index]
		if current < 1 then
			current = if delta > 0 then 0 else 1
		end
		map.name[index] = (current - 1 + delta) % #list + 1
		dirty = true
		BuilderHud.updatePublish(publishView())
	end,
	onRandom = function()
		map.name = {
			math.random(#MapNames.ADJECTIVES),
			math.random(#MapNames.NOUNS),
			math.random(#MapNames.PLACES),
		}
		dirty = true
		BuilderHud.updatePublish(publishView())
	end,
	onTag = function(index)
		local bit = bit32.lshift(1, index - 1)
		if bit32.btest(map.tags, bit) then
			map.tags = bit32.band(map.tags, bit32.bnot(bit))
		elseif MapNames.tagCount(map.tags) < MapNames.MAX_TAGS then
			map.tags = bit32.bor(map.tags, bit)
		else
			BuilderHud.toast("3 tags at most")
			return
		end
		dirty = true
		BuilderHud.updatePublish(publishView())
	end,
	onFullDamage = function()
		MapCodec.setFullDamage(map, not MapCodec.fullDamage(map))
		dirty = true
		BuilderHud.updatePublish(publishView())
	end,
	onPublish = function()
		save(false)
		publishNote = "Publishing..."
		Net.send("Map.Publish", slot, MapCodec.encode(map))
		BuilderHud.updatePublish(publishView())
	end,
	onClose = function()
		BuilderHud.closePublish()
		if dirty then
			save(false)
		end
	end,
}

openMapSettings = function()
	if state ~= "build" then
		return
	end
	if not MapNames.valid(map.name[1], map.name[2], map.name[3]) then
		publishActions.onRandom() -- start from a fun name; the wheels change it
	end
	BuilderHud.openPublish(publishView(), publishActions)
end

local function onPublished(result: { [string]: any })
	if type(result) ~= "table" then
		return
	end
	if result.ok then
		publishNote, queuedPublish = nil, false
		BuilderHud.closePublish()
		controllers.Juice.fire("Publish")
		Confetti.burst(cam.focus + Vector3.new(0, 8, 0), 60)
		BuilderHud.showPublished(result.name or "", result.first == true, function()
			pcall(function()
				SocialService:PromptGameInvite(LocalPlayer)
			end)
		end)
		Net.send("Map.RequestDrafts")
		return
	end
	local reason = result.reason
	local wait = tonumber(result.wait) or 0
	if reason == "cooldown" then
		queuedPublish = result.queued == true
		publishNote = "Publishing by itself in " .. minutes(wait)
	elseif reason == "needPlayTime" then
		publishNote = "Play " .. minutes(wait) .. " more to publish"
	else
		publishNote = PUBLISH_REASONS[reason] or "Couldn't publish. Try again!"
	end
	BuilderHud.updatePublish(publishView())
	BuilderHud.toast(publishNote :: string, 3)
end

---------------------------------------------------------------------------
-- Draft picker
---------------------------------------------------------------------------

local wantPicker = false

local function showPicker()
	if drafts == nil then
		return
	end
	local cards = {}
	for _, s in drafts.slots do
		table.insert(cards, {
			slot = s.slot,
			pieces = s.pieces or 0,
			live = s.mapId ~= nil,
			tested = s.tested == true,
			locked = false,
		})
	end
	-- Without VIP, show the slots VIP would add (locked)
	if not drafts.vip then
		for extra = drafts.maxSlots + 1, Config.Builder.vipDraftSlots do
			table.insert(cards, { slot = extra, pieces = 0, live = false, tested = false, locked = true })
		end
	end
	local note = if drafts.vip then nil else "VIP: 10 slots, a fine grid and 24 colours"
	BuilderHud.openDrafts(cards, note, enter)
end

-- BUILD on the Tracks HUD: the draft slots, or back to building from a TEST
function BuilderClient.onBuildButton()
	if state == "test" then
		backToBuild()
		return
	end
	if state ~= "off" then
		return
	end
	if controllers.Tracks.getRunState() == "running" then
		controllers.Tracks.toast("Finish or reset your run first!")
		return
	end
	wantPicker = true
	Net.send("Map.RequestDrafts")
end

function BuilderClient.isBuilding(): boolean
	return state ~= "off"
end

---------------------------------------------------------------------------

function BuilderClient.init(all)
	controllers = all
end

function BuilderClient.start()
	BuilderHud.build({
		onExit = exit,
		onSave = function()
			save(true)
		end,
		onTest = test,
		onMapSettings = function()
			openMapSettings()
		end,
		onUndo = undo,
		onRedo = redo,
		onPick = pick,
		onRotate = function()
			rotate(1)
		end,
		onTilt = tilt,
		onSize = resize,
		onColour = colour,
		onUp = function()
			raise(1)
		end,
		onDown = function()
			raise(-1)
		end,
		onDelete = delete,
		onDone = done,
		onFineGrid = function()
			fineGrid = not fineGrid
			refreshHud()
		end,
	})
	connectInput()

	Net.listen("Map.Drafts", function(view)
		if type(view) ~= "table" or type(view.slots) ~= "table" then
			return
		end
		drafts = view
		if wantPicker and state == "off" then
			wantPicker = false
			showPicker()
		end
	end)
	Net.listen("Map.TestReady", function(readySlot, ok, reason)
		if readySlot ~= slot or state ~= "loading" or pendingTest == nil then
			return
		end
		if not ok then
			pendingTest = nil
			state = "build"
			showBuildView()
			BuilderHud.toast(TEST_REASONS[reason] or TEST_REASONS.invalid)
		end
		-- ok: the server is putting a new car on the start gate; driving starts when it arrives
	end)
	Net.listen("Map.Published", onPublished)
	controllers.Vehicle.Spawned:Connect(function()
		if state == "loading" and pendingTest then
			task.defer(startDriving) -- after TracksClient readies the run for the new car
		elseif state == "build" then
			parkCar() -- a new car while building (the watchdog): keep it parked
		end
	end)
	controllers.Tracks.TestFinished:Connect(onTestFinished)

	-- Autosave every 30 s while something changed
	RunService.Heartbeat:Connect(function(dt)
		if state == "build" and dirty then
			sinceSave += dt
			if sinceSave >= Config.Builder.autosaveInterval then
				save(false)
			end
		end
	end)
	-- Leaving the game saves too (best effort: the server keeps the last autosave otherwise)
	Players.PlayerRemoving:Connect(function(player)
		if player == LocalPlayer and dirty then
			save(false)
		end
	end)
end

return BuilderClient
