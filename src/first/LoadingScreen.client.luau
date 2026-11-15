-- LoadingScreen: the Wobble Bot tap toy while the game loads and during teleports between places
-- (spec: Waiting screens > Loading or teleport: Wobble Bot tap-to-bounce toy). It replaces Roblox's
-- default loading screen, is handed to TeleportService so a mode hop shows it too, and fades out once
-- the game has loaded and the client is ready (or after 25 s, whatever happens).
-- PLACEHOLDER ART: Wobble Bot is made of rounded frames (the art pass gives him a proper look).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local FONT = Enum.Font.FredokaOne
local INK = Color3.fromRGB(35, 35, 45)
local SKY = Color3.fromRGB(120, 205, 255)
local BOT = Color3.fromRGB(255, 205, 40)
local MAX_WAIT = 25
local MIN_SHOW = 1

local LINES = {
	"Tap Wobble Bot!",
	"Boing!",
	"Again!",
	"He loves this.",
	"Wobble wobble!",
	"Higher!",
}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function round(parent: Instance, name: string, color: Color3, pos: UDim2, size: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	corner(f, 0.5)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = INK
	stroke.Parent = f
	f.Parent = parent
	return f
end

local function build(): (ScreenGui, TextButton, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "WobbleLoading"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	local back = Instance.new("Frame")
	back.Name = "Back"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = SKY
	back.BorderSizePixel = 0
	back.Parent = gui
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.08)
	title.Size = UDim2.fromScale(0.8, 0.12)
	title.Font = FONT
	title.TextScaled = true
	title.Text = "RAGDOLL RIDES"
	title.TextColor3 = Color3.new(1, 1, 1)
	local titleStroke = Instance.new("UIStroke")
	titleStroke.Thickness = 3
	titleStroke.Color = INK
	titleStroke.Parent = title
	title.Parent = back
	-- Wobble Bot: a round body on a spring, two eyes and an antenna
	local bot = Instance.new("TextButton")
	bot.Name = "WobbleBot"
	bot.Text = ""
	bot.AutoButtonColor = false
	bot.BackgroundTransparency = 1
	bot.AnchorPoint = Vector2.new(0.5, 0.5)
	bot.Position = UDim2.fromScale(0.5, 0.52)
	bot.SizeConstraint = Enum.SizeConstraint.RelativeYY
	bot.Size = UDim2.fromScale(0.3, 0.3)
	bot.Parent = back
	round(
		bot,
		"Spring",
		Color3.fromRGB(180, 180, 190),
		UDim2.fromScale(0.5, 0.95),
		UDim2.fromScale(0.18, 0.3)
	)
	local body = round(bot, "Body", BOT, UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.8, 0.8))
	round(body, "EyeL", Color3.new(1, 1, 1), UDim2.fromScale(0.35, 0.42), UDim2.fromScale(0.2, 0.2))
	round(body, "EyeR", Color3.new(1, 1, 1), UDim2.fromScale(0.65, 0.42), UDim2.fromScale(0.2, 0.2))
	round(body, "PupilL", INK, UDim2.fromScale(0.36, 0.44), UDim2.fromScale(0.08, 0.08))
	round(body, "PupilR", INK, UDim2.fromScale(0.66, 0.44), UDim2.fromScale(0.08, 0.08))
	round(body, "Smile", INK, UDim2.fromScale(0.5, 0.7), UDim2.fromScale(0.3, 0.06))
	round(bot, "Antenna", Color3.fromRGB(255, 120, 90), UDim2.fromScale(0.5, 0.04), UDim2.fromScale(0.1, 0.1))
	local line = Instance.new("TextLabel")
	line.Name = "Line"
	line.BackgroundTransparency = 1
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.fromScale(0.5, 0.75)
	line.Size = UDim2.fromScale(0.7, 0.07)
	line.Font = FONT
	line.TextScaled = true
	line.Text = LINES[1]
	line.TextColor3 = INK
	line.Parent = back
	local loading = Instance.new("TextLabel")
	loading.Name = "Loading"
	loading.BackgroundTransparency = 1
	loading.AnchorPoint = Vector2.new(0.5, 1)
	loading.Position = UDim2.fromScale(0.5, 0.95)
	loading.Size = UDim2.fromScale(0.5, 0.05)
	loading.Font = FONT
	loading.TextScaled = true
	loading.Text = "Loading..."
	loading.TextColor3 = Color3.new(1, 1, 1)
	loading.Parent = back
	return gui, bot, line
end

local function wire(gui: ScreenGui, bot: TextButton, line: TextLabel)
	local body = bot:FindFirstChild("Body") :: Frame
	local count = 0
	local bouncing = false
	bot.Activated:Connect(function()
		count += 1
		line.Text = if count < #LINES then LINES[count + 1] else string.format("%d bounces!", count)
		if bouncing then
			return
		end
		bouncing = true
		local up = TweenService:Create(
			body,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.2), Size = UDim2.fromScale(0.72, 0.9) }
		)
		local down = TweenService:Create(
			body,
			TweenInfo.new(0.35, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.8, 0.8) }
		)
		up.Completed:Once(function()
			down:Play()
		end)
		down.Completed:Once(function()
			bouncing = false
		end)
		up:Play()
	end)
	-- An idle wobble so he is alive before the first tap
	task.spawn(function()
		local t = 0
		while gui.Parent do
			t += task.wait(0.03)
			if not bouncing then
				body.Rotation = math.sin(t * 3) * 6
			end
		end
	end)
end

ReplicatedFirst:RemoveDefaultLoadingScreen()

-- Arriving from a teleport, Roblox may already show the copy we handed it; use our own either way
local arriving = TeleportService:GetArrivingTeleportGui()
if arriving then
	arriving:Destroy()
end

local gui, bot, line = build()
wire(gui, bot, line)
gui.Parent = playerGui

-- Teleports between places show a copy of the toy (the copy can't run code, so it just stands there)
local teleportGui = build()
pcall(function()
	TeleportService:SetTeleportGui(teleportGui)
end)

local shownAt = os.clock()
if not game:IsLoaded() then
	game.Loaded:Wait()
end
local deadline = os.clock() + MAX_WAIT
while LocalPlayer:GetAttribute("ClientReady") ~= true and os.clock() < deadline do
	task.wait(0.1)
end
local left = MIN_SHOW - (os.clock() - shownAt)
if left > 0 then
	task.wait(left)
end

-- Fade out
local back = gui:FindFirstChild("Back") :: Frame
for _, d in back:GetDescendants() do
	if d:IsA("TextLabel") then
		TweenService:Create(d, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
	elseif d:IsA("Frame") then
		TweenService:Create(d, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
	elseif d:IsA("UIStroke") then
		TweenService:Create(d, TweenInfo.new(0.4), { Transparency = 1 }):Play()
	end
end
TweenService:Create(back, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
task.wait(0.45)
gui:Destroy()
