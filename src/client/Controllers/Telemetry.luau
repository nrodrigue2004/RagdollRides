-- Telemetry: the analytics facts only this device knows (spec: Analytics and KPIs > Custom events),
-- sent to the server's Analytics on Analytics.Client and kept well under its rate limit.
-- * perf_sample every 60 s while driving: average fps, 1% low fps, memory (MB), the graphics setting
--   and the device class (phone, tablet, PC, console).
-- * crash_huge on a Huge crash (at most one every 5 s).
-- * Telemetry.send(name, value, a?, b?) for the screens: shop_open, item_view, hub_view, clip_share.

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Telemetry = {}

local SAMPLE_EVERY = 60
local MIN_GAP = 1.1 -- the remote allows 1 a second
local CRASH_GAP = 5

local controllers: any = nil
local lastSend = -math.huge
local lastCrash = -math.huge
local queue: { { any } } = {}

function Telemetry.send(name: string, value: number?, a: string?, b: string?)
	if #queue >= 8 then
		return -- never pile up (nothing here is worth a failure on the server)
	end
	table.insert(
		queue,
		{ name, math.clamp(value or 1, 0, 100000), string.sub(a or "", 1, 40), string.sub(b or "", 1, 40) }
	)
end

local function deviceClass(): string
	if GuiService:IsTenFootInterface() then
		return "console"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		local camera = Workspace.CurrentCamera
		local size = camera and camera.ViewportSize or Vector2.new(800, 400)
		return if math.min(size.X, size.Y) >= 700 then "tablet" else "phone"
	end
	return "pc"
end

function Telemetry.init(all)
	controllers = all
end

function Telemetry.start()
	local frames: { number } = {}
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		-- Send what is queued, one a second
		local t = os.clock()
		if #queue > 0 and t - lastSend >= MIN_GAP then
			lastSend = t
			local entry = table.remove(queue, 1) :: { any }
			Net.send("Analytics.Client", entry[1], entry[2], entry[3], entry[4])
		end
		-- Perf samples while driving
		if controllers.Vehicle.getChassis() == nil then
			return
		end
		table.insert(frames, dt)
		elapsed += dt
		if elapsed < SAMPLE_EVERY then
			return
		end
		local count = #frames
		local sorted = table.clone(frames)
		table.sort(sorted, function(x, y)
			return x > y
		end)
		local worst = sorted[math.max(1, math.floor(count * 0.01))] or dt
		local average = count / elapsed
		local memory = math.floor(Stats:GetTotalMemoryUsageMb())
		local graphics = controllers.Settings.get("graphics") or "auto"
		Telemetry.send(
			"perf_sample",
			math.floor(average + 0.5),
			string.format("low %d, %d MB", math.floor(1 / math.max(worst, 1e-3) + 0.5), memory),
			string.format("%s, %s", tostring(graphics), deviceClass())
		)
		table.clear(frames)
		elapsed = 0
	end)
	controllers.Vehicle.Impact:Connect(function(info)
		local t = os.clock()
		if info.tier == "HugeCrash" and t - lastCrash >= CRASH_GAP then
			lastCrash = t
			local chassis = controllers.Vehicle.getChassis()
			local model = chassis and chassis.Parent
			local vehicle = model and model:GetAttribute("VehicleId")
			Telemetry.send("crash_huge", math.floor(info.impact), tostring(vehicle or ""))
		end
	end)
end

return Telemetry
