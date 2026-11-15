-- Unit tests for the pure modules, run outside Studio with Lune:  lune run tests/run.luau
-- Optional: pass a built place file to also check the Rojo layout:  lune run tests/run.luau build/RagdollRides.rbxl

local process = require("@lune/process")

local Config = require("../src/shared/Config")
local Damage = require("../src/shared/Damage")
local NetSchema = require("../src/shared/NetSchema")
local PoseCodec = require("../src/shared/PoseCodec")
local Remotes = require("../src/shared/Remotes")
local VehicleMath = require("../src/shared/VehicleMath")

local passed, failed = 0, 0
local current = ""

local function check(condition: boolean, message: string)
	if condition then
		passed += 1
	else
		failed += 1
		print(string.format("  FAIL [%s] %s", current, message))
	end
end

local function near(a: number, b: number, tolerance: number, message: string)
	check(
		math.abs(a - b) <= tolerance,
		string.format("%s (got %.4f, want %.4f +- %.4f)", message, a, b, tolerance)
	)
end

local function test(name: string, fn: () -> ())
	current = name
	local ok, err = pcall(fn)
	if not ok then
		failed += 1
		print(string.format("  ERROR [%s] %s", name, tostring(err)))
	end
end

---------------------------------------------------------------------------
test("spring coefficients follow the spec formula", function()
	local k, c = VehicleMath.springCoefficients(25, 3.2, 0.7)
	local omega = 2 * math.pi * 3.2
	near(k, 25 * omega * omega, 1e-6, "k")
	near(c, 2 * 0.7 * 25 * omega, 1e-6, "c")
end)

test("torque curve is flat to 60% then falls to 0 at top speed", function()
	near(VehicleMath.torqueCurve(0, 0.6), 1, 1e-9, "0%")
	near(VehicleMath.torqueCurve(0.6, 0.6), 1, 1e-9, "60%")
	near(VehicleMath.torqueCurve(0.8, 0.6), 0.5, 1e-9, "80%")
	near(VehicleMath.torqueCurve(1, 0.6), 0, 1e-9, "100%")
	near(VehicleMath.torqueCurve(1.2, 0.6), 0, 1e-9, "over top speed")
end)

test("every class reaches top speed in its table time, and in 3.3 s or less", function()
	for id, class in Config.Classes do
		local t = VehicleMath.simulateTimeToTop(
			class.topSpeed,
			class.timeToTop,
			Config.Driving.torqueFlatFraction,
			Config.Driving.topSpeedReachFraction
		)
		near(t, class.timeToTop, 0.02, id .. " time to top")
		check(t <= 3.3, id .. " within the 3.3 s feel test")
	end
end)

test("steering angle runs 32 to 10 degrees", function()
	near(VehicleMath.maxSteerAngle(0, 32, 10), 32, 1e-9, "standstill")
	near(VehicleMath.maxSteerAngle(1, 32, 10), 10, 1e-9, "top speed")
	near(VehicleMath.maxSteerAngle(0.5, 32, 10), 21, 1e-9, "half speed")
	near(VehicleMath.maxSteerAngle(2, 32, 10), 10, 1e-9, "clamped")
end)

test("digital steering ramps to full in 0.12 s", function()
	local value, t = 0, 0
	while value < 1 and t < 1 do
		value = VehicleMath.rampInput(value, 1, 0.12, 1 / 60)
		t += 1 / 60
	end
	near(t, 0.12, 1 / 60 + 1e-6, "ramp time")
end)

test("tyre and brake helpers clamp correctly", function()
	near(VehicleMath.lateralForce(10, 5, 30), -30, 1e-9, "lateral clamp")
	near(VehicleMath.lateralForce(-2, 5, 30), 10, 1e-9, "lateral linear")
	local fx, fy = VehicleMath.frictionCircle(30, 40, 25)
	near(math.sqrt(fx * fx + fy * fy), 25, 1e-9, "friction circle magnitude")
	near(fx / fy, 0.75, 1e-9, "friction circle keeps direction")
	-- A stopping force never reverses the wheel in one step
	local f = VehicleMath.stoppingForce(1, 1000, 10, 1 / 60)
	near(f, -600, 1e-9, "stopping force limited to what stops it")
	near(VehicleMath.stoppingForce(0, 1000, 10, 1 / 60), 0, 1e-9, "no force at rest")
end)

test("suspension compression and spring force", function()
	local comp, over = VehicleMath.compression(2.5, 1.2, 1.3) -- exactly full extension
	near(comp, 0, 1e-9, "full extension")
	near(over, 0, 1e-9, "no overshoot")
	comp, over = VehicleMath.compression(1.0, 1.2, 1.3)
	near(comp, 1.2, 1e-9, "fully compressed")
	near(over, 0.3, 1e-9, "overshoot")
	local p = {
		k = 100,
		c = 10,
		bumpK = 300,
		bumpDampingMultiplier = 6,
		cornerMass = 25,
		travel = 1.2,
		radius = 1.3,
		progressiveSpeed = 15,
		reboundMultiplier = 1.5,
	}
	local spring, deltaV, touching = VehicleMath.suspensionStep(p, 3.0, 0, 1 / 60)
	check(spring == 0 and deltaV == 0 and not touching, "out of reach does nothing")
	spring, deltaV, touching = VehicleMath.suspensionStep(p, 2.6, 60, 1 / 60)
	check(not touching and deltaV > 0, "a fast drop is damped one frame before contact")
	spring, deltaV = VehicleMath.suspensionStep(p, 2.0, -50, 1 / 60)
	check(
		spring > 0 and deltaV <= 0 and -deltaV <= spring / 60 / 25 + 1e-9,
		"rebound never pulls the car down"
	)
	spring, deltaV = VehicleMath.suspensionStep(p, 1.5, 200, 1 / 30)
	check(deltaV > 0 and deltaV <= 200, "damping never reverses the wheel's motion")
end)

test("downforce is 0.5 x weight at top speed, scaled by speed squared", function()
	near(VehicleMath.downforce(1000, 1, 0.5), 500, 1e-9, "top speed")
	near(VehicleMath.downforce(1000, 0.5, 0.5), 125, 1e-9, "half speed")
end)

---------------------------------------------------------------------------
-- A vertical drop test per class: 4 corners, forces updated once per frame (60 Hz) and integrated at
-- 240 Hz like Roblox, with the same step guards as VehicleController. It predicts the Studio drop test.
local function dropSim(class, frameRate: number)
	local g = Config.World.gravity
	local drive = Config.Driving
	local mass = class.relativeMass * drive.baseMass
	local corner = mass / 4
	local k, c = VehicleMath.springCoefficients(corner, class.springFrequency, class.dampingRatio)
	local dt = 1 / frameRate
	local springLimit = corner * (1.6 / dt) ^ 2
	local params = {
		k = math.min(k, springLimit),
		c = c,
		bumpK = math.min(k * drive.bumpStopStiffnessMultiplier, springLimit),
		bumpDampingMultiplier = drive.bumpStopDampingMultiplier,
		cornerMass = corner,
		travel = class.suspensionTravel,
		radius = class.wheelRadius,
		progressiveSpeed = drive.progressiveDampingSpeed,
		reboundMultiplier = drive.reboundDampingMultiplier,
	}
	-- y = height of the suspension mount above the ground
	local sag = g / (2 * math.pi * class.springFrequency) ^ 2
	local restMount = class.suspensionTravel - sag + class.wheelRadius
	local bellyBelowMount = class.colliderSize[2] / 2 + class.mountY
	local y = restMount + Config.TestTrack.dropHeight
	local v = 0
	local t = 0
	local contactTime: number? = nil
	local passedBottom = false
	local rebound = 0
	local stableSince: number? = nil
	local settledAt: number? = nil
	local lastV = 0
	local substeps = math.max(1, math.floor(240 / frameRate))
	while t < 4 do
		-- Controller update (once per frame), exactly as VehicleController does it
		local spring, deltaV, touching = VehicleMath.suspensionStep(params, y, -v, dt)
		v += deltaV
		local force = spring * 4
		if touching then
			contactTime = contactTime or t
		end
		for _ = 1, substeps do
			local h = dt / substeps
			v += (force / mass - g) * h
			y += v * h
			-- The chassis belly hits the ground: an inelastic stop
			local belly = y - bellyBelowMount
			if belly < 0 then
				y -= belly
				if v < 0 then
					v = 0
				end
			end
		end
		t += dt
		if contactTime then
			if not passedBottom and lastV < 0 and v >= 0 then
				passedBottom = true
			end
			if passedBottom then
				rebound = math.max(rebound, y - restMount)
			end
			local stable = math.abs(v) < 0.6 and math.abs(y - restMount) < 0.2
			if stable then
				stableSince = stableSince or t
				if t - (stableSince :: number) > 0.1 and not settledAt then
					settledAt = stableSince
				end
			else
				stableSince = nil
				settledAt = nil
			end
		end
		lastV = v
	end
	local settle = if settledAt and contactTime then settledAt - contactTime else 99
	return settle, rebound
end

test("20-stud drop settles (predicted, 60 fps and 30 fps)", function()
	for id, class in Config.Classes do
		for _, fps in { 60, 30 } do
			local settle, rebound = dropSim(class, fps)
			print(
				string.format(
					"    drop %-5s @%d fps: settle %.2f s, rebound %.2f studs",
					id,
					fps,
					settle,
					rebound
				)
			)
			check(settle < 0.3, id .. " settles in under 0.3 s at " .. fps .. " fps")
			check(rebound < 0.3, id .. " rebounds under 0.3 studs at " .. fps .. " fps")
		end
	end
end)

test("ride height leaves the chassis belly clear of the ground", function()
	for id, class in Config.Classes do
		local sag = Config.World.gravity / (2 * math.pi * class.springFrequency) ^ 2
		local bellyBelowMount = class.colliderSize[2] / 2 + class.mountY
		local restMount = class.suspensionTravel - sag + class.wheelRadius
		check(restMount - bellyBelowMount > 0.5, id .. " belly clearance at rest")
		check(class.wheelRadius - bellyBelowMount > 0.1, id .. " belly clearance at full compression")
		check(sag < class.suspensionTravel * 0.6, id .. " sag uses under 60% of travel")
	end
end)

---------------------------------------------------------------------------
test("impact: mass factor, tiers, closing speed", function()
	local cfg = Config.Impact
	near(Damage.massFactor(100, nil, cfg), 2.0, 1e-9, "static counts as 2.0")
	near(Damage.massFactor(100, 400, cfg), 2.0, 1e-9, "clamped high")
	near(Damage.massFactor(100, 10, cfg), 0.5, 1e-9, "clamped low")
	near(Damage.massFactor(100, 100, cfg), 1.0, 1e-9, "equal mass")
	check(Damage.tier(9.9, cfg) == "Scrape", "under 10 is a scrape")
	check(Damage.tier(10, cfg) == "Bump", "10 is a bump")
	check(Damage.tier(25, cfg) == "HardHit", "25 is a hard hit")
	check(Damage.tier(59.9, cfg) == "HardHit", "under 60 is a hard hit")
	check(Damage.tier(60, cfg) == "HugeCrash", "60 is a huge crash")
	near(Damage.closingSpeedFromDeltaV(10, 100, nil), 10, 1e-9, "static closing speed")
	near(Damage.closingSpeedFromDeltaV(10, 100, 100), 20, 1e-9, "equal masses double it")
	-- The dev panel's ram speeds land in the expected tiers against the wall
	local expected = { "Bump", "HardHit", "HugeCrash" }
	for index, speed in Config.TestTrack.ramSpeeds do
		local impact = Damage.impact(speed, Damage.massFactor(100, nil, cfg))
		check(Damage.tier(impact, cfg) == expected[index], "ram speed " .. speed)
	end
end)

test("contact side from the normal", function()
	local a, b = Config.Impact.landingNormalDot, Config.Impact.roofNormalDot
	check(Damage.contactSide(0, 1, 0, a, b) == "Bottom", "bottom")
	check(Damage.contactSide(0, -1, 0, a, b) == "Roof", "roof")
	check(Damage.contactSide(0, 0, 1, a, b) == "Front", "front (pushed backwards)")
	check(Damage.contactSide(0, 0, -1, a, b) == "Rear", "rear")
	check(Damage.contactSide(1, 0, 0, a, b) == "Left", "left")
	check(Damage.contactSide(-1, 0, 0, a, b) == "Right", "right")
end)

---------------------------------------------------------------------------
test("net schema checks types, ranges and NaN", function()
	local schema =
		{ { t = "string", max = 5 }, { t = "number", min = 0, max = 1 }, { t = "boolean", optional = true } }
	check(NetSchema.validate(schema, { "abc", 0.5 }, 2), "valid call")
	check(not NetSchema.validate(schema, { "abcdef", 0.5 }, 2), "string too long")
	check(not NetSchema.validate(schema, { "abc", 0 / 0 }, 2), "NaN")
	check(not NetSchema.validate(schema, { "abc", math.huge }, 2), "inf")
	check(not NetSchema.validate(schema, { "abc", 2 }, 2), "above max")
	check(not NetSchema.validate(schema, { "abc", 0.5, true, 1 }, 4), "too many arguments")
	check(not NetSchema.validate(schema, { 5, 0.5 }, 2), "wrong type")
	check(not NetSchema.validate({ { t = "integer" } }, { 1.5 }, 1), "integer")
	local b = buffer.create(7)
	check(NetSchema.validate({ { t = "buffer", len = { 7, 127 } } }, { b }, 1), "buffer length ok")
	check(not NetSchema.validate({ { t = "buffer", len = { 8 } } }, { b }, 1), "buffer length wrong")
	check(not NetSchema.validate({ { t = "string", oneOf = { "a" } } }, { "b" }, 1), "oneOf")
end)

test("token bucket and kick counter", function()
	local bucket = NetSchema.newBucket(2, 0)
	check(NetSchema.take(bucket, 1, 2, 0), "first")
	check(NetSchema.take(bucket, 1, 2, 0), "second (burst)")
	check(not NetSchema.take(bucket, 1, 2, 0), "third refused")
	check(NetSchema.take(bucket, 1, 2, 1.01), "refilled after 1 s")
	local log = { times = {} }
	local count = 0
	for i = 1, 25 do
		count = NetSchema.recordFailure(log, i, 60)
	end
	check(count == 25, "counts within the window")
	count = NetSchema.recordFailure(log, 100, 60)
	check(count == 1 + 0 + #log.times - 1, "old failures drop out")
	check(#log.times <= 1, "only recent failures kept")
end)

test("every remote is well formed", function()
	for name, def in Remotes do
		check(def.dir == "C2S" or def.dir == "S2C" or def.dir == "C2S2C", name .. " direction")
		if def.dir ~= "S2C" then
			check(def.schema ~= nil, name .. " has a schema")
			check((def.rate or 0) > 0 and (def.burst or 0) >= 1, name .. " has a rate limit")
		end
	end
end)

---------------------------------------------------------------------------
test("pose codec round trip", function()
	local pose =
		{ steer = -0.5, throttle = 1, flags = PoseCodec.FLAG_BRAKING, compression = { 0, 0.25, 0.5, 1 } }
	local b = PoseCodec.encode(pose)
	check(buffer.len(b) == PoseCodec.BASE_SIZE, "base size")
	local decoded = PoseCodec.decode(b) :: any
	near(decoded.steer, -0.5, 0.01, "steer")
	near(decoded.throttle, 1, 0.01, "throttle")
	check(decoded.flags == PoseCodec.FLAG_BRAKING, "flags")
	near(decoded.compression[2], 0.25, 0.005, "compression")
	check(decoded.rider == nil, "no rider")

	local s = math.sqrt(0.5)
	local rider = {}
	for i = 1, 6 do
		rider[i] = { i * 10.5, -3.25, 1000.125, 0, s, 0, -s } -- negative w gets canonicalised
	end
	local ragdoll = PoseCodec.encode({
		steer = 0,
		throttle = 0,
		flags = PoseCodec.FLAG_RAGDOLL,
		compression = { 0, 0, 0, 0 },
		rider = rider,
	})
	check(buffer.len(ragdoll) == PoseCodec.RAGDOLL_SIZE, "ragdoll size")
	local back = (PoseCodec.decode(ragdoll) :: any).rider
	near(back[3][1], 31.5, 1e-3, "position x")
	near(back[3][3], 1000.125, 1e-2, "position z")
	near(math.abs(back[3][5]), s, 1e-3, "quaternion y")
	check(back[3][7] >= 0, "w canonical")
	check(PoseCodec.decode(buffer.create(9)) == nil, "rejects bad sizes")
end)

test("matrix to quaternion", function()
	local x, y, z, w = PoseCodec.matrixToQuaternion(1, 0, 0, 0, 1, 0, 0, 0, 1)
	near(w, 1, 1e-9, "identity w")
	near(x + y + z, 0, 1e-9, "identity xyz")
	-- 90 degrees about Y: x' = z, z' = -x
	x, y, z, w = PoseCodec.matrixToQuaternion(0, 0, 1, 0, 1, 0, -1, 0, 0)
	near(y, math.sqrt(0.5), 1e-9, "y")
	near(w, math.sqrt(0.5), 1e-9, "w")
	-- 180 degrees about X
	x, y, z, w = PoseCodec.matrixToQuaternion(1, 0, 0, 0, -1, 0, 0, 0, -1)
	near(math.abs(x), 1, 1e-9, "x for 180")
end)

---------------------------------------------------------------------------
test("config is consistent", function()
	for id, def in Config.Vehicles do
		check(def.id == id, id .. " id matches key")
		check(Config.Classes[def.class] ~= nil, id .. " class exists")
	end
	check(Config.Vehicles[Config.DefaultVehicle] ~= nil, "default vehicle exists")
	for _, id in Config.TestTrackVehicles do
		check(Config.Vehicles[id] ~= nil, "test track vehicle " .. id)
	end
	for id, class in Config.Classes do
		local size = class.colliderSize
		local seat = class.seatOffset
		check(
			math.abs(seat[1]) < size[1] / 2 and math.abs(seat[3]) < size[3] / 2,
			id .. " seat inside the body"
		)
		check(class.frontAxleZ < 0 and class.rearAxleZ > 0, id .. " axles straddle the centre")
	end
	for mode, rules in Config.EjectRules do
		check(type(rules.hugeCrash) == "boolean", mode .. " eject rules")
	end
end)

---------------------------------------------------------------------------
-- Optional: check the built place file has the scripts in the right services
local placePath = process.args[1]
if placePath then
	test("built place layout", function()
		local fs = require("@lune/fs")
		local roblox = require("@lune/roblox")
		local game = roblox.deserializePlace(fs.readFile(placePath))
		local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
		check(shared ~= nil, "ReplicatedStorage.Shared")
		for _, name in
			{
				"Config",
				"Net",
				"NetSchema",
				"Remotes",
				"VehicleMath",
				"Damage",
				"PoseCodec",
				"VehicleBuilder",
			}
		do
			check(shared ~= nil and shared:FindFirstChild(name) ~= nil, "Shared." .. name)
		end
		local server = game:GetService("ServerScriptService"):FindFirstChild("Server")
		check(server ~= nil and server.ClassName == "Script", "Server script")
		check(server ~= nil and server:FindFirstChild("Services") ~= nil, "Server.Services")
		local client =
			game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"):FindFirstChild("Client")
		check(client ~= nil and client.ClassName == "LocalScript", "Client local script")
		for _, name in
			{
				"InputController",
				"VehicleController",
				"RagdollClient",
				"CameraController",
				"HudController",
				"JuiceService",
				"SurfaceEffects",
				"RemoteVehicles",
				"DevPanel",
			}
		do
			check(client ~= nil and client:FindFirstChild("Controllers"):FindFirstChild(name) ~= nil, name)
		end
		check(game:GetService("Players").CharacterAutoLoads == false, "no avatar characters")
		check(game:GetService("Workspace").StreamingEnabled == true, "streaming on")
	end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
