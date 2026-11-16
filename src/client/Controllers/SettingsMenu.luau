-- SettingsMenu: the settings cog (spec: Data model > settings; Accessibility). Every option is a big
-- choice button or a -/+ stepper (no sliders, nothing to type). Changes apply at once and are sent with
-- Settings.Save at most once per 5 s (the server checks and clamps them: ProfileSchema.sanitizeSettings).
-- Saved settings arrive with the profile and are applied on load.
-- "Fewer flashes" and "Effects" are saved now; the VFX pass reads them (notes/Tasks.md).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Mix = require(script.Parent.Parent.Fx.Mix)

local LocalPlayer = Players.LocalPlayer

local SettingsMenu = {}

local controllers: any = nil
local current: { [string]: any } = table.clone(Config.Settings.defaults)
local pending: { [string]: any } = {}
local lastSend = -math.huge
local applied: { [string]: any } = {}
local panel: Frame? = nil
local assistForced: string? = nil -- a map forcing steering assist (TracksClient)

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local PANEL = Color3.fromRGB(255, 250, 240)
local ON = Color3.fromRGB(80, 210, 110)
local OFF = Color3.fromRGB(235, 232, 240)

local ASSIST = { off = "Off", low = "Low", high = "High" }

-- Rows: key, label, kind ("choice" with options {value, label}, or "step" with step and format)
local ROWS = {
	{ key = "controlSize", label = "Button size", kind = "step", step = 0.1, percent = true },
	{
		key = "layout",
		label = "Controls",
		kind = "choice",
		options = { { "default", "Right hand" }, { "lefthanded", "Left hand" } },
	},
	{
		key = "steerAssist",
		label = "Steering help",
		kind = "choice",
		options = { { "off", "Off" }, { "low", "Low" }, { "high", "High" } },
	},
	{
		key = "shake",
		label = "Camera shake",
		kind = "choice",
		options = { { true, "On" }, { false, "Off" } },
	},
	{
		key = "reducedMotion",
		label = "Reduced motion",
		kind = "choice",
		options = { { false, "Off" }, { true, "On" } },
	},
	{
		key = "reducedFlash",
		label = "Fewer flashes",
		kind = "choice",
		options = { { false, "Off" }, { true, "On" } },
	},
	{
		key = "dents",
		label = "Dents",
		kind = "choice",
		options = { { "full", "Full" }, { "panels", "Panels" } },
	},
	{
		key = "graphics",
		label = "Effects",
		kind = "choice",
		options = { { "auto", "Auto" }, { "low", "Low" }, { "medium", "Mid" }, { "high", "High" } },
	},
	{ key = "music", label = "Music", kind = "step", step = 0.1, percent = true },
	{ key = "sfx", label = "Sounds", kind = "step", step = 0.1, percent = true },
}

---------------------------------------------------------------------------
-- Apply
---------------------------------------------------------------------------

local function musicGroup(): SoundGroup
	return Mix.group("Music")
end

local function applySteerAssist()
	local level = assistForced or ASSIST[current.steerAssist] or "High"
	controllers.Vehicle.setSteerAssist(level)
end

-- Effects Low: the screen effects that cost the most on phones (bloom, sun rays, colour grade) go off on
-- this device. Auto keeps them unless the device class is a phone with a small screen.
local function applyEffects(level: string)
	local Lighting = game:GetService("Lighting")
	local camera = workspace.CurrentCamera
	local small = camera ~= nil and math.min(camera.ViewportSize.X, camera.ViewportSize.Y) < 500
	local on = level == "high" or level == "medium" or (level == "auto" and not small)
	for _, name in { "Bloom" } do
		local effect = Lighting:FindFirstChild(name)
		if effect and effect:IsA("PostEffect") then
			effect.Enabled = on
		end
	end
	local grade = Lighting:FindFirstChild("Grade")
	if grade and grade:IsA("PostEffect") then
		grade.Enabled = level ~= "low"
	end
end

local function apply()
	local s = current
	applyEffects(s.graphics or "auto")
	if applied.controlSize ~= s.controlSize or applied.layout ~= s.layout then
		controllers.Hud.setLayout(s.controlSize, s.layout == "lefthanded")
	end
	applySteerAssist()
	controllers.Juice.setShake(s.shake)
	controllers.Camera.setReducedMotion(s.reducedMotion or not s.shake)
	if controllers.Damage then
		controllers.Damage.setDents(if s.dents == "full" then "Full" else "PanelsOnly")
	end
	controllers.Juice.setVolume(s.sfx)
	musicGroup().Volume = s.music
	applied = table.clone(s)
end

-- A map can force steering assist (the first 2 tracks for a first-time player); nil gives it back
function SettingsMenu.forceSteerAssist(level: string?)
	assistForced = level
	applySteerAssist()
end

function SettingsMenu.get(key: string): any
	return current[key]
end

local function set(key: string, value: any)
	local range = Config.Settings.ranges[key]
	if range and type(value) == "number" then
		value = math.clamp(math.floor(value * 10 + 0.5) / 10, range[1], range[2])
	end
	if current[key] == value then
		return
	end
	current[key] = value
	pending[key] = value
	apply()
end

local function flush()
	if next(pending) == nil then
		return
	end
	lastSend = os.clock()
	Net.send("Settings.Save", pending)
	pending = {}
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local refreshers: { () -> () } = {}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function button(parent: Instance, label: string, width: number): TextButton
	local b = Instance.new("TextButton")
	b.Text = label
	b.Font = FONT
	b.TextScaled = true
	b.TextColor3 = INK
	b.BackgroundColor3 = OFF
	b.Size = UDim2.new(0, width, 1, 0)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.2, 0)
	padding.PaddingBottom = UDim.new(0.2, 0)
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = b
	corner(b, 0.3)
	stroke(b, 2)
	b.Parent = parent
	return b
end

local function buildRow(list: Instance, row, order: number)
	local rowHeight = Config.UI.minTapTarget
	local frame = Instance.new("Frame")
	frame.Name = row.key
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, -12, 0, rowHeight)
	frame.LayoutOrder = order
	frame.Parent = list
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = INK
	label.Text = row.label
	label.Size = UDim2.new(0.36, 0, 0.6, 0)
	label.Position = UDim2.fromScale(0, 0.2)
	label.Parent = frame
	local controls = Instance.new("Frame")
	controls.BackgroundTransparency = 1
	controls.AnchorPoint = Vector2.new(1, 0)
	controls.Position = UDim2.fromScale(1, 0)
	controls.Size = UDim2.new(0.62, 0, 1, 0)
	controls.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = controls

	if row.kind == "choice" then
		local buttons = {}
		for index, option in row.options do
			local b = button(controls, option[2], 92)
			b.LayoutOrder = index
			b.Activated:Connect(function()
				set(row.key, option[1])
				for _, refresh in refreshers do
					refresh()
				end
			end)
			buttons[index] = { b, option[1] }
		end
		table.insert(refreshers, function()
			for _, entry in buttons do
				entry[1].BackgroundColor3 = if current[row.key] == entry[2] then ON else OFF
			end
		end)
	else
		local minus = button(controls, "−", rowHeight)
		minus.LayoutOrder = 1
		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.Font = FONT
		value.TextScaled = true
		value.TextColor3 = INK
		value.Size = UDim2.new(0, 90, 0.6, 0)
		value.LayoutOrder = 2
		value.Parent = controls
		local plus = button(controls, "+", rowHeight)
		plus.LayoutOrder = 3
		minus.Activated:Connect(function()
			set(row.key, current[row.key] - row.step)
			value.Text = string.format("%d%%", math.floor(current[row.key] * 100 + 0.5))
		end)
		plus.Activated:Connect(function()
			set(row.key, current[row.key] + row.step)
			value.Text = string.format("%d%%", math.floor(current[row.key] * 100 + 0.5))
		end)
		table.insert(refreshers, function()
			value.Text = string.format("%d%%", math.floor(current[row.key] * 100 + 0.5))
		end)
	end
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "Settings"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10
	screen.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local card = Instance.new("Frame")
	card.Name = "Panel"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(0, 560, 0.86, 0)
	card.BackgroundColor3 = PANEL
	card.Visible = false
	corner(card, 0.05)
	stroke(card, 2)
	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(560, 720)
	maxWidth.Parent = card
	card.Parent = screen
	panel = card

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Font = FONT
	title.TextScaled = true
	title.TextColor3 = INK
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "SETTINGS"
	title.Position = UDim2.new(0, 20, 0, 12)
	title.Size = UDim2.new(0.6, 0, 0, 44)
	title.Parent = card
	local close = button(card, "✕", Config.UI.minTapTarget)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -12, 0, 8)
	close.Size = UDim2.fromOffset(Config.UI.minTapTarget, Config.UI.minTapTarget)
	close.Activated:Connect(SettingsMenu.close)

	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.new(0, 16, 0, 84)
	list.Size = UDim2.new(1, -24, 1, -96)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 8
	list.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	for order, row in ROWS do
		buildRow(list, row, order)
	end
end

function SettingsMenu.open()
	if not panel then
		build()
	end
	for _, refresh in refreshers do
		refresh()
	end
	(panel :: Frame).Visible = true
end

function SettingsMenu.close()
	if panel then
		panel.Visible = false
	end
	-- Closing saves soon (the 5 s limit still holds; the loop below sends it)
end

function SettingsMenu.isOpen(): boolean
	return panel ~= nil and panel.Visible
end

---------------------------------------------------------------------------

function SettingsMenu.init(all)
	controllers = all
end

function SettingsMenu.start()
	-- The driving HUD must exist before the layout can be applied to it
	while controllers.Hud.getGui() == nil do
		task.wait()
	end
	apply()
	controllers.Profile.Changed:Connect(function(view)
		-- Take the saved values, except any the player changed that are not sent yet
		for key, value in view.settings do
			if pending[key] == nil and Config.Settings.defaults[key] ~= nil then
				current[key] = value
			end
		end
		apply()
		if SettingsMenu.isOpen() then
			for _, refresh in refreshers do
				refresh()
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(0.5)
			if next(pending) ~= nil and os.clock() - lastSend >= Config.Settings.saveInterval then
				flush()
			end
		end
	end)
	-- Send anything unsaved when leaving (Settings.Save's burst allows it)
	Players.PlayerRemoving:Connect(function(player)
		if player == LocalPlayer then
			flush()
		end
	end)
end

return SettingsMenu
