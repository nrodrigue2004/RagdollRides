-- TracksHud: the Tracks screens on top of the driving HUD (spec: Screens and UI > Tracks screens).
--   Top bar (calm pass, nate 2026-11-15: "way too much going on"): only coins and stars at the top left
--   and one MENU button beside RESET. The menu holds HUB, MAPS, BUILD, TOP, SHOP, GARAGE, QUESTS, any
--   extra items (EMOTE) and the cog, with the next goal bar on top; a red dot on an item shows on MENU.
--   Run: the timer (top centre), checkpoints passed, and the split against your best at each checkpoint
--   (green ahead, red behind).
--   Cues: one big centre word that pulses (DRIVE, JUMP!, LEAN BACK!), and short toasts.
--   Results card: time, best, stars (popping in), coins (counting up), the goal bar, RETRY and NEXT;
--   skippable after 2 s, then NEXT counts down 5 s and goes by itself (no downtime).
--   Player maps: under the results card, rate the map 1 to 5 stars and REPORT it (3 preset reasons
--   and SEND). Touching either stops NEXT's countdown so nobody is rushed. MAPS opens Ui/BrowseHud.
-- Text here is ours only; players never type anything (design pillar: no free text).
-- PLACEHOLDER ART: plain rounded frames and text glyphs (coin dot, star) until the UI art pass.

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local TracksMath = require(Shared.TracksMath)

local TracksHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local RED = Color3.fromRGB(255, 100, 90)
local PANEL = Color3.fromRGB(255, 250, 240)
local DIM_STAR = Color3.fromRGB(200, 196, 210)

local gui: ScreenGui
local root: Frame
local coinsLabel: TextLabel
local starsLabel: TextLabel
local goalFrame: Frame
local goalFill: Frame
local goalLabel: TextLabel
local timerLabel: TextLabel
local checkpointLabel: TextLabel
local splitLabel: TextLabel
local cueLabel: TextLabel
local toastLabel: TextLabel
local buttonsFrame: Frame
local menuButton: TextButton
local menuPanel: Frame
local menuCatcher: TextButton
local resultsFrame: Frame? = nil
local holdCurrent: (() -> ())? = nil

local shownCoins = 0
local coinTween: Tween? = nil
local cueUntil = 0
local cueClock = 0
local toastToken = 0
local splitToken = 0

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
	return s
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

-- Text outlines stay thin (calm pass): at most 2 px, a little see-through
local function outlined(label: TextLabel, thickness: number?)
	local s = stroke(label, math.min(thickness or 2, 2), Enum.ApplyStrokeMode.Contextual)
	s.Transparency = 0.25
end

local function pill(name: string, glyph: string, glyphColor: Color3, order: number): TextLabel
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = INK
	frame.BackgroundTransparency = 0.25
	frame.SizeConstraint = Enum.SizeConstraint.RelativeYY
	frame.Size = UDim2.fromScale(2.9, 1) -- the row is 5.5% of the screen tall
	frame.LayoutOrder = order
	corner(frame, 0.5)
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(100, 34)
	minimum.Parent = frame
	frame.Parent = root:FindFirstChild("TopLeft")
	local icon = text(frame, "Icon", glyph, glyphColor)
	icon.Size = UDim2.fromScale(0.3, 0.8)
	icon.Position = UDim2.fromScale(0.04, 0.1)
	local value = text(frame, "Value", "0", WHITE)
	value.TextXAlignment = Enum.TextXAlignment.Left
	value.Size = UDim2.fromScale(0.6, 0.7)
	value.Position = UDim2.fromScale(0.36, 0.15)
	return value
end

local function bigButton(
	parent: Instance,
	name: string,
	label: string,
	color: Color3,
	heightFraction: number
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = label
	button.Font = FONT
	button.TextScaled = true
	button.TextColor3 = INK
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.SizeConstraint = Enum.SizeConstraint.RelativeYY
	button.Size = UDim2.fromScale(heightFraction * 2.6, heightFraction)
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(Config.UI.minTapTarget * 2, Config.UI.minTapTarget)
	minimum.Parent = button
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.2, 0)
	padding.PaddingBottom = UDim.new(0.2, 0)
	padding.Parent = button
	corner(button, 0.35)
	stroke(button)
	button.Parent = parent
	return button
end

local function squareButton(parent: Instance, name: string, label: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = label
	button.Font = FONT
	button.TextScaled = true
	button.TextColor3 = INK
	button.BackgroundColor3 = WHITE
	button.BackgroundTransparency = 0.08
	button.SizeConstraint = Enum.SizeConstraint.RelativeYY
	button.Size = UDim2.fromScale(0.85, 0.85) -- of the row's height
	button.LayoutOrder = order
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(Config.UI.minTapTarget, Config.UI.minTapTarget)
	minimum.Parent = button
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.24, 0)
	padding.PaddingBottom = UDim.new(0.24, 0)
	padding.PaddingLeft = UDim.new(0.1, 0)
	padding.PaddingRight = UDim.new(0.1, 0)
	padding.Parent = button
	corner(button, 0.5)
	stroke(button)
	button.Parent = parent
	return button
end

local function addDot(button: GuiObject)
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(1, -6, 0, 6)
	dot.Size = UDim2.fromOffset(14, 14)
	dot.BackgroundColor3 = RED
	dot.Visible = false
	corner(dot, 0.5)
	dot.Parent = button
end

local menuItems: Frame? = nil

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------

export type Callbacks = {
	onMaps: () -> (),
	onBuild: () -> (),
	onSettings: () -> (),
	onShop: (() -> ())?,
	onGarage: (() -> ())?,
	onQuests: (() -> ())?,
	onHub: (() -> ())?,
	onTop: (() -> ())?,
}

function TracksHud.build(parentGui: ScreenGui, resetButton: GuiObject?, callbacks: Callbacks)
	gui = parentGui
	root = Instance.new("Frame")
	root.Name = "Tracks"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	-- Top left: coins, stars, goal
	local topLeft = Instance.new("Frame")
	topLeft.Name = "TopLeft"
	topLeft.BackgroundTransparency = 1
	topLeft.Position = UDim2.fromOffset(16, 16)
	topLeft.Size = UDim2.fromScale(0.5, 0.055)
	topLeft.Parent = root
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = topLeft
	coinsLabel = pill("Coins", "●", GOLD, 1)
	starsLabel = pill("Stars", "★", GOLD, 2)

	-- Top centre: timer, checkpoints, split
	timerLabel = text(root, "Timer", "0:00.00", WHITE)
	timerLabel.AnchorPoint = Vector2.new(0.5, 0)
	timerLabel.Position = UDim2.new(0.5, 0, 0, 12)
	timerLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	timerLabel.Size = UDim2.fromScale(0.36, 0.085)
	outlined(timerLabel, 4)
	checkpointLabel = text(root, "Checkpoints", "", WHITE)
	checkpointLabel.AnchorPoint = Vector2.new(0.5, 0)
	checkpointLabel.Position = UDim2.new(0.5, 0, 0.095, 12)
	checkpointLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	checkpointLabel.Size = UDim2.fromScale(0.3, 0.045)
	outlined(checkpointLabel, 3)
	splitLabel = text(root, "Split", "", GREEN)
	splitLabel.AnchorPoint = Vector2.new(0.5, 0)
	splitLabel.Position = UDim2.new(0.5, 0, 0.145, 12)
	splitLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	splitLabel.Size = UDim2.fromScale(0.3, 0.055)
	splitLabel.Visible = false
	outlined(splitLabel, 3)

	-- Centre cue and toast
	cueLabel = text(root, "Cue", "", WHITE)
	cueLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	cueLabel.Position = UDim2.fromScale(0.5, 0.3)
	cueLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	cueLabel.Size = UDim2.fromScale(0.9, 0.09)
	cueLabel.Visible = false
	outlined(cueLabel, 5)
	toastLabel = text(root, "Toast", "", WHITE)
	toastLabel.AnchorPoint = Vector2.new(0.5, 0)
	toastLabel.Position = UDim2.fromScale(0.5, 0.21)
	toastLabel.Size = UDim2.fromScale(0.7, 0.05)
	toastLabel.Visible = false
	outlined(toastLabel, 3)

	-- Top right: one MENU button, left of RESET
	buttonsFrame = Instance.new("Frame")
	buttonsFrame.Name = "TopRight"
	buttonsFrame.BackgroundTransparency = 1
	buttonsFrame.AnchorPoint = Vector2.new(1, 0)
	buttonsFrame.Size = UDim2.fromScale(0.4, 0.09)
	buttonsFrame.Parent = root
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.Padding = UDim.new(0, 10)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = buttonsFrame
	menuButton = squareButton(buttonsFrame, "Menu", "MENU", 1)
	menuButton.Size = UDim2.fromScale(1.5, 0.85)
	addDot(menuButton)
	menuButton.Activated:Connect(function()
		TracksHud.setMenuOpen(not menuPanel.Visible)
	end)

	-- The menu: a tap outside closes it
	menuCatcher = Instance.new("TextButton")
	menuCatcher.Name = "MenuCatcher"
	menuCatcher.Text = ""
	menuCatcher.BackgroundTransparency = 1
	menuCatcher.Size = UDim2.fromScale(1, 1)
	menuCatcher.Visible = false
	menuCatcher.ZIndex = 5
	menuCatcher.Parent = root
	menuCatcher.Activated:Connect(function()
		TracksHud.setMenuOpen(false)
	end)
	menuPanel = Instance.new("Frame")
	menuPanel.Name = "MenuPanel"
	menuPanel.AnchorPoint = Vector2.new(1, 0)
	menuPanel.BackgroundColor3 = INK
	menuPanel.BackgroundTransparency = 0.12
	menuPanel.Size = UDim2.new(0, 420, 0, 0)
	menuPanel.AutomaticSize = Enum.AutomaticSize.Y
	menuPanel.Visible = false
	menuPanel.ZIndex = 6
	corner(menuPanel, 0.06)
	local menuPad = Instance.new("UIPadding")
	for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
		(menuPad :: any)[side] = UDim.new(0, 12)
	end
	menuPad.Parent = menuPanel
	local menuList = Instance.new("UIListLayout")
	menuList.SortOrder = Enum.SortOrder.LayoutOrder
	menuList.Padding = UDim.new(0, 10)
	menuList.Parent = menuPanel
	menuPanel.Parent = root
	-- The next goal sits at the top of the menu, not over the road
	goalFrame = Instance.new("Frame")
	goalFrame.Name = "Goal"
	goalFrame.BackgroundColor3 = Color3.fromRGB(70, 70, 84)
	goalFrame.Size = UDim2.new(1, 0, 0, 30)
	goalFrame.LayoutOrder = 0
	goalFrame.Visible = false
	corner(goalFrame, 0.5)
	goalFrame.Parent = menuPanel
	goalFill = Instance.new("Frame")
	goalFill.Name = "Fill"
	goalFill.BackgroundColor3 = GOLD
	goalFill.Size = UDim2.fromScale(0, 1)
	corner(goalFill, 0.5)
	goalFill.Parent = goalFrame
	goalLabel = text(goalFrame, "Label", "", WHITE)
	goalLabel.Size = UDim2.fromScale(0.92, 0.7)
	goalLabel.Position = UDim2.fromScale(0.04, 0.15)
	goalLabel.ZIndex = 2
	outlined(goalLabel, 1)
	local grid = Instance.new("Frame")
	grid.Name = "Items"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 1
	grid.Parent = menuPanel
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(1 / 3, -7, 0, Config.UI.minTapTarget)
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	menuItems = grid
	local onHub = callbacks.onHub
	if onHub then
		TracksHud.addMenuItem("Hub", "HUB", 1, onHub).Visible = false -- hidden until Pip's Hill is done
	end
	TracksHud.addMenuItem("Maps", "MAPS", 2, callbacks.onMaps)
	TracksHud.addMenuItem("Build", "BUILD", 3, callbacks.onBuild)
	local onTop = callbacks.onTop
	if onTop then
		TracksHud.addMenuItem("Top", "TOP", 4, onTop).Visible = false
	end
	for index, entry in
		{
			{ "Shop", "SHOP", callbacks.onShop },
			{ "Garage", "GARAGE", callbacks.onGarage },
			{ "Quests", "QUESTS", callbacks.onQuests },
		}
	do
		local onPress = entry[3]
		if onPress then
			TracksHud.addMenuItem(entry[1], entry[2], 4 + index, onPress)
		end
	end
	TracksHud.addMenuItem("Settings", "SETTINGS", 99, callbacks.onSettings)
	local function placeMenu()
		menuPanel.Position = UDim2.fromOffset(
			menuButton.AbsolutePosition.X - gui.AbsolutePosition.X + menuButton.AbsoluteSize.X,
			menuButton.AbsolutePosition.Y - gui.AbsolutePosition.Y + menuButton.AbsoluteSize.Y + 8
		)
	end
	menuButton:GetPropertyChangedSignal("AbsolutePosition"):Connect(placeMenu)
	menuButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeMenu)
	placeMenu()
	local function placeButtons()
		if resetButton then
			local x = resetButton.AbsolutePosition.X - gui.AbsolutePosition.X
			buttonsFrame.Position = UDim2.fromOffset(x - 10, 16)
		else
			buttonsFrame.Position = UDim2.new(1, -16, 0, 16)
		end
	end
	if resetButton then
		resetButton:GetPropertyChangedSignal("AbsolutePosition"):Connect(placeButtons)
		resetButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeButtons)
	end
	placeButtons()
end

---------------------------------------------------------------------------
-- Top bar
---------------------------------------------------------------------------

export type Goal = { label: string, coins: number, stars: number? }

-- A red dot on a top-bar or left-column button (something to claim)
function TracksHud.setDot(name: string, visible: boolean)
	local b = root and root:FindFirstChild(name, true)
	local dot = b and b:FindFirstChild("Dot")
	if dot and dot:IsA("GuiObject") then
		dot.Visible = visible
	end
	-- MENU shows a dot while any visible item in it has one
	local any = false
	if menuItems then
		for _, item in menuItems:GetChildren() do
			local d = item:FindFirstChild("Dot")
			if item:IsA("GuiObject") and item.Visible and d and (d :: GuiObject).Visible then
				any = true
			end
		end
	end
	local menuDot = menuButton and menuButton:FindFirstChild("Dot")
	if menuDot then
		(menuDot :: GuiObject).Visible = any
	end
end

function TracksHud.hasMenu(): boolean
	return menuItems ~= nil
end

-- Open or close the menu
function TracksHud.setMenuOpen(open: boolean)
	if menuPanel == nil then
		return
	end
	menuPanel.Visible = open
	menuCatcher.Visible = open
	menuButton.Text = if open then "CLOSE" else "MENU"
end

-- Another screen's item in the menu (EMOTE): pressing it closes the menu, then calls onPress
function TracksHud.addMenuItem(name: string, label: string, order: number, onPress: () -> ()): TextButton
	local b = squareButton(menuItems :: Frame, name, label, order)
	b.BackgroundTransparency = 0
	addDot(b)
	b.Activated:Connect(function()
		TracksHud.setMenuOpen(false)
		onPress()
	end)
	return b
end

function TracksHud.setButtonVisible(name: string, visible: boolean)
	local b = (
		buttonsFrame and buttonsFrame:FindFirstChild(name) or root and root:FindFirstChild(name, true)
	) :: GuiObject?
	if b then
		b.Visible = visible
	end
end

-- The quest tracker (spec: top right, collapsible: 3 daily quests with live counts). Tap to fold it.
export type TrackerRow = { text: string, progress: number, target: number, claimed: boolean }
local tracker: Frame? = nil
local trackerOpen = false -- folded to one line until tapped (calm pass)
local trackerRows: { TrackerRow } = {}

local function drawTracker()
	local frame = tracker
	if frame == nil then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("TextLabel") and child.Name ~= "Header" then
			child:Destroy()
		end
	end
	local header = frame:FindFirstChild("Header") :: TextButton
	local done = 0
	for _, row in trackerRows do
		if row.claimed or row.progress >= row.target then
			done += 1
		end
	end
	header.Text = string.format("QUESTS %d/%d %s", done, #trackerRows, if trackerOpen then "▴" else "▾")
	if not trackerOpen then
		return
	end
	for index, row in trackerRows do
		local ready = not row.claimed and row.progress >= row.target
		local label = text(
			frame,
			"Row" .. index,
			string.format(
				"%s  %s",
				row.text,
				if row.claimed
					then "✓"
					else string.format("%d/%d", math.min(row.progress, row.target), row.target)
			),
			if ready then GOLD elseif row.claimed then Color3.fromRGB(170, 230, 180) else WHITE
		)
		label.LayoutOrder = index
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.Size = UDim2.new(1, 0, 0.22, 0)
		outlined(label, 2)
	end
end

function TracksHud.setQuestTracker(rows: { TrackerRow }?)
	if root == nil then
		return
	end
	if rows == nil or #rows == 0 then
		if tracker then
			tracker.Visible = false
		end
		return
	end
	trackerRows = rows
	if tracker == nil then
		local frame = Instance.new("Frame")
		frame.Name = "QuestTracker"
		frame.BackgroundTransparency = 1
		frame.AnchorPoint = Vector2.new(1, 0)
		frame.Size = UDim2.fromScale(0.3, 0.2)
		frame.Parent = root
		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.HorizontalAlignment = Enum.HorizontalAlignment.Right
		list.Padding = UDim.new(0, 2)
		list.Parent = frame
		local header = Instance.new("TextButton")
		header.Name = "Header"
		header.BackgroundTransparency = 1
		header.Font = FONT
		header.TextScaled = true
		header.TextColor3 = WHITE
		header.TextXAlignment = Enum.TextXAlignment.Right
		header.Size = UDim2.new(1, 0, 0.24, 0)
		header.LayoutOrder = 0
		local headerStroke = Instance.new("UIStroke")
		headerStroke.Thickness = 2
		headerStroke.Color = INK
		headerStroke.Parent = header
		header.Parent = frame
		header.Activated:Connect(function()
			trackerOpen = not trackerOpen
			drawTracker()
		end)
		local function place()
			local y = buttonsFrame.AbsolutePosition.Y
				- gui.AbsolutePosition.Y
				+ buttonsFrame.AbsoluteSize.Y * 0.75
			frame.Position = UDim2.new(1, -16, 0, y + 6)
		end
		buttonsFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)
		buttonsFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		place()
		tracker = frame
	end
	(tracker :: Frame).Visible = true
	drawTracker()
end

-- Where flying coins land (the coin counter)
function TracksHud.coinTarget(): GuiObject?
	return coinsLabel
end

function TracksHud.setWallet(coins: number, stars: number, goal: Goal?)
	starsLabel.Text = tostring(stars)
	if coins ~= shownCoins then
		-- Count up (or down after a purchase) so earning is felt
		if coinTween then
			coinTween:Cancel()
		end
		local value = Instance.new("NumberValue")
		value.Value = shownCoins
		value.Changed:Connect(function(v)
			coinsLabel.Text = tostring(math.floor(v + 0.5))
		end)
		local tween = TweenService:Create(value, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { Value = coins })
		coinTween = tween
		tween.Completed:Once(function()
			value:Destroy()
		end)
		tween:Play()
		shownCoins = coins
	else
		coinsLabel.Text = tostring(coins)
	end
	if goal then
		goalFrame.Visible = true
		local fraction = math.clamp(coins / math.max(1, goal.coins), 0, 1)
		if goal.stars and goal.stars > 0 then
			fraction = math.min(fraction, math.clamp(stars / goal.stars, 0, 1))
		end
		TweenService:Create(goalFill, TweenInfo.new(0.5), { Size = UDim2.fromScale(fraction, 1) }):Play()
		local need = string.format("%d / %d", math.min(coins, goal.coins), goal.coins)
		goalLabel.Text = if fraction >= 1
			then "Goal reached: " .. goal.label .. "!"
			else "Next: " .. goal.label .. "  " .. need
	else
		goalFrame.Visible = false
	end
end

---------------------------------------------------------------------------
-- Run display
---------------------------------------------------------------------------

function TracksHud.setTimer(seconds: number?)
	timerLabel.Visible = seconds ~= nil
	if seconds then
		timerLabel.Text = TracksMath.formatTime(seconds)
	end
end

function TracksHud.setCheckpoints(reached: number, total: number)
	checkpointLabel.Visible = total > 0
	checkpointLabel.Text = string.format("CHECKPOINT %d/%d", reached, total)
end

-- Split against the best run at a checkpoint (ms): negative = ahead (green)
function TracksHud.showSplit(deltaMs: number)
	splitToken += 1
	local token = splitToken
	local ahead = deltaMs <= 0
	splitLabel.TextColor3 = if ahead then GREEN else RED
	splitLabel.Text = string.format("%s%.2f", if ahead then "-" else "+", math.abs(deltaMs) / 1000)
	splitLabel.Visible = true
	task.delay(2.5, function()
		if splitToken == token then
			splitLabel.Visible = false
		end
	end)
end

function TracksHud.showCue(value: string, duration: number)
	cueLabel.Text = value
	cueLabel.Visible = true
	cueUntil = os.clock() + duration
end

function TracksHud.hideCue()
	cueUntil = 0
	cueLabel.Visible = false
end

function TracksHud.toast(value: string, duration: number?)
	toastToken += 1
	local token = toastToken
	toastLabel.Text = value
	toastLabel.Visible = true
	task.delay(duration or Config.UI.toastTime, function()
		if toastToken == token then
			toastLabel.Visible = false
		end
	end)
end

-- Per frame: the cue throbs while it is up
function TracksHud.update(dt: number)
	if cueLabel.Visible then
		if os.clock() >= cueUntil then
			cueLabel.Visible = false
		else
			cueClock += dt
			local scale = 1 + 0.03 * math.sin(cueClock * 6)
			cueLabel.Size = UDim2.fromScale(0.9 * scale, 0.09 * scale)
		end
	end
end

---------------------------------------------------------------------------
-- Results card
---------------------------------------------------------------------------

export type ResultView = {
	ok: boolean,
	title: string,
	mapName: string,
	time: number?,
	bestText: string?, -- "Best 0:20.10", or "Was 0:23.10" on a new best
	tier: number,
	newStars: number,
	coins: number,
	capped: boolean,
	reason: string?,
	nextName: string,
	goal: Goal?,
	walletCoins: number,
	walletStars: number,
	rate: RateView?, -- player maps only, after a counted finish
}

export type RateView = {
	current: number?, -- the stars this player gave before
	canRate: boolean, -- not on your own map
	reported: boolean,
	onRate: (number) -> (),
	onReport: (string) -> (),
}

export type ResultActions = {
	onRetry: () -> (),
	onNext: () -> (),
	onStarPop: (index: number, isNew: boolean) -> (),
}

function TracksHud.hideResults()
	if resultsFrame then
		resultsFrame:Destroy()
		resultsFrame = nil
	end
end

function TracksHud.resultsOpen(): boolean
	return resultsFrame ~= nil
end

-- Hide the results card while a one-time offer sits on top, so only one card shows (calm pass)
function TracksHud.setResultsVisible(visible: boolean)
	if resultsFrame then
		resultsFrame.Visible = visible
	end
end

function TracksHud.showResults(view: ResultView, actions: ResultActions)
	TracksHud.hideResults()
	local cfg = Config.Tracks
	local card = Instance.new("Frame")
	card.Name = "Results"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.48)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(0.95, 0.72)
	card.BackgroundColor3 = PANEL
	card.ZIndex = 20
	corner(card, 0.08)
	stroke(card, 2)
	card.Parent = root
	resultsFrame = card

	local function line(name: string, value: string, y: number, h: number, color: Color3?): TextLabel
		local label = text(card, name, value, color or INK)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.fromScale(0.5, y)
		label.Size = UDim2.fromScale(0.86, h)
		label.ZIndex = 21
		return label
	end

	line("Title", view.title, 0.04, 0.12, if view.ok then INK else RED)
	line("Map", view.mapName, 0.16, 0.06, Color3.fromRGB(110, 110, 125))
	if view.ok and view.time then
		line("Time", TracksMath.formatTime(view.time), 0.23, 0.14, INK)
		if view.bestText then
			line("Best", view.bestText, 0.37, 0.06, Color3.fromRGB(110, 110, 125))
		end
		-- Stars pop in one by one; newly earned ones get the juice
		local starRow = Instance.new("Frame")
		starRow.BackgroundTransparency = 1
		starRow.AnchorPoint = Vector2.new(0.5, 0)
		starRow.Position = UDim2.fromScale(0.5, 0.44)
		starRow.Size = UDim2.fromScale(0.6, 0.14)
		starRow.ZIndex = 21
		starRow.Parent = card
		for index = 1, 3 do
			local star = text(starRow, "Star" .. index, "★", DIM_STAR)
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale((index - 0.5) / 3, 0.5)
			star.Size = UDim2.fromScale(0.3, 1)
			star.ZIndex = 22
			outlined(star, 2)
			if index <= view.tier then
				local isNew = index > view.tier - view.newStars
				task.delay(0.35 + index * 0.3, function()
					if star.Parent == nil then
						return
					end
					star.TextColor3 = GOLD
					star.Size = UDim2.fromScale(0.45, 1.5)
					TweenService:Create(
						star,
						TweenInfo.new(0.25, Enum.EasingStyle.Back),
						{ Size = UDim2.fromScale(0.3, 1) }
					):Play()
					actions.onStarPop(index, isNew)
				end)
			end
		end
		local reward = string.format("+%d coins", view.coins)
		if view.newStars > 0 then
			reward ..= string.format("   +%d ★", view.newStars)
		end
		line("Reward", reward, 0.6, 0.08, Color3.fromRGB(205, 150, 0))
		if view.capped then
			line(
				"Cap",
				"Daily Tracks coins reached: stars still count!",
				0.68,
				0.045,
				Color3.fromRGB(110, 110, 125)
			)
		end
	else
		line("Reason", view.reason or "This run didn't count.", 0.3, 0.07, INK)
		line(
			"Hint",
			"Drive through every checkpoint, then the finish.",
			0.4,
			0.05,
			Color3.fromRGB(110, 110, 125)
		)
	end

	-- Goal bar on the card
	if view.goal then
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.fromRGB(225, 220, 210)
		bar.AnchorPoint = Vector2.new(0.5, 0)
		bar.Position = UDim2.fromScale(0.5, 0.73)
		bar.Size = UDim2.fromScale(0.8, 0.045)
		bar.ZIndex = 21
		corner(bar, 0.5)
		bar.Parent = card
		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = GOLD
		fill.Size = UDim2.fromScale(
			math.clamp((view.walletCoins - view.coins) / math.max(1, view.goal.coins), 0, 1),
			1
		)
		fill.ZIndex = 22
		corner(fill, 0.5)
		fill.Parent = bar
		local fraction = math.clamp(view.walletCoins / math.max(1, view.goal.coins), 0, 1)
		task.delay(0.4, function()
			if fill.Parent then
				TweenService:Create(
					fill,
					TweenInfo.new(0.8, Enum.EasingStyle.Quad),
					{ Size = UDim2.fromScale(fraction, 1) }
				):Play()
			end
		end)
		local goalText = text(
			bar,
			"Label",
			string.format(
				"%s  %d / %d",
				view.goal.label,
				math.min(view.walletCoins, view.goal.coins),
				view.goal.coins
			),
			INK
		)
		goalText.Size = UDim2.fromScale(1, 0.8)
		goalText.Position = UDim2.fromScale(0, 0.1)
		goalText.ZIndex = 23
	end

	-- Buttons: locked for the first 2 s, then NEXT counts down and goes by itself
	local buttons = Instance.new("Frame")
	buttons.BackgroundTransparency = 1
	buttons.AnchorPoint = Vector2.new(0.5, 1)
	buttons.Position = UDim2.fromScale(0.5, 0.96)
	buttons.Size = UDim2.fromScale(0.9, 0.16)
	buttons.ZIndex = 21
	buttons.Parent = card
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0.04, 0)
	row.Parent = buttons
	local retry = bigButton(buttons, "Retry", "RETRY", WHITE, 0.9)
	retry.ZIndex = 22
	local nextButton = bigButton(buttons, "Next", "NEXT ▶", GREEN, 0.9)
	nextButton.ZIndex = 22
	for _, b in { retry, nextButton } do
		b.AutoButtonColor = false
		b.BackgroundTransparency = 0.5
	end

	local done = false
	local held = false -- the player is rating, reporting or looking at an offer: no auto NEXT
	holdCurrent = function()
		held = true
	end
	local opened = os.clock()
	local function finish(choice: () -> ())
		if done or os.clock() - opened < cfg.resultsSkippableAfter then
			return
		end
		done = true
		TracksHud.hideResults()
		choice()
	end
	retry.Activated:Connect(function()
		finish(actions.onRetry)
	end)
	if view.rate then
		TracksHud.ratePanel(card, view.rate, function()
			held = true
		end)
	end
	nextButton.Activated:Connect(function()
		finish(actions.onNext)
	end)
	task.spawn(function()
		task.wait(cfg.resultsSkippableAfter)
		for _, b in { retry, nextButton } do
			b.AutoButtonColor = true
			b.BackgroundTransparency = 0
		end
		local left = cfg.autoNextTime
		while left > 0 and not done and card.Parent do
			if held then
				nextButton.Text = "NEXT ▶"
				return
			end
			nextButton.Text = string.format("NEXT ▶ %d", math.ceil(left))
			task.wait(0.1)
			left -= 0.1
		end
		if not done and card.Parent then
			finish(actions.onNext)
		end
	end)
end

-- Under the results card on a player map: 5 stars to rate it and REPORT (3 preset reasons + SEND)
local REPORT_REASONS = {
	{ id = "Shape", label = "Rude shape" },
	{ id = "Impossible", label = "Can't finish" },
	{ id = "Spam", label = "Spam copy" },
}

-- Stop the results card's auto NEXT (an offer or a panel opened over it)
function TracksHud.holdResults()
	if holdCurrent then
		holdCurrent()
	end
end

function TracksHud.ratePanel(card: Frame, rate: RateView, hold: () -> ())
	local panel = Instance.new("Frame")
	panel.Name = "Rate"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.fromScale(0.5, 1.025)
	panel.Size = UDim2.fromScale(0.95, 0.16)
	panel.BackgroundColor3 = PANEL
	panel.ZIndex = 20
	corner(panel, 0.3)
	stroke(panel, 2)
	panel.Parent = card

	local stars: { TextButton } = {}
	local chosen = rate.current or 0
	local function paint()
		for index, star in stars do
			star.TextColor3 = if index <= chosen then GOLD else DIM_STAR
		end
	end
	if rate.canRate then
		local label = text(panel, "Label", if rate.current then "YOUR RATING" else "RATE IT!", INK)
		label.Position = UDim2.fromScale(0.03, 0.15)
		label.Size = UDim2.fromScale(0.24, 0.7)
		label.ZIndex = 21
		for index = 1, 5 do
			local star = Instance.new("TextButton")
			star.Name = "Star" .. index
			star.Text = "★"
			star.Font = FONT
			star.TextScaled = true
			star.BackgroundTransparency = 1
			star.Position = UDim2.fromScale(0.28 + (index - 1) * 0.095, 0.05)
			star.Size = UDim2.fromScale(0.09, 0.9)
			star.ZIndex = 21
			local minimum = Instance.new("UISizeConstraint")
			minimum.MinSize = Vector2.new(Config.UI.minTapTarget * 0.75, Config.UI.minTapTarget * 0.75)
			minimum.Parent = star
			outlined(star :: any, 2)
			star.Parent = panel
			star.Activated:Connect(function()
				hold()
				chosen = index
				paint()
				star.Size = UDim2.fromScale(0.12, 1.2)
				TweenService:Create(
					star,
					TweenInfo.new(0.2, Enum.EasingStyle.Back),
					{ Size = UDim2.fromScale(0.09, 0.9) }
				):Play()
				label.Text = "THANKS!"
				rate.onRate(index)
			end)
			table.insert(stars, star)
		end
		paint()
	end

	local report = Instance.new("TextButton")
	report.Name = "Report"
	report.Text = if rate.reported then "REPORTED" else "⚑ REPORT"
	report.Font = FONT
	report.TextScaled = true
	report.TextColor3 = INK
	report.BackgroundColor3 = WHITE
	report.AnchorPoint = Vector2.new(1, 0.5)
	report.Position = UDim2.fromScale(0.97, 0.5)
	report.Size = UDim2.fromScale(0.2, 0.7)
	report.ZIndex = 21
	report.Active = not rate.reported
	corner(report, 0.3)
	stroke(report, 2)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
	padding.Parent = report
	report.Parent = panel

	report.Activated:Connect(function()
		if not report.Active then
			return
		end
		hold()
		-- Swap the panel for the 3 reasons and SEND
		for _, child in panel:GetChildren() do
			if child:IsA("GuiObject") then
				child.Visible = false
			end
		end
		local picked: string? = nil
		local choices: { [string]: TextButton } = {}
		local send: TextButton
		for index, reason in REPORT_REASONS do
			local b = Instance.new("TextButton")
			b.Name = reason.id
			b.Text = reason.label
			b.Font = FONT
			b.TextScaled = true
			b.TextColor3 = INK
			b.BackgroundColor3 = WHITE
			b.Position = UDim2.fromScale(0.02 + (index - 1) * 0.245, 0.15)
			b.Size = UDim2.fromScale(0.23, 0.7)
			b.ZIndex = 21
			corner(b, 0.3)
			stroke(b, 2)
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.2, 0)
			pad.PaddingBottom = UDim.new(0.2, 0)
			pad.Parent = b
			b.Parent = panel
			choices[reason.id] = b
			b.Activated:Connect(function()
				picked = reason.id
				for id, other in choices do
					other.BackgroundColor3 = if id == picked then GOLD else WHITE
				end
				send.BackgroundTransparency = 0
				send.TextTransparency = 0
			end)
		end
		send = Instance.new("TextButton")
		send.Name = "Send"
		send.Text = "SEND"
		send.Font = FONT
		send.TextScaled = true
		send.TextColor3 = INK
		send.BackgroundColor3 = RED
		send.BackgroundTransparency = 0.5
		send.TextTransparency = 0.5
		send.Position = UDim2.fromScale(0.76, 0.15)
		send.Size = UDim2.fromScale(0.22, 0.7)
		send.ZIndex = 21
		corner(send, 0.3)
		stroke(send, 2)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.2, 0)
		pad.PaddingBottom = UDim.new(0.2, 0)
		pad.Parent = send
		send.Parent = panel
		send.Activated:Connect(function()
			if picked == nil then
				return
			end
			rate.onReport(picked)
			for _, child in panel:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			local thanks = text(panel, "Thanks", "Thanks for keeping maps fun!", INK)
			thanks.Position = UDim2.fromScale(0.05, 0.15)
			thanks.Size = UDim2.fromScale(0.9, 0.7)
			thanks.ZIndex = 21
		end)
	end)
end

return TracksHud
