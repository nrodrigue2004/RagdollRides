-- ShopHud: the shop, garage and quests screens (spec: Screens and UI > Shop, Pass page, Crate screen,
-- Garage, Quests, Rebirth). One panel with tabs and a grid of cards; the controller (ShopClient)
-- decides what each card says and does.
--   Shop: "Nothing here makes you faster or stronger." on top. Prices are in coins or Robux, never both
--   on one card. No countdowns or "only X left" (design pillar).
--   Crate screen: the odds table is always on the card, never behind a button; the opening shows for
--   2.5 s and a tap skips it.
--   Quests: 3 daily and 3 weekly quests with progress bars, claim buttons that pulse, the daily chest,
--   and the 7-day login streak calendar.
-- Text is ours only (preset). PLACEHOLDER ART: flat rounded cards, colour swatches and text glyphs.

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local ShopHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local BLUE = Color3.fromRGB(86, 170, 255)
local PANEL = Color3.fromRGB(255, 250, 240)
local GREY = Color3.fromRGB(110, 110, 125)
local LIGHT = Color3.fromRGB(235, 230, 220)
local MIN = Config.UI.minTapTarget

ShopHud.RARITY_COLORS = {
	common = Color3.fromRGB(190, 195, 205),
	rare = Color3.fromRGB(86, 170, 255),
	epic = Color3.fromRGB(190, 110, 255),
	legendary = Color3.fromRGB(255, 190, 40),
}
ShopHud.GOLD = GOLD
ShopHud.GREEN = GREEN
ShopHud.BLUE = BLUE
ShopHud.WHITE = WHITE
ShopHud.GREY = GREY

export type Tab = { id: string, label: string }

export type Card = {
	id: string,
	title: string,
	sub: string?, -- a second line (what it gives, an unlock rule)
	swatch: Color3?, -- a colour square for looks
	rarity: string?,
	badge: string?, -- "EQUIPPED", "OWNED", "NEW", "SHINY"
	button: string?, -- "300 ●", "R$ 79", "EQUIP", "DRIVE"; nil for no button
	buttonColor: Color3?,
	enabled: boolean?,
	onPress: (() -> ())?,
	wide: boolean?, -- a full-width card (bundles, the crate with its odds)
	lines: { string }?, -- extra lines under the title (the odds table)
}

export type QuestRow = {
	id: string,
	text: string,
	progress: number,
	target: number,
	reward: string,
	claimed: boolean,
	onClaim: (() -> ())?,
}

export type QuestsView = {
	daily: { QuestRow },
	weekly: { QuestRow },
	chest: { ready: boolean, claimed: boolean, onClaim: () -> () },
	weeklyStars: { ready: boolean, claimed: boolean, onClaim: () -> () },
	streak: { day: number, nextDay: number, canClaim: boolean, rewards: { string }, onClaim: () -> () },
	gifts: { { name: string, onGift: () -> () } }?,
	giftSent: boolean,
}

local gui: ScreenGui? = nil
local shade: Frame? = nil
local content: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local headerLine: TextLabel
local pulses: { Tween } = {}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number?, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = color or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
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
	b.TextTransparency = if enabled then 0 else 0.55
	b.BackgroundTransparency = if enabled then 0 else 0.4
end

-- A claim button that gently pulses (spec: claim buttons pulse)
local function pulse(b: GuiObject)
	local scale = Instance.new("UIScale")
	scale.Parent = b
	local tween = TweenService:Create(
		scale,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.08 }
	)
	tween:Play()
	table.insert(pulses, tween)
end

local function clearContent()
	for _, tween in pulses do
		tween:Cancel()
	end
	table.clear(pulses)
	for _, child in content:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, child in content:GetChildren() do
		if child:IsA("UIGridLayout") or child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function ShopHud.isOpen(): boolean
	return shade ~= nil
end

function ShopHud.close()
	for _, tween in pulses do
		tween:Cancel()
	end
	table.clear(pulses)
	if shade then
		shade:Destroy()
		shade = nil
	end
	table.clear(tabButtons)
end

local function ensureGui(parent: Instance): ScreenGui
	if gui == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "Shop"
		g.ResetOnSpawn = false
		g.DisplayOrder = 21
		g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		g.Parent = parent
		gui = g
	end
	return gui :: ScreenGui
end

function ShopHud.open(
	parent: Instance,
	title: string,
	line: string?,
	tabs: { Tab },
	selected: string,
	onTab: (string) -> (),
	onClose: () -> ()
)
	ShopHud.close()
	local g = ensureGui(parent)
	local s = Instance.new("Frame")
	s.Name = "ShopShade"
	s.BackgroundColor3 = Color3.new(0, 0, 0)
	s.BackgroundTransparency = 0.45
	s.Size = UDim2.fromScale(1, 1)
	s.Active = true
	s.Parent = g
	shade = s

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.96, 0.92)
	panel.BackgroundColor3 = PANEL
	corner(panel, 0.04)
	stroke(panel, 2)
	panel.Parent = s
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.7
	aspect.Parent = panel

	local titleLabel = text(panel, "Title", title, INK)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Position = UDim2.fromScale(0.03, 0.025)
	titleLabel.Size = UDim2.fromScale(0.25, 0.08)
	headerLine = text(panel, "Line", line or "", GREY)
	headerLine.Position = UDim2.fromScale(0.28, 0.04)
	headerLine.Size = UDim2.fromScale(0.58, 0.05)
	local close = button(panel, "Close", "✕", WHITE)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.975, 0.02)
	close.Size = UDim2.fromScale(0.07, 0.1)
	minSize(close, MIN, MIN)
	close.Activated:Connect(onClose)

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
		b.Size = UDim2.fromScale(math.max(0.12, 0.95 / #tabs - 0.012), 0.9)
		minSize(b, MIN * 1.5, MIN)
		b.Activated:Connect(function()
			onTab(tab.id)
		end)
		tabButtons[tab.id] = b
	end

	local c = Instance.new("ScrollingFrame")
	c.Name = "Content"
	c.BackgroundTransparency = 1
	c.Position = UDim2.fromScale(0.03, 0.245)
	c.Size = UDim2.fromScale(0.94, 0.73)
	c.CanvasSize = UDim2.new()
	c.AutomaticCanvasSize = Enum.AutomaticSize.Y
	c.ScrollingDirection = Enum.ScrollingDirection.Y
	c.ScrollBarThickness = 8
	c.Parent = panel
	content = c
	ShopHud.setTab(selected)
end

function ShopHud.setTab(tab: string)
	for id, b in tabButtons do
		b.BackgroundColor3 = if id == tab then GOLD else WHITE
	end
end

function ShopHud.setLine(line: string)
	if shade then
		headerLine.Text = line
	end
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local function makeCard(parent: Instance, card: Card, order: number)
	local frame = Instance.new("Frame")
	frame.Name = card.id
	frame.LayoutOrder = order
	frame.BackgroundColor3 = WHITE
	corner(frame, 0.08)
	stroke(frame, 2, if card.rarity then ShopHud.RARITY_COLORS[card.rarity] else INK)
	frame.Parent = parent
	local wide = card.wide == true
	if card.swatch then
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.BackgroundColor3 = card.swatch
		swatch.Position = UDim2.fromScale(0.05, 0.06)
		swatch.Size = if wide then UDim2.fromScale(0.12, 0.5) else UDim2.fromScale(0.9, 0.32)
		corner(swatch, 0.15)
		swatch.Parent = frame
	end
	local textLeft = if wide and card.swatch then 0.2 else 0.05
	local titleY = if wide then 0.06 else (if card.swatch then 0.4 else 0.08)
	local titleLabel = text(frame, "Title", card.title, INK)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Position = UDim2.fromScale(textLeft, titleY)
	titleLabel.Size = UDim2.fromScale(if wide then 0.5 else 0.9, if wide then 0.22 else 0.16)
	if card.sub then
		local sub = text(frame, "Sub", card.sub, GREY)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Position = UDim2.fromScale(textLeft, titleY + (if wide then 0.24 else 0.17))
		sub.Size = UDim2.fromScale(if wide then 0.5 else 0.9, if wide then 0.14 else 0.11)
	end
	if card.lines then
		for index, value in card.lines do
			local l = text(frame, "Line" .. index, value, INK)
			l.TextXAlignment = Enum.TextXAlignment.Left
			l.Position = UDim2.fromScale(textLeft, 0.44 + (index - 1) * 0.11)
			l.Size = UDim2.fromScale(0.5, 0.1)
		end
	end
	if card.badge then
		local badge = text(frame, "Badge", card.badge, INK)
		badge.BackgroundTransparency = 0
		badge.BackgroundColor3 = if card.badge == "SHINY" then GOLD else GREEN
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.fromScale(0.97, 0.04)
		badge.Size = if wide then UDim2.fromScale(0.16, 0.18) else UDim2.fromScale(0.5, 0.11)
		badge.ZIndex = 3
		corner(badge, 0.3)
	end
	if card.button then
		local b = button(frame, "Buy", card.button, card.buttonColor or GOLD)
		if wide then
			b.AnchorPoint = Vector2.new(1, 1)
			b.Position = UDim2.fromScale(0.97, 0.92)
			b.Size = UDim2.fromScale(0.25, 0.35)
		else
			b.AnchorPoint = Vector2.new(0.5, 1)
			b.Position = UDim2.fromScale(0.5, 0.95)
			b.Size = UDim2.fromScale(0.9, 0.22)
		end
		minSize(b, MIN * 1.4, MIN * 0.8)
		setEnabled(b, card.enabled ~= false)
		local onPress = card.onPress
		if onPress then
			b.Activated:Connect(function()
				if b.Active then
					onPress()
				end
			end)
		end
	end
	return frame
end

-- A grid of cards (wide cards take a whole row, above the grid)
function ShopHud.showCards(cards: { Card }, emptyText: string?)
	if shade == nil then
		return
	end
	clearContent()
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = content
	local order = 0
	local grid: Frame? = nil
	for _, card in cards do
		order += 1
		if card.wide then
			grid = nil
			local holder = Instance.new("Frame")
			holder.Name = "Wide_" .. card.id
			holder.BackgroundTransparency = 1
			holder.LayoutOrder = order
			holder.Size = UDim2.new(1, -12, 0, math.max(MIN * 2.4, content.AbsoluteSize.Y * 0.38))
			holder.Parent = content
			local f = makeCard(holder, card, 1)
			f.Size = UDim2.fromScale(1, 1)
		else
			if grid == nil then
				local g = Instance.new("Frame")
				g.Name = "Grid" .. order
				g.BackgroundTransparency = 1
				g.LayoutOrder = order
				g.Size = UDim2.new(1, -12, 0, 0)
				g.AutomaticSize = Enum.AutomaticSize.Y
				g.Parent = content
				local layout = Instance.new("UIGridLayout")
				layout.CellSize = UDim2.new(0.235, 0, 0, math.max(MIN * 3, content.AbsoluteSize.Y * 0.52))
				layout.CellPadding = UDim2.new(0.018, 0, 0, 10)
				layout.SortOrder = Enum.SortOrder.LayoutOrder
				layout.Parent = g
				grid = g
			end
			makeCard(grid :: Frame, card, order)
		end
	end
	if #cards == 0 then
		local empty = text(content, "Empty", emptyText or "Nothing here yet.", GREY)
		empty.Size = UDim2.new(1, 0, 0, 40)
	end
end

---------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------

local function questRow(parent: Instance, row: QuestRow, order: number)
	local f = Instance.new("Frame")
	f.Name = row.id
	f.LayoutOrder = order
	f.BackgroundColor3 = WHITE
	f.Size = UDim2.new(1, -12, 0, math.max(MIN * 1.1, 70))
	corner(f, 0.2)
	stroke(f, 2)
	f.Parent = parent
	local label = text(f, "Text", row.text, INK)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = UDim2.fromScale(0.03, 0.1)
	label.Size = UDim2.fromScale(0.45, 0.45)
	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = LIGHT
	bar.Position = UDim2.fromScale(0.03, 0.62)
	bar.Size = UDim2.fromScale(0.45, 0.22)
	corner(bar, 0.5)
	bar.Parent = f
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = GREEN
	fill.Size = UDim2.fromScale(math.clamp(row.progress / math.max(1, row.target), 0, 1), 1)
	corner(fill, 0.5)
	fill.Parent = bar
	local count = text(bar, "Count", string.format("%d / %d", row.progress, row.target), INK)
	count.Size = UDim2.fromScale(1, 1)
	local reward = text(f, "Reward", row.reward, Color3.fromRGB(205, 150, 0))
	reward.Position = UDim2.fromScale(0.52, 0.2)
	reward.Size = UDim2.fromScale(0.2, 0.6)
	local b = button(
		f,
		"Claim",
		if row.claimed then "DONE" elseif row.onClaim then "CLAIM" else "...",
		if row.onClaim then GREEN else WHITE
	)
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.fromScale(0.98, 0.5)
	b.Size = UDim2.fromScale(0.22, 0.75)
	minSize(b, MIN * 1.4, MIN * 0.8)
	setEnabled(b, row.onClaim ~= nil)
	local onClaim = row.onClaim
	if onClaim then
		pulse(b)
		b.Activated:Connect(onClaim)
	end
end

local function heading(parent: Instance, value: string, order: number)
	local h = text(parent, "Heading" .. order, value, INK)
	h.TextXAlignment = Enum.TextXAlignment.Left
	h.LayoutOrder = order
	h.Size = UDim2.new(1, -12, 0, 34)
end

local function wideButton(
	parent: Instance,
	label: string,
	color: Color3,
	enabled: boolean,
	order: number,
	fn: () -> ()
)
	local b = button(parent, label, label, color)
	b.LayoutOrder = order
	b.Size = UDim2.new(0.5, 0, 0, MIN)
	setEnabled(b, enabled)
	if enabled then
		pulse(b)
		b.Activated:Connect(fn)
	end
	return b
end

function ShopHud.showQuests(view: QuestsView)
	if shade == nil then
		return
	end
	clearContent()
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Parent = content
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- Login streak calendar
	heading(content, "LOGIN STREAK", nextOrder())
	local week = Instance.new("Frame")
	week.Name = "Streak"
	week.BackgroundTransparency = 1
	week.LayoutOrder = nextOrder()
	week.Size = UDim2.new(1, -12, 0, math.max(MIN * 1.3, 84))
	week.Parent = content
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0.01, 0)
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.Parent = week
	local streak = view.streak
	for day = 1, 7 do
		local done = day < streak.nextDay or (not streak.canClaim and day <= streak.day)
		local today = streak.canClaim and day == streak.nextDay
		local cell = Instance.new("Frame")
		cell.Name = "Day" .. day
		cell.LayoutOrder = day
		cell.Size = UDim2.fromScale(0.13, 1)
		cell.BackgroundColor3 = if today then GOLD elseif done then GREEN else WHITE
		corner(cell, 0.15)
		stroke(cell, 2)
		cell.Parent = week
		local dayLabel = text(cell, "Day", "DAY " .. day, INK)
		dayLabel.Size = UDim2.fromScale(1, 0.4)
		local reward = text(cell, "Reward", streak.rewards[day] or "", INK)
		reward.Position = UDim2.fromScale(0.05, 0.45)
		reward.Size = UDim2.fromScale(0.9, 0.45)
	end
	wideButton(
		content,
		if streak.canClaim then "CLAIM DAY " .. streak.nextDay else "COME BACK TOMORROW",
		GREEN,
		streak.canClaim,
		nextOrder(),
		streak.onClaim
	)

	heading(content, "DAILY QUESTS", nextOrder())
	for _, q in view.daily do
		questRow(content, q, nextOrder())
	end
	wideButton(
		content,
		if view.chest.claimed then "CHEST OPENED" else "OPEN DAILY CHEST",
		GOLD,
		view.chest.ready,
		nextOrder(),
		view.chest.onClaim
	)

	heading(content, "WEEKLY QUESTS", nextOrder())
	for _, q in view.weekly do
		questRow(content, q, nextOrder())
	end
	wideButton(
		content,
		if view.weeklyStars.claimed then "WEEKLY STARS CLAIMED" else "CLAIM 5 ★ FOR ALL 3",
		GOLD,
		view.weeklyStars.ready,
		nextOrder(),
		view.weeklyStars.onClaim
	)

	if view.gifts and #view.gifts > 0 then
		heading(
			content,
			if view.giftSent then "GIFT SENT TODAY" else "GIFT 10 COINS TO A FRIEND",
			nextOrder()
		)
		for _, friend in view.gifts do
			local b = button(content, "Gift_" .. friend.name, "GIFT " .. friend.name, BLUE)
			b.LayoutOrder = nextOrder()
			b.Size = UDim2.new(0.5, 0, 0, MIN)
			setEnabled(b, not view.giftSent)
			b.Activated:Connect(function()
				if b.Active then
					friend.onGift()
				end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Crate opening (2.5 s, a tap skips) and the one-time offer card
---------------------------------------------------------------------------

export type CrateView = { name: string, rarity: string, shiny: boolean, duplicate: boolean, refund: number }

function ShopHud.crateReveal(parent: Instance, view: CrateView, onDone: () -> ())
	local g = ensureGui(parent)
	local cover = Instance.new("TextButton")
	cover.Name = "CrateReveal"
	cover.Text = ""
	cover.AutoButtonColor = false
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 0.3
	cover.Size = UDim2.fromScale(1, 1)
	cover.ZIndex = 50
	cover.Parent = g
	local box = Instance.new("Frame")
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.45)
	box.SizeConstraint = Enum.SizeConstraint.RelativeYY
	box.Size = UDim2.fromScale(0.3, 0.3)
	box.BackgroundColor3 = Color3.fromRGB(200, 140, 70)
	box.ZIndex = 51
	corner(box, 0.12)
	stroke(box, 2)
	box.Parent = cover
	local lid = text(box, "Lid", "?", WHITE)
	lid.Size = UDim2.fromScale(1, 1)
	lid.ZIndex = 52
	local result = text(cover, "Result", "", WHITE)
	result.AnchorPoint = Vector2.new(0.5, 0)
	result.Position = UDim2.fromScale(0.5, 0.65)
	result.Size = UDim2.fromScale(0.7, 0.09)
	result.ZIndex = 52
	local sub = text(cover, "Sub", "", WHITE)
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.fromScale(0.5, 0.75)
	sub.Size = UDim2.fromScale(0.6, 0.05)
	sub.ZIndex = 52

	local finished = false
	local revealed = false
	local function reveal()
		if revealed then
			return
		end
		revealed = true
		box.Rotation = 0
		box.BackgroundColor3 = ShopHud.RARITY_COLORS[view.rarity] or WHITE
		lid.Text = if view.shiny then "✦" else "★"
		result.Text = (if view.shiny then "SHINY " else "") .. view.name
		sub.Text = if view.duplicate
			then string.format("%s · duplicate: +%d coins back", string.upper(view.rarity), view.refund)
			else string.upper(view.rarity)
		box.Size = UDim2.fromScale(0.42, 0.42)
		TweenService
			:Create(box, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Size = UDim2.fromScale(0.3, 0.3) })
			:Play()
	end
	local function finish()
		if finished then
			return
		end
		finished = true
		cover:Destroy()
		onDone()
	end
	cover.Activated:Connect(function()
		if revealed then
			finish()
		else
			reveal()
		end
	end)
	task.spawn(function()
		-- Shake for 1.6 s, reveal, then close by itself at 2.5 s unless tapped
		local start = os.clock()
		while not revealed and cover.Parent and os.clock() - start < 1.6 do
			box.Rotation = math.sin((os.clock() - start) * 30) * (4 + (os.clock() - start) * 6)
			task.wait()
		end
		reveal()
		task.wait(0.9)
		if cover.Parent and not finished then
			sub.Text ..= "   (tap to close)"
		end
	end)
end

export type OfferView = { title: string, lines: { string }, price: string, onBuy: () -> (), onClose: () -> () }

-- A one-time offer (the Starter Pack after the first finish): no timer, a clear NO THANKS
function ShopHud.offer(parent: Instance, view: OfferView)
	local g = ensureGui(parent)
	local cover = Instance.new("Frame")
	cover.Name = "Offer"
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 0.45
	cover.Size = UDim2.fromScale(1, 1)
	cover.Active = true
	cover.ZIndex = 40
	cover.Parent = g
	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(0.9, 0.62)
	card.BackgroundColor3 = PANEL
	card.ZIndex = 41
	corner(card, 0.08)
	stroke(card, 2)
	card.Parent = cover
	local title = text(card, "Title", view.title, INK)
	title.Position = UDim2.fromScale(0.05, 0.05)
	title.Size = UDim2.fromScale(0.9, 0.16)
	title.ZIndex = 42
	for index, value in view.lines do
		local l = text(card, "Line" .. index, "• " .. value, INK)
		l.Position = UDim2.fromScale(0.1, 0.25 + (index - 1) * 0.1)
		l.Size = UDim2.fromScale(0.8, 0.08)
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.ZIndex = 42
	end
	local buy = button(card, "Buy", view.price, GREEN)
	buy.AnchorPoint = Vector2.new(0, 1)
	buy.Position = UDim2.fromScale(0.08, 0.94)
	buy.Size = UDim2.fromScale(0.4, 0.17)
	buy.ZIndex = 42
	minSize(buy, MIN * 2, MIN)
	local no = button(card, "NoThanks", "NO THANKS", WHITE)
	no.AnchorPoint = Vector2.new(1, 1)
	no.Position = UDim2.fromScale(0.92, 0.94)
	no.Size = UDim2.fromScale(0.4, 0.17)
	no.ZIndex = 42
	minSize(no, MIN * 2, MIN)
	buy.Activated:Connect(function()
		cover:Destroy()
		view.onBuy()
	end)
	no.Activated:Connect(function()
		cover:Destroy()
		view.onClose()
	end)
end

-- Rebirth: hold CONFIRM for 1.5 s (never a single tap)
function ShopHud.holdButton(parent: Instance, label: string, seconds: number, onDone: () -> ()): TextButton
	local b = button(parent, "Hold", label, Color3.fromRGB(255, 120, 90))
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.fromRGB(255, 220, 120)
	fill.BackgroundTransparency = 0.3
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = b.ZIndex
	corner(fill, 0.3)
	fill.Parent = b
	local holding = false
	b.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonA
		then
			holding = true
			local start = os.clock()
			while holding and b.Parent do
				local t = (os.clock() - start) / seconds
				fill.Size = UDim2.fromScale(math.clamp(t, 0, 1), 1)
				if t >= 1 then
					holding = false
					onDone()
					break
				end
				task.wait()
			end
			fill.Size = UDim2.fromScale(0, 1)
		end
	end)
	b.InputEnded:Connect(function()
		holding = false
	end)
	return b
end

function ShopHud.content(): ScrollingFrame?
	return if shade then content else nil
end

function ShopHud.clear()
	if shade then
		clearContent()
	end
end

return ShopHud
