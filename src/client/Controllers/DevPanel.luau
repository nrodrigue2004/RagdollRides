-- DevPanel: milestone 1 test tools (Studio, or user ids in Config.Admins only).
-- Runs the spec's feel acceptance tests as scripted drives and prints PASS/FAIL with numbers:
--   Accel  every class reaches top speed in 3.3 s or less on flat ground
--   Drift  a full-lock turn at 60 studs/s drifts but recovers without input within 1 s
--   Drop   a 20-stud drop lands and settles in under 0.3 s with no second bounce over 0.3 studs
--   Ram    impact tiers trigger at 10 / 25 / 60 (driving into the crash wall at 6, 15 and 35 studs/s)
-- Milestone 1b damage tests (spec: QA > Driving and damage):
--   Crash 60   a 60 mph head-on crash shows dents, torn panels and an explosion at 30+ fps; debris never
--              passes 12 pieces and is gone by 3.0 s
--   Zones      steps each of the 9 zones through clean, dented, crushed and 0 (watch the car)
--   Race looks in looks-only mode (quick race), damage never changes handling
-- Also: class picker, eject, explode, repair, the Dents setting, FPS and memory readout. Every test starts
-- from a repaired car. Results also go to the Output window.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local LocalPlayer = Players.LocalPlayer

local DevPanel = {}

local controllers: any = nil
local panel: Frame
local logLabel: TextLabel
local fpsLabel: TextLabel
local logLines: { string } = {}
local busy = false

local function isAdmin(): boolean
	if RunService:IsStudio() then
		return true
	end
	return table.find(Config.Admins, LocalPlayer.UserId) ~= nil
end

local function log(line: string)
	print("[DevPanel] " .. line)
	table.insert(logLines, line)
	while #logLines > 14 do
		table.remove(logLines, 1)
	end
	if logLabel then
		logLabel.Text = table.concat(logLines, "\n")
	end
end

local function input(throttle: number, brake: number, steer: number)
	return {
		throttle = throttle,
		brake = brake,
		steer = steer,
		lean = 0,
		handbrake = false,
		analogSteer = true,
	}
end

local function vehicle()
	return controllers.Vehicle.getState()
end

local function spot(t: { number }): CFrame
	local p = Config.vec3(t)
	return CFrame.lookAt(p, p + Vector3.new(0, 0, -1))
end

local function placeAndSettle(cf: CFrame, settle: number)
	controllers.Input.setOverride(input(0, 0, 0))
	controllers.Vehicle.placeAt(cf + Vector3.new(0, controllers.Vehicle.rideHeight() + 0.2, 0))
	task.wait(settle)
end

local function verdict(pass: boolean): string
	return if pass then "PASS" else "FAIL"
end

local function waitUntil(predicate: () -> boolean, timeout: number): (boolean, number)
	local start = os.clock()
	while os.clock() - start < timeout do
		if predicate() then
			return true, os.clock() - start
		end
		RunService.PostSimulation:Wait()
	end
	return false, timeout
end

local function accelTest()
	local s = vehicle()
	placeAndSettle(spot(Config.TestTrack.accelStart), 1.0)
	controllers.Input.setOverride(input(1, 0, 0))
	local target = s.class.topSpeed * Config.Driving.topSpeedReachFraction
	local ok, t = waitUntil(function()
		return vehicle().forwardSpeed >= target
	end, 8)
	controllers.Input.setOverride(input(0, 1, 0))
	task.wait(1.5)
	log(
		string.format(
			"Accel %s: %s s to %d studs/s (spec class %.1f s, limit 3.3) %s",
			s.class.id,
			if ok then string.format("%.2f", t) else ">8",
			math.floor(target),
			s.class.timeToTop,
			verdict(ok and t <= 3.3)
		)
	)
end

local function driftTest()
	local s = vehicle()
	placeAndSettle(spot(Config.TestTrack.openGround), 0.8)
	controllers.Input.setOverride(input(1, 0, 0))
	local reached = waitUntil(function()
		return vehicle().forwardSpeed >= 60
	end, 6)
	if not reached then
		controllers.Input.setOverride(nil)
		log("Drift " .. s.class.id .. ": never reached 60 studs/s FAIL")
		return
	end
	local chassis = s.chassis
	local peakSlip = 0
	controllers.Input.setOverride(input(1, 0, 1))
	local start = os.clock()
	while os.clock() - start < 1.0 do
		local v = chassis.AssemblyLinearVelocity
		peakSlip = math.max(peakSlip, math.abs(v:Dot(chassis.CFrame.RightVector)))
		RunService.PostSimulation:Wait()
	end
	controllers.Input.setOverride(input(0, 0, 0))
	local ok, t = waitUntil(function()
		local v = chassis.AssemblyLinearVelocity
		local slip = math.abs(v:Dot(chassis.CFrame.RightVector))
		local yaw = math.abs(chassis.AssemblyAngularVelocity:Dot(chassis.CFrame.UpVector))
		return slip < 2 and yaw < 0.3
	end, 4)
	task.wait(0.5)
	log(
		string.format(
			"Drift %s: peak slip %.1f studs/s, recovered in %s s (limit 1.0) %s",
			s.class.id,
			peakSlip,
			if ok then string.format("%.2f", t) else ">4",
			verdict(ok and t <= 1.0 and peakSlip > 4)
		)
	)
end

local function dropTest()
	local s = vehicle()
	local ground = spot(Config.TestTrack.dropSpot)
	local restY = ground.Position.Y + controllers.Vehicle.rideHeight()
	controllers.Input.setOverride(input(0, 0, 0))
	controllers.Vehicle.placeAt(
		ground + Vector3.new(0, controllers.Vehicle.rideHeight() + Config.TestTrack.dropHeight, 0)
	)
	local chassis = s.chassis
	local contacted = waitUntil(function()
		return vehicle().groundedCount > 0
	end, 5)
	if not contacted then
		log("Drop " .. s.class.id .. ": never touched down FAIL")
		return
	end
	local contactTime = os.clock()
	local passedBottom = false
	local bounce = 0
	local settledAt: number? = nil
	local stableSince: number? = nil
	local lastVy = chassis.AssemblyLinearVelocity.Y
	while os.clock() - contactTime < 3 do
		RunService.PostSimulation:Wait()
		local y = chassis.Position.Y
		local vy = chassis.AssemblyLinearVelocity.Y
		if not passedBottom and lastVy < 0 and vy >= 0 then
			passedBottom = true
		end
		if passedBottom then
			bounce = math.max(bounce, y - restY)
		end
		lastVy = vy
		local stable = math.abs(vy) < 0.6 and math.abs(y - restY) < 0.2
		if stable then
			stableSince = stableSince or os.clock()
			if os.clock() - (stableSince :: number) > 0.1 and not settledAt then
				settledAt = stableSince
			end
		else
			stableSince = nil
			settledAt = nil
		end
	end
	local settle = if settledAt then settledAt - contactTime else 99
	log(
		string.format(
			"Drop %s: settled in %s s (limit 0.3), rebound %.2f studs (limit 0.3) %s",
			s.class.id,
			if settledAt then string.format("%.2f", settle) else ">3",
			bounce,
			verdict(settle < 0.3 and bounce < 0.3)
		)
	)
end

local function ramTest()
	local expected = { "Bump", "HardHit", "HugeCrash" }
	for index, speed in Config.TestTrack.ramSpeeds do
		local s = vehicle()
		local start = CFrame.lookAt(
			Vector3.new(0, 0, Config.TestTrack.crashWallZ + 45),
			Vector3.new(0, 0, Config.TestTrack.crashWallZ - 100)
		)
		controllers.Input.setOverride(input(0, 0, 0))
		controllers.Vehicle.placeAt(
			start + Vector3.new(0, controllers.Vehicle.rideHeight() + 0.2, 0),
			start.LookVector * speed
		)
		local hit = nil
		local connection = controllers.Vehicle.Impact:Connect(function(info)
			if hit == nil and info.side == "Front" then
				hit = info
			end
		end)
		local t0 = os.clock()
		while hit == nil and os.clock() - t0 < 8 do
			local v = vehicle().forwardSpeed
			local throttle = math.clamp((speed - v) * 0.6, 0, 1)
			local brake = math.clamp((v - speed) * 0.3, 0, 1)
			controllers.Input.setOverride(input(throttle, brake, 0))
			RunService.PostSimulation:Wait()
		end
		connection:Disconnect()
		controllers.Input.setOverride(input(0, 0, 0))
		if hit then
			log(
				string.format(
					"Ram %d studs/s: Impact %.0f -> %s (expected %s) %s",
					speed,
					hit.impact,
					hit.tier,
					expected[index],
					verdict(hit.tier == expected[index])
				)
			)
		else
			log(string.format("Ram %d studs/s: no impact detected FAIL", speed))
		end
		task.wait(1.2)
		if controllers.Ragdoll.isRagdolled() then
			controllers.Ragdoll.respawn()
			task.wait(0.8)
		end
		if s ~= vehicle() then
			break
		end
	end
end

local function crashTest()
	local speed = 60 / Config.World.mphPerStudPerSecond -- 60 mph in studs/s
	local start = CFrame.lookAt(
		Vector3.new(0, 0, Config.TestTrack.crashWallZ + 60),
		Vector3.new(0, 0, Config.TestTrack.crashWallZ - 100)
	)
	local Damage = controllers.Damage
	local Debris = controllers.Debris
	controllers.Input.setOverride(input(1, 0, 0))
	controllers.Vehicle.placeAt(
		start + Vector3.new(0, controllers.Vehicle.rideHeight() + 0.2, 0),
		start.LookVector * speed
	)
	local hit = nil
	local exploded = false
	local connections = {
		controllers.Vehicle.Impact:Connect(function(info)
			if hit == nil and info.side == "Front" then
				hit = info
			end
		end),
		Damage.Exploded:Connect(function()
			exploded = true
		end),
	}
	-- Hold 60 mph until the wall, then watch for 4.5 s: fire, explosion, debris and the frame rate
	local t0 = os.clock()
	while hit == nil and os.clock() - t0 < 4 do
		local s = vehicle()
		if s then
			s.chassis.AssemblyLinearVelocity = start.LookVector * speed
				+ Vector3.new(0, s.chassis.AssemblyLinearVelocity.Y, 0)
		end
		RunService.PostSimulation:Wait()
	end
	controllers.Input.setOverride(input(0, 0, 0))
	local minFps, maxDebris = math.huge, 0
	local frames, window = 0, 0
	local crashTime = os.clock()
	local explodedAt = nil
	local looks = nil
	while os.clock() - crashTime < 4.5 do
		local dt = RunService.RenderStepped:Wait()
		frames += 1
		window += dt
		if window >= 0.5 then
			minFps = math.min(minFps, frames / window)
			frames, window = 0, 0
		end
		maxDebris = math.max(maxDebris, Debris.count())
		if exploded and not explodedAt then
			explodedAt = os.clock()
		end
		if os.clock() - crashTime < 0.5 then
			looks = Damage.getLooks()
		end
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	if not hit then
		log("Crash 60: never reached the wall FAIL")
		return
	end
	local dented = looks ~= nil and looks[1] >= 2
	log(
		string.format(
			"Crash 60: Impact %.0f, front look %s, debris max %d (<= 12 %s)",
			hit.impact,
			if looks then tostring(looks[1]) else "?",
			maxDebris,
			verdict(maxDebris <= Config.Damage.debris.max)
		)
	)
	log(
		string.format(
			"  dents and torn panels %s, explosion %s, min fps %.0f (30+ %s)",
			verdict(dented),
			if explodedAt then string.format("at %.1f s PASS", explodedAt - crashTime) else "none FAIL",
			minFps,
			verdict(minFps >= 30)
		)
	)
	-- Debris must be gone 3.0 s after the last piece flew
	local cleared = waitUntil(function()
		return Debris.count() == 0
	end, Config.Damage.debris.lifetime + 0.3)
	log("  debris gone by 3.0 s " .. verdict(cleared))
end

local function zonesTest()
	local Damage = controllers.Damage
	local names = { "Front", "Rear", "Left", "Right", "Roof", "FL", "FR", "RL", "RR" }
	local all = true
	-- Park somewhere open so nothing else hits the car
	placeAndSettle(spot(Config.TestTrack.openGround), 0.6)
	for zone = 1, 9 do
		local state = Damage.getState()
		if not state then
			return
		end
		local max = state.max[zone]
		local seen = {}
		-- 40% steps: dented, crushed, then 0
		for _, target in { 0.5, 0.2, 0 } do
			local current = Damage.getState().hp[zone]
			Damage.damageZone(zone, current - target * max)
			task.wait(0.5)
			table.insert(seen, tostring(Damage.getLooks()[zone]))
		end
		local ok = table.concat(seen, ",") == "1,2,3"
		all = all and ok
		log(string.format("Zone %s: looks %s %s", names[zone], table.concat(seen, " "), verdict(ok)))
		if zone == 1 then
			-- the front at 0 sets the car on fire; repair before it blows so the other zones are visible
			task.wait(0.5)
		end
		Damage.repair()
		task.wait(0.3)
	end
	log("Zones: clean -> dented -> crushed -> 0 for all 9 " .. verdict(all))
end

local function raceLooksTest()
	local Damage = controllers.Damage
	local previous = workspace:GetAttribute("Mode")
	-- Local only: the server never sees this, it just switches this device's damage rules
	workspace:SetAttribute("Mode", "TracksRace")
	task.wait(0.1)
	Damage.damageZone(1, 1000)
	Damage.damageZone(7, 50)
	Damage.damageZone(8, 1000)
	task.wait(3.5)
	local s = vehicle()
	local h = s and s.handling
	local clean = h ~= nil
		and h.topSpeed == 1
		and h.drive == 1
		and not h.engineDead
		and h.steerPull == 0
		and not h.lost[3]
	local state = Damage.getState()
	local noBoom = state ~= nil and not state.exploded
	log(
		string.format(
			"Race looks-only: handling unchanged %s, no explosion %s",
			verdict(clean),
			verdict(noBoom)
		)
	)
	workspace:SetAttribute("Mode", previous)
	Damage.repair()
end

local function run(name: string, fn: () -> ())
	if busy then
		log("Busy: wait for the current test to finish")
		return
	end
	if not vehicle() then
		log("No vehicle yet")
		return
	end
	if controllers.Ragdoll.isRagdolled() then
		controllers.Ragdoll.respawn()
		task.wait(0.8)
	end
	busy = true
	task.spawn(function()
		-- The feel and crash tests use the test track's spots: go there first (a new car)
		if LocalPlayer:GetAttribute("MapId") ~= "test_track" then
			log("Going to the test track first...")
			Net.send("Map.Go", "test_track")
			local arrived = waitUntil(function()
				return LocalPlayer:GetAttribute("MapId") == "test_track" and vehicle() ~= nil
			end, 8)
			if not arrived then
				log("Could not reach the test track")
				busy = false
				return
			end
			task.wait(1)
		end
		if controllers.Damage then
			controllers.Damage.repair() -- every test starts from a clean car
		end
		local ok, err = pcall(fn)
		controllers.Input.setOverride(nil)
		busy = false
		if not ok then
			log(name .. " errored: " .. tostring(err))
		end
	end)
end

local function button(parent: Instance, text: string, order: number, onClick: () -> ())
	local b = Instance.new("TextButton")
	b.Name = text
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.TextColor3 = Color3.fromRGB(30, 30, 40)
	b.BackgroundColor3 = Color3.fromRGB(240, 240, 248)
	b.Size = UDim2.fromOffset(104, 34)
	b.LayoutOrder = order
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = b
	b.Parent = parent
	b.Activated:Connect(onClick)
	return b
end

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DevPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.Text = "DEV"
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 16
	toggle.Size = UDim2.fromOffset(64, 36)
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 12, 0.5, 0) -- left middle, clear of the coins and goal bar
	toggle.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
	toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggle.Parent = gui

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 84, 0.5, 0)
	panel.Size = UDim2.fromOffset(470, 640)
	panel.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = panel
	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)

	fpsLabel = Instance.new("TextLabel")
	fpsLabel.BackgroundTransparency = 1
	fpsLabel.Size = UDim2.new(1, 0, 0, 22)
	fpsLabel.Font = Enum.Font.Code
	fpsLabel.TextSize = 16
	fpsLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
	fpsLabel.TextXAlignment = Enum.TextXAlignment.Left
	fpsLabel.Text = "fps"
	fpsLabel.Parent = panel

	local vehicles = Instance.new("Frame")
	vehicles.BackgroundTransparency = 1
	vehicles.Position = UDim2.fromOffset(0, 28)
	vehicles.Size = UDim2.new(1, 0, 0, 34)
	vehicles.Parent = panel
	local vLayout = Instance.new("UIListLayout")
	vLayout.FillDirection = Enum.FillDirection.Horizontal
	vLayout.Padding = UDim.new(0, 6)
	vLayout.SortOrder = Enum.SortOrder.LayoutOrder
	vLayout.Parent = vehicles
	for index, vehicleId in Config.TestTrackVehicles do
		local def = Config.Vehicles[vehicleId]
		button(vehicles, def.class, index, function()
			controllers.Vehicle.equip(vehicleId)
			log("Equip " .. def.displayName .. " (" .. def.class .. ")")
		end)
	end

	local tests = Instance.new("Frame")
	tests.BackgroundTransparency = 1
	tests.Position = UDim2.fromOffset(0, 70)
	tests.Size = UDim2.new(1, 0, 0, 194)
	tests.Parent = panel
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(104, 34)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = tests
	button(tests, "Accel", 1, function()
		run("Accel", accelTest)
	end)
	button(tests, "Drift", 2, function()
		run("Drift", driftTest)
	end)
	button(tests, "Drop", 3, function()
		run("Drop", dropTest)
	end)
	button(tests, "Ram", 4, function()
		run("Ram", ramTest)
	end)
	button(tests, "All tests", 5, function()
		run("All", function()
			accelTest()
			driftTest()
			dropTest()
			ramTest()
		end)
	end)
	button(tests, "Eject", 6, function()
		controllers.Vehicle.ejectRider()
	end)
	button(tests, "Reset", 7, function()
		controllers.Vehicle.reset()
	end)
	button(tests, "Clear log", 8, function()
		table.clear(logLines)
		logLabel.Text = ""
	end)
	button(tests, "Crash 60", 9, function()
		run("Crash 60", crashTest)
	end)
	button(tests, "Zones", 10, function()
		run("Zones", zonesTest)
	end)
	button(tests, "Race looks", 11, function()
		run("Race looks", raceLooksTest)
	end)
	button(tests, "Explode", 12, function()
		controllers.Damage.damageZone(1, 10000)
		log("Front zone at 0: fire for 3 s, then the explosion")
	end)
	button(tests, "Repair", 13, function()
		controllers.Damage.repair()
	end)
	local dents = button(tests, "Dents: Full", 14, function() end)
	dents.Activated:Connect(function()
		local Fx = controllers.Damage
		local nextValue = if dents.Text == "Dents: Full" then "PanelsOnly" else "Full"
		Fx.setDents(nextValue)
		dents.Text = "Dents: " .. (if nextValue == "Full" then "Full" else "Panels")
		log("Dents " .. nextValue .. " (" .. Fx.dentStatus() .. ")")
	end)
	button(tests, "Force dents", 15, function()
		controllers.Damage.forceDents()
		log("Dents forced on (" .. controllers.Damage.dentStatus() .. ")")
	end)
	button(tests, "Test track", 16, function()
		Net.send("Map.Go", "test_track")
		log("To the test track")
	end)
	button(tests, "Pip's Hill", 17, function()
		Net.send("Map.Go", "pips_hill")
		log("To Pip's Hill")
	end)
	button(tests, "Fresh save", 18, function()
		Net.send("Dev.ResetProfile")
		log("Profile reset: you are a first-time player again (back to Pip's Hill)")
	end)

	logLabel = Instance.new("TextLabel")
	logLabel.BackgroundTransparency = 1
	logLabel.Position = UDim2.fromOffset(0, 272)
	logLabel.Size = UDim2.new(1, 0, 1, -280)
	logLabel.Font = Enum.Font.Code
	logLabel.TextSize = 14
	logLabel.TextWrapped = true
	logLabel.TextXAlignment = Enum.TextXAlignment.Left
	logLabel.TextYAlignment = Enum.TextYAlignment.Top
	logLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
	logLabel.Text = "Feel tests run on the test track (they take you there). Pick a class, then a test."
	logLabel.Parent = panel
end

function DevPanel.init(all)
	controllers = all
end

function DevPanel.start()
	if not isAdmin() then
		return
	end
	build()
	local frames, elapsed = 0, 0
	RunService.RenderStepped:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed >= 1 then
			local s = vehicle()
			fpsLabel.Text = string.format(
				"%d fps   %d MB   %s   g=%d",
				math.floor(frames / elapsed + 0.5),
				math.floor(Stats:GetTotalMemoryUsageMb()),
				if s then s.class.id else "-",
				workspace.Gravity
			)
			frames, elapsed = 0, 0
		end
	end)
end

return DevPanel
