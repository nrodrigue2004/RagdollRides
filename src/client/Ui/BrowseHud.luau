-- BrowseHud: the browse screen (spec: Screens and UI > Browse). MAPS opens it.
--   Tabs: FEATURED, POPULAR, NEWEST, FRIENDS, MY MAPS, STARTER (and REVIEW for admins).
--   A 3 x 3 grid of map cards: a top-down sketch drawn from the map's own pieces, the preset name,
--   "by" the creator, the rating (or NEW under 10 ratings) and plays, and up to 3 tags. Badges:
--   FEATURED, HIDDEN FOR REVIEW. Tap a card to drive it. Paging arrows under the grid.
--   Grey skeleton cards pulse while a page loads, so the screen never sits blank.
--   Admins get a small gear on each card with the moderation actions.
-- Text is ours only: names are preset words, tags are a fixed list (design pillar: no free text).
-- PLACEHOLDER ART: plain rounded frames and text glyphs until the UI art pass.

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local MapBuilder = require(Shared.MapBuilder)
local StarterMaps = require(Shared.StarterMaps)

local BrowseHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local RED = Color3.fromRGB(255, 100, 90)
local PANEL = Color3.fromRGB(255, 250, 240)
local GREY = Color3.fromRGB(110, 110, 125)
local SKETCH_BG = Color3.fromRGB(122, 204, 120)
local SKELETON = Color3.fromRGB(225, 220, 210)
local MIN = Config.UI.minTapTarget
local MAX_SKETCH_PARTS = 160

export type Tab = { id: string, label: string }

export type AdminState = { featured: boolean, hidden: boolean }

export type CardView = {
	id: string,
	name: string,
	sub: string, -- "by name", or the starter map's best time
	stats: string, -- "★ 4.3 · 1,204 plays", "NEW · 12 plays", or stars earned
	tags: string,
	badge: string?,
	badgeColor: Color3?,
	pieces: { StarterMaps.Piece },
	current: boolean?,
	admin: AdminState?, -- set only for admins on player maps
}

export type Callbacks = {
	onTab: (string) -> (),
	onPage: (number) -> (), -- -1 or +1
	onPlay: (CardView) -> (),
	onAdmin: (CardView, string) -> (),
	onClose: () -> (),
}

local gui: ScreenGui? = nil
local card: Frame? = nil
local grid: Frame
local tabButtons: { [string]: TextButton } = {}
local pageLabel: TextLabel
local prevButton: TextButton
local nextButton: TextButton
local emptyLabel: TextLabel
local callbacks: Callbacks
local pulse: Tween? = nil

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number?, mode: Enum.ApplyStrokeMode?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 3
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
	label.TextColor3 = color or INK
	label.Parent = parent
	return label
end

local function button(parent: Instance, name: string, label: string, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = label
	b.Font = FONT
	b.TextScaled = true
	b.TextColor3 = INK
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.2, 0)
	padding.PaddingBottom = UDim.new(0.2, 0)
	padding.PaddingLeft = UDim.new(0.06, 0)
	padding.PaddingRight = UDim.new(0.06, 0)
	padding.Parent = b
	corner(b, 0.3)
	stroke(b, 2)
	b.Parent = parent
	return b
end

local function minSize(parent: GuiObject, width: number, height: number)
	local c = Instance.new("UISizeConstraint")
	c.MinSize = Vector2.new(width, height)
	c.Parent = parent
end

local function setEnabled(b: TextButton, enabled: boolean)
	b.Active = enabled
	b.AutoButtonColor = enabled
	b.TextTransparency = if enabled then 0 else 0.6
	b.BackgroundTransparency = if enabled then 0 else 0.4
end

---------------------------------------------------------------------------
-- Sketch: the map from above, drawn with one rotated frame per piece (forward is up)
---------------------------------------------------------------------------

local function drawSketch(parent: Frame, pieces: { StarterMaps.Piece })
	local square = Instance.new("Frame")
	square.Name = "Square"
	square.AnchorPoint = Vector2.new(0.5, 0.5)
	square.Position = UDim2.fromScale(0.5, 0.5)
	square.Size = UDim2.fromScale(0.92, 0.92)
	square.BackgroundTransparency = 1
	square.Parent = parent
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = square

	local shown = {}
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, piece in pieces do
		local colour = MapBuilder.sketchColour(piece)
		if colour then
			local yaw = math.rad(piece.yaw or 0)
			local c, s = math.abs(math.cos(yaw)), math.abs(math.sin(yaw))
			local hx = c * piece.sx / 2 + s * piece.sz / 2
			local hz = s * piece.sx / 2 + c * piece.sz / 2
			minX, maxX = math.min(minX, piece.x - hx), math.max(maxX, piece.x + hx)
			minZ, maxZ = math.min(minZ, piece.z - hz), math.max(maxZ, piece.z + hz)
			table.insert(shown, { piece = piece, colour = colour })
		end
	end
	if #shown == 0 then
		return
	end
	local span = math.max(maxX - minX, maxZ - minZ, 1)
	local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
	-- Big maps: every nth piece, so the sketch stays light (the shape still reads)
	local step = math.max(1, math.ceil(#shown / MAX_SKETCH_PARTS))
	for i = 1, #shown, step do
		local entry = shown[i]
		local piece = entry.piece
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = entry.colour
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5 + (piece.x - cx) / span, 0.5 + (piece.z - cz) / span)
		f.Size = UDim2.fromScale(math.max(piece.sx / span, 0.012), math.max(piece.sz / span, 0.012))
		f.Rotation = -(piece.yaw or 0) -- a positive yaw turns left, which is anticlockwise from above
		f.Parent = square
	end
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local ADMIN_ACTIONS = {
	{
		id = "feature",
		label = "FEATURE",
		show = function(a: AdminState)
			return not a.featured and not a.hidden
		end,
	},
	{
		id = "unfeature",
		label = "UNFEATURE",
		show = function(a: AdminState)
			return a.featured
		end,
	},
	{
		id = "hide",
		label = "HIDE",
		show = function(a: AdminState)
			return not a.hidden
		end,
	},
	{
		id = "confirm",
		label = "CONFIRM HIDE",
		show = function(a: AdminState)
			return a.hidden
		end,
	},
	{
		id = "unhide",
		label = "UNHIDE",
		show = function(a: AdminState)
			return a.hidden
		end,
	},
	{
		id = "ban7",
		label = "BAN 7D",
		show = function()
			return true
		end,
	},
	{
		id = "ban30",
		label = "BAN 30D",
		show = function()
			return true
		end,
	},
	{
		id = "banForever",
		label = "BAN ∞",
		show = function()
			return true
		end,
	},
	{
		id = "unban",
		label = "UNBAN",
		show = function()
			return true
		end,
	},
}

local function clearGrid()
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
	for _, child in grid:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	emptyLabel.Visible = false
end

local function adminStrip(cell: TextButton, view: CardView)
	local strip = Instance.new("ScrollingFrame")
	strip.Name = "Admin"
	strip.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
	strip.Position = UDim2.fromScale(0, 0)
	strip.Size = UDim2.fromScale(1, 1)
	strip.CanvasSize = UDim2.new()
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.ScrollBarThickness = 4
	strip.ZIndex = 5
	corner(strip, 0.12)
	strip.Parent = cell
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = strip
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = strip
	local order = 0
	local function add(label: string, color: Color3, fn: () -> ())
		order += 1
		local b = button(strip, label, label, color)
		b.LayoutOrder = order
		b.Size = UDim2.new(0, 120, 0.7, 0)
		b.ZIndex = 6
		minSize(b, 96, math.min(MIN, 48))
		b.Activated:Connect(fn)
	end
	add("BACK", WHITE, function()
		strip:Destroy()
	end)
	for _, action in ADMIN_ACTIONS do
		local state = view.admin :: AdminState
		if action.show(state) then
			add(action.label, if action.id:find("ban") then RED else GOLD, function()
				strip:Destroy()
				callbacks.onAdmin(view, action.id)
			end)
		end
	end
end

local function makeCard(view: CardView, order: number)
	local cell = Instance.new("TextButton")
	cell.Name = view.id
	cell.Text = ""
	cell.AutoButtonColor = true
	cell.LayoutOrder = order
	cell.BackgroundColor3 = if view.current then Color3.fromRGB(255, 236, 170) else WHITE
	corner(cell, 0.12)
	stroke(cell, 2)
	cell.Parent = grid

	local sketch = Instance.new("Frame")
	sketch.Name = "Sketch"
	sketch.BackgroundColor3 = SKETCH_BG
	sketch.Position = UDim2.fromScale(0.03, 0.08)
	sketch.Size = UDim2.fromScale(0.34, 0.84)
	sketch.ClipsDescendants = true
	corner(sketch, 0.1)
	sketch.Parent = cell
	drawSketch(sketch, view.pieces)

	local function line(name: string, value: string, y: number, h: number, color: Color3): TextLabel
		local label = text(cell, name, value, color)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Position = UDim2.fromScale(0.41, y)
		label.Size = UDim2.fromScale(0.56, h)
		return label
	end
	line("Name", view.name, 0.08, 0.3, INK)
	line("Sub", view.sub, 0.4, 0.17, GREY)
	line("Stats", view.stats, 0.58, 0.17, Color3.fromRGB(205, 150, 0))
	if view.tags ~= "" then
		line("Tags", view.tags, 0.77, 0.15, GREY)
	end
	if view.badge then
		local badge = text(cell, "Badge", view.badge, INK)
		badge.BackgroundTransparency = 0
		badge.BackgroundColor3 = view.badgeColor or GOLD
		badge.AnchorPoint = Vector2.new(0, 0)
		badge.Position = UDim2.fromScale(0.04, 0.04)
		badge.Size = UDim2.fromScale(0.32, 0.18)
		badge.ZIndex = 3
		corner(badge, 0.3)
	end

	cell.Activated:Connect(function()
		if cell:FindFirstChild("Admin") == nil then
			callbacks.onPlay(view)
		end
	end)
	if view.admin then
		local gear = button(cell, "Gear", "⚙", WHITE)
		gear.AnchorPoint = Vector2.new(1, 0)
		gear.Position = UDim2.fromScale(0.985, 0.04)
		gear.Size = UDim2.fromScale(0.12, 0.32)
		gear.ZIndex = 4
		gear.Activated:Connect(function()
			adminStrip(cell, view)
		end)
	end
end

---------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------

function BrowseHud.isOpen(): boolean
	return card ~= nil
end

function BrowseHud.close()
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
	if card then
		card:Destroy()
		card = nil
	end
	table.clear(tabButtons)
end

function BrowseHud.open(parent: Instance, tabs: { Tab }, selected: string, actions: Callbacks)
	BrowseHud.close()
	callbacks = actions
	if gui == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "Browse"
		g.ResetOnSpawn = false
		g.DisplayOrder = 20
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.Parent = parent
		gui = g
	end

	local shade = Instance.new("Frame")
	shade.Name = "BrowseShade"
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.Size = UDim2.fromScale(1, 1)
	shade.Active = true
	shade.Parent = gui
	card = shade

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.96, 0.92)
	panel.BackgroundColor3 = PANEL
	corner(panel, 0.04)
	stroke(panel, 4)
	panel.Parent = shade
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.7
	aspect.Parent = panel

	local title = text(panel, "Title", "MAPS", INK)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromScale(0.03, 0.025)
	title.Size = UDim2.fromScale(0.3, 0.08)
	local close = button(panel, "Close", "✕", WHITE)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.975, 0.02)
	close.Size = UDim2.fromScale(0.07, 0.1)
	minSize(close, MIN, MIN)
	close.Activated:Connect(function()
		callbacks.onClose()
	end)

	-- Tabs
	local tabRow = Instance.new("ScrollingFrame")
	tabRow.Name = "Tabs"
	tabRow.BackgroundTransparency = 1
	tabRow.Position = UDim2.fromScale(0.03, 0.125)
	tabRow.Size = UDim2.fromScale(0.94, 0.1)
	tabRow.CanvasSize = UDim2.new()
	tabRow.AutomaticCanvasSize = Enum.AutomaticSize.X
	tabRow.ScrollingDirection = Enum.ScrollingDirection.X
	tabRow.ScrollBarThickness = 0
	tabRow.Parent = panel
	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.Padding = UDim.new(0.01, 0)
	tabList.SortOrder = Enum.SortOrder.LayoutOrder
	tabList.VerticalAlignment = Enum.VerticalAlignment.Center
	tabList.Parent = tabRow
	for index, tab in tabs do
		local b = button(tabRow, tab.id, tab.label, WHITE)
		b.LayoutOrder = index
		b.Size = UDim2.fromScale(math.max(0.14, 0.95 / #tabs - 0.012), 0.9)
		minSize(b, MIN * 1.6, MIN)
		b.Activated:Connect(function()
			callbacks.onTab(tab.id)
		end)
		tabButtons[tab.id] = b
	end

	-- Grid
	local g = Instance.new("Frame")
	g.Name = "Grid"
	g.BackgroundTransparency = 1
	g.Position = UDim2.fromScale(0.03, 0.245)
	g.Size = UDim2.fromScale(0.94, 0.62)
	g.Parent = panel
	grid = g
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.325, 0.31)
	layout.CellPadding = UDim2.fromScale(0.0125, 0.035)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = g
	emptyLabel = text(panel, "Empty", "", GREY)
	emptyLabel.Position = UDim2.fromScale(0.1, 0.45)
	emptyLabel.Size = UDim2.fromScale(0.8, 0.08)
	emptyLabel.Visible = false

	-- Paging
	prevButton = button(panel, "Prev", "◀", WHITE)
	prevButton.AnchorPoint = Vector2.new(0, 1)
	prevButton.Position = UDim2.fromScale(0.3, 0.975)
	prevButton.Size = UDim2.fromScale(0.09, 0.095)
	minSize(prevButton, MIN, MIN)
	prevButton.Activated:Connect(function()
		if prevButton.Active then
			callbacks.onPage(-1)
		end
	end)
	nextButton = button(panel, "Next", "▶", WHITE)
	nextButton.AnchorPoint = Vector2.new(1, 1)
	nextButton.Position = UDim2.fromScale(0.7, 0.975)
	nextButton.Size = UDim2.fromScale(0.09, 0.095)
	minSize(nextButton, MIN, MIN)
	nextButton.Activated:Connect(function()
		if nextButton.Active then
			callbacks.onPage(1)
		end
	end)
	pageLabel = text(panel, "Page", "", GREY)
	pageLabel.AnchorPoint = Vector2.new(0.5, 1)
	pageLabel.Position = UDim2.fromScale(0.5, 0.965)
	pageLabel.Size = UDim2.fromScale(0.2, 0.065)

	BrowseHud.setTab(selected)
end

function BrowseHud.setTab(tab: string)
	for id, b in tabButtons do
		b.BackgroundColor3 = if id == tab then GOLD else WHITE
	end
end

local function setPaging(page: number, pages: number)
	pageLabel.Text = if pages > 1 then string.format("%d / %d", page, pages) else ""
	prevButton.Visible = pages > 1
	nextButton.Visible = pages > 1
	setEnabled(prevButton, page > 1)
	setEnabled(nextButton, page < pages)
end

-- Grey cards that pulse until the page arrives
function BrowseHud.showLoading()
	if card == nil then
		return
	end
	clearGrid()
	local cells = {}
	for i = 1, Config.Maps.pageSize do
		local cell = Instance.new("Frame")
		cell.Name = "Skeleton" .. i
		cell.LayoutOrder = i
		cell.BackgroundColor3 = SKELETON
		corner(cell, 0.12)
		cell.Parent = grid
		table.insert(cells, cell)
	end
	local holder = Instance.new("NumberValue")
	holder.Name = "Pulse"
	holder.Value = 0
	holder.Changed:Connect(function(value)
		for _, cell in cells do
			cell.BackgroundTransparency = value
		end
	end)
	holder.Parent = grid
	local tween = TweenService:Create(
		holder,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Value = 0.5 }
	)
	tween:Play()
	pulse = tween
	setPaging(1, 1)
end

function BrowseHud.showCards(cards: { CardView }, page: number, pages: number, emptyText: string?)
	if card == nil then
		return
	end
	clearGrid()
	for _, child in grid:GetChildren() do
		if child:IsA("NumberValue") then
			child:Destroy()
		end
	end
	for index, view in cards do
		makeCard(view, index)
	end
	if #cards == 0 then
		emptyLabel.Text = emptyText or "Nothing here yet."
		emptyLabel.Visible = true
	end
	setPaging(page, pages)
end

-- Colours callers use for badges
BrowseHud.GOLD = GOLD
BrowseHud.RED = RED
BrowseHud.GREEN = GREEN

return BrowseHud
