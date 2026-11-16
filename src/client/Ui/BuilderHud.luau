-- BuilderHud: the map builder's screens (spec: Screens and UI > Builder, Publish dialog).
--   Top bar: EXIT, the piece count "132 / 250" and part meter "260 / 400", SAVE, MAP (settings and
--   publish). Right: TEST (big), UNDO, REDO. Bottom: the scrolling tray of 20 pieces (greyed when a
--   limit is reached). Above the tray when a piece is picked: ROTATE, TILT, SIZE, COLOUR, UP, DOWN,
--   DELETE, DONE. A status line says what the map still needs.
--   Draft picker: one card per slot (pieces, LIVE badge, locked VIP slots).
--   Map dialog: three name word wheels, RANDOM, 3 tag chips from the fixed list, FULL DAMAGE, the
--   publish checklist ("Finish your map once to publish") and PUBLISH (or PUBLISH WHEN READY).
-- Text is ours only: players pick words and chips, never type (design pillar: no free text).
-- Every tap target is at least Config.UI.minTapTarget (64 px at 1080p).
-- PLACEHOLDER ART: plain rounded frames, text labels for icons, until the UI art pass.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local BuilderHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local RED = Color3.fromRGB(255, 100, 90)
local BLUE = Color3.fromRGB(86, 170, 255)
local PANEL = Color3.fromRGB(255, 250, 240)
local GREY = Color3.fromRGB(170, 170, 182)
local MIN = Config.UI.minTapTarget

export type Callbacks = {
	onExit: () -> (),
	onSave: () -> (),
	onTest: () -> (),
	onMapSettings: () -> (),
	onUndo: () -> (),
	onRedo: () -> (),
	onPick: (number) -> (),
	onRotate: () -> (),
	onTilt: () -> (),
	onSize: () -> (),
	onColour: (number) -> (),
	onUp: () -> (),
	onDown: () -> (),
	onDelete: () -> (),
	onDone: () -> (),
	onFineGrid: () -> (),
}

export type TrayEntry = { id: number, label: string, cost: number, ok: boolean, reason: string? }

export type Selection = {
	title: string,
	canTilt: boolean,
	canSize: boolean,
	placing: boolean, -- true: the settings for the next placed piece (no DELETE)
	sizeLabel: string?,
}

local gui: ScreenGui
local buildFrame: Frame
local trayList: ScrollingFrame
local trayButtons: { [number]: TextButton } = {}
local selectionBar: Frame
local selectionTitle: TextLabel
local tiltButton: TextButton
local sizeButton: TextButton
local deleteButton: TextButton
local swatchRow: Frame? = nil
local piecesLabel: TextLabel
local partsLabel: TextLabel
local statusLabel: TextLabel
local toastLabel: TextLabel
local undoButton: TextButton
local redoButton: TextButton
local fineButton: TextButton
local testBanner: TextLabel
local draftsFrame: Frame? = nil
local publishFrame: Frame? = nil
local toastToken = 0
local callbacks: Callbacks

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number?, mode: Enum.ApplyStrokeMode?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = INK
	s.ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function text(parent: Instance, name: string, value: string, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextScaled = true
	label.Text = value
	label.TextColor3 = color or WHITE
	label.Parent = parent
	return label
end

local function outlined(label: TextLabel, thickness: number?)
	stroke(label, thickness or 3, Enum.ApplyStrokeMode.Contextual)
end

-- A button sized as a fraction of the screen height (RelativeYY), never under the minimum tap target
local function button(
	parent: Instance,
	name: string,
	label: string,
	color: Color3,
	width: number,
	height: number,
	order: number?
): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = label
	b.Font = FONT
	b.TextScaled = true
	b.TextColor3 = INK
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.SizeConstraint = Enum.SizeConstraint.RelativeYY
	b.Size = UDim2.fromScale(width, height)
	b.LayoutOrder = order or 0
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(math.max(MIN, MIN * width / height), MIN)
	minimum.Parent = b
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.22, 0)
	padding.PaddingBottom = UDim.new(0.22, 0)
	padding.PaddingLeft = UDim.new(0.08, 0)
	padding.PaddingRight = UDim.new(0.08, 0)
	padding.Parent = b
	corner(b, 0.3)
	stroke(b)
	b.Parent = parent
	return b
end

local function row(parent: Instance, name: string, horizontal: boolean, gap: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Parent = parent
	local list = Instance.new("UIListLayout")
	list.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	list.Padding = UDim.new(0, gap or 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Parent = f
	return f
end

local function setEnabled(b: TextButton, enabled: boolean)
	b.Active = enabled
	b.AutoButtonColor = enabled
	b.TextTransparency = if enabled then 0 else 0.55
	b.BackgroundTransparency = if enabled then 0 else 0.35
end

local function modal(name: string, width: number, height: number): Frame
	local shade = Instance.new("Frame")
	shade.Name = name
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.Size = UDim2.fromScale(1, 1)
	shade.Active = true -- taps on the shade never reach the plot
	shade.ZIndex = 20
	shade.Parent = gui
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BackgroundColor3 = PANEL
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(width, height)
	card.ZIndex = 21
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(math.huge, math.huge)
	maxSize.Parent = card
	corner(card, 0.06)
	stroke(card, 2)
	card.Parent = shade
	return shade
end

local function zAll(root: Instance, z: number)
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, z)
		end
	end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

function BuilderHud.build(cb: Callbacks)
	callbacks = cb
	gui = Instance.new("ScreenGui")
	gui.Name = "BuilderHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	buildFrame = Instance.new("Frame")
	buildFrame.Name = "Build"
	buildFrame.BackgroundTransparency = 1
	buildFrame.Size = UDim2.fromScale(1, 1)
	buildFrame.Visible = false
	buildFrame.Parent = gui

	-- Top bar
	local top = row(buildFrame, "Top", true)
	top.Position = UDim2.new(0, 16, 0, 12)
	top.Size = UDim2.new(1, -32, 0.1, 0)
	button(top, "Exit", "EXIT", WHITE, 0.16, 0.085, 1).Activated:Connect(function()
		callbacks.onExit()
	end)
	local counters = Instance.new("Frame")
	counters.Name = "Counters"
	counters.BackgroundColor3 = INK
	counters.BackgroundTransparency = 0.25
	counters.SizeConstraint = Enum.SizeConstraint.RelativeYY
	counters.Size = UDim2.fromScale(0.5, 0.085)
	counters.LayoutOrder = 2
	corner(counters, 0.4)
	counters.Parent = top
	piecesLabel = text(counters, "Pieces", "0 / 250", WHITE)
	piecesLabel.Size = UDim2.fromScale(0.48, 0.7)
	piecesLabel.Position = UDim2.fromScale(0.02, 0.15)
	partsLabel = text(counters, "Parts", "0 / 400", WHITE)
	partsLabel.Size = UDim2.fromScale(0.48, 0.7)
	partsLabel.Position = UDim2.fromScale(0.5, 0.15)
	button(top, "Save", "SAVE", WHITE, 0.16, 0.085, 3).Activated:Connect(function()
		callbacks.onSave()
	end)
	button(top, "Map", "MAP", GOLD, 0.16, 0.085, 4).Activated:Connect(function()
		callbacks.onMapSettings()
	end)
	fineButton = button(top, "Fine", "FINE GRID", WHITE, 0.24, 0.085, 5)
	fineButton.Visible = false
	fineButton.Activated:Connect(function()
		callbacks.onFineGrid()
	end)

	-- Right column: TEST, UNDO, REDO
	local right = row(buildFrame, "Right", false)
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.new(1, -16, 0.42, 0)
	right.Size = UDim2.fromScale(0.2, 0.5)
	button(right, "Test", "TEST", GREEN, 0.24, 0.12, 1).Activated:Connect(function()
		callbacks.onTest()
	end)
	undoButton = button(right, "Undo", "UNDO", WHITE, 0.2, 0.085, 2)
	undoButton.Activated:Connect(function()
		callbacks.onUndo()
	end)
	redoButton = button(right, "Redo", "REDO", WHITE, 0.2, 0.085, 3)
	redoButton.Activated:Connect(function()
		callbacks.onRedo()
	end)

	-- Bottom tray: 20 pieces, scrolling sideways
	trayList = Instance.new("ScrollingFrame")
	trayList.Name = "Tray"
	trayList.Active = true
	trayList.BackgroundColor3 = INK
	trayList.BackgroundTransparency = 0.3
	trayList.BorderSizePixel = 0
	trayList.AnchorPoint = Vector2.new(0.5, 1)
	trayList.Position = UDim2.new(0.5, 0, 1, -10)
	trayList.Size = UDim2.new(1, -20, 0.15, 0)
	trayList.ScrollingDirection = Enum.ScrollingDirection.X
	trayList.AutomaticCanvasSize = Enum.AutomaticSize.X
	trayList.CanvasSize = UDim2.new(0, 0, 0, 0)
	trayList.ScrollBarThickness = 6
	corner(trayList, 0.15)
	trayList.Parent = buildFrame
	local trayLayout = Instance.new("UIListLayout")
	trayLayout.FillDirection = Enum.FillDirection.Horizontal
	trayLayout.Padding = UDim.new(0, 8)
	trayLayout.SortOrder = Enum.SortOrder.LayoutOrder
	trayLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	trayLayout.Parent = trayList
	local trayPad = Instance.new("UIPadding")
	trayPad.PaddingLeft = UDim.new(0, 8)
	trayPad.PaddingRight = UDim.new(0, 8)
	trayPad.Parent = trayList

	-- Selection bar above the tray
	selectionBar = row(buildFrame, "Selection", true, 8)
	selectionBar.AnchorPoint = Vector2.new(0.5, 1)
	selectionBar.Position = UDim2.new(0.5, 0, 0.85, -18)
	selectionBar.Size = UDim2.new(1, -20, 0.1, 0)
	selectionBar.Visible = false
	selectionTitle = text(selectionBar, "Title", "", WHITE)
	selectionTitle.SizeConstraint = Enum.SizeConstraint.RelativeYY
	selectionTitle.Size = UDim2.fromScale(0.24, 0.06)
	selectionTitle.LayoutOrder = 0
	outlined(selectionTitle)
	button(selectionBar, "Rotate", "ROTATE", WHITE, 0.17, 0.08, 1).Activated:Connect(function()
		callbacks.onRotate()
	end)
	tiltButton = button(selectionBar, "Tilt", "TILT", WHITE, 0.14, 0.08, 2)
	tiltButton.Activated:Connect(function()
		callbacks.onTilt()
	end)
	sizeButton = button(selectionBar, "Size", "SIZE", WHITE, 0.14, 0.08, 3)
	sizeButton.Activated:Connect(function()
		callbacks.onSize()
	end)
	button(selectionBar, "Colour", "COLOUR", WHITE, 0.17, 0.08, 4).Activated:Connect(function()
		BuilderHud.toggleSwatches()
	end)
	button(selectionBar, "Up", "UP", WHITE, 0.1, 0.08, 5).Activated:Connect(function()
		callbacks.onUp()
	end)
	button(selectionBar, "Down", "DOWN", WHITE, 0.12, 0.08, 6).Activated:Connect(function()
		callbacks.onDown()
	end)
	deleteButton = button(selectionBar, "Delete", "DELETE", RED, 0.15, 0.08, 7)
	deleteButton.Activated:Connect(function()
		callbacks.onDelete()
	end)
	button(selectionBar, "Done", "DONE", GREEN, 0.12, 0.08, 8).Activated:Connect(function()
		callbacks.onDone()
	end)

	statusLabel = text(buildFrame, "Status", "", WHITE)
	statusLabel.AnchorPoint = Vector2.new(0.5, 0)
	statusLabel.Position = UDim2.fromScale(0.5, 0.13)
	statusLabel.Size = UDim2.fromScale(0.6, 0.04)
	outlined(statusLabel)

	toastLabel = text(gui, "Toast", "", WHITE)
	toastLabel.AnchorPoint = Vector2.new(0.5, 0)
	toastLabel.Position = UDim2.fromScale(0.5, 0.2)
	toastLabel.Size = UDim2.fromScale(0.7, 0.05)
	toastLabel.Visible = false
	toastLabel.ZIndex = 30
	outlined(toastLabel)

	-- TEST mode: one line under the timer (BUILD is beside MAPS on the Tracks HUD)
	testBanner = text(gui, "TestBanner", "", WHITE)
	testBanner.AnchorPoint = Vector2.new(0.5, 0)
	testBanner.Position = UDim2.fromScale(0.5, 0.2)
	testBanner.Size = UDim2.fromScale(0.6, 0.045)
	testBanner.Visible = false
	outlined(testBanner)
end

function BuilderHud.setVisible(visible: boolean)
	gui.Enabled = visible
end

-- "build": the plot tools; "test": only the test line (the driving HUD is back)
function BuilderHud.setMode(mode: string)
	buildFrame.Visible = mode == "build"
	testBanner.Visible = mode == "test" and testBanner.Text ~= ""
	if mode ~= "build" then
		BuilderHud.closeSwatches()
	end
end

function BuilderHud.setTestStatus(value: string?)
	testBanner.Text = value or ""
	testBanner.Visible = value ~= nil and not buildFrame.Visible
end

function BuilderHud.setFineGrid(available: boolean, on: boolean)
	fineButton.Visible = available
	fineButton.BackgroundColor3 = if on then GOLD else WHITE
end

function BuilderHud.setTray(entries: { TrayEntry }, picked: number?)
	for _, entry in entries do
		local b = trayButtons[entry.id]
		if b == nil then
			b = button(trayList, "Piece" .. entry.id, entry.label, WHITE, 0.17, 0.11, entry.id)
			local cost = text(b, "Cost", "", INK)
			cost.Size = UDim2.fromScale(0.5, 0.35)
			cost.AnchorPoint = Vector2.new(1, 0)
			cost.Position = UDim2.new(1, 0, -0.42, 0)
			cost.TextXAlignment = Enum.TextXAlignment.Right
			local id = entry.id
			b.Activated:Connect(function()
				callbacks.onPick(id)
			end)
			trayButtons[entry.id] = b
		end
		local cost = b:FindFirstChild("Cost") :: TextLabel
		cost.Text = if entry.ok then tostring(entry.cost) else (entry.reason or "")
		b.BackgroundColor3 = if picked == entry.id then GOLD elseif entry.ok then WHITE else GREY
		b.TextTransparency = if entry.ok then 0 else 0.45
	end
end

function BuilderHud.setCounts(pieces: number, maxPieces: number, parts: number, maxParts: number)
	piecesLabel.Text = string.format("%d / %d", pieces, maxPieces)
	partsLabel.Text = string.format("%d / %d", parts, maxParts)
	piecesLabel.TextColor3 = if pieces >= maxPieces then RED else WHITE
	partsLabel.TextColor3 = if parts >= maxParts then RED else WHITE
end

function BuilderHud.setStatus(value: string?)
	statusLabel.Text = value or ""
	statusLabel.Visible = value ~= nil
end

function BuilderHud.setUndo(canUndo: boolean, canRedo: boolean)
	setEnabled(undoButton, canUndo)
	setEnabled(redoButton, canRedo)
end

function BuilderHud.setSelection(selection: Selection?)
	selectionBar.Visible = selection ~= nil
	if selection == nil then
		BuilderHud.closeSwatches()
		return
	end
	selectionTitle.Text = selection.title
	tiltButton.Visible = selection.canTilt
	sizeButton.Visible = selection.canSize
	sizeButton.Text = selection.sizeLabel or "SIZE"
	deleteButton.Visible = not selection.placing
end

-- Colour swatches: 0 (the piece's own), then 12 (24 with VIP)
local swatchColours: { Color3 } = {}
local swatchCount = 12
function BuilderHud.setSwatches(colours: { Color3 }, count: number)
	swatchColours = colours
	swatchCount = count
end

function BuilderHud.closeSwatches()
	if swatchRow then
		swatchRow:Destroy()
		swatchRow = nil
	end
end

function BuilderHud.toggleSwatches()
	if swatchRow then
		BuilderHud.closeSwatches()
		return
	end
	local f = Instance.new("Frame")
	f.Name = "Swatches"
	f.Active = true
	f.BackgroundColor3 = INK
	f.BackgroundTransparency = 0.25
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.new(0.5, 0, 0.75, -20)
	f.Size = UDim2.new(0.9, 0, 0.18, 0)
	corner(f, 0.12)
	f.Parent = buildFrame
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.CellSize = UDim2.fromOffset(MIN, MIN)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = f
	for index = 0, swatchCount do
		local b = Instance.new("TextButton")
		b.Name = "Swatch" .. index
		b.LayoutOrder = index
		b.Text = if index == 0 then "↺" else ""
		b.Font = FONT
		b.TextScaled = true
		b.TextColor3 = INK
		b.BackgroundColor3 = if index == 0 then WHITE else swatchColours[index] or WHITE
		corner(b, 0.5)
		stroke(b, 2)
		b.Parent = f
		b.Activated:Connect(function()
			callbacks.onColour(index)
		end)
	end
	swatchRow = f
end

function BuilderHud.toast(value: string, duration: number?)
	toastToken += 1
	local token = toastToken
	toastLabel.Text = value
	toastLabel.Visible = true
	task.delay(duration or 2.5, function()
		if toastToken == token then
			toastLabel.Visible = false
		end
	end)
end

---------------------------------------------------------------------------
-- Draft picker
---------------------------------------------------------------------------

export type DraftCard = { slot: number, pieces: number, live: boolean, tested: boolean, locked: boolean }

function BuilderHud.closeDrafts()
	if draftsFrame then
		draftsFrame:Destroy()
		draftsFrame = nil
	end
	if not buildFrame.Visible and publishFrame == nil then
		gui.Enabled = false
	end
end

function BuilderHud.draftsOpen(): boolean
	return draftsFrame ~= nil
end

function BuilderHud.openDrafts(cards: { DraftCard }, note: string?, onPick: (number) -> ())
	BuilderHud.closeDrafts()
	gui.Enabled = true
	local shade = modal("Drafts", 1.3, 0.8)
	local card = shade:FindFirstChild("Card") :: Frame
	local title = text(card, "Title", "MY MAPS", INK)
	title.Size = UDim2.fromScale(0.6, 0.1)
	title.Position = UDim2.fromScale(0.2, 0.03)
	local close = button(card, "Close", "CLOSE", WHITE, 0.16, 0.07)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.97, 0.03)
	close.Activated:Connect(BuilderHud.closeDrafts)
	local list = Instance.new("ScrollingFrame")
	list.Name = "Slots"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromScale(0.04, 0.16)
	list.Size = UDim2.fromScale(0.92, if note then 0.72 else 0.8)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.ScrollBarThickness = 6
	list.Parent = card
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromScale(0.02, 0.02)
	grid.CellSize = UDim2.new(0.31, 0, 0, math.max(MIN * 1.6, 110))
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = list
	for _, entry in cards do
		local b = Instance.new("TextButton")
		b.Name = "Slot" .. entry.slot
		b.LayoutOrder = entry.slot
		b.Text = ""
		b.BackgroundColor3 = if entry.locked then GREY elseif entry.pieces > 0 then WHITE else PANEL
		b.AutoButtonColor = not entry.locked
		corner(b, 0.12)
		stroke(b, 2)
		b.Parent = list
		local name = text(b, "Name", if entry.locked then "VIP" else "MAP " .. entry.slot, INK)
		name.Size = UDim2.fromScale(0.9, 0.38)
		name.Position = UDim2.fromScale(0.05, 0.08)
		local detail = text(
			b,
			"Detail",
			if entry.locked
				then "More slots"
				elseif entry.pieces == 0 then "Empty"
				else entry.pieces .. " pieces",
			INK
		)
		detail.Size = UDim2.fromScale(0.9, 0.26)
		detail.Position = UDim2.fromScale(0.05, 0.5)
		if entry.live then
			local badge = text(b, "Live", "LIVE", WHITE)
			badge.BackgroundTransparency = 0
			badge.BackgroundColor3 = GREEN
			badge.Size = UDim2.fromScale(0.36, 0.22)
			badge.Position = UDim2.fromScale(0.6, -0.08)
			corner(badge, 0.4)
		end
		if not entry.locked then
			local slot = entry.slot
			b.Activated:Connect(function()
				BuilderHud.closeDrafts()
				onPick(slot)
			end)
		end
	end
	if note then
		local noteLabel = text(card, "Note", note, INK)
		noteLabel.Size = UDim2.fromScale(0.9, 0.07)
		noteLabel.Position = UDim2.fromScale(0.05, 0.9)
	end
	zAll(shade, 22)
	draftsFrame = shade
end

---------------------------------------------------------------------------
-- Map settings and publish
---------------------------------------------------------------------------

export type PublishView = {
	words: { string }, -- adjective, noun, place (or "?")
	tags: { { name: string, on: boolean } },
	fullDamage: boolean,
	checks: { { text: string, ok: boolean } }, -- the publish checklist
	canPublish: boolean,
	publishLabel: string, -- "PUBLISH", "UPDATE" or "WHEN READY"
}

export type PublishActions = {
	onWord: (number, number) -> (), -- wheel index 1..3, step -1 or 1
	onRandom: () -> (),
	onTag: (number) -> (),
	onFullDamage: () -> (),
	onPublish: () -> (),
	onClose: () -> (),
}

local publishActions: PublishActions? = nil

function BuilderHud.closePublish()
	if publishFrame then
		publishFrame:Destroy()
		publishFrame = nil
	end
	publishActions = nil
end

function BuilderHud.publishOpen(): boolean
	return publishFrame ~= nil
end

function BuilderHud.openPublish(view: PublishView, actions: PublishActions)
	BuilderHud.closePublish()
	publishActions = actions
	local shade = modal("Publish", 1.35, 0.9)
	local card = shade:FindFirstChild("Card") :: Frame
	local title = text(card, "Title", "MAP SETTINGS", INK)
	title.Size = UDim2.fromScale(0.6, 0.08)
	title.Position = UDim2.fromScale(0.2, 0.025)
	local close = button(card, "Close", "CLOSE", WHITE, 0.16, 0.07)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.97, 0.02)
	close.Activated:Connect(function()
		actions.onClose()
	end)

	-- Name: three word wheels and RANDOM
	local wheels = row(card, "Wheels", true, 8)
	wheels.Position = UDim2.fromScale(0.03, 0.12)
	wheels.Size = UDim2.fromScale(0.94, 0.2)
	for index = 1, 3 do
		local wheel = Instance.new("Frame")
		wheel.Name = "Wheel" .. index
		wheel.BackgroundColor3 = WHITE
		wheel.LayoutOrder = index
		wheel.Size = UDim2.fromScale(0.27, 1)
		corner(wheel, 0.15)
		stroke(wheel, 2)
		wheel.Parent = wheels
		local word = text(wheel, "Word", view.words[index], INK)
		word.Size = UDim2.fromScale(0.9, 0.36)
		word.Position = UDim2.fromScale(0.05, 0.32)
		local up = button(wheel, "Up", "▲", PANEL, 0.08, 0.055)
		up.AnchorPoint = Vector2.new(0.5, 0)
		up.Position = UDim2.fromScale(0.5, 0)
		up.Size = UDim2.fromScale(0.5, 0.3)
		up.SizeConstraint = Enum.SizeConstraint.RelativeXY
		up.Activated:Connect(function()
			actions.onWord(index, -1)
		end)
		local down = button(wheel, "Down", "▼", PANEL, 0.08, 0.055)
		down.AnchorPoint = Vector2.new(0.5, 1)
		down.Position = UDim2.fromScale(0.5, 1)
		down.Size = UDim2.fromScale(0.5, 0.3)
		down.SizeConstraint = Enum.SizeConstraint.RelativeXY
		down.Activated:Connect(function()
			actions.onWord(index, 1)
		end)
	end
	local random = button(wheels, "Random", "RANDOM", GOLD, 0.16, 0.08, 4)
	random.Activated:Connect(function()
		actions.onRandom()
	end)

	-- Tags: up to 3 chips
	local tagsLabel = text(card, "TagsLabel", "TAGS (UP TO 3)", INK)
	tagsLabel.Size = UDim2.fromScale(0.5, 0.045)
	tagsLabel.Position = UDim2.fromScale(0.25, 0.34)
	local chips = Instance.new("Frame")
	chips.Name = "Tags"
	chips.BackgroundTransparency = 1
	chips.Position = UDim2.fromScale(0.04, 0.4)
	chips.Size = UDim2.fromScale(0.92, 0.17)
	chips.Parent = card
	local chipGrid = Instance.new("UIGridLayout")
	chipGrid.CellPadding = UDim2.fromScale(0.015, 0.08)
	chipGrid.CellSize = UDim2.fromScale(0.235, 0.44)
	chipGrid.SortOrder = Enum.SortOrder.LayoutOrder
	chipGrid.Parent = chips
	for index, tag in view.tags do
		local chip = button(
			chips,
			"Tag" .. index,
			string.upper(tag.name),
			if tag.on then BLUE else WHITE,
			0.1,
			0.06,
			index
		)
		chip.Activated:Connect(function()
			actions.onTag(index)
		end)
	end

	local damage = button(
		card,
		"FullDamage",
		if view.fullDamage then "FULL DAMAGE: ON" else "FULL DAMAGE: OFF",
		if view.fullDamage then GOLD else WHITE,
		0.5,
		0.07
	)
	damage.AnchorPoint = Vector2.new(0.5, 0)
	damage.Position = UDim2.fromScale(0.5, 0.59)
	damage.Activated:Connect(function()
		actions.onFullDamage()
	end)

	-- Publish checklist and button
	local checks = row(card, "Checks", false, 2)
	checks.Position = UDim2.fromScale(0.05, 0.68)
	checks.Size = UDim2.fromScale(0.9, 0.17)
	for index, check in view.checks do
		local line = text(
			checks,
			"Check" .. index,
			(if check.ok then "✓ " else "• ") .. check.text,
			if check.ok then GREEN else INK
		)
		line.LayoutOrder = index
		line.Size = UDim2.fromScale(1, 0.24)
		line.TextXAlignment = Enum.TextXAlignment.Left
	end
	local publish =
		button(card, "PublishButton", view.publishLabel, if view.canPublish then GREEN else GREY, 0.36, 0.08)
	publish.AnchorPoint = Vector2.new(0.5, 1)
	publish.Position = UDim2.fromScale(0.5, 0.975)
	setEnabled(publish, view.canPublish)
	publish.Activated:Connect(function()
		if view.canPublish then
			actions.onPublish()
		end
	end)
	zAll(shade, 22)
	publishFrame = shade
end

-- Redraw the dialog with a new view (a wheel turned, a tag picked)
function BuilderHud.updatePublish(view: PublishView)
	if publishFrame and publishActions then
		BuilderHud.openPublish(view, publishActions)
	end
end

-- The publish banner: the map's name sliding up, and INVITE on a first publish
function BuilderHud.showPublished(name: string, first: boolean, onInvite: (() -> ())?)
	local banner = Instance.new("Frame")
	banner.Name = "Published"
	banner.BackgroundColor3 = GOLD
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.75)
	banner.SizeConstraint = Enum.SizeConstraint.RelativeYY
	banner.Size = UDim2.fromScale(1.1, 0.22)
	banner.ZIndex = 40
	corner(banner, 0.15)
	stroke(banner, 2)
	banner.Parent = gui
	local headline = text(banner, "Headline", "PUBLISHED!", INK)
	headline.Size = UDim2.fromScale(0.9, 0.36)
	headline.Position = UDim2.fromScale(0.05, 0.06)
	local mapName = text(banner, "Name", name, INK)
	mapName.Size = UDim2.fromScale(0.9, 0.26)
	mapName.Position = UDim2.fromScale(0.05, 0.42)
	if first and onInvite then
		local invite = button(banner, "Invite", "INVITE", WHITE, 0.22, 0.06)
		invite.AnchorPoint = Vector2.new(0.5, 1)
		invite.Position = UDim2.fromScale(0.5, 0.96)
		invite.Activated:Connect(onInvite)
	end
	zAll(banner, 40)
	banner:TweenPosition(
		UDim2.fromScale(0.5, 0.45),
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Back,
		0.45,
		true
	)
	task.delay(if first then 6 else 3.5, function()
		banner:Destroy()
	end)
end

return BuilderHud
