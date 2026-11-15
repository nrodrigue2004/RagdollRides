-- HighwayHud: Highway Havoc screens (spec: Highway screens; Highway Havoc > Destruction Score; Bone
-- breaks; Leaderboards).
-- * Run bar (top centre): the run timer, the big Destruction Score, the combo meter (x1 to x8 with its
--   3 s bar draining), the Crack Count (n / 12), the server's Havoc meter and today's event chip.
-- * Pops: "+points" where a hit landed, and big banners for PILE-UP!, NEAR MISS, FLIP and bone breaks.
-- * X-ray: a cartoon skeleton flashes for 0.25 s on a bone break with the broken bones in red. With
--   Fewer flashes on, the rider glows instead (HighwayClient).
-- * Results card: score, bones, best combo, pile-ups, coins, the daily Havoc target bar, personal best,
--   RIDE AGAIN (after 2 s) and LEAVE, plus TOP for the boards.
-- * Boards panel: DESTRUCTION or BONE-BREAKS, each with FRIENDS, TODAY (the day's event) and THIS WEEK.
-- Text is ours only, apart from Roblox display names. PLACEHOLDER ART: flat cards, a frame skeleton.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local HighwayHud = {}

local cfg = Config.Highway
local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local WHITE = Color3.fromRGB(255, 255, 255)
local GOLD = Color3.fromRGB(255, 205, 40)
local GREEN = Color3.fromRGB(80, 210, 110)
local CORAL = Color3.fromRGB(255, 120, 90)
local GREY = Color3.fromRGB(110, 110, 125)
local PANEL = Color3.fromRGB(255, 250, 240)
local SKY = Color3.fromRGB(110, 200, 255)
local MIN = Config.UI.minTapTarget

-- Combo colours, x1 to x8
local COMBO_COLORS = {
	WHITE,
	Color3.fromRGB(160, 230, 255),
	Color3.fromRGB(120, 230, 140),
	Color3.fromRGB(255, 230, 90),
	Color3.fromRGB(255, 180, 60),
	Color3.fromRGB(255, 120, 80),
	Color3.fromRGB(255, 90, 170),
	Color3.fromRGB(190, 120, 255),
}

local gui: ScreenGui? = nil
local runFrame: Frame? = nil
local resultsFrame: Frame? = nil
local boardFrame: Frame? = nil
local xrayFrame: Frame? = nil
local labels: { [string]: any } = {}

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

local function textStroke(label: TextLabel, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = INK
	s.Parent = label
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

local function bar(parent: Instance, name: string, fill: Color3): (Frame, Frame)
	local back = Instance.new("Frame")
	back.Name = name
	back.BackgroundColor3 = INK
	back.BackgroundTransparency = 0.3
	corner(back, 0.5)
	back.Parent = parent
	local front = Instance.new("Frame")
	front.Name = "Fill"
	front.BackgroundColor3 = fill
	front.Size = UDim2.fromScale(0, 1)
	corner(front, 0.5)
	front.Parent = back
	return back, front
end

local function ensureGui(parent: Instance): ScreenGui
	if gui == nil or gui.Parent == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "Highway"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.DisplayOrder = 18
		g.Parent = parent
		gui = g
	end
	return gui :: ScreenGui
end

function HighwayHud.commas(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local sign = ""
	if string.sub(s, 1, 1) == "-" then
		sign, s = "-", string.sub(s, 2)
	end
	local out = s
	while true do
		local next, k = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = next
		if k == 0 then
			break
		end
	end
	return sign .. out
end

local function clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

---------------------------------------------------------------------------
-- The run bar
---------------------------------------------------------------------------

export type RunView = {
	timeLeft: number,
	score: number,
	multiplier: number,
	comboLeft: number, -- 0 to 1 of the 3 s window left
	breaks: number,
	meter: number, -- 0 to 1
	event: { name: string, line: string }?,
	tutorial: boolean,
}

function HighwayHud.run(parent: Instance, view: RunView?)
	if view == nil then
		if runFrame then
			runFrame:Destroy()
			runFrame = nil
		end
		return
	end
	local g = ensureGui(parent)
	if runFrame == nil then
		local f = Instance.new("Frame")
		f.Name = "RunBar"
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(0.5, 0.11)
		f.SizeConstraint = Enum.SizeConstraint.RelativeYY
		f.Size = UDim2.fromScale(0.9, 0.24)
		f.BackgroundTransparency = 1
		f.Parent = g
		runFrame = f
		local timer = text(f, "Timer", "3:30", WHITE)
		timer.Position = UDim2.fromScale(0, 0)
		timer.Size = UDim2.fromScale(1, 0.16)
		textStroke(timer)
		local score = text(f, "Score", "0", GOLD)
		score.Position = UDim2.fromScale(0, 0.15)
		score.Size = UDim2.fromScale(1, 0.34)
		textStroke(score, 3)
		local scale = Instance.new("UIScale")
		scale.Parent = score
		local combo = text(f, "Combo", "x1", WHITE)
		combo.AnchorPoint = Vector2.new(0.5, 0)
		combo.Position = UDim2.fromScale(0.5, 0.5)
		combo.Size = UDim2.fromScale(0.3, 0.2)
		textStroke(combo, 2)
		local comboScale = Instance.new("UIScale")
		comboScale.Parent = combo
		local comboBack, comboFill = bar(f, "ComboBar", GOLD)
		comboBack.AnchorPoint = Vector2.new(0.5, 0)
		comboBack.Position = UDim2.fromScale(0.5, 0.71)
		comboBack.Size = UDim2.fromScale(0.36, 0.035)
		local crack = text(f, "Crack", cfg.counterLabel .. " 0 / " .. cfg.bones.total, WHITE)
		crack.Position = UDim2.fromScale(0, 0.77)
		crack.Size = UDim2.fromScale(1, 0.1)
		textStroke(crack)
		local chip = text(f, "Event", "", SKY)
		chip.Position = UDim2.fromScale(0, 0.88)
		chip.Size = UDim2.fromScale(1, 0.08)
		textStroke(chip)
		-- The Havoc meter: a thin bar along the right edge of the screen
		local meterBack, meterFill = bar(g, "HavocMeter", CORAL)
		meterBack.AnchorPoint = Vector2.new(1, 0.5)
		meterBack.Position = UDim2.new(1, -12, 0.45, 0)
		meterBack.Size = UDim2.new(0, 16, 0.35, 0)
		meterFill.AnchorPoint = Vector2.new(0, 1)
		meterFill.Position = UDim2.fromScale(0, 1)
		local meterLabel = text(meterBack, "Label", "HAVOC", WHITE)
		meterLabel.AnchorPoint = Vector2.new(0.5, 1)
		meterLabel.Position = UDim2.new(0.5, 0, 0, -4)
		meterLabel.Size = UDim2.new(0, 70, 0, 18)
		textStroke(meterLabel, 1.5)
		labels = {
			timer = timer,
			score = score,
			scoreScale = scale,
			combo = combo,
			comboScale = comboScale,
			comboBack = comboBack,
			comboFill = comboFill,
			crack = crack,
			chip = chip,
			meterBack = meterBack,
			meterFill = meterFill,
			lastScore = 0,
			lastMultiplier = 1,
			lastBreaks = 0,
		}
		runFrame.Destroying:Connect(function()
			meterBack:Destroy()
		end)
	end
	local l = labels
	l.timer.Text = clock(view.timeLeft)
	l.timer.TextColor3 = if view.timeLeft <= 10 then CORAL else WHITE
	l.score.Text = HighwayHud.commas(view.score)
	if view.score > l.lastScore then
		l.scoreScale.Scale = 1.15
		TweenService:Create(l.scoreScale, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end
	l.lastScore = view.score
	local m = math.clamp(view.multiplier, 1, #COMBO_COLORS)
	l.combo.Text = "x" .. m
	l.combo.TextColor3 = COMBO_COLORS[m]
	if m > l.lastMultiplier then
		l.comboScale.Scale = 1.5
		TweenService:Create(l.comboScale, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end
	l.lastMultiplier = m
	l.comboBack.Visible = view.comboLeft > 0
	l.comboFill.Size = UDim2.fromScale(math.clamp(view.comboLeft, 0, 1), 1)
	l.comboFill.BackgroundColor3 = COMBO_COLORS[m]
	l.crack.Text = string.format("%s %d / %d", cfg.counterLabel, view.breaks, cfg.bones.total)
	l.crack.TextColor3 = if view.breaks > 0 then Color3.fromRGB(255, 240, 200) else WHITE
	l.meterBack.Visible = not view.tutorial
	l.meterFill.Size = UDim2.fromScale(1, math.clamp(view.meter, 0, 1))
	if view.tutorial then
		l.chip.Text = "PRACTICE ROAD"
	elseif view.event then
		l.chip.Text = view.event.name .. ": " .. view.event.line
	else
		l.chip.Text = ""
	end
end

---------------------------------------------------------------------------
-- Pops and banners
---------------------------------------------------------------------------

-- "+120" at a point in the world (or the screen centre), floating up and fading
function HighwayHud.pop(parent: Instance, value: string, color: Color3?, worldPoint: Vector3?, size: number?)
	local g = ensureGui(parent)
	local camera = Workspace.CurrentCamera
	local x, y = 0.5, 0.42
	if worldPoint and camera then
		local screen, onScreen = camera:WorldToViewportPoint(worldPoint)
		if onScreen then
			local viewport = camera.ViewportSize
			x = math.clamp(screen.X / viewport.X, 0.1, 0.9)
			y = math.clamp(screen.Y / viewport.Y, 0.15, 0.85)
		end
	end
	local label = text(g, "Pop", value, color or GOLD)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(x, y)
	label.SizeConstraint = Enum.SizeConstraint.RelativeYY
	label.Size = UDim2.fromScale(0.35, size or 0.055)
	textStroke(label, 2)
	local s = Instance.new("UIScale")
	s.Scale = 0.4
	s.Parent = label
	TweenService:Create(s, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	TweenService:Create(
		label,
		TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.fromScale(x, y - 0.08), TextTransparency = 1 }
	):Play()
	task.delay(0.95, function()
		label:Destroy()
	end)
end

-- A big banner across the middle (PILE-UP!, NEAR MISS, CRACK!)
function HighwayHud.banner(parent: Instance, title: string, line: string?, color: Color3?)
	local g = ensureGui(parent)
	local f = Instance.new("Frame")
	f.Name = "Banner"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.36)
	f.SizeConstraint = Enum.SizeConstraint.RelativeYY
	f.Size = UDim2.fromScale(1.1, 0.16)
	f.BackgroundTransparency = 1
	f.Parent = g
	local t = text(f, "Title", title, color or GOLD)
	t.Size = UDim2.fromScale(1, if line then 0.65 else 1)
	textStroke(t, 3)
	if line then
		local l = text(f, "Line", line, WHITE)
		l.Position = UDim2.fromScale(0, 0.65)
		l.Size = UDim2.fromScale(1, 0.35)
		textStroke(l, 2)
	end
	local s = Instance.new("UIScale")
	s.Scale = 0.3
	s.Parent = f
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	task.delay(1.1, function()
		for _, child in f:GetChildren() do
			if child:IsA("TextLabel") then
				TweenService:Create(child, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			end
		end
	end)
	task.delay(1.45, function()
		f:Destroy()
	end)
end

---------------------------------------------------------------------------
-- X-ray: a cartoon skeleton, the broken bones in red
---------------------------------------------------------------------------

-- Bone shapes on a 1 x 1 figure: { piece, bone index, x, y, width, height, rotation }
local SKELETON = {
	{ 1, 1, 0.5, 0.1, 0.16, 0.13, 0 }, -- noggin
	{ 2, 1, 0.5, 0.31, 0.22, 0.1, 0 }, -- ribs
	{ 2, 2, 0.5, 0.4, 0.04, 0.18, 0 }, -- spine
	{ 2, 3, 0.5, 0.52, 0.2, 0.06, 0 }, -- pelvis
	{ 3, 1, 0.33, 0.32, 0.04, 0.14, 20 }, -- left upper arm
	{ 3, 2, 0.28, 0.45, 0.04, 0.13, 10 },
	{ 4, 1, 0.67, 0.32, 0.04, 0.14, -20 },
	{ 4, 2, 0.72, 0.45, 0.04, 0.13, -10 },
	{ 5, 1, 0.43, 0.65, 0.05, 0.17, 5 }, -- left thigh
	{ 5, 2, 0.42, 0.84, 0.045, 0.17, 0 },
	{ 6, 1, 0.57, 0.65, 0.05, 0.17, -5 },
	{ 6, 2, 0.58, 0.84, 0.045, 0.17, 0 },
}

function HighwayHud.xray(parent: Instance, broken: { [number]: number }, duration: number)
	local g = ensureGui(parent)
	if xrayFrame then
		xrayFrame:Destroy()
	end
	local shade = Instance.new("Frame")
	shade.Name = "XRay"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(20, 40, 90)
	shade.BackgroundTransparency = 0.25
	shade.ZIndex = 20
	shade.Parent = g
	xrayFrame = shade
	local fig = Instance.new("Frame")
	fig.AnchorPoint = Vector2.new(0.5, 0.5)
	fig.Position = UDim2.fromScale(0.5, 0.5)
	fig.SizeConstraint = Enum.SizeConstraint.RelativeYY
	fig.Size = UDim2.fromScale(0.75, 0.75)
	fig.BackgroundTransparency = 1
	fig.ZIndex = 21
	fig.Parent = shade
	for _, b in SKELETON do
		local bone = Instance.new("Frame")
		bone.AnchorPoint = Vector2.new(0.5, 0.5)
		bone.Position = UDim2.fromScale(b[3], b[4])
		bone.Size = UDim2.fromScale(b[5], b[6])
		bone.Rotation = b[7]
		local isBroken = (broken[b[1]] or 0) >= b[2]
		bone.BackgroundColor3 = if isBroken then CORAL else Color3.fromRGB(240, 245, 255)
		bone.ZIndex = 22
		corner(bone, 0.5)
		bone.Parent = fig
		if isBroken then
			-- A crack: a dark zigzag across the middle
			local crack = Instance.new("Frame")
			crack.AnchorPoint = Vector2.new(0.5, 0.5)
			crack.Position = UDim2.fromScale(0.5, 0.5)
			crack.Size = UDim2.fromScale(1.4, 0.08)
			crack.Rotation = 30
			crack.BackgroundColor3 = INK
			crack.BorderSizePixel = 0
			crack.ZIndex = 23
			crack.Parent = bone
		end
	end
	task.delay(duration, function()
		if xrayFrame == shade then
			xrayFrame = nil
		end
		shade:Destroy()
	end)
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

export type ResultView = {
	title: string,
	score: number,
	bones: number,
	bestMultiplier: number,
	pileups: number,
	coins: number,
	capped: boolean,
	flagged: boolean,
	best: number,
	newBest: boolean,
	havoc: number,
	target: number,
	chestLine: string?,
	tutorial: boolean,
	line: string?,
}
export type ResultActions = {
	onAgain: () -> (),
	onLeave: () -> (),
	onBoard: () -> (),
	onClip: (() -> ())?, -- nil: no clip this run
	onChallenge: (() -> ())?, -- Beat my score (nil: not offered)
}

function HighwayHud.hideResults()
	if resultsFrame then
		resultsFrame:Destroy()
		resultsFrame = nil
	end
end

function HighwayHud.resultsOpen(): boolean
	return resultsFrame ~= nil
end

-- Hide the card while the clip plays, then bring it back
function HighwayHud.setResultsVisible(visible: boolean)
	if resultsFrame then
		resultsFrame.Visible = visible
	end
end

-- A small panel over the clip: SHARE (when a capture is ready) and DONE
function HighwayHud.clipBar(parent: Instance, onShare: (() -> ())?, onDone: (() -> ())?)
	local g = ensureGui(parent)
	local old = g:FindFirstChild("ClipBar")
	if old then
		old:Destroy()
	end
	if onShare == nil and onDone == nil then
		return
	end
	local f = Instance.new("Frame")
	f.Name = "ClipBar"
	f.AnchorPoint = Vector2.new(0.5, 1)
	f.Position = UDim2.fromScale(0.5, 0.95)
	f.SizeConstraint = Enum.SizeConstraint.RelativeYY
	f.Size = UDim2.fromScale(0.8, 0.1)
	f.BackgroundTransparency = 1
	f.Parent = g
	local label = text(f, "Label", "BEST 10 SECONDS", WHITE)
	label.Size = UDim2.fromScale(0.4, 1)
	textStroke(label, 2)
	if onShare then
		local share = button(f, "Share", "SHARE", GOLD)
		share.Position = UDim2.fromScale(0.42, 0)
		share.Size = UDim2.fromScale(0.3, 1)
		share.Activated:Connect(onShare)
	end
	if onDone then
		local done = button(f, "Done", "DONE", WHITE)
		done.Position = UDim2.fromScale(0.74, 0)
		done.Size = UDim2.fromScale(0.26, 1)
		done.Activated:Connect(onDone)
	end
end

function HighwayHud.showResults(parent: Instance, view: ResultView, actions: ResultActions)
	HighwayHud.hideResults()
	local g = ensureGui(parent)
	local shade = Instance.new("Frame")
	shade.Name = "Results"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.5
	shade.Active = true
	shade.Parent = g
	resultsFrame = shade
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.Size = UDim2.fromScale(1.15, 0.86)
	card.BackgroundColor3 = PANEL
	corner(card, 0.05)
	stroke(card, 4)
	card.Parent = shade
	local title = text(card, "Title", view.title, INK)
	title.Position = UDim2.fromScale(0.05, 0.03)
	title.Size = UDim2.fromScale(0.9, 0.09)
	local score = text(card, "Score", HighwayHud.commas(view.score), GOLD)
	score.Position = UDim2.fromScale(0.05, 0.12)
	score.Size = UDim2.fromScale(0.9, 0.15)
	textStroke(score, 3)
	local best = text(
		card,
		"Best",
		if view.newBest then "NEW PERSONAL BEST!" else "Personal best " .. HighwayHud.commas(view.best),
		if view.newBest then GREEN else GREY
	)
	best.Position = UDim2.fromScale(0.05, 0.27)
	best.Size = UDim2.fromScale(0.9, 0.06)
	-- Four stat tiles
	local stats = {
		{ "BONES", string.format("%d / %d", view.bones, cfg.bones.total) },
		{ "BEST COMBO", "x" .. view.bestMultiplier },
		{ "PILE-UPS", tostring(view.pileups) },
		{ "COINS", "+" .. view.coins },
	}
	for i, stat in stats do
		local tile = Instance.new("Frame")
		tile.Name = stat[1]
		tile.Position = UDim2.fromScale(0.05 + (i - 1) * 0.228, 0.35)
		tile.Size = UDim2.fromScale(0.21, 0.17)
		tile.BackgroundColor3 = WHITE
		corner(tile, 0.15)
		stroke(tile, 2)
		tile.Parent = card
		local v = text(tile, "Value", stat[2], INK)
		v.Position = UDim2.fromScale(0.05, 0.08)
		v.Size = UDim2.fromScale(0.9, 0.55)
		local k = text(tile, "Label", stat[1], GREY)
		k.Position = UDim2.fromScale(0.05, 0.64)
		k.Size = UDim2.fromScale(0.9, 0.28)
	end
	-- Notes: capped coins, a flagged run, the chest
	local notes = {}
	if view.line then
		table.insert(notes, view.line)
	end
	if view.flagged then
		table.insert(notes, "Some hits didn't add up, so this run pays half and skips the boards.")
	elseif view.capped then
		table.insert(notes, "Daily Highway coin cap reached. Come back tomorrow for more!")
	end
	if view.chestLine then
		table.insert(notes, view.chestLine)
	end
	local note = text(card, "Note", table.concat(notes, "  "), INK)
	note.Position = UDim2.fromScale(0.05, 0.53)
	note.Size = UDim2.fromScale(0.9, 0.05)
	-- The daily Havoc target
	if not view.tutorial then
		local targetLine = text(
			card,
			"TargetLine",
			string.format(
				"Daily Havoc: %s / %s",
				HighwayHud.commas(math.min(view.havoc, view.target)),
				HighwayHud.commas(view.target)
			),
			INK
		)
		targetLine.Position = UDim2.fromScale(0.05, 0.585)
		targetLine.Size = UDim2.fromScale(0.9, 0.05)
		local back, fill = bar(card, "Target", GREEN)
		back.Position = UDim2.fromScale(0.1, 0.64)
		back.Size = UDim2.fromScale(0.8, 0.035)
		fill.Size = UDim2.fromScale(math.clamp(view.havoc / math.max(1, view.target), 0, 1), 1)
	end
	-- Clip and Beat my score
	if actions.onClip then
		local clip = button(card, "Clip", "▶ CLIP", Color3.fromRGB(255, 180, 220))
		clip.Position = UDim2.fromScale(0.05, 0.69)
		clip.Size = UDim2.fromScale(0.42, 0.09)
		clip.Activated:Connect(actions.onClip)
	end
	if actions.onChallenge then
		local beat = button(card, "Beat", "BEAT MY SCORE", Color3.fromRGB(190, 230, 255))
		beat.Position = UDim2.fromScale(0.5, 0.69)
		beat.Size = UDim2.fromScale(0.45, 0.09)
		beat.Activated:Connect(actions.onChallenge)
	end
	-- Buttons
	local again = button(card, "Again", "RIDE AGAIN", GREY)
	again.Position = UDim2.fromScale(0.05, 0.81)
	again.Size = UDim2.fromScale(0.42, 0.14)
	local leave = button(card, "Leave", "LEAVE", WHITE)
	leave.Position = UDim2.fromScale(0.5, 0.81)
	leave.Size = UDim2.fromScale(0.24, 0.14)
	local top = button(card, "Top", "TOP", SKY)
	top.Position = UDim2.fromScale(0.76, 0.81)
	top.Size = UDim2.fromScale(0.19, 0.14)
	local armed = false
	task.delay(cfg.Run.resultsSkip, function()
		armed = true
		again.BackgroundColor3 = GREEN
	end)
	again.Activated:Connect(function()
		if armed then
			HighwayHud.hideResults()
			actions.onAgain()
		end
	end)
	leave.Activated:Connect(actions.onLeave)
	top.Activated:Connect(actions.onBoard)
end

---------------------------------------------------------------------------
-- Boards
---------------------------------------------------------------------------

export type BoardRow = { rank: number?, name: string, value: number, me: boolean?, friend: boolean? }
export type BoardView = {
	board: string, -- "score" or "bones"
	tab: string, -- "friends", "daily", "weekly"
	rows: { BoardRow },
	mine: BoardRow?,
	loading: boolean,
	eventName: string?,
	onBoard: (board: string) -> (),
	onTab: (tab: string) -> (),
}

local BOARDS = { { "score", "DESTRUCTION" }, { "bones", "BONE-BREAKS" } }
local TABS = { { "friends", "FRIENDS" }, { "daily", "TODAY" }, { "weekly", "THIS WEEK" } }

local function valueText(board: string, value: number): string
	if board == "bones" then
		local breaks = value // 1e6
		return string.format("%d bones, %s", breaks, HighwayHud.commas(value - breaks * 1e6))
	end
	return HighwayHud.commas(value)
end

local function boardRow(parent: Instance, board: string, row: BoardRow, order: number, pinned: boolean)
	local f = Instance.new("Frame")
	f.Name = "Row"
	f.LayoutOrder = order
	f.Size = UDim2.new(1, 0, 0, 40)
	f.BackgroundColor3 = if row.me then Color3.fromRGB(255, 240, 180) else WHITE
	corner(f, 0.25)
	stroke(f, if pinned then 3 else 1)
	f.Parent = parent
	local rank = text(f, "Rank", if row.rank then "#" .. row.rank else "-", INK)
	rank.Position = UDim2.fromScale(0.02, 0.15)
	rank.Size = UDim2.fromScale(0.12, 0.7)
	local name = text(f, "Name", row.name, INK)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Position = UDim2.fromScale(0.16, 0.15)
	name.Size = UDim2.fromScale(0.46, 0.7)
	local v = text(f, "Value", valueText(board, row.value), INK)
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Position = UDim2.fromScale(0.62, 0.15)
	v.Size = UDim2.fromScale(0.35, 0.7)
end

function HighwayHud.closeBoard()
	if boardFrame then
		boardFrame:Destroy()
		boardFrame = nil
	end
end

function HighwayHud.boardOpen(): boolean
	return boardFrame ~= nil
end

function HighwayHud.openBoard(parent: Instance, view: BoardView, onClose: () -> ())
	HighwayHud.closeBoard()
	local g = ensureGui(parent)
	local shade = Instance.new("Frame")
	shade.Name = "Board"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.Active = true
	shade.ZIndex = 5
	shade.Parent = g
	boardFrame = shade
	local p = Instance.new("Frame")
	p.Name = "Panel"
	p.AnchorPoint = Vector2.new(0.5, 0.5)
	p.Position = UDim2.fromScale(0.5, 0.5)
	p.Size = UDim2.fromScale(0.94, 0.9)
	p.BackgroundColor3 = PANEL
	corner(p, 0.04)
	stroke(p, 4)
	p.Parent = shade
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.75
	aspect.Parent = p
	local title = text(
		p,
		"Title",
		if view.tab == "daily" and view.eventName then "TOP TODAY: " .. view.eventName else "SUNNY PASS TOP",
		INK
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromScale(0.03, 0.025)
	title.Size = UDim2.fromScale(0.6, 0.08)
	local close = button(p, "Close", "✕", WHITE)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.975, 0.02)
	close.Size = UDim2.fromScale(0.07, 0.1)
	close.Activated:Connect(function()
		HighwayHud.closeBoard()
		onClose()
	end)
	local function row(y: number, items: { { string } }, current: string, onPick: (string) -> ())
		local strip = Instance.new("Frame")
		strip.BackgroundTransparency = 1
		strip.Position = UDim2.fromScale(0.03, y)
		strip.Size = UDim2.fromScale(0.94, 0.09)
		strip.Parent = p
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.Padding = UDim.new(0.02, 0)
		list.Parent = strip
		for _, item in items do
			local b = button(strip, item[1], item[2], if item[1] == current then GOLD else WHITE)
			b.Size = UDim2.fromScale(if #items == 2 then 0.35 else 0.3, 1)
			b.Activated:Connect(function()
				onPick(item[1])
			end)
		end
	end
	row(0.12, BOARDS, view.board, view.onBoard)
	row(0.22, TABS, view.tab, view.onTab)
	local list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromScale(0.03, 0.33)
	list.Size = UDim2.fromScale(0.94, 0.5)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 6
	list.Parent = p
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	if view.loading then
		local wait = text(list, "Loading", "Loading scores...", GREY)
		wait.Size = UDim2.new(1, 0, 0, 40)
	elseif #view.rows == 0 then
		local none = text(
			list,
			"None",
			if view.tab == "friends"
				then "No friends on this board yet. Invite some!"
				else "No scores yet. Be the first!",
			GREY
		)
		none.Size = UDim2.new(1, 0, 0, 40)
	end
	for index, r in view.rows do
		boardRow(list, view.board, r, index, false)
	end
	local pinned = Instance.new("Frame")
	pinned.Name = "Mine"
	pinned.BackgroundTransparency = 1
	pinned.Position = UDim2.fromScale(0.03, 0.85)
	pinned.Size = UDim2.fromScale(0.94, 0.12)
	pinned.Parent = p
	local pinnedList = Instance.new("UIListLayout")
	pinnedList.Parent = pinned
	if view.mine then
		boardRow(pinned, view.board, view.mine, 1, true)
	else
		local none = text(pinned, "NoScore", "Ride a run to get on this board!", GREY)
		none.Size = UDim2.fromScale(1, 0.8)
	end
end

function HighwayHud.destroy()
	if gui then
		gui:Destroy()
		gui = nil
	end
	runFrame, resultsFrame, boardFrame, xrayFrame = nil, nil, nil, nil
end

return HighwayHud
