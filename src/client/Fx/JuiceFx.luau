-- JuiceFx: the juice table's visual replies that had no home yet (spec: Audio, VFX and juice > Juice
-- table), driven by JuiceService:
-- * Speed lines: faint white streaks at the screen edges above 100 studs/s, stronger with speed (none with
--   Reduced motion).
-- * Coin pickup: a coin flies from where it was grabbed to the coin counter, which bounces.
-- * Ragdoll eject: a star puff where the rider leaves the seat.
-- * Respawn: a glow ring where the car comes back.
-- * Quest complete and other wins: a small confetti burst on screen.
-- PLACEHOLDER ART: plain frames and neon parts.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local JuiceFx = {}

local LocalPlayer = Players.LocalPlayer
local SPEED_LINES_FROM = 100 -- calm pass: later and fainter
local SPEED_LINES_FULL = 160
local LINE_COUNT = 10

local gui: ScreenGui? = nil
local lines: { Frame } = {}
local lineSeeds: { number } = {}

local function ensureGui(): ScreenGui
	if gui == nil or gui.Parent == nil then
		local g = Instance.new("ScreenGui")
		g.Name = "JuiceFx"
		g.IgnoreGuiInset = true
		g.ResetOnSpawn = false
		g.DisplayOrder = 5
		g.Parent = LocalPlayer:WaitForChild("PlayerGui")
		gui = g
		table.clear(lines)
	end
	return gui :: ScreenGui
end

local function fxPart(color: Color3, size: Vector3, position: Vector3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.Position = position
	p.Parent = Workspace
	return p
end

-- Speed lines: call every frame with the car's speed (0 hides them)
function JuiceFx.speedLines(speed: number, reducedMotion: boolean, t: number)
	local strength = if reducedMotion
		then 0
		else math.clamp((speed - SPEED_LINES_FROM) / (SPEED_LINES_FULL - SPEED_LINES_FROM), 0, 1)
	if strength <= 0 and #lines == 0 then
		return
	end
	local g = ensureGui()
	if #lines == 0 then
		for i = 1, LINE_COUNT do
			local f = Instance.new("Frame")
			f.Name = "SpeedLine"
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.BackgroundColor3 = Color3.new(1, 1, 1)
			f.BorderSizePixel = 0
			f.Parent = g
			lines[i] = f
			lineSeeds[i] = math.random()
		end
	end
	for i, f in lines do
		-- Each streak sits on an edge band and slides outward, looping
		local seed = lineSeeds[i]
		local left = i % 2 == 0
		local phase = (t * (1.6 + seed) + seed) % 1
		local y = 0.15 + ((seed * 7.3 + i * 0.13) % 1) * 0.7
		local x = if left then 0.18 - phase * 0.16 else 0.82 + phase * 0.16
		f.Position = UDim2.fromScale(x, y)
		f.Size = UDim2.new(0.05 + strength * 0.07, 0, 0, 2)
		f.Rotation = if left then (y - 0.5) * 30 else -(y - 0.5) * 30
		f.BackgroundTransparency = 1 - strength * 0.25 * (1 - phase)
		f.Visible = strength > 0
	end
end

-- A coin flies from its world spot to the counter, which bounces when it lands
function JuiceFx.coinFly(from: Vector3?, target: GuiObject?)
	local camera = Workspace.CurrentCamera
	if target == nil or camera == nil then
		return
	end
	local g = ensureGui()
	local start = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
	if from then
		local screen, onScreen = camera:WorldToViewportPoint(from)
		if onScreen then
			start = Vector2.new(screen.X, screen.Y)
		end
	end
	local finish = target.AbsolutePosition + target.AbsoluteSize / 2
	local coin = Instance.new("Frame")
	coin.Name = "FlyingCoin"
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Size = UDim2.fromOffset(22, 22)
	coin.Position = UDim2.fromOffset(start.X, start.Y)
	coin.BackgroundColor3 = Color3.fromRGB(255, 205, 40)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = coin
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Color3.fromRGB(35, 35, 45)
	s.Parent = coin
	coin.Parent = g
	local tween = TweenService:Create(
		coin,
		TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.fromOffset(finish.X, finish.Y), Size = UDim2.fromOffset(14, 14) }
	)
	tween.Completed:Once(function()
		coin:Destroy()
		JuiceFx.bounce(target)
	end)
	tween:Play()
end

-- A quick squash on a HUD element (counters, buttons)
function JuiceFx.bounce(target: GuiObject)
	local scale = target:FindFirstChild("JuiceBounce") :: UIScale?
	if scale == nil then
		local s = Instance.new("UIScale")
		s.Name = "JuiceBounce"
		s.Parent = target
		scale = s
	end
	local s = scale :: UIScale
	s.Scale = 1.25
	TweenService:Create(s, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
end

-- Three stars puffing out of a point (the rider leaving the seat)
function JuiceFx.starPuff(position: Vector3)
	for i = 1, 3 do
		local star = fxPart(Color3.fromRGB(255, 230, 80), Vector3.one * 0.7, position)
		star.Shape = Enum.PartType.Ball
		local angle = i * math.pi * 2 / 3
		TweenService:Create(star, TweenInfo.new(0.55, Enum.EasingStyle.Quad), {
			Position = position + Vector3.new(math.cos(angle) * 3, 2.5, math.sin(angle) * 3),
			Size = Vector3.one * 0.1,
			Transparency = 0.7,
		}):Play()
		task.delay(0.6, function()
			star:Destroy()
		end)
	end
end

-- A glow ring on the ground where the car pops back in
function JuiceFx.glowRing(position: Vector3)
	local ring =
		fxPart(Color3.fromRGB(140, 230, 255), Vector3.new(0.3, 2, 2), position - Vector3.new(0, 1.5, 0))
	ring.Shape = Enum.PartType.Cylinder
	ring.CFrame = CFrame.new(ring.Position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Transparency = 0.25
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad), {
		Size = Vector3.new(0.3, 14, 14),
		Transparency = 1,
	}):Play()
	task.delay(0.5, function()
		ring:Destroy()
	end)
end

-- A small burst of confetti squares from a point on screen (0 to 1)
function JuiceFx.confetti(x: number, y: number)
	local g = ensureGui()
	local colors = {
		Color3.fromRGB(255, 205, 40),
		Color3.fromRGB(255, 120, 200),
		Color3.fromRGB(110, 200, 255),
		Color3.fromRGB(120, 230, 140),
	}
	for i = 1, 14 do
		local bit = Instance.new("Frame")
		bit.AnchorPoint = Vector2.new(0.5, 0.5)
		bit.Size = UDim2.fromOffset(8, 12)
		bit.Position = UDim2.fromScale(x, y)
		bit.BackgroundColor3 = colors[i % #colors + 1]
		bit.BorderSizePixel = 0
		bit.Rotation = math.random(0, 180)
		bit.Parent = g
		local angle = math.random() * math.pi * 2
		local reach = 0.06 + math.random() * 0.08
		TweenService:Create(bit, TweenInfo.new(0.7, Enum.EasingStyle.Quad), {
			Position = UDim2.fromScale(x + math.cos(angle) * reach, y + math.sin(angle) * reach + 0.05),
			Rotation = bit.Rotation + 240,
			BackgroundTransparency = 1,
		}):Play()
		task.delay(0.75, function()
			bit:Destroy()
		end)
	end
end

return JuiceFx
