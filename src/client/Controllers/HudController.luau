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
	buildFade()

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
