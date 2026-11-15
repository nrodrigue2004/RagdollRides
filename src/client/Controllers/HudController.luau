-- HudController: the milestone 1 in-run HUD (spec: Screens and UI > Tracks screens > In-run HUD).
-- Big-button, icon-first, phone-first: every tap target is at least 64 px at 1080p, scaled by the control
-- size setting (80% to 140%), with a left-handed (mirrored) layout. Touch controls: GAS, BRAKE, steer
-- left/right, JUMP (vehicles with a hop), LEAN forward/back, RESET, FLIP when needed, RESPAWN while thrown.
-- Keyboard and gamepad players see the same RESET / FLIP / RESPAWN prompts with their key.
-- The timer, ghost split and checkpoint count join this HUD in milestone 2.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local LocalPlayer = Players.LocalPlayer

local HudController = {}

local controllers: any = nil
local gui: ScreenGui
local touchFrame: Frame
local speedLabel: TextLabel
local flipButton: TextButton
local resetButton: TextButton
local respawnButton: TextButton
local jumpButton: TextButton
local flailCatcher: TextButton
local fadeFrame: Frame
local hintLabel: TextLabel
local silhouette: Frame
local zoneFrames: { Frame } = {}
local fireIcon: TextLabel
local wreckedLabel: TextLabel
local replayFrame: Frame
local onFire = false
local wrecked = false
local layout = { controlSize = 1.0, leftHanded = false }
local heldInputs: { [InputObject]: string } = {}

local FONT = Enum.Font.FredokaOne
local COLORS = {
	gas = Color3.fromRGB(80, 210, 110),
	brake = Color3.fromRGB(255, 110, 100),
	steer = Color3.fromRGB(255, 255, 255),
	lean = Color3.fromRGB(150, 190, 255),
	jump = Color3.fromRGB(255, 200, 60),
	utility = Color3.fromRGB(255, 255, 255),
	flip = Color3.fromRGB(255, 170, 50),
	text = Color3.fromRGB(35, 35, 45),
}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromRGB(35, 35, 45)
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

-- A square button sized as a fraction of screen height, never under the 64 px minimum.
local function makeButton(
	name: string,
	text: string,
	heightFraction: number,
	color: Color3,
	parent: Instance
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = text
	button.Font = FONT
	button.TextScaled = true
	button.TextColor3 = COLORS.text
	button.BackgroundColor3 = color
	button.BackgroundTransparency = 0.08
	button.AutoButtonColor = true
	button.SizeConstraint = Enum.SizeConstraint.RelativeYY
	button.Size = UDim2.fromScale(heightFraction * layout.controlSize, heightFraction * layout.controlSize)
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(Config.UI.minTapTarget, Config.UI.minTapTarget)
	minimum.Parent = button
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.22, 0)
	padding.PaddingBottom = UDim.new(0.22, 0)
	padding.PaddingLeft = UDim.new(0.12, 0)
	padding.PaddingRight = UDim.new(0.12, 0)
	padding.Parent = button
	corner(button, 0.5)
	stroke(button)
	button.Parent = parent
	return button
end

local function bindHold(button: TextButton, action: string)
	button.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			heldInputs[input] = action
			controllers.Input.setTouch(action, true)
			button.BackgroundTransparency = 0.35
		end
	end)
	button.InputEnded:Connect(function(input)
		if heldInputs[input] then
			heldInputs[input] = nil
			controllers.Input.setTouch(action, false)
			button.BackgroundTransparency = 0.08
		end
	end)
end

local function bindTap(button: TextButton, action: string)
	button.Activated:Connect(function()
		controllers.Input.tap(action)
	end)
end

-- Places a control from the bottom corner. x and y are fractions of screen height from the edge, so the
-- layout keeps its shape on any aspect ratio. side is "left" or "right" (mirrored when left-handed).
local function place(button: GuiObject, side: string, x: number, y: number)
	local mirrored = if layout.leftHanded then (if side == "left" then "right" else "left") else side
	if mirrored == "left" then
		button.AnchorPoint = Vector2.new(0, 1)
		button.Position = UDim2.new(0, 0, 1, 0)
	else
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.new(1, 0, 1, 0)
	end
	button:SetAttribute("Side", mirrored)
	button:SetAttribute("OffsetX", x)
	button:SetAttribute("OffsetY", y)
end

local function relayout()
	local viewport = workspace.CurrentCamera.ViewportSize
	local h = viewport.Y
	for _, child in touchFrame:GetChildren() do
		if child:IsA("GuiObject") and child:GetAttribute("OffsetX") then
			local x = (child:GetAttribute("OffsetX") :: number) * h * layout.controlSize
			local y = (child:GetAttribute("OffsetY") :: number) * h * layout.controlSize
			if child:GetAttribute("Side") == "left" then
				child.Position = UDim2.new(0, x, 1, -y)
			else
				child.Position = UDim2.new(1, -x, 1, -y)
			end
		end
	end
end

local function buildTouchControls()
	touchFrame = Instance.new("Frame")
	touchFrame.Name = "TouchControls"
	touchFrame.BackgroundTransparency = 1
	touchFrame.Size = UDim2.fromScale(1, 1)
	touchFrame.Visible = UserInputService.TouchEnabled
	touchFrame.Parent = gui

	local steerLeft = makeButton("SteerLeft", "◀", 0.24, COLORS.steer, touchFrame)
	place(steerLeft, "left", 0.05, 0.05)
	bindHold(steerLeft, "left")
	local steerRight = makeButton("SteerRight", "▶", 0.24, COLORS.steer, touchFrame)
	place(steerRight, "left", 0.33, 0.05)
	bindHold(steerRight, "right")

	local leanBack = makeButton("LeanBack", "↺", 0.16, COLORS.lean, touchFrame)
	place(leanBack, "left", 0.06, 0.34)
	bindHold(leanBack, "leanBack")
	local leanForward = makeButton("LeanForward", "↻", 0.16, COLORS.lean, touchFrame)
	place(leanForward, "left", 0.25, 0.34)
	bindHold(leanForward, "leanForward")

	local gas = makeButton("Gas", "GAS", 0.28, COLORS.gas, touchFrame)
	place(gas, "right", 0.05, 0.05)
	bindHold(gas, "gas")
	local brake = makeButton("Brake", "BRAKE", 0.2, COLORS.brake, touchFrame)
	place(brake, "right", 0.37, 0.05)
	bindHold(brake, "brake")

	jumpButton = makeButton("Jump", "JUMP", 0.17, COLORS.jump, touchFrame)
	place(jumpButton, "right", 0.1, 0.37)
	bindTap(jumpButton, "jump")

	relayout()
end

local function buildPrompts()
	resetButton = makeButton("Reset", "RESET", 0.11, COLORS.utility, gui)
	resetButton.AnchorPoint = Vector2.new(1, 0)
	resetButton.Position = UDim2.new(1, -16, 0, 16)
	resetButton.Activated:Connect(function()
		controllers.Input.tap("reset")
	end)

	flipButton = makeButton("Flip", "FLIP", 0.2, COLORS.flip, gui)
	flipButton.AnchorPoint = Vector2.new(0.5, 0.5)
	flipButton.Position = UDim2.fromScale(0.5, 0.42)
	flipButton.Visible = false
	flipButton.Activated:Connect(function()
		controllers.Input.tap("flip")
	end)

	-- While thrown, a tap anywhere flails the rider (fun, no gameplay effect)
	flailCatcher = Instance.new("TextButton")
	flailCatcher.Name = "FlailCatcher"
	flailCatcher.Text = ""
	flailCatcher.BackgroundTransparency = 1
	flailCatcher.Size = UDim2.fromScale(1, 1)
	flailCatcher.Visible = false
	flailCatcher.ZIndex = 0
	flailCatcher.Parent = gui
	flailCatcher.Activated:Connect(function()
		controllers.Ragdoll.flail()
	end)

	respawnButton = makeButton("Respawn", "RESPAWN", 0.2, COLORS.gas, gui)
	respawnButton.AnchorPoint = Vector2.new(0.5, 1)
	respawnButton.Position = UDim2.new(0.5, 0, 1, -24)
	respawnButton.Visible = false
	respawnButton.ZIndex = 2
	respawnButton.Activated:Connect(function()
		controllers.Input.tap("respawn")
	end)
end

local function buildSpeedometer()
	speedLabel = Instance.new("TextLabel")
	speedLabel.Name = "Speed"
	speedLabel.BackgroundTransparency = 1
	speedLabel.AnchorPoint = Vector2.new(0.5, 1)
	speedLabel.Position = UDim2.new(0.5, 0, 1, -12)
	speedLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	speedLabel.Size = UDim2.fromScale(0.3, 0.09)
	speedLabel.Font = FONT
	speedLabel.TextScaled = true
	speedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	speedLabel.Text = "0 mph"
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromRGB(35, 35, 45)
	s.Parent = speedLabel
	speedLabel.Parent = gui
end

local function buildHints()
	hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "KeyHints"
	hintLabel.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
	hintLabel.BackgroundTransparency = 0.35
	hintLabel.AnchorPoint = Vector2.new(0, 1)
	hintLabel.Position = UDim2.new(0, 16, 1, -16)
	hintLabel.Size = UDim2.fromOffset(440, 110)
	hintLabel.Font = Enum.Font.GothamMedium
	hintLabel.TextSize = 18
	hintLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Left
	hintLabel.TextWrapped = true
	hintLabel.Text =
		"  W/S gas and brake   A/D steer   Space jump\n  Q/E lean in the air   Shift handbrake\n  R reset or respawn   F flip"
	corner(hintLabel, 0.12)
	hintLabel.Visible = not UserInputService.TouchEnabled
	hintLabel.Parent = gui
	task.delay(15, function()
		if hintLabel then
			TweenService
				:Create(hintLabel, TweenInfo.new(1), { TextTransparency = 1, BackgroundTransparency = 1 })
				:Play()
		end
	end)
end

-- Damage silhouette: the car from above, each zone coloured by its look (spec: Brawl and Highway HUDs;
-- shown on the test track too). Front at the top.
local LOOK_COLORS = {
	[0] = Color3.fromRGB(120, 220, 120),
	[1] = Color3.fromRGB(255, 215, 80),
	[2] = Color3.fromRGB(255, 130, 60),
	[3] = Color3.fromRGB(70, 70, 80),
}
-- zone -> position and size as fractions of the silhouette (x, y, w, h)
local ZONE_LAYOUT = {
	{ 0.25, 0.04, 0.5, 0.2 }, -- front
	{ 0.25, 0.76, 0.5, 0.2 }, -- rear
	{ 0.08, 0.26, 0.15, 0.48 }, -- left
	{ 0.77, 0.26, 0.15, 0.48 }, -- right
	{ 0.27, 0.3, 0.46, 0.4 }, -- roof
	{ 0.0, 0.08, 0.16, 0.16 }, -- FL
	{ 0.84, 0.08, 0.16, 0.16 }, -- FR
	{ 0.0, 0.76, 0.16, 0.16 }, -- RL
	{ 0.84, 0.76, 0.16, 0.16 }, -- RR
}

local function buildDamage()
	silhouette = Instance.new("Frame")
	silhouette.Name = "DamageSilhouette"
	silhouette.BackgroundTransparency = 1
	silhouette.SizeConstraint = Enum.SizeConstraint.RelativeYY
	silhouette.Size = UDim2.fromScale(0.08, 0.13)
	silhouette.AnchorPoint = Vector2.new(0, 0)
	silhouette.Position = UDim2.new(0, 16, 0, 96)
	silhouette.Parent = gui
	for index, rect in ZONE_LAYOUT do
		local zone = Instance.new("Frame")
		zone.Name = "Zone" .. index
		zone.Position = UDim2.fromScale(rect[1], rect[2])
		zone.Size = UDim2.fromScale(rect[3], rect[4])
		zone.BackgroundColor3 = LOOK_COLORS[0]
		zone.BorderSizePixel = 0
		corner(zone, 0.3)
		local s = Instance.new("UIStroke")
		s.Thickness = 2
		s.Color = Color3.fromRGB(35, 35, 45)
		s.Parent = zone
		zone.Parent = silhouette
		zoneFrames[index] = zone
	end

	fireIcon = Instance.new("TextLabel")
	fireIcon.Name = "FireWarning"
	fireIcon.Text = "!"
	fireIcon.Font = FONT
	fireIcon.TextScaled = true
	fireIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
	fireIcon.BackgroundColor3 = Color3.fromRGB(255, 90, 40)
	fireIcon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	fireIcon.Size = UDim2.fromScale(0.5, 0.5)
	fireIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	fireIcon.Position = UDim2.fromScale(1.6, 0.3) -- just right of the silhouette
	fireIcon.Visible = false
	fireIcon.ZIndex = 3
	corner(fireIcon, 0.5)
	stroke(fireIcon)
	fireIcon.Parent = silhouette

	wreckedLabel = Instance.new("TextLabel")
	wreckedLabel.Name = "Wrecked"
	wreckedLabel.Text = "WRECKED"
	wreckedLabel.Font = FONT
	wreckedLabel.TextScaled = true
	wreckedLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	wreckedLabel.BackgroundTransparency = 1
	wreckedLabel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	wreckedLabel.Size = UDim2.fromScale(0.6, 0.1)
	wreckedLabel.AnchorPoint = Vector2.new(0.5, 0)
	wreckedLabel.Position = UDim2.new(0.5, 0, 0, 24)
	wreckedLabel.Visible = false
	local ws = Instance.new("UIStroke")
	ws.Thickness = 4
	ws.Color = Color3.fromRGB(35, 35, 45)
	ws.Parent = wreckedLabel
	wreckedLabel.Parent = gui

	-- Crash replay: letterbox bars and a REPLAY tag
	replayFrame = Instance.new("Frame")
	replayFrame.Name = "Replay"
	replayFrame.BackgroundTransparency = 1
	replayFrame.Size = UDim2.fromScale(1, 1)
	replayFrame.Visible = false
	replayFrame.ZIndex = 5
	replayFrame.Parent = gui
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.Size = UDim2.fromScale(1, 0.09)
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.ZIndex = 5
		bar.Parent = replayFrame
	end
	local tag = Instance.new("TextLabel")
	tag.Text = "REPLAY"
	tag.Font = FONT
	tag.TextScaled = true
	tag.TextColor3 = Color3.fromRGB(255, 220, 80)
	tag.BackgroundTransparency = 1
	tag.Size = UDim2.fromScale(0.3, 0.06)
	tag.AnchorPoint = Vector2.new(0.5, 0.5)
	tag.Position = UDim2.fromScale(0.5, 0.045)
	tag.ZIndex = 6
	tag.Parent = replayFrame
end

local function showDamage(fractions: { number }, flags: number)
	local cfg = Config.Damage
	for index, zone in zoneFrames do
		local fraction = fractions[index] or 1
		local look = if fraction <= 0
			then 3
			elseif fraction < cfg.crushedBelow then 2
			elseif fraction < cfg.dentedBelow then 1
			else 0
		zone.BackgroundColor3 = LOOK_COLORS[look]
		zone.BackgroundTransparency = if look == 3 and index >= 6 then 0.7 else 0
	end
	onFire = bit32.band(flags, 1) ~= 0
end

function HudController.setReplay(on: boolean)
	if replayFrame then
		replayFrame.Visible = on
	end
end

local function buildFade()
	fadeFrame = Instance.new("Frame")
	fadeFrame.Name = "Fade"
	fadeFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	fadeFrame.BackgroundTransparency = 1
	fadeFrame.Size = UDim2.fromScale(1, 1)
	fadeFrame.ZIndex = 10
	fadeFrame.Active = false
	fadeFrame.Parent = gui
end

-- Quick fade out and back in around a reset (half the time each way)
function HudController.fade(duration: number)
	if not fadeFrame then
		return
	end
	local half = duration / 2
	local out = TweenService:Create(fadeFrame, TweenInfo.new(half), { BackgroundTransparency = 0.15 })
	out:Play()
	out.Completed:Once(function()
		TweenService:Create(fadeFrame, TweenInfo.new(half), { BackgroundTransparency = 1 }):Play()
	end)
end

function HudController.setLayout(controlSize: number, leftHanded: boolean)
	layout.controlSize = math.clamp(controlSize, Config.UI.controlSizeMin, Config.UI.controlSizeMax)
	layout.leftHanded = leftHanded
	if touchFrame then
		touchFrame:Destroy()
	end
	buildTouchControls()
end

local pulseClock = 0

local function update(dt: number)
	local vehicle = controllers.Vehicle.getState()
	local ragdolled = controllers.Ragdoll.isRagdolled()
	if vehicle then
		local speed = math.abs(vehicle.forwardSpeed)
		speedLabel.Text = string.format("%d mph", math.floor(speed * Config.World.mphPerStudPerSecond + 0.5))
		jumpButton.Visible = vehicle.def.hopSpeed > 0 and not ragdolled
		local showFlip = vehicle.flipAvailable and not ragdolled
		flipButton.Visible = showFlip
		if showFlip then
			pulseClock += dt
			local pulse = 1 + 0.08 * math.sin(pulseClock * 8)
			flipButton.Size =
				UDim2.fromScale(0.2 * pulse * layout.controlSize, 0.2 * pulse * layout.controlSize)
			flipButton.Text = if controllers.Input.lastDevice() == "keyboard" then "FLIP (F)" else "FLIP"
		end
	end
	local canRespawn = controllers.Ragdoll.canRespawn()
	respawnButton.Visible = canRespawn
	if canRespawn then
		respawnButton.Text = if controllers.Input.lastDevice() == "keyboard" then "RESPAWN (R)" else "RESPAWN"
	end
	flailCatcher.Visible = ragdolled
	touchFrame.Visible = UserInputService.TouchEnabled and not ragdolled
	resetButton.Visible = not ragdolled

	-- Fire warning pulse beside the damage silhouette; WRECKED pulses RESET
	local t = os.clock()
	fireIcon.Visible = onFire
	if onFire then
		local pulse = 0.5 * (1 + 0.15 * math.sin(t * 12))
		fireIcon.Size = UDim2.fromScale(pulse, pulse)
	end
	local showWrecked = wrecked and not ragdolled
	wreckedLabel.Visible = showWrecked
	if showWrecked then
		local pulse = 0.11 * (1 + 0.1 * math.sin(t * 8)) * layout.controlSize
		resetButton.Size = UDim2.fromScale(pulse, pulse)
	else
		resetButton.Size = UDim2.fromScale(0.11 * layout.controlSize, 0.11 * layout.controlSize)
	end
end

function HudController.init(all)
	controllers = all
end

function HudController.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "RagdollRidesHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	buildSpeedometer()
	buildTouchControls()
	buildPrompts()
	buildHints()
	buildDamage()
	buildFade()

	if controllers.Damage then
		controllers.Damage.Changed:Connect(showDamage)
		controllers.Damage.Wrecked:Connect(function(value: boolean)
			wrecked = value
		end)
	end

	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
	-- A finger that slides off a held button still releases it
	UserInputService.InputEnded:Connect(function(input)
		local action = heldInputs[input]
		if action then
			heldInputs[input] = nil
			controllers.Input.setTouch(action, false)
		end
	end)
	RunService.RenderStepped:Connect(update)
end

return HudController
