-- BrawlHud: Bumper Brawl screens (spec: Brawl screens; Hub and menus > Mode card detail).
-- * Lobby panel (top centre, in the pen): the round's 8 slots filling (bots tagged BOT), the countdown
--   ring and a line ("Next round in 7"). While a round you are not in is running: "Round on: 5 left".
-- * Round bar (top centre): the timer (then SUDDEN DEATH), cars left, and a kill feed under it.
-- * ACTION button (right, above the drive controls): the held powerup; tap (or G / RB) to use it.
-- * Eliminated panel: your place, WATCH (spectate the finalists, tap again for the next), CHEER and
--   QUEUE NEXT (you are always in the next round; this closes the panel).
-- * Results card: places with KOs, your coins, the ranked bar and points change (ranked), QUEUE NEXT
--   with the seconds left (skips the wait) and LEAVE (back to Tumble Park).
-- * Practice bar: "Knock the bot off!" with the 1 / 2 count and SKIP.
-- Text is ours only, apart from Roblox display names. PLACEHOLDER ART: flat cards and a plain ring.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local BrawlHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local CORAL = Color3.fromRGB(255, 120, 90)
local GREY = Color3.fromRGB(110, 110, 125)
local PANEL = Color3.fromRGB(255, 250, 240)
local MIN = Config.UI.minTapTarget

BrawlHud.POWERUPS = {
	spring = { label = "SPRING", line = "Next 3 bumps hit harder", color = Color3.fromRGB(120, 230, 90) },
	shield = { label = "SHIELD", line = "Nothing can knock you", color = Color3.fromRGB(110, 200, 255) },
	wrench = { label = "WRENCH", line = "Fixes your car", color = Color3.fromRGB(255, 200, 60) },
	honk = { label = "HONK", line = "Blasts cars away", color = Color3.fromRGB(255, 120, 200) },
}

local gui: ScreenGui? = nil
local lobbyFrame: Frame? = nil
local roundFrame: Frame? = nil
local feedFrame: Frame? = nil
local actionButton: TextButton? = nil
local outFrame: Frame? = nil
local resultsFrame: Frame? = nil
local practiceFrame: Frame? = nil

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
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
	padding.PaddingLeft = UDim.new(0.05, 0)
	padding.PaddingRight = UDim.new(0.05, 0)
	padding.Parent = b
	corner(b, 0.3)
	stroke(b, 2)
	local min = Instance.new("UISizeConstraint")
	min.MinSize = Vector2.new(MIN, MIN * 0.7)
	min.Parent = b
	b.Parent = parent
	return b
end

local function ensureGui(parent: Instance): ScreenGui
	if gui == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "Brawl"
		g.ResetOnSpawn = false
		g.DisplayOrder = 18
		g.Parent = parent
		gui = g
	end
	return gui :: ScreenGui
end

local function kill(frame: Frame?): nil
	if frame then
		frame:Destroy()
	end
	return nil
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------

export type Slot = { name: string, bot: boolean }
export type LobbyView = {
	title: string,
	line: string,
	seconds: number?, -- the countdown ring (nil: waiting)
	slots: { Slot },
	max: number,
}

function BrawlHud.lobby(parent: Instance, view: LobbyView?)
	if view == nil then
		lobbyFrame = kill(lobbyFrame)
		return
	end
	local g = ensureGui(parent)
	if lobbyFrame == nil then
		local f = Instance.new("Frame")
		f.Name = "Lobby"
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(0.5, 0.17)
		f.SizeConstraint = Enum.SizeConstraint.RelativeYY
		f.Size = UDim2.fromScale(1.1, 0.25)
		f.BackgroundColor3 = INK
		f.BackgroundTransparency = 0.2
		corner(f, 0.12)
		f.Parent = g
		local title = text(f, "Title", "", GOLD)
		title.Position = UDim2.fromScale(0.04, 0.06)
		title.Size = UDim2.fromScale(0.7, 0.22)
		title.TextXAlignment = Enum.TextXAlignment.Left
		local line = text(f, "Line", "", WHITE)
		line.Position = UDim2.fromScale(0.04, 0.3)
		line.Size = UDim2.fromScale(0.7, 0.17)
		line.TextXAlignment = Enum.TextXAlignment.Left
		-- The countdown ring
		local ring = Instance.new("Frame")
		ring.Name = "Ring"
		ring.AnchorPoint = Vector2.new(1, 0)
		ring.Position = UDim2.fromScale(0.97, 0.06)
		ring.SizeConstraint = Enum.SizeConstraint.RelativeYY
		ring.Size = UDim2.fromScale(0.42, 0.42)
		ring.BackgroundColor3 = CORAL
		corner(ring, 0.5)
		stroke(ring, 4, WHITE)
		ring.Parent = f
		local seconds = text(ring, "Seconds", "", WHITE)
		seconds.Size = UDim2.fromScale(1, 1)
		local slots = Instance.new("Frame")
		slots.Name = "Slots"
		slots.BackgroundTransparency = 1
		slots.Position = UDim2.fromScale(0.03, 0.55)
		slots.Size = UDim2.fromScale(0.94, 0.4)
		slots.Parent = f
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromScale(0.235, 0.44)
		grid.CellPadding = UDim2.fromScale(0.02, 0.1)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = slots
		lobbyFrame = f
	end
	local f = lobbyFrame :: Frame;
	(f:FindFirstChild("Title") :: TextLabel).Text = view.title;
	(f:FindFirstChild("Line") :: TextLabel).Text = view.line
	local ring = f:FindFirstChild("Ring") :: Frame
	ring.Visible = view.seconds ~= nil
	if view.seconds then
		(ring:FindFirstChild("Seconds") :: TextLabel).Text = tostring(math.max(0, math.ceil(view.seconds)))
	end
	local slots = f:FindFirstChild("Slots") :: Frame
	-- Rebuild the slots only when they change (this is called a few times a second)
	local parts = { tostring(view.max) }
	for _, slot in view.slots do
		table.insert(parts, slot.name .. (if slot.bot then "*" else ""))
	end
	local key = table.concat(parts, "|")
	if slots:GetAttribute("Key") == key then
		return
	end
	slots:SetAttribute("Key", key)
	for _, child in slots:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i = 1, view.max do
		local slot = view.slots[i]
		local cell = Instance.new("Frame")
		cell.LayoutOrder = i
		cell.BackgroundColor3 = if slot == nil then GREY elseif slot.bot then PANEL else GOLD
		cell.BackgroundTransparency = if slot == nil then 0.6 else 0
		corner(cell, 0.3)
		cell.Parent = slots
		local label = text(cell, "Name", if slot then slot.name else "...", INK)
		label.Position = UDim2.fromScale(0.05, 0.1)
		label.Size = UDim2.fromScale(if slot and slot.bot then 0.6 else 0.9, 0.8)
		if slot and slot.bot then
			local tag = text(cell, "Bot", "BOT", WHITE)
			tag.BackgroundTransparency = 0
			tag.BackgroundColor3 = INK
			tag.Position = UDim2.fromScale(0.68, 0.2)
			tag.Size = UDim2.fromScale(0.28, 0.6)
			corner(tag, 0.3)
		end
	end
end

---------------------------------------------------------------------------
-- In the round
---------------------------------------------------------------------------

function BrawlHud.round(parent: Instance, timer: string?, left: number?, sudden: boolean?)
	if timer == nil then
		roundFrame = kill(roundFrame)
		feedFrame = kill(feedFrame)
		return
	end
	local g = ensureGui(parent)
	if roundFrame == nil then
		local f = Instance.new("Frame")
		f.Name = "RoundBar"
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(0.5, 0.17)
		f.SizeConstraint = Enum.SizeConstraint.RelativeYY
		f.Size = UDim2.fromScale(0.62, 0.075)
		f.BackgroundColor3 = INK
		f.BackgroundTransparency = 0.2
		corner(f, 0.5)
		f.Parent = g
		local t = text(f, "Timer", "", WHITE)
		t.Position = UDim2.fromScale(0.05, 0.12)
		t.Size = UDim2.fromScale(0.55, 0.76)
		local l = text(f, "Left", "", GOLD)
		l.Position = UDim2.fromScale(0.6, 0.12)
		l.Size = UDim2.fromScale(0.36, 0.76)
		roundFrame = f
		local feed = Instance.new("Frame")
		feed.Name = "Feed"
		feed.BackgroundTransparency = 1
		feed.AnchorPoint = Vector2.new(0.5, 0)
		feed.Position = UDim2.fromScale(0.5, 0.255)
		feed.SizeConstraint = Enum.SizeConstraint.RelativeYY
		feed.Size = UDim2.fromScale(0.9, 0.14)
		feed.Parent = g
		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
		list.Parent = feed
		feedFrame = feed
	end
	local f = roundFrame :: Frame
	local t = f:FindFirstChild("Timer") :: TextLabel
	t.Text = timer
	t.TextColor3 = if sudden then CORAL else WHITE;
	(f:FindFirstChild("Left") :: TextLabel).Text = if left then string.format("%d LEFT", left) else ""
end

local feedOrder = 0
-- A kill feed line under the round bar (fades after 4 s, 3 at most)
function BrawlHud.feed(value: string, mine: boolean?)
	local feed = feedFrame
	if feed == nil then
		return
	end
	feedOrder += 1
	local lines = {}
	for _, child in feed:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(lines, child)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #lines >= 3 do
		table.remove(lines, 1):Destroy()
	end
	local label = text(feed, "Line", value, if mine then GOLD else WHITE)
	label.LayoutOrder = feedOrder
	label.Size = UDim2.fromScale(1, 0.32)
	label.TextStrokeTransparency = 0.3
	task.delay(4, function()
		if label.Parent then
			label:Destroy()
		end
	end)
end

-- The ACTION button with the held powerup (nil hides it)
function BrawlHud.powerup(parent: Instance, kind: string?, onAction: () -> ())
	local g = ensureGui(parent)
	if actionButton == nil then
		local b = button(g, "Action", "", WHITE)
		b.AnchorPoint = Vector2.new(1, 1)
		b.Position = UDim2.fromScale(0.97, 0.6)
		b.SizeConstraint = Enum.SizeConstraint.RelativeYY
		b.Size = UDim2.fromScale(0.2, 0.2)
		corner(b, 0.5)
		b.Activated:Connect(function()
			onAction()
		end)
		actionButton = b
	end
	local b = actionButton :: TextButton
	local info = kind and BrawlHud.POWERUPS[kind]
	b.Visible = info ~= nil
	if info then
		b.Text = info.label
		b.BackgroundColor3 = info.color
	end
end

---------------------------------------------------------------------------
-- Out of the round
---------------------------------------------------------------------------

export type OutView = {
	line: string,
	watching: string?, -- the finalist you watch (nil: not watching)
	onWatch: () -> (),
	onCheer: () -> (),
	onQueue: () -> (),
}

function BrawlHud.eliminated(parent: Instance, view: OutView?)
	outFrame = kill(outFrame)
	if view == nil then
		return
	end
	local g = ensureGui(parent)
	local f = Instance.new("Frame")
	f.Name = "Out"
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.fromScale(0.5, 0.97)
	f.SizeConstraint = Enum.SizeConstraint.RelativeYY
	f.Size = UDim2.fromScale(1.15, 0.2)
	f.BackgroundColor3 = PANEL
	corner(f, 0.15)
	stroke(f, 2)
	f.Parent = g
	local line = text(f, "Line", view.line, INK)
	line.Position = UDim2.fromScale(0.04, 0.06)
	line.Size = UDim2.fromScale(0.92, 0.34)
	local watch = button(
		f,
		"Watch",
		if view.watching then "WATCHING " .. string.upper(view.watching) .. " ▸" else "WATCH",
		WHITE
	)
	watch.Position = UDim2.fromScale(0.04, 0.48)
	watch.Size = UDim2.fromScale(0.4, 0.42)
	watch.Activated:Connect(view.onWatch)
	local cheer = button(f, "Cheer", "CHEER", GOLD)
	cheer.Position = UDim2.fromScale(0.47, 0.48)
	cheer.Size = UDim2.fromScale(0.2, 0.42)
	cheer.Visible = view.watching ~= nil
	cheer.Activated:Connect(view.onCheer)
	local queue = button(f, "Queue", "QUEUE NEXT ✓", GREEN)
	queue.Position = UDim2.fromScale(0.7, 0.48)
	queue.Size = UDim2.fromScale(0.26, 0.42)
	queue.Activated:Connect(view.onQueue)
end

function BrawlHud.isOut(): boolean
	return outFrame ~= nil
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

export type ResultRow = { place: number, name: string, bot: boolean, kos: number, me: boolean }
export type RankView = {
	tierName: string,
	progress: number,
	points: number,
	delta: number,
	rankUp: boolean,
	note: string?,
}
export type ResultView = {
	title: string,
	arena: string,
	rows: { ResultRow },
	coinsLine: string,
	ranked: RankView?,
	seconds: number,
	onQueue: () -> (),
	onLeave: () -> (),
}

function BrawlHud.hideResults()
	resultsFrame = kill(resultsFrame)
end

function BrawlHud.resultsOpen(): boolean
	return resultsFrame ~= nil
end

function BrawlHud.showResults(parent: Instance, view: ResultView)
	BrawlHud.hideResults()
	local g = ensureGui(parent)
	local card = Instance.new("Frame")
	card.Name = "BrawlResults"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(1.15, 0.9)
	card.BackgroundColor3 = PANEL
	corner(card, 0.05)
	stroke(card, 2)
	card.Parent = g
	resultsFrame = card
	local title = text(card, "Title", view.title, INK)
	title.Position = UDim2.fromScale(0.05, 0.02)
	title.Size = UDim2.fromScale(0.9, 0.11)
	local arena = text(card, "Arena", view.arena, GREY)
	arena.Position = UDim2.fromScale(0.05, 0.13)
	arena.Size = UDim2.fromScale(0.9, 0.05)
	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.08, 0.2)
	list.Size = UDim2.fromScale(0.84, 0.44)
	list.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0.01, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	for index, row in view.rows do
		local f = Instance.new("Frame")
		f.LayoutOrder = index
		f.Size = UDim2.fromScale(1, 0.115)
		f.BackgroundColor3 = if row.me then GOLD else WHITE
		corner(f, 0.3)
		f.Parent = list
		local place = text(f, "Place", "#" .. row.place, INK)
		place.Position = UDim2.fromScale(0.02, 0.1)
		place.Size = UDim2.fromScale(0.13, 0.8)
		local name = text(f, "Name", row.name .. (if row.bot then "  [BOT]" else ""), INK)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromScale(0.17, 0.1)
		name.Size = UDim2.fromScale(0.55, 0.8)
		local kos = text(f, "KOs", string.format("%d KO", row.kos), INK)
		kos.TextXAlignment = Enum.TextXAlignment.Right
		kos.Position = UDim2.fromScale(0.74, 0.1)
		kos.Size = UDim2.fromScale(0.24, 0.8)
	end
	local coins = text(card, "Coins", view.coinsLine, Color3.fromRGB(205, 150, 0))
	coins.Position = UDim2.fromScale(0.05, 0.655)
	coins.Size = UDim2.fromScale(0.9, 0.065)
	local ranked = view.ranked
	if ranked then
		local name = text(
			card,
			"Tier",
			string.format(
				"%s  %s%d",
				string.upper(ranked.tierName),
				if ranked.delta >= 0 then "+" else "",
				ranked.delta
			),
			INK
		)
		name.Position = UDim2.fromScale(0.08, 0.725)
		name.Size = UDim2.fromScale(0.84, 0.05)
		local bar = Instance.new("Frame")
		bar.Name = "RankBar"
		bar.Position = UDim2.fromScale(0.08, 0.78)
		bar.Size = UDim2.fromScale(0.84, 0.03)
		bar.BackgroundColor3 = Color3.fromRGB(220, 215, 205)
		corner(bar, 0.5)
		bar.Parent = card
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(math.clamp(ranked.progress, 0.02, 1), 1)
		fill.BackgroundColor3 = if ranked.rankUp then GOLD else CORAL
		corner(fill, 0.5)
		fill.Parent = bar
		if ranked.note then
			local note = text(card, "Note", ranked.note, GREY)
			note.Position = UDim2.fromScale(0.08, 0.815)
			note.Size = UDim2.fromScale(0.84, 0.035)
		end
	end
	local queue = button(card, "Queue", "", GREEN)
	queue.Position = UDim2.fromScale(0.06, 0.86)
	queue.Size = UDim2.fromScale(0.54, 0.11)
	local leave = button(card, "Leave", "LEAVE", WHITE)
	leave.Position = UDim2.fromScale(0.64, 0.86)
	leave.Size = UDim2.fromScale(0.3, 0.11)
	local queued = false
	queue.Activated:Connect(function()
		queued = true
		queue.Text = "QUEUED!"
		view.onQueue()
	end)
	leave.Activated:Connect(function()
		BrawlHud.hideResults()
		view.onLeave()
	end)
	task.spawn(function()
		local left = view.seconds
		while card.Parent and left > 0 do
			if not queued then
				queue.Text = string.format("QUEUE NEXT ▶ %d", math.ceil(left))
			end
			task.wait(0.2)
			left -= 0.2
		end
		if resultsFrame == card then
			BrawlHud.hideResults()
		end
	end)
end

---------------------------------------------------------------------------
-- Practice
---------------------------------------------------------------------------

function BrawlHud.practice(parent: Instance, step: number?, of: number?, onSkip: (() -> ())?)
	if step == nil then
		practiceFrame = kill(practiceFrame)
		return
	end
	local g = ensureGui(parent)
	if practiceFrame == nil then
		local f = Instance.new("Frame")
		f.Name = "Practice"
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(0.5, 0.17)
		f.SizeConstraint = Enum.SizeConstraint.RelativeYY
		f.Size = UDim2.fromScale(0.9, 0.12)
		f.BackgroundColor3 = INK
		f.BackgroundTransparency = 0.2
		corner(f, 0.3)
		f.Parent = g
		local line = text(f, "Line", "BUMP THE BOT OFF!", WHITE)
		line.Position = UDim2.fromScale(0.05, 0.08)
		line.Size = UDim2.fromScale(0.62, 0.48)
		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.Position = UDim2.fromScale(0.05, 0.64)
		bar.Size = UDim2.fromScale(0.62, 0.2)
		bar.BackgroundColor3 = Color3.fromRGB(90, 90, 105)
		corner(bar, 0.5)
		bar.Parent = f
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = GREEN
		fill.Size = UDim2.fromScale(0, 1)
		corner(fill, 0.5)
		fill.Parent = bar
		local count = text(bar, "Count", "", WHITE)
		count.Size = UDim2.fromScale(1, 1)
		count.ZIndex = 2
		local skip = button(f, "Skip", "SKIP", WHITE)
		skip.AnchorPoint = Vector2.new(1, 0.5)
		skip.Position = UDim2.fromScale(0.96, 0.5)
		skip.Size = UDim2.fromScale(0.25, 0.7)
		skip.Activated:Connect(function()
			if onSkip then
				onSkip()
			end
		end)
		practiceFrame = f
	end
	local f = practiceFrame :: Frame
	local bar = f:FindFirstChild("Bar") :: Frame
	local done = math.max(0, step - 1);
	(bar:FindFirstChild("Fill") :: Frame).Size = UDim2.fromScale(done / math.max(of or 1, 1), 1);
	(bar:FindFirstChild("Count") :: TextLabel).Text = string.format("%d / %d", done, of or 1)
end

return BrawlHud
