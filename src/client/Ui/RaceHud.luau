-- RaceHud: quick race screens (spec: Tracks: quick race; Session units > race results, auto-requeue).
-- * Status pill (top centre, under the timer): the lobby ("QUICK RACE 3/8 · starts in 7") with LEAVE,
--   and your place while racing ("2nd of 5").
-- * Results card: places with names and times, your place and coins, then "Next race in 6" (you stay
--   in the queue) with SKIP and LEAVE.
-- Countdown numbers use TracksHud's centre cue. Text is ours only, apart from Roblox display names.
-- PLACEHOLDER ART: flat cards.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local RaceHud = {}

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local PANEL = Color3.fromRGB(255, 250, 240)
local MIN = Config.UI.minTapTarget

local gui: ScreenGui? = nil
local pill: Frame? = nil
local results: Frame? = nil
local leaveHandler: (() -> ())? = nil

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = INK
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
	padding.PaddingTop = UDim.new(0.2, 0)
	padding.PaddingBottom = UDim.new(0.2, 0)
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
		g.Name = "Race"
		g.ResetOnSpawn = false
		g.DisplayOrder = 18
		g.Parent = parent
		gui = g
	end
	return gui :: ScreenGui
end

-- The status pill; nil hides it. onLeave adds a LEAVE button.
function RaceHud.status(parent: Instance, value: string?, onLeave: (() -> ())?)
	if value == nil then
		if pill then
			pill:Destroy()
			pill = nil
		end
		return
	end
	local g = ensureGui(parent)
	if pill == nil then
		local f = Instance.new("Frame")
		f.Name = "Status"
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(0.5, 0.2)
		f.SizeConstraint = Enum.SizeConstraint.RelativeYY
		f.Size = UDim2.fromScale(0.85, 0.075)
		f.BackgroundColor3 = INK
		f.BackgroundTransparency = 0.2
		corner(f, 0.5)
		f.Parent = g
		local label = text(f, "Text", "", WHITE)
		label.Position = UDim2.fromScale(0.05, 0.15)
		label.Size = UDim2.fromScale(0.62, 0.7)
		local leave = button(f, "Leave", "LEAVE", WHITE)
		leave.AnchorPoint = Vector2.new(1, 0.5)
		leave.Position = UDim2.fromScale(0.97, 0.5)
		leave.Size = UDim2.fromScale(0.28, 0.8)
		leave.Activated:Connect(function()
			if leaveHandler then
				leaveHandler()
			end
		end)
		pill = f
	end
	local f = pill :: Frame
	local label = f:FindFirstChild("Text") :: TextLabel
	label.Text = value
	local leave = f:FindFirstChild("Leave") :: TextButton
	leave.Visible = onLeave ~= nil
	label.Size = if onLeave then UDim2.fromScale(0.62, 0.7) else UDim2.fromScale(0.9, 0.7)
	leaveHandler = onLeave
end

export type ResultRow = { place: number, name: string, time: string, me: boolean, dnf: boolean }
export type ResultView = {
	title: string,
	mapName: string,
	rows: { ResultRow },
	coinsLine: string,
	seconds: number,
	onSkip: () -> (),
	onLeave: () -> (),
}

function RaceHud.hideResults()
	if results then
		results:Destroy()
		results = nil
	end
end

function RaceHud.resultsOpen(): boolean
	return results ~= nil
end

function RaceHud.showResults(parent: Instance, view: ResultView)
	RaceHud.hideResults()
	local g = ensureGui(parent)
	local card = Instance.new("Frame")
	card.Name = "RaceResults"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(1.15, 0.86)
	card.BackgroundColor3 = PANEL
	corner(card, 0.05)
	stroke(card, 2)
	card.Parent = g
	results = card
	local title = text(card, "Title", view.title, INK)
	title.Position = UDim2.fromScale(0.05, 0.03)
	title.Size = UDim2.fromScale(0.9, 0.12)
	local map = text(card, "Map", view.mapName, Color3.fromRGB(110, 110, 125))
	map.Position = UDim2.fromScale(0.05, 0.15)
	map.Size = UDim2.fromScale(0.9, 0.06)
	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.08, 0.23)
	list.Size = UDim2.fromScale(0.84, 0.48)
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
		local place = text(f, "Place", if row.dnf then "DNF" else "#" .. row.place, INK)
		place.Position = UDim2.fromScale(0.02, 0.1)
		place.Size = UDim2.fromScale(0.15, 0.8)
		local name = text(f, "Name", row.name, INK)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromScale(0.2, 0.1)
		name.Size = UDim2.fromScale(0.5, 0.8)
		local t = text(f, "Time", row.time, INK)
		t.TextXAlignment = Enum.TextXAlignment.Right
		t.Position = UDim2.fromScale(0.72, 0.1)
		t.Size = UDim2.fromScale(0.26, 0.8)
	end
	local coins = text(card, "Coins", view.coinsLine, Color3.fromRGB(205, 150, 0))
	coins.Position = UDim2.fromScale(0.05, 0.72)
	coins.Size = UDim2.fromScale(0.9, 0.08)
	local skip = button(card, "Skip", "", GREEN)
	skip.Position = UDim2.fromScale(0.06, 0.83)
	skip.Size = UDim2.fromScale(0.52, 0.13)
	local leave = button(card, "Leave", "LEAVE", WHITE)
	leave.Position = UDim2.fromScale(0.62, 0.83)
	leave.Size = UDim2.fromScale(0.32, 0.13)
	skip.Activated:Connect(function()
		skip.Text = "RACING AGAIN!"
		view.onSkip()
	end)
	leave.Activated:Connect(function()
		RaceHud.hideResults()
		view.onLeave()
	end)
	task.spawn(function()
		local left = view.seconds
		while card.Parent and left > 0 do
			if skip.Text ~= "RACING AGAIN!" then
				skip.Text = string.format("RACE AGAIN ▶ %d", math.ceil(left))
			end
			task.wait(0.2)
			left -= 0.2
		end
		if results == card then
			RaceHud.hideResults()
		end
	end)
end

return RaceHud
