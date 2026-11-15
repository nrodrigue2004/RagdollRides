-- Unit tests for the pure modules, run outside Studio with Lune:  lune run tests/run.luau
-- Optional: pass a built place file to also check the Rojo layout:  lune run tests/run.luau build/RagdollRides.rbxl

local process = require("@lune/process")

local Config = require("../src/shared/Config")
local Damage = require("../src/shared/Damage")
local DamageModel = require("../src/shared/DamageModel")
local GhostCodec = require("../src/shared/GhostCodec")
local MapCodec = require("../src/shared/MapCodec")
local MapNames = require("../src/shared/MapNames")
local MapRules = require("../src/shared/MapRules")
local Catalog = require("../src/shared/Catalog")
local MapStats = require("../src/shared/MapStats")
local Quests = require("../src/shared/Quests")
local ShopMath = require("../src/shared/ShopMath")
local PieceCatalog = require("../src/shared/PieceCatalog")
local ProfileSchema = require("../src/shared/ProfileSchema")
local StarterMaps = require("../src/shared/StarterMaps")
local TracksMath = require("../src/shared/TracksMath")
local NetSchema = require("../src/shared/NetSchema")
local PoseCodec = require("../src/shared/PoseCodec")
local Remotes = require("../src/shared/Remotes")
local VehicleMath = require("../src/shared/VehicleMath")
local Round = require("../src/shared/Round")
local RaceMath = require("../src/shared/RaceMath")
local Boards = require("../src/shared/Boards")
local BrawlMath = require("../src/shared/BrawlMath")
local HighwayMath = require("../src/shared/HighwayMath")
local Score = require("../src/shared/Score")
local Emotes = require("../src/shared/Emotes")

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
-- Damage model (milestone 1b)
local DC = Config.Damage
local FULL = Config.Damage.modes.TestTrack
local RACE = Config.Damage.modes.TracksRace

test("damage: zone health and the hit formula", function()
	local state = DamageModel.new(1, DC)
	near(state.max[1], 100, 1e-9, "body 100 HP")
	near(state.max[6], 60, 1e-9, "wheel 60 HP")
	local buggy =
		DamageModel.new(Config.Classes.Buggy.zoneHealthMultiplier * Config.Damage.modes.Highway.health, DC)
	near(buggy.max[1], 100 * 0.8 * 3, 1e-9, "class and mode multipliers")
	-- Head-on centre hit at I 40: 30 to the front, 7.5 to left and right, 7.5 to each front wheel
	local dealt = DamageModel.applyImpact(state, "Front", 40, 0, -5, 3, 5, DC)
	near(dealt, 30, 1e-9, "max(0, I - 15) x 1.2")
	near(state.hp[1], 70, 1e-9, "front")
	near(state.hp[3], 92.5, 1e-9, "left spill 25%")
	near(state.hp[4], 92.5, 1e-9, "right spill 25%")
	near(state.hp[2], 100, 1e-9, "rear untouched")
	near(state.hp[6], 60 - 7.5, 1e-9, "FL half of 50%")
	near(state.hp[7], 60 - 7.5, 1e-9, "FR half of 50%")
	near(state.hp[8], 60, 1e-9, "RL untouched")
	-- Hit on the front-right corner: the FR wheel takes the whole 50%
	local corner = DamageModel.new(1, DC)
	DamageModel.applyImpact(corner, "Front", 40, 3, -5, 3, 5, DC)
	near(corner.hp[7], 60 - 15, 1e-9, "FR takes 50%")
	near(corner.hp[6], 60, 1e-9, "FL none")
	-- Left side, rear half
	local side = DamageModel.new(1, DC)
	DamageModel.applyImpact(side, "Left", 40, -3, 5, 3, 5, DC)
	near(side.hp[3], 70, 1e-9, "left")
	near(side.hp[1], 92.5, 1e-9, "front spill")
	near(side.hp[8], 45, 1e-9, "RL takes 50%")
	-- Below I 15 nothing; landings deal no body damage
	check(
		DamageModel.applyImpact(DamageModel.new(1, DC), "Front", 12, 0, 0, 3, 5, DC) == 0,
		"under 15 is free"
	)
	check(DamageModel.applyImpact(state, "Bottom", 200, 0, 0, 3, 5, DC) == 0, "bottom does nothing")
	-- Health never goes negative
	DamageModel.applyImpact(state, "Front", 500, 0, 0, 3, 5, DC)
	check(state.hp[1] == 0, "clamped at 0")
end)

test("damage: landings hurt only the wheels that touched, above 50 studs/s", function()
	local state = DamageModel.new(1, DC)
	check(DamageModel.applyLanding(state, 45, { true, true, true, true }, DC) == 0, "soft landing free")
	DamageModel.applyLanding(state, 70, { true, false, true, false }, DC)
	near(state.hp[6], 60 - 24, 1e-9, "FL (70 - 50) x 1.2")
	near(state.hp[7], 60, 1e-9, "FR stayed in the air")
	near(state.hp[1], 100, 1e-9, "body untouched")
end)

test("damage: looks follow the health thresholds", function()
	check(DamageModel.lookOf(1, DC) == 0, "100% clean")
	check(DamageModel.lookOf(0.67, DC) == 0, "67% clean")
	check(DamageModel.lookOf(0.66, DC) == 1, "66% dented")
	check(DamageModel.lookOf(0.34, DC) == 1, "34% dented")
	check(DamageModel.lookOf(0.33, DC) == 2, "33% crushed")
	check(DamageModel.lookOf(0.01, DC) == 2, "1% crushed")
	check(DamageModel.lookOf(0, DC) == 3, "0 destroyed")
end)

test("damage: look changes become the spec's detach events", function()
	local function kinds(events)
		local out = {}
		for _, e in events do
			out[e.kind .. ":" .. tostring(e.zone) .. ":" .. tostring(e.part)] = true
		end
		return out
	end
	local clean = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	local e = kinds(DamageModel.diff(clean, { 1, 0, 0, 0, 0, 0, 0, 0, 0 }))
	check(e["look:1:1"] and e["crackGlass:1:nil"], "front dented: look and glass cracks")
	e = kinds(DamageModel.diff({ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, { 2, 2, 2, 0, 0, 0, 0, 0, 0 }))
	check(e["detach:1:Bumper_Front"], "front crushed: bumper tears off")
	check(e["detach:2:Bumper_Rear"], "rear crushed: bumper tears off")
	check(e["doorLoose:3:nil"], "side crushed: door swings loose")
	check(e["shatterGlass:1:nil"], "crushed zone's glass shatters")
	e = kinds(DamageModel.diff(clean, { 3, 0, 0, 3, 2, 3, 0, 0, 0 }))
	check(e["detach:1:Panel_Front"], "front at 0: hood tears off")
	check(e["detach:1:Bumper_Front"], "skipping straight to 0 still drops the bumper")
	check(e["detach:4:Panel_Right"], "side at 0: door tears off")
	check(e["shatterGlass:nil:nil"], "roof crushed: all glass shatters")
	check(e["wheelLost:6:nil"], "wheel at 0 pops off")
	check(
		#DamageModel.diff({ 2, 0, 0, 0, 0, 0, 0, 0, 0 }, { 2, 0, 0, 0, 0, 0, 0, 0, 0 }) == 0,
		"no change, no events"
	)
end)

test("damage: handling effects, and none in looks-only modes", function()
	local h = DamageModel.handling({ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, FULL, DC)
	near(h.topSpeed, 0.95, 1e-9, "front dented -5%")
	check(h.smoke == 1, "light smoke")
	h = DamageModel.handling({ 2, 0, 0, 0, 0, 0, 0, 0, 0 }, FULL, DC)
	near(h.topSpeed, 0.85, 1e-9, "front crushed -15%")
	check(h.smoke == 2, "heavy smoke")
	h = DamageModel.handling({ 3, 0, 0, 0, 0, 0, 0, 0, 0 }, FULL, DC)
	check(h.engineDead, "front at 0: engine stops")
	h = DamageModel.handling({ 0, 0, 0, 0, 0, 1, 0, 0, 0 }, FULL, DC)
	near(h.steerPull, -2, 1e-9, "dented FL pulls 2 degrees left")
	h = DamageModel.handling({ 0, 0, 0, 0, 0, 0, 2, 0, 0 }, FULL, DC)
	near(h.steerPull, 5, 1e-9, "crushed FR pulls 5 degrees right")
	near(h.grip[2], 0.8, 1e-9, "crushed wheel grip -20%")
	h = DamageModel.handling({ 0, 0, 0, 0, 0, 0, 0, 3, 3 }, FULL, DC)
	check(h.lost[3] and h.lost[4], "lost wheels")
	near(h.drive, 0.5, 1e-9, "drive -25% per lost wheel")
	h = DamageModel.handling({ 3, 0, 0, 0, 0, 2, 3, 0, 0 }, RACE, DC)
	check(not h.engineDead and h.topSpeed == 1 and h.drive == 1 and h.steerPull == 0, "race: looks only")
	check(h.smoke == 2, "race still smokes")
end)

test("damage: fire for 3 s then the explosion; wreck rules", function()
	local state = DamageModel.new(1, DC)
	check(DamageModel.tick(state, 0.1, FULL, DC) == nil, "no fire while the front lives")
	DamageModel.applyToZone(state, 1, 1000)
	check(DamageModel.tick(state, 0.1, FULL, DC) == "fire", "fire starts")
	local result = nil
	local t = 0
	while t < 5 and result == nil do
		t += 0.1
		result = DamageModel.tick(state, 0.1, FULL, DC)
	end
	check(result == "explode", "explodes")
	near(t, 3.0, 0.11, "after 3 s")
	check(DamageModel.isWrecked(state, DC), "exploded = wrecked")
	check(DamageModel.tick(state, 0.1, FULL, DC) == nil, "explodes once")
	local race = DamageModel.new(1, DC)
	DamageModel.applyToZone(race, 1, 1000)
	check(DamageModel.tick(race, 0.1, RACE, DC) == nil, "no explosions in quick races")
	local wheels = DamageModel.new(1, DC)
	for _, zone in { 6, 7 } do
		DamageModel.applyToZone(wheels, zone, 100)
	end
	check(not DamageModel.isWrecked(wheels, DC), "2 wheels lost: still going")
	DamageModel.applyToZone(wheels, 8, 100)
	check(DamageModel.isWrecked(wheels, DC), "3 wheels lost: wrecked")
	DamageModel.repair(wheels)
	check(DamageModel.isPristine(wheels), "repair resets everything")
end)

test("damage: heals and the pit wrench remount", function()
	local state = DamageModel.new(1, DC)
	DamageModel.applyToZone(state, 1, 80)
	DamageModel.applyToZone(state, 6, 100)
	DamageModel.applyToZone(state, 7, 100)
	DamageModel.heal(state, 50)
	near(state.hp[1], 70, 1e-9, "wrench heals 50")
	check(state.hp[6] == 0 and state.hp[7] == 0, "wrench reattaches nothing")
	DamageModel.heal(state, 30, true)
	near(state.hp[6], 30, 1e-9, "pit wrench remounts one wheel")
	check(state.hp[7] == 0, "only one")
	near(state.hp[1], 100, 1e-9, "capped at max")
end)

test("damage: shockwave falloff", function()
	local push, up, damage = DamageModel.shockwave(0, DC)
	near(push, 45, 1e-9, "45 at the centre")
	near(up, 20, 1e-9, "plus 20 up")
	near(damage, 30, 1e-9, "30 damage")
	push, _, damage = DamageModel.shockwave(9, DC)
	near(push, 22.5, 1e-9, "half at 9 studs")
	near(damage, 15, 1e-9, "half damage")
	push = DamageModel.shockwave(18, DC)
	check(push == 0, "nothing at 18 studs")
	check(DamageModel.zoneFacing(0, 0, -1) == 1, "blast ahead hits the front")
	check(DamageModel.zoneFacing(1, 0, 0) == 4, "blast on the right")
end)

test("damage: state codec round trip", function()
	local state = DamageModel.new(1.5, DC)
	DamageModel.applyToZone(state, 1, 150)
	DamageModel.applyToZone(state, 4, 0.01)
	DamageModel.applyToZone(state, 9, 89.99)
	DamageModel.tick(state, 0.1, FULL, DC)
	local b = DamageModel.encode(state, DC)
	check(buffer.len(b) == 10, "10 bytes")
	local decoded = DamageModel.decode(b)
	check(decoded ~= nil, "decodes")
	if decoded then
		check(decoded.fractions[1] == 0, "front 0")
		check(decoded.fractions[4] < 1, "a tiny dent never rounds up to clean")
		check(decoded.fractions[9] > 0, "a living wheel never rounds down to 0")
		near(decoded.fractions[2], 1, 1e-9, "rear full")
		check(bit32.band(decoded.flags, DamageModel.FLAG_FIRE) ~= 0, "fire flag")
		local looks = DamageModel.looksFromFractions(decoded.fractions, DC)
		local own = DamageModel.looks(state, DC)
		for i = 1, 9 do
			check(looks[i] == own[i], "remote look matches owner look, zone " .. i)
		end
	end
	check(DamageModel.decode(buffer.create(9)) == nil, "wrong size rejected")
end)

test("damage: mesh dents follow the spec radius, push and cap", function()
	-- A row of vertices along X at y = 0
	local rest, offsets = {}, {}
	for i = 0, 10 do
		table.insert(rest, i * 0.5)
		table.insert(rest, 0)
		table.insert(rest, 0)
		table.insert(offsets, 0)
		table.insert(offsets, 0)
		table.insert(offsets, 0)
	end
	-- I 40: r = 2.5, push = 0.4
	local moved = DamageModel.dent(rest, offsets, 0, 0, 0, 0, -1, 0, 40, DC)
	check(moved == 5, "vertices within 2.5 studs move (got " .. moved .. ")")
	near(offsets[2], -0.4, 1e-9, "centre pushed 0.4 along the impact")
	check(offsets[3 * 3 + 2] > -0.4 and offsets[3 * 3 + 2] < 0, "falloff away from the centre")
	near(offsets[5 * 3 + 2], 0, 1e-9, "outside the radius untouched")
	for _ = 1, 10 do
		DamageModel.dent(rest, offsets, 0, 0, 0, 0, -1, 0, 200, DC)
	end
	near(offsets[2], -1.2, 1e-9, "total capped at 1.2")
	near(DamageModel.impactForDamage(30, DC), 40, 1e-9, "impact for damage inverts the formula")
end)

test("damage config covers every mode and remote size", function()
	for _, mode in { "TestTrack", "Tracks", "TracksRace", "Brawl", "Highway" } do
		local rules = Config.Damage.modes[mode]
		check(
			rules ~= nil and type(rules.handling) == "boolean" and rules.health > 0,
			mode .. " damage rules"
		)
	end
	check(
		Config.Damage.modes.Brawl.health == 1.5 and Config.Damage.modes.Highway.health == 3.0,
		"mode health"
	)
	local def = Remotes["Damage.State"]
	check(def ~= nil and def.schema[1].len[1] == DamageModel.STATE_SIZE, "Damage.State schema size")
end)

---------------------------------------------------------------------------
-- Milestone 2: profiles, Tracks scoring, ghosts, starter maps
local TC = Config.Tracks

test("profile: defaults, load, migrate and reconcile", function()
	local fresh = ProfileSchema.load(nil)
	check(fresh.v == 1 and fresh.coins == 0 and fresh.stars == 0, "fresh profile")
	check(fresh.vehicles.starter_buggy.owned == true, "starter buggy owned")
	check(fresh.settings.steerAssist == "high" and fresh.settings.dents == "full", "default settings")
	check(fresh.tut.pipHill == false, "tutorial flags")
	-- An old save missing new fields gets them, and keeps what it had
	local old = {
		v = 1,
		coins = 250,
		settings = { sfx = 0.3 },
		vehicles = { pocket_sedan = { owned = true } },
		tut = { pipHill = true },
	}
	local loaded = ProfileSchema.load(old)
	check(loaded.coins == 250, "keeps coins")
	near(loaded.settings.sfx, 0.3, 1e-9, "keeps a setting")
	check(loaded.settings.music == 0.6, "fills a missing setting")
	check(loaded.tut.pipHill == true and loaded.tut.lean == false, "keeps and fills tutorial flags")
	check(
		loaded.vehicles.pocket_sedan.owned and loaded.vehicles.starter_buggy == nil,
		"vehicles map left as saved"
	)
	check(loaded.daily ~= nil and loaded.tracks ~= nil and loaded.ghosts ~= nil, "new tables added")
end)

test("profile: settings from a client are checked", function()
	local ok = ProfileSchema.sanitizeSettings({ controlSize = 3, steerAssist = "low", shake = false })
	check(ok ~= nil, "valid settings accepted")
	if ok then
		near(ok.controlSize, 1.4, 1e-9, "control size clamped to 140%")
		check(ok.steerAssist == "low" and ok.shake == false, "values kept")
		check(ok.music == nil, "only the keys sent")
	end
	check(ProfileSchema.sanitizeSettings({ steerAssist = "turbo" }) == nil, "unknown choice rejected")
	check(ProfileSchema.sanitizeSettings({ nickname = "x" }) == nil, "unknown key rejected (no free text)")
	check(ProfileSchema.sanitizeSettings({ sfx = 0 / 0 }) == nil, "NaN rejected")
	check(ProfileSchema.sanitizeSettings({ shake = "yes" }) == nil, "wrong type rejected")
	check(ProfileSchema.sanitizeSettings("hi") == nil, "not a table")
end)

test("profile: days roll over at UTC midnight", function()
	local profile = ProfileSchema.default()
	-- 2026-11-15 23:59:59 UTC and one second later
	local before = 1794787199
	check(ProfileSchema.dayKey(before) == 20261115, "day key " .. ProfileSchema.dayKey(before))
	check(ProfileSchema.rollDay(profile, before), "first roll resets")
	profile.daily.coinsByMode.tracks = 900
	check(not ProfileSchema.rollDay(profile, before - 60), "same day keeps")
	check(profile.daily.coinsByMode.tracks == 900, "counter kept")
	check(ProfileSchema.rollDay(profile, before + 1), "next day resets")
	check(profile.daily.coinsByMode.tracks == 0 and profile.daily.day == 20261116, "fresh counters")
end)

test("profile: ghosts and receipts are bounded", function()
	local profile = ProfileSchema.default()
	local keep = { pips_hill = true }
	ProfileSchema.storeGhost(profile, "pips_hill", "A", keep)
	for i = 1, 25 do
		ProfileSchema.storeGhost(profile, "map" .. i, "G" .. i, keep)
	end
	check(profile.ghosts.pips_hill == "A", "starter ghost always kept")
	check(profile.ghosts.map1 == nil and profile.ghosts.map5 == nil, "oldest player-map ghosts dropped")
	check(profile.ghosts.map25 == "G25" and profile.ghosts.map6 == "G6", "newest 20 kept")
	check(ProfileSchema.recordReceipt(profile, "p1"), "new receipt")
	check(not ProfileSchema.recordReceipt(profile, "p1"), "duplicate receipt refused")
	for i = 2, 120 do
		ProfileSchema.recordReceipt(profile, "p" .. i)
	end
	check(#profile.receipts == 100, "last 100 kept")
end)

test("tracks: stars, coins, caps and boosts", function()
	check(TracksMath.starTier(29.9, 20, TC) == 2, "under x 1.5 is Silver")
	check(TracksMath.starTier(30, 20, TC) == 1, "exactly x 1.5 is not under it")
	check(TracksMath.starTier(21.9, 20, TC) == 3, "under x 1.1 is Gold")
	check(TracksMath.starTier(40, 20, TC) == 1, "finish is Bronze")
	check(TracksMath.starsToPay(3, 1) == 2, "pay only new tiers")
	check(TracksMath.starsToPay(1, 3) == 0, "never twice")
	check(TracksMath.finishCoins(true, 0, TC) == 50, "starter map 50")
	check(TracksMath.finishCoins(false, 2, TC) == 30, "player map 30")
	check(TracksMath.finishCoins(true, 3, TC) == 5, "after 3 finishes 5")
	check(TracksMath.applyCap(50, 0, 1180, TC.dailyCap) == 20, "daily cap")
	check(TracksMath.applyCap(50, 0.2, 0, TC.dailyCap) == 60, "boost applies before the cap")
	near(TracksMath.boost(7, 0, Config.Economy), 0.5, 1e-9, "friend boost max +50%")
	near(TracksMath.boost(2, 3, Config.Economy), 0.35, 1e-9, "friends + rebirths")
end)

test("tracks: run validation (order, minimum time, speed)", function()
	local function run(cps)
		return { mapId = "m", startTime = 100, checkpoints = cps, checkpointCount = 2, speedFlags = 0 }
	end
	local ok, _, elapsed = TracksMath.validateFinish(run({ 105, 110 }), 120, 20, TC)
	check(ok and math.abs(elapsed - 20) < 1e-9, "a clean run")
	ok = TracksMath.validateFinish(run({ 105 }), 120, 20, TC)
	check(not ok, "missed checkpoint")
	ok = TracksMath.validateFinish(run({ 110, 105 }), 120, 20, TC)
	check(not ok, "out of order")
	ok = TracksMath.validateFinish(run({ 102, 104 }), 111, 20, TC)
	check(not ok, "faster than creator x 0.6")
	near(TracksMath.minimumTime(4, TC), 5, 1e-9, "5 s floor")
	local flagged = run({ 105, 110 })
	flagged.speedFlags = 1
	check(not TracksMath.validateFinish(flagged, 120, 20, TC), "speed flag rejects")
	local r = run({})
	check(TracksMath.acceptCheckpoint(r, 1), "first checkpoint")
	check(not TracksMath.acceptCheckpoint(r, 2), "cannot skip")
	r.checkpoints[1] = 101
	check(not TracksMath.acceptCheckpoint(r, 1), "once only")
	check(TracksMath.acceptCheckpoint(r, 2), "next in order")
	check(not TracksMath.acceptCheckpoint(r, 3), "out of range")
	check(TracksMath.tooFast(200, 1, 100, 1.4, 50), "200 studs/s flagged")
	check(not TracksMath.tooFast(180, 1, 100, 1.4, 50), "within allowance")
	check(TracksMath.formatTime(65.321) == "1:05.32", "format " .. TracksMath.formatTime(65.321))
	check(TracksMath.split(9500, 10000) == -500, "ahead is negative")
end)

test("ghost codec round trip and base64", function()
	local samples = {}
	for i = 1, 50 do
		local a = i * 0.1
		table.insert(samples, {
			x = i * 3.3,
			y = 10 + math.sin(a),
			z = -i * 7.1,
			qx = 0,
			qy = math.sin(a / 2),
			qz = 0,
			qw = math.cos(a / 2),
		})
	end
	local b = GhostCodec.encode(samples, 5)
	check(buffer.len(b) == 2 + 50 * 14, "14 bytes a sample")
	local text = GhostCodec.toBase64(b)
	local back = GhostCodec.fromBase64(text)
	check(back ~= nil and buffer.len(back) == buffer.len(b), "base64 round trip length")
	if back then
		local same = true
		for i = 0, buffer.len(b) - 1 do
			if buffer.readu8(b, i) ~= buffer.readu8(back, i) then
				same = false
			end
		end
		check(same, "base64 round trip bytes")
		local decoded, rate = GhostCodec.decode(back)
		check(decoded ~= nil and #decoded == 50 and rate == 5, "decode")
		if decoded then
			near(decoded[20].x, 66, 0.07, "position to 1/8 stud")
			near(decoded[20].qy, math.sin(1), 1e-3, "rotation")
		end
	end
	for _, n in { 0, 1, 2, 3, 4 } do
		local raw = buffer.create(n)
		for i = 0, n - 1 do
			buffer.writeu8(raw, i, (i * 77 + 5) % 256)
		end
		local again = GhostCodec.fromBase64(GhostCodec.toBase64(raw))
		check(again ~= nil and buffer.len(again) == n, "base64 padding " .. n)
	end
	check(GhostCodec.fromBase64("abc") == nil, "bad length rejected")
	check(GhostCodec.fromBase64("ab!d") == nil, "bad characters rejected")
	local _, emptyRate = GhostCodec.decode(buffer.create(5))
	check(emptyRate == 0, "bad ghost size rejected")
	-- 90 s at 5 Hz fits easily
	check(#GhostCodec.toBase64(buffer.create(2 + 450 * 14)) < 9000, "a 90 s ghost is under 9 KB")
end)

test("starter maps are complete and sane", function()
	check(#StarterMaps.maps == 5, "5 starter maps")
	for _, map in StarterMaps.maps do
		local starts, finishes = 0, 0
		local seen = {}
		local maxAbs = 0
		for _, piece in map.pieces do
			if piece.kind == "Start" then
				starts += 1
			elseif piece.kind == "Finish" then
				finishes += 1
			elseif piece.kind == "Checkpoint" and piece.index then
				seen[piece.index] = true
			end
			for _, v in { piece.x, piece.y, piece.z, piece.sx, piece.sy, piece.sz } do
				check(v == v, map.id .. " no NaN")
			end
			maxAbs = math.max(maxAbs, math.abs(piece.x), math.abs(piece.y), math.abs(piece.z))
		end
		check(starts == 1 and finishes == 1, map.id .. " has one start and one finish")
		check(map.checkpoints >= 1 and map.checkpoints <= 10, map.id .. " 1 to 10 checkpoints")
		for i = 1, map.checkpoints do
			check(seen[i] == true, map.id .. " checkpoint " .. i)
		end
		check(map.coins > 0, map.id .. " has coins")
		check(maxAbs < 4000, map.id .. " fits the ghost range")
		check(map.creatorTime >= 5, map.id .. " creator time")
		check(StarterMaps.startPiece(map) ~= nil, map.id .. " start piece")
	end
	local pip = StarterMaps.byId.pips_hill
	check(
		pip.order == 1 and pip.reward ~= nil and pip.reward.coins == 100 and pip.reward.stars == 1,
		"Pip's Hill pays 100 coins and 1 star"
	)
	check(pip.autoRespawn == 1 and pip.assist == true, "Pip's Hill respawns in 1 s with assist")
	local trail = 0
	for _, piece in pip.pieces do
		if piece.kind == "Coin" then
			trail += 1
		end
	end
	check(trail == 13, "Pip's Hill has the 8-coin trail and the 5-coin arc")
	check(StarterMaps.byId.lean_ledge.tut == "lean", "second track teaches lean")
	check(StarterMaps.nextMap("pips_hill") == "lean_ledge", "next map")
	check(StarterMaps.nextMap("tumble_gulch") == "pips_hill", "wraps")
end)

test("tracks: speed window and payout", function()
	-- 1 s window at top speed x 1.25 + the speed pad boost (100 -> 155 studs in 1 s)
	local function steps(perStep)
		local list = {}
		for i = 1, 5 do
			table.insert(list, { time = 10 + i * 0.25, distance = perStep })
		end
		return list
	end
	check(not TracksMath.windowTooFast(steps(30), 11.25, 100, 1.25, 30, 1), "120 studs/s is fine")
	check(TracksMath.windowTooFast(steps(45), 11.25, 100, 1.25, 30, 1), "180 studs/s over 1 s is too fast")
	check(
		not TracksMath.windowTooFast({ { time = 11, distance = 90 } }, 11.25, 100, 1.25, 30, 1),
		"short windows are not judged"
	)
	local base = {
		timeSeconds = 21,
		creatorSeconds = 20,
		previousTier = 0,
		previousBestMs = nil,
		isStarter = true,
		finishesToday = 0,
		trailCoins = 6,
		coinValue = 1,
		reward = nil,
		rewardClaimed = false,
		boost = 0,
		earnedToday = 0,
	}
	local first = TracksMath.payout(base, TC)
	check(first.tier == 3 and first.stars == 3, "first Gold pays all 3 stars")
	check(first.coins == 56 and not first.capped, "50 for the finish + 6 trail coins")
	check(first.isBest and first.bestMs == 21000, "first finish is the best")
	local again = table.clone(base)
	again.previousTier, again.previousBestMs, again.timeSeconds = 3, 21000, 25
	local second = TracksMath.payout(again, TC)
	check(second.stars == 0 and not second.isBest and second.bestMs == 21000, "no stars twice, best kept")
	local tired = table.clone(base)
	tired.finishesToday, tired.trailCoins = 3, 0
	check(TracksMath.payout(tired, TC).coins == 5, "4th finish today pays 5")
	local capped = table.clone(base)
	capped.earnedToday = TC.dailyCap - 10
	local c = TracksMath.payout(capped, TC)
	check(c.coins == 10 and c.capped, "the cap cuts the payout and says so")
	local boosted = table.clone(base)
	boosted.boost = 0.5
	check(TracksMath.payout(boosted, TC).coins == 84, "boost on finish and trail coins")
	local pip = table.clone(base)
	pip.reward, pip.boost, pip.timeSeconds = { coins = 100, stars = 1 }, 0.5, 40
	local p = TracksMath.payout(pip, TC)
	check(
		p.firstReward and p.coins == 100 and p.stars == 1,
		"Pip's Hill first finish: exactly 100 coins, 1 star"
	)
	pip.rewardClaimed, pip.previousTier = true, 1
	local p2 = TracksMath.payout(pip, TC)
	check(not p2.firstReward and p2.coins == 84 and p2.stars == 0, "after that, normal pay")
	check(
		TC.pipHillCoins == StarterMaps.byId.pips_hill.reward.coins
			and TC.pipHillStars == StarterMaps.byId.pips_hill.reward.stars,
		"config and map agree on Pip's Hill's reward"
	)
end)

test("starter maps: respawn points, bounds, kill height, cues", function()
	for _, map in StarterMaps.maps do
		local points = StarterMaps.respawnPoints(map)
		check(#points >= 1 + map.checkpoints, map.id .. " start + every checkpoint respawn")
		local lo, hi = StarterMaps.bounds(map)
		check(lo[2] <= hi[2] and lo[1] <= hi[1] and lo[3] <= hi[3], map.id .. " bounds")
		check(StarterMaps.killY(map) < lo[2], map.id .. " kill height under the lowest piece")
		for i = 1, map.checkpoints do
			local cp = StarterMaps.find(map, "Checkpoint", i)
			check(cp ~= nil and cp.index == i, map.id .. " find checkpoint " .. i)
		end
		check(StarterMaps.find(map, "Finish") ~= nil, map.id .. " find finish")
		-- Rough pace check: creator time is above a flat-out run (a buggy at 70% of top speed) and not
		-- absurdly slow. Real tuning is a Studio playtest (notes/Tasks.md).
		local length = 0
		for _, piece in map.pieces do
			if piece.kind == "Road" then
				length += piece.sz
			end
		end
		local flatOut = length / (Config.Classes.Buggy.topSpeed * 0.7)
		check(
			map.creatorTime > flatOut and map.creatorTime < flatOut * 2.5,
			map.id .. " creator time is plausible"
		)
	end
	local pip = StarterMaps.byId.pips_hill
	local hazard = StarterMaps.find(pip, "Hazard")
	check(hazard ~= nil, "Pip's Hill has its guaranteed spinner hit")
	if hazard then
		local x, y, z = StarterMaps.hazardRespawn(hazard)
		local fx, fz = StarterMaps.forward(hazard.yaw)
		local along = (x - hazard.x) * fx + (z - hazard.z) * fz
		check(along > hazard.sz / 2, "respawn is past the hazard, along the road")
		near(y, hazard.y - hazard.sy / 2, 1e-9, "respawn on the road")
	end
	local spinner = StarterMaps.find(pip, "Spinner")
	check(spinner ~= nil and spinner.axis == "across", "Pip's Hill spinner is a full-width roller")
	check(StarterMaps.find(pip, "JumpCue") ~= nil, "JUMP cue before the ramp")
	check(StarterMaps.find(StarterMaps.byId.lean_ledge, "LeanCue") ~= nil, "LEAN cue on Lean Ledge")
	check(
		StarterMaps.find(StarterMaps.byId.tumble_gulch, "Hazard") == nil,
		"Tumble Gulch's spinner is a real dodge"
	)
	local fx, fz = StarterMaps.forward(0)
	check(math.abs(fx) < 1e-9 and math.abs(fz + 1) < 1e-9, "yaw 0 faces -Z")
end)

test("profile: client view shows only display data", function()
	local profile = ProfileSchema.default()
	profile.inventory.starter_paint = true
	profile.tracks.pips_hill = { best = 20000, stars = 2, splits = { 5000 } }
	local view = ProfileSchema.clientView(profile)
	check(view.coins == 0 and view.stars == 0, "wallet")
	check(table.find(view.owned, Config.DefaultVehicle) ~= nil, "owned vehicles")
	check(table.find(view.inventory, "starter_paint") ~= nil, "inventory ids")
	check(view.tracks.pips_hill.best == 20000, "best times")
	check(view.ghosts == nil and view.receipts == nil and view.flags == nil, "no ghosts, receipts or flags")
	check(profile.flags.boardBanDay == 0, "board ban flag defaults off")
end)

local function entry(key: string, fields: { [string]: number }?): PieceCatalog.Entry
	local e = { t = PieceCatalog.byKey[key].id, x = 0, y = 0, z = 0, r = 0, tilt = 0, s = 0, c = 0, p = 0 }
	for k, v in fields or {} do
		(e :: any)[k] = v
	end
	return e
end

test("builder: piece catalog is complete", function()
	check(#PieceCatalog.defs == 20, "20 pieces (spec)")
	for index, def in PieceCatalog.defs do
		check(def.id == index, def.key .. " id is its position")
		check(def.sizes == 1 or def.sizes == 3, def.key .. " sizes")
		check(#def.footprint == def.sizes * 2, def.key .. " footprint per size")
		check(#def.label <= 12 and #string.split(def.label, " ") <= 2, def.key .. " label is 2 words at most")
		check(def.cost >= 1, def.key .. " costs parts")
		for size = 0, def.sizes - 1 do
			local pieces = PieceCatalog.expand(entry(def.key, { s = size }), 1)
			check(#pieces >= 1, def.key .. " expands")
			for _, p in pieces do
				check(p.sx > 0 and p.sy > 0 and p.sz > 0, def.key .. " has a size")
				check(p.x == p.x and p.y == p.y and p.z == p.z, def.key .. " position is a number")
			end
		end
	end
	check(
		#PieceCatalog.PALETTE == 24 and PieceCatalog.FREE_COLOURS == 12,
		"12 colours free, 24 with VIP (spec)"
	)
	check(
		PieceCatalog.MOTION.spinner.speed == 90 and PieceCatalog.MOTION.hammer.period == 2.5,
		"spinner and hammer (spec)"
	)
	check(
		PieceCatalog.MOTION.piston.period == 2 and PieceCatalog.MOTION.tilt.angle == 15,
		"piston and tilt (spec)"
	)
end)

test("builder: road pieces join end to end on the grid", function()
	-- A straight road's exit is its length ahead
	local function exitOf(e: PieceCatalog.Entry): (number, number, number, number)
		local x, y, z, yaw = PieceCatalog.exit(e)
		return x :: number, y :: number, z :: number, yaw :: number
	end
	local x, y, z, yaw = exitOf(entry("road", { s = 1 }))
	near(x, 0, 1e-6, "road exit x")
	near(z, -32, 1e-6, "road exit 32 ahead (-Z)")
	check(y == 0 and yaw == 0, "road exit height and heading")
	-- A 90 degree curve turns left and lands on the 4-stud snap grid
	x, y, z, yaw = exitOf(entry("curve90"))
	near(x, -48, 1e-6, "curve90 exit x")
	near(z, -48, 1e-6, "curve90 exit z")
	near(yaw, 90, 1e-9, "curve90 turns left 90")
	check(
		math.abs(x / 4 - math.round(x / 4)) < 1e-6 and math.abs(z / 4 - math.round(z / 4)) < 1e-6,
		"curve90 exit on the grid"
	)
	-- Turned 90 degrees, a 64 road heads along -X
	x, _, z = exitOf(entry("road", { s = 2, r = 6 }))
	near(x, -64, 1e-6, "turned road exit x")
	near(z, 0, 1e-6, "turned road exit z")
	-- A slope climbs its rise
	_, y = exitOf(entry("slope", { s = 2 }))
	check(y == 18, "large slope climbs 18")
	check(PieceCatalog.exit(entry("block")) == nil, "blocks have no exit")
	-- Curve segments overlap rather than gap: each is at least its share of the outer arc
	local segments = PieceCatalog.expand(entry("curve90"), nil)
	check(#segments == 3, "curve90 is 3 segments")
	local outerArc = (PieceCatalog.CURVE_RADIUS + PieceCatalog.ROAD_WIDTH / 2) * math.rad(30)
	check(segments[1].sz >= outerArc - 0.5, "segment covers the outer arc")
end)

test("builder: tilted pieces sit on their floor", function()
	local flat = PieceCatalog.expand(entry("block", { s = 2, y = 10 }), nil)[1]
	near(flat.y - flat.sy / 2, 10, 1e-6, "flat block sits on y")
	local stood = PieceCatalog.expand(entry("block", { s = 2, y = 10, tilt = 1 }), nil)[1]
	near(stood.y - stood.sz / 2, 10, 1e-6, "block turned on X sits on y")
	check(stood.pitch == 90, "tilt 1 is a quarter turn on X")
	local rolled = PieceCatalog.expand(entry("wall", { s = 2, tilt = 4 }), nil)[1]
	check(rolled.roll == 90, "tilt 4 is a quarter turn on Z")
	near(rolled.y - rolled.sx / 2, 0, 1e-6, "rolled wall stands on its end")
	local slab = PieceCatalog.expand(entry("platform", { s = 1, tilt = 1 }), nil)[1]
	check(slab.kind == "Block", "a tilted platform becomes a slab")
	local ramp = PieceCatalog.expand(entry("road", { tilt = 1 }), nil)[1]
	check(ramp.pitch == 0, "roads never tilt")
end)

test("builder: map codec round trip", function()
	local map = MapCodec.empty()
	MapCodec.setFullDamage(map, true)
	map.tags = 0b101
	map.name = { 3, 80, 40 }
	table.insert(map.pieces, entry("start"))
	table.insert(map.pieces, entry("road", { x = -40, y = 200, z = 512, r = 23, s = 2, c = 24, p = 255 }))
	table.insert(map.pieces, entry("block", { x = 6, z = -6, tilt = 6, s = 1, c = 3 }))
	table.insert(map.pieces, entry("finish", { z = -100 }))
	local b = MapCodec.encode(map)
	check(buffer.len(b) == MapCodec.HEADER + 4 * MapCodec.PIECE, "8 + 11 bytes a piece (spec)")
	local back = MapCodec.decode(b)
	check(back ~= nil, "decodes")
	if back then
		check(MapCodec.fullDamage(back) and back.tags == 0b101, "flags and tags")
		check(back.name[1] == 3 and back.name[2] == 80 and back.name[3] == 40, "name word ids")
		check(MapCodec.count(b) == 4, "count without decoding")
		check(#back.pieces == 4, "piece count")
		for index, original in map.pieces do
			local copy = back.pieces[index]
			for _, key in { "t", "x", "y", "z", "r", "tilt", "s", "c", "p" } do
				check((copy :: any)[key] == (original :: any)[key], string.format("piece %d %s", index, key))
			end
		end
	end
	check(
		MapCodec.fingerprint(b) == MapCodec.fingerprint(MapCodec.encode(back :: any)),
		"fingerprint is stable"
	)
	local renamed = MapCodec.decode(b) :: any
	renamed.name = { 9, 9, 9 }
	renamed.tags = 0
	local b2 = MapCodec.encode(renamed)
	check(
		MapCodec.fingerprint(b2, MapCodec.PIECES_FROM) == MapCodec.fingerprint(b, MapCodec.PIECES_FROM),
		"settings changes keep the tested pieces"
	)
	check(MapCodec.fingerprint(b2) ~= MapCodec.fingerprint(b), "but change the whole buffer")
	MapCodec.setFullDamage(map, false)
	check(not MapCodec.fullDamage(map), "full damage off")
	-- Bad bytes are refused, never half read
	check(MapCodec.decode(buffer.create(3)) == nil, "too short")
	local wrong = buffer.create(MapCodec.HEADER + 5)
	buffer.writeu8(wrong, 0, MapCodec.VERSION)
	buffer.writeu16(wrong, 6, 1)
	check(MapCodec.decode(wrong) == nil, "wrong length")
	local future = MapCodec.encode(MapCodec.empty())
	buffer.writeu8(future, 0, 99)
	check(MapCodec.decode(future) == nil, "unknown version")
	local big = MapCodec.empty()
	for _ = 1, MapCodec.MAX_PIECES do
		table.insert(big.pieces, entry("road"))
	end
	local full = MapCodec.encode(big)
	check(buffer.len(full) <= 4096, "a full map fits the remote's 4 KB")
end)

test("builder: limits", function()
	local map = MapCodec.empty()
	check(MapRules.checkDraft(map), "an empty draft is fine")
	check(not MapRules.checkPlayable(map), "but cannot be driven")
	table.insert(map.pieces, entry("start"))
	table.insert(map.pieces, entry("road", { z = -2 }))
	table.insert(map.pieces, entry("finish", { z = -20 }))
	check(MapRules.checkPlayable(map), "start + finish is playable")
	check(not MapRules.canAdd(map, PieceCatalog.byKey.start.id), "one start")
	check(not MapRules.canAdd(map, PieceCatalog.byKey.finish.id), "one finish")
	check(MapRules.canAdd(map, PieceCatalog.byKey.road.id), "roads still fit")
	-- Entries
	check(not MapRules.checkEntry(entry("road", { x = 1 })), "odd x is off the normal grid")
	check(MapRules.checkEntry(entry("road", { x = 1 }), { vip = true }), "VIP fine grid")
	check(not MapRules.checkEntry(entry("road", { c = 13 })), "VIP colours need VIP")
	check(MapRules.checkEntry(entry("road", { c = 24 }), { vip = true }), "24 colours with VIP")
	check(not MapRules.checkEntry(entry("road", { tilt = 1 })), "roads cannot tilt")
	check(MapRules.checkEntry(entry("block", { tilt = 6 })), "blocks can")
	check(not MapRules.checkEntry(entry("road", { s = 3 })), "3 sizes at most")
	check(not MapRules.checkEntry(entry("start", { s = 1 })), "the start has one size")
	check(not MapRules.checkEntry(entry("road", { x = 258 })), "x past 512 studs is outside")
	check(not MapRules.checkEntry(entry("road", { y = -2 })), "below the floor is outside")
	check(
		not MapRules.checkEntry({ t = 99, x = 0, y = 0, z = 0, r = 0, tilt = 0, s = 0, c = 0, p = 0 }),
		"unknown piece"
	)
	-- Counted limits
	local moving = MapCodec.empty()
	for _ = 1, MapRules.LIMITS.moving do
		table.insert(moving.pieces, entry("spinner"))
	end
	check(MapRules.checkDraft(moving), "12 moving pieces")
	check(not MapRules.canAdd(moving, PieceCatalog.byKey.hammer.id), "no 13th moving piece")
	table.insert(moving.pieces, entry("piston"))
	check(not MapRules.checkDraft(moving), "13 moving pieces refused")
	local parts = MapCodec.empty()
	for _ = 1, 200 do
		table.insert(parts.pieces, entry("rampBig"))
	end
	check(MapRules.count(parts).parts == 400 and MapRules.checkDraft(parts), "400 parts is the limit")
	check(not MapRules.canAdd(parts, PieceCatalog.byKey.road.id), "the 401st part is refused")
	local checkpoints = MapCodec.empty()
	for _ = 1, 11 do
		table.insert(checkpoints.pieces, entry("checkpoint"))
	end
	check(not MapRules.checkDraft(checkpoints), "10 checkpoints at most")
	local tagged = MapCodec.empty()
	tagged.tags = 0b1111
	check(not MapRules.checkDraft(tagged), "3 tags at most")
	local named = MapCodec.empty()
	named.name = { 1, 999, 1 }
	check(not MapRules.checkDraft(named), "name word ids must exist")
	named.name = { 1, 2, 3 }
	check(MapRules.checkDraft(named), "a real name is fine")
end)

test("builder: preset names and tags", function()
	check(#MapNames.ADJECTIVES >= 50 and #MapNames.NOUNS >= 50 and #MapNames.PLACES >= 30, "enough words")
	check(MapNames.format(1, 1, 1) == "Wobbly Pickle Canyon", "name format")
	check(MapNames.format(1, 1, 1, 2) == "Wobbly Pickle Canyon 2", "taken names get a number")
	check(
		MapNames.valid(1, 1, 1) and not MapNames.valid(0, 1, 1) and not MapNames.valid(1, 999, 1),
		"ids checked"
	)
	local seen = {}
	for _, list in { MapNames.ADJECTIVES, MapNames.NOUNS, MapNames.PLACES } do
		for _, word in list do
			check(not seen[word], "no repeated word: " .. word)
			seen[word] = true
			check(word:match("^[%a %-]+$") ~= nil, "plain words only: " .. word)
		end
	end
	check(
		MapNames.validTags(0b111) and not MapNames.validTags(0b1111) and not MapNames.validTags(256),
		"tag masks"
	)
	local names = MapNames.tagNames(0b100001)
	check(#names == 2 and names[1] == "Easy" and names[2] == "Jumps", "tag names")
end)

test("builder: a builder map drives like a starter map", function()
	local entries = {
		entry("start"),
		entry("road", { s = 2 }),
		entry("checkpoint", { z = -32 }),
		entry("spinner", { z = -40 }),
		entry("checkpoint", { z = -50 }),
		entry("finish", { z = -60 }),
	}
	local def = PieceCatalog.toMapDef(entries, { id = "test_1", offset = { 0, 0, 6000 } }) :: any
	check(def.checkpoints == 2 and def.custom == true, "checkpoints counted")
	local cp2 = StarterMaps.find(def, "Checkpoint", 2)
	check(
		cp2 ~= nil and cp2.z < StarterMaps.find(def, "Checkpoint", 1).z,
		"checkpoints numbered in placement order"
	)
	check(StarterMaps.startPiece(def) ~= nil and StarterMaps.find(def, "Finish") ~= nil, "start and finish")
	check(#StarterMaps.respawnPoints(def) == 3, "respawn at the start and each checkpoint")
	check(StarterMaps.killY(def) < 0, "kill height under the floor")
	local wx, _, wz = StarterMaps.toWorld(def, 0, 0, 0)
	check(wx == 0 and wz == 6000, "plot offset")
end)

test("maps: ratings, Popular score and paging", function()
	check(MapStats.shownRating(40, 9) == nil, "under 10 ratings shows NEW")
	check(MapStats.shownRating(43, 10) == 4.3, "average to one decimal")
	check(MapStats.scoreRating(5, 1) == 3.5, "a new map counts as 3.5 stars")
	check(MapStats.scoreRating(50, 10) == 5, "enough ratings use the real average")
	local days = { ["100"] = 10, ["97"] = 5, ["93"] = 99, ["94"] = 1 }
	check(MapStats.recentPlays(days, 100) == 16, "only the last 7 days count")
	check(MapStats.popularScore(days, 100, 50, 10) == 1600, "16 plays at 5 stars")
	check(MapStats.popularScore(days, 100, 0, 0) == math.floor(16 * 0.49 * 100 + 0.5), "16 plays, new map")
	check(
		MapStats.popularScore({ ["100"] = 10 }, 100, 10, 10)
			< MapStats.popularScore({ ["100"] = 10 }, 100, 0, 0),
		"a 1 star map ranks under a new one"
	)
	MapStats.trimDays(days, 100)
	check(days["93"] == nil and days["94"] == 1 and days["100"] == 10, "old days dropped")
	local sum, count = MapStats.ratingDelta(nil, 4)
	check(sum == 4 and count == 1, "first rating")
	sum, count = MapStats.ratingDelta(4, 2)
	check(sum == -2 and count == 0, "a changed rating moves the sum only")
	local first, last = MapStats.pageRange(20, 3, 9)
	check(first == 19 and last == 20, "last page")
	local o1, o2 = MapStats.slotOffset(1), MapStats.slotOffset(2)
	check(o1[3] == Config.Maps.slotOrigin[3] and o2[3] == o1[3] - Config.Maps.slotSpacing, "map slots")
	-- Slots never touch the starter maps or the build plots
	local lastSlot = MapStats.slotOffset(Config.Maps.maxLoaded)
	check(lastSlot[3] < 0 and o1[3] + 1024 / 2 < 0, "slots are on the far side of the starter maps")
end)

test("maps: reports, strikes and royalties", function()
	-- Stricter than the spec (nate, 2026-11-15): 15 counted reports AND over 25% of finishers
	check(not MapStats.shouldHide(5, 10), "5 reports is far from enough")
	check(not MapStats.shouldHide(14, 20), "14 reports is not enough")
	check(MapStats.shouldHide(15, 59), "15 reports from over 25% of 59 finishers hides")
	check(not MapStats.shouldHide(15, 60), "15 of 60 finishers is not over 25%")
	check(not MapStats.shouldHide(40, 400), "a popular map needs a real share of its players")
	check(not MapStats.reportCounts(29, true, false), "accounts under 30 days don't count")
	check(not MapStats.reportCounts(300, false, false), "you must finish it")
	check(not MapStats.reportCounts(300, true, true), "never your own map")
	check(MapStats.reportCounts(30, true, false), "a counted report")
	local day = 86400
	local now = 1000 * day
	local strikes, level, ban = MapStats.addStrike({}, 0, now)
	check(#strikes == 1 and level == 0 and ban == 0, "one strike")
	strikes, level, ban = MapStats.addStrike({ now - 100 * day, now - 60 * day }, 0, now)
	check(#strikes == 2 and ban == 0, "a strike over 90 days old drops off")
	strikes, level, ban = MapStats.addStrike({ now - 2 * day, now - day }, 0, now)
	check(#strikes == 0 and level == 1 and ban == now + 7 * day, "3 strikes: 7 day ban")
	_, level, ban = MapStats.addStrike({ now - 2 * day, now - day }, 1, now)
	check(level == 2 and ban == now + 30 * day, "then 30 days")
	_, level, ban = MapStats.addStrike({ now - 2 * day, now - day }, 2, now)
	check(level == 3 and ban == Config.Maps.forever, "then for good")
	_, level, ban = MapStats.addStrike({ now - 2 * day, now - day }, 3, now)
	check(level == 3 and ban == Config.Maps.forever, "and it stays for good")
	check(MapStats.royaltyRoom(5, 0) == 5, "royalty paid")
	check(MapStats.royaltyRoom(5, 198) == 2, "up to the daily cap")
	check(MapStats.royaltyRoom(5, 200) == 0, "capped")
end)

test("profile: player map entries are bounded", function()
	local profile = ProfileSchema.default()
	local keep = { pip = true }
	profile.tracks.pip = { best = 1, stars = 1, splits = {} }
	ProfileSchema.noteTrack(profile, "pip", keep)
	check(#profile.trackOrder == 0, "starter maps are never trimmed")
	local cap = Config.Tracks.maxStoredTracks
	for i = 1, cap + 5 do
		local id = "map" .. i
		profile.tracks[id] = { best = i, stars = 1, splits = {} }
		profile.ratings[id] = 3
		ProfileSchema.noteTrack(profile, id, keep)
	end
	check(#profile.trackOrder == cap, "kept to the cap")
	check(profile.tracks.map1 == nil and profile.ratings.map1 == nil, "oldest dropped with its rating")
	check(profile.tracks["map" .. (cap + 5)] ~= nil, "newest kept")
	check(profile.tracks.pip ~= nil, "starter entry kept")
	ProfileSchema.noteTrack(profile, "map10", keep)
	check(profile.trackOrder[#profile.trackOrder] == "map10", "a replay moves to the newest")
	check(profile.daily.mapStarts ~= nil and profile.daily.royalties == 0, "daily map counters")
end)

test("remotes: milestone 4", function()
	for _, name in { "Map.Play", "Map.Data", "Map.List", "Map.Browse", "Map.Rate", "Map.Report", "Admin.Map" } do
		check(Remotes[name] ~= nil, name)
	end
	local browse = Remotes["Map.Browse"].schema :: any
	check(NetSchema.validate(browse, { "popular", 2 }, 2), "a browse request")
	check(not NetSchema.validate(browse, { "everything", 1 }, 2), "unknown tabs refused")
	check(
		not NetSchema.validate(Remotes["Map.Rate"].schema :: any, { "abc12345", 6 }, 2),
		"ratings are 1 to 5"
	)
	check(
		not NetSchema.validate(Remotes["Map.Report"].schema :: any, { "abc12345", "Mean" }, 2),
		"preset reasons only"
	)
end)

test("shop: catalog", function()
	local seen = {}
	for _, item in Catalog.items do
		check(not seen[item.id], "unique id " .. item.id)
		seen[item.id] = true
		check(table.find(Catalog.RARITIES, item.rarity) ~= nil, item.id .. " rarity")
		if item.source == "shop" then
			check(item.coins ~= nil and item.coins > 0, item.id .. " has a coin price")
		end
		if item.source == "pass" then
			check(Config.Monetization.passes[item.pass] ~= nil, item.id .. " names a real pass")
		end
	end
	-- Spec price bands
	for _, item in Catalog.shopItems() do
		local c = item.coins :: number
		if item.kind == "paint" then
			check(c >= 200 and c <= 900, item.id .. " paint 200-900")
		elseif item.kind == "rims" then
			check(c >= 300 and c <= 700, item.id .. " rims 300-700")
		elseif item.kind == "trail" then
			check(c >= 400 and c <= 1500, item.id .. " trail 400-1500")
		elseif item.kind == "horn" then
			check(c == 250, item.id .. " horn 250")
		elseif item.kind == "explosion" then
			check(c == 1500, item.id .. " explosion 1500")
		elseif item.kind == "hat" then
			check(c >= 300 and c <= 1200, item.id .. " hat 300-1200")
		else
			check(c >= 300 and c <= 800, item.id .. " part or decal 300-800")
		end
	end
	check(#Catalog.passItems("rider") == 12, "Rider Pass: 8 outfits and 4 emotes")
	check(#Catalog.passItems("explosions") == 3, "Explosion Styles: 3 styles")
	check(
		#Catalog.masteryItems() == 9 and Catalog.masteryItems()[9].mastery == 10,
		"a mastery item per level 2-10"
	)
	check(Catalog.byId.starter_paint ~= nil, "the first goal is a real item")
	local pool = Catalog.cratePool()
	for _, rarity in Catalog.RARITIES do
		check(#pool[rarity] > 0, "crate has " .. rarity .. " items")
		for _, item in pool[rarity] do
			check(item.source == "shop" or item.source == "crate", item.id .. " in crate pool")
		end
	end
	local total = 0
	for _, row in ShopMath.oddsTable() do
		total += row.percent
	end
	near(total, 100, 1e-6, "crate odds add to 100%")
	for _, id in Config.TierOneVehicles do
		check(Config.Vehicles[id] ~= nil and Config.Vehicles[id].tier == 1, id .. " is tier 1")
	end
	local stunts = 0
	for _, def in Config.Vehicles do
		if def.unlock.pass == "stunt" then
			stunts += 1
		end
	end
	check(stunts == 3, "Stunt Set has 3 side-grades")
end)

test("shop: rotation, crates, mastery, vehicles, rebirth", function()
	local a, b = ShopMath.rotation(20000), ShopMath.rotation(20000)
	check(#a == 4 and table.concat(a) == table.concat(b), "rotation is 4 and the same everywhere")
	check(table.concat(ShopMath.rotation(20001)) ~= table.concat(a), "rotation changes daily")
	local unique = {}
	for _, id in a do
		check(not unique[id] and Catalog.byId[id].source == "shop", "rotation items are distinct shop items")
		unique[id] = true
	end
	-- Crate: rarity shares over many rolls match the odds
	local random = Quests.rng(12345)
	local counts = { common = 0, rare = 0, epic = 0, legendary = 0 }
	local shinies = 0
	local n = 20000
	for _ = 1, n do
		local item, shiny = ShopMath.rollCrate(random, {})
		counts[item.rarity] += 1
		if shiny then
			shinies += 1
		end
	end
	near(counts.common / n, 0.60, 0.02, "60% common")
	near(counts.rare / n, 0.28, 0.02, "28% rare")
	near(counts.epic / n, 0.10, 0.015, "10% epic")
	near(counts.legendary / n, 0.02, 0.006, "2% legendary")
	near(shinies / n, 0.02, 0.006, "1 in 50 shiny")
	-- Duplicates refund 30%
	local owned = {}
	for _, item in Catalog.items do
		owned[item.id] = { count = 1, shiny = true }
	end
	local item, _, duplicate, refund = ShopMath.rollCrate(Quests.rng(7), owned)
	check(duplicate and refund == math.floor(Catalog.coinValue(item) * 0.3 + 0.5), "duplicate refunds 30%")
	-- Mastery
	check(
		ShopMath.masteryLevel(0) == 1 and ShopMath.masteryLevel(24) == 1 and ShopMath.masteryLevel(25) == 2,
		"levels"
	)
	check(ShopMath.masteryLevel(1500) == 10 and ShopMath.masteryNext(1500) == nil, "max level")
	check(ShopMath.masteryNext(70) == 5, "points to next")
	-- Vehicles
	local profile = ProfileSchema.default()
	profile.coins = 600
	local ok, reason = ShopMath.canBuyVehicle(profile, "dune_hopper")
	check(not ok and reason == "mastery", "Dune Hopper needs mastery 3")
	profile.vehicles.starter_buggy.mastery = 75
	check(ShopMath.canBuyVehicle(profile, "dune_hopper"), "then it can be bought")
	profile.coins = 6000
	ok, reason = ShopMath.canBuyVehicle(profile, "haul_hog")
	check(not ok and reason == "stars", "Haul Hog needs 10 stars")
	check(not ShopMath.canBuyVehicle(profile, "hop_rod"), "pass vehicles are not for sale")
	check(not ShopMath.canBuyVehicle(profile, "starter_buggy"), "owned")
	-- Equip rules
	check(not ShopMath.canEquip(profile, "paint_cherry", "starter_buggy"), "not owned")
	profile.inventory.paint_cherry = { count = 1, shiny = false }
	check(ShopMath.canEquip(profile, "paint_cherry", "starter_buggy"), "owned item")
	check(ShopMath.canEquip(profile, "mastery_rims", "starter_buggy"), "mastery 3 item on a level 3 car")
	check(not ShopMath.canEquip(profile, "mastery_dust", "starter_buggy"), "mastery 4 item locked")
	check(not ShopMath.canEquip(profile, "outfit_racer", nil), "pass item needs the pass")
	profile.passes.rider = true
	check(ShopMath.canEquip(profile, "outfit_racer", nil), "pass item with the pass")
	-- Rebirth
	check(not ShopMath.canRebirth(profile), "rebirth needs all 6")
	for _, id in Config.TierOneVehicles do
		profile.vehicles[id] = { owned = true, mastery = 0, parts = {} }
	end
	profile.stars = 30
	check(ShopMath.canRebirth(profile), "all 6 owned")
	ShopMath.rebirth(profile)
	check(profile.coins == 0 and profile.stars == 0 and profile.rebirths == 1, "coins and stars reset")
	check(
		profile.vehicles.bumble_bus.owned and profile.inventory.paint_cherry ~= nil,
		"vehicles and items kept"
	)
	near(ShopMath.capMultiplier(1), 1.05, 1e-9, "caps rise 5% per rebirth")
	near(ShopMath.capMultiplier(20), 1.5, 1e-9, "to +50%")
end)

test("quests: picks, progress, streak", function()
	local daily = Quests.pickDaily(123456, { "tracks" })
	check(#daily == 3, "3 daily quests")
	local tiers = {}
	for _, state in daily do
		local def = Quests.byId[state.id]
		check(def.mode == "tracks", "tracks quests while only Tracks is live")
		tiers[def.tier] = true
	end
	check(tiers[1] and tiers[2] and tiers[3], "one of each reward tier")
	local again = Quests.pickDaily(123456, { "tracks" })
	check(again[1].id == daily[1].id and again[3].id == daily[3].id, "same seed, same quests")
	local all = Quests.pickDaily(99, { "tracks", "brawl", "highway" })
	local modes = {}
	for _, state in all do
		modes[Quests.byId[state.id].mode] = true
	end
	check(modes.tracks and modes.brawl and modes.highway, "one per mode when all are live")
	check(#Quests.DAILY == 24, "a pool of 24")
	check(#Quests.pickWeekly(5, { "tracks" }) == 3, "3 weekly quests")
	-- Progress
	local list = {
		{ id = "d_finish3", progress = 0, claimed = false },
		{ id = "d_player2", progress = 0, claimed = false, keys = {} },
	}
	check(#Quests.apply(list, "finish", 2) == 0 and list[1].progress == 2, "counts up")
	check(#Quests.apply(list, "finish", 5) == 1 and list[1].progress == 3, "done at the target, capped")
	Quests.apply(list, "playerMapFinish", 1, "mapA")
	Quests.apply(list, "playerMapFinish", 1, "mapA")
	check(list[2].progress == 1, "the same map counts once")
	Quests.apply(list, "playerMapFinish", 1, "mapB")
	check(Quests.isDone(list[2]), "two different maps")
	check(
		Quests.reward(list[1], Config.Quests) == 60 and Quests.reward(list[2], Config.Quests) == 80,
		"rewards by tier"
	)
	check(Quests.text(list[1]) == "Finish 3 runs", "quest text")
	local peak = { { id = "d_score10k", progress = 0, claimed = false } }
	Quests.apply(peak, "highwayScore", 6000)
	Quests.apply(peak, "highwayScore", 5000)
	check(peak[1].progress == 6000, "a best-run quest keeps the best, not the sum")
	-- Streak
	local d, can = Quests.streakNext(0, 0, 100)
	check(d == 1 and can, "first claim is day 1")
	d, can = Quests.streakNext(3, 100, 100)
	check(not can, "once a day")
	d = Quests.streakNext(3, 100, 101)
	check(d == 4, "next day")
	d = Quests.streakNext(5, 100, 102)
	check(d == 5, "one missed day steps back one")
	d = Quests.streakNext(2, 100, 110)
	check(d == 1, "never below day 1")
	d = Quests.streakNext(7, 100, 101)
	check(d == 1, "the loop starts again after day 7")
	check(Quests.weekOf(4) == 1 and Quests.weekOf(3) == 0, "weeks start on Monday")
end)

---------------------------------------------------------------------------
-- Milestone 6: the round state machine, quick races and map boards
test("round: lobby waits, fills, and starts full at once", function()
	local rules = Config.Race :: any
	local r = Round.new(0)
	check(Round.update(r, rules, 5, { players = 1 }) == nil and r.endsAt == nil, "1 player waits")
	check(Round.update(r, rules, 6, { players = 2 }) == nil, "2nd player starts the fill clock")
	near(r.endsAt :: number, 6 + rules.lobbyFill, 1e-9, "fill clock")
	check(Round.update(r, rules, 8, { players = 1 }) == nil and r.endsAt == nil, "a leaver stops the clock")
	Round.update(r, rules, 9, { players = 2 })
	check(
		Round.update(r, rules, 9 + rules.lobbyFill, { players = 2 }) == "Countdown",
		"starts after the fill"
	)
	local full = Round.new(0)
	check(Round.update(full, rules, 1, { players = rules.maxPlayers }) == "Countdown", "full starts at once")
end)

test("round: countdown, play ends 20 s after the first finish, results, requeue", function()
	local rules = Config.Race :: any
	local r = Round.new(0)
	Round.update(r, rules, 0, { players = 8 })
	check(r.phase == "Countdown", "countdown")
	check(Round.update(r, rules, rules.countdown - 0.1, { players = 8 }) == nil, "countdown holds")
	check(Round.update(r, rules, rules.countdown, { players = 8 }) == "Play", "play")
	local start = rules.countdown
	Round.noteFinish(r, start + 40, rules)
	near(r.endsAt :: number, start + 40 + rules.afterFirstFinish, 1e-9, "first finish + 20 s")
	Round.noteFinish(r, start + 45, rules)
	near(r.endsAt :: number, start + 40 + rules.afterFirstFinish, 1e-9, "a second finish changes nothing")
	check(Round.update(r, rules, start + 50, { players = 8, finished = 3 }) == nil, "still racing")
	check(Round.update(r, rules, start + 60, { players = 8, finished = 3 }) == "Results", "ends on the clock")
	check(Round.update(r, rules, start + 61, { players = 8, skipped = 8 }) == "Requeue", "all skipped")
	check(Round.update(r, rules, start + 61 + rules.requeue, { players = 2 }) == "Lobby", "back to lobby")
	check(r.round == 2, "round counter")
	local p = Round.new(0)
	Round.update(p, rules, 0, { players = 8 })
	Round.update(p, rules, rules.countdown, { players = 8 })
	check(
		Round.update(p, rules, rules.countdown + 30, { players = 3, finished = 3 }) == "Results",
		"all finished"
	)
	local cap = Round.new(0)
	Round.update(cap, rules, 0, { players = 8 })
	Round.update(cap, rules, rules.countdown, { players = 8 })
	check(
		Round.update(cap, rules, rules.countdown + rules.playMax, { players = 8 }) == "Results",
		"180 s cap"
	)
	local empty = Round.new(0)
	Round.update(empty, rules, 0, { players = 8 })
	check(Round.update(empty, rules, 1, { players = 0 }) == "Results", "everyone left in the countdown")
end)

test("race: places, pay, grid and map turns", function()
	local cfg = Config.Race :: any
	local places = RaceMath.places({
		{ userId = 30, time = 41.2 },
		{ userId = 10, time = nil },
		{ userId = 20, time = 39.9 },
		{ userId = 40, time = 41.2 },
		{ userId = 5, time = nil },
	})
	check(places[1].userId == 20 and places[1].place == 1, "fastest first")
	check(places[2].userId == 30 and places[3].userId == 40, "ties by user id")
	check(places[4].dnf and places[4].userId == 5 and places[5].userId == 10, "DNFs last")
	check(RaceMath.coins(places[1], cfg) == 80 and RaceMath.coins(places[3], cfg) == 45, "place pay")
	check(RaceMath.coins(places[4], cfg) == cfg.dnfCoins, "DNF pays 10")
	check(RaceMath.coins({ userId = 1, place = 12, dnf = false }, cfg) == 10, "past 8th pays the last")
	local seen = {}
	for i = 1, 8 do
		local right, forward = RaceMath.gridOffset(i, cfg.gridSpacing)
		local key = right .. "," .. forward
		check(seen[key] == nil, "grid slot " .. i .. " is free")
		seen[key] = true
		check(math.abs(right) <= 15 - 3, "grid slot " .. i .. " on a 30-stud road")
	end
	local _, poleForward = RaceMath.gridOffset(1, cfg.gridSpacing)
	local _, backForward = RaceMath.gridOffset(5, cfg.gridSpacing)
	check(poleForward > backForward, "front row ahead")
	check(
		RaceMath.ordinal(1) == "1st" and RaceMath.ordinal(2) == "2nd" and RaceMath.ordinal(3) == "3rd",
		"ordinals"
	)
	check(RaceMath.ordinal(11) == "11th" and RaceMath.ordinal(22) == "22nd", "ordinals 11, 22")
	check(
		RaceMath.pickMap({ "a", "b" }, 0) == "a" and RaceMath.pickMap({ "a", "b" }, 3) == "b",
		"maps in turn"
	)
	check(RaceMath.pickMap({}, 0) == nil, "no maps")
	local order = RaceMath.liveOrder({
		{ userId = 1, checkpoints = 2, at = 10 },
		{ userId = 2, checkpoints = 3, at = 12 },
		{ userId = 3, checkpoints = 2, at = 9 },
		{ userId = 4, checkpoints = 3, at = 20, finished = 30 },
	})
	check(order[1] == 4 and order[2] == 2 and order[3] == 3 and order[4] == 1, "live order")
end)

test("boards: scopes, tabs and the pinned row", function()
	check(Boards.allTimeScope("pips_hill") == "pips_hill_A", "all-time scope")
	check(Boards.allTimeScope("abc12345", 2) == "abc12345_E2_A", "epoch scope")
	local day = ProfileSchema.dayNumber(1767225600) -- 2026-01-01, a Thursday
	check(Boards.weeklyScope("m", nil, day) == Boards.weeklyScope("m", nil, day + 3), "Thu to Sun same week")
	check(Boards.weeklyScope("m", nil, day) ~= Boards.weeklyScope("m", nil, day + 4), "Monday is a new week")
	check(#Boards.weeklyScope(string.rep("x", 12), 99, day) <= 50, "scopes fit the 50 character limit")
	local entries = {
		{ userId = 1, ms = 30000 },
		{ userId = 2, ms = 31000 },
		{ userId = 3, ms = 32000 },
		{ userId = 4, ms = 33000 },
	}
	local list, mine = Boards.rows("alltime", entries, 3, 32000, {}, 2)
	check(#list == 2 and list[1].userId == 1, "top count")
	check(mine ~= nil and mine.rank == 3 and mine.me, "own row pinned with rank")
	local friends, me = Boards.rows("friends", entries, 4, 33000, { [2] = true }, 10)
	check(#friends == 2 and friends[1].userId == 2 and friends[1].rank == 1, "friends tab ranks friends")
	check(friends[2].userId == 4 and me ~= nil and me.rank == 2, "you are in the friends tab")
	local _, outside = Boards.rows("alltime", entries, 9, 40000, {}, 10)
	check(outside ~= nil and outside.rank == nil and outside.ms == 40000, "own row without a rank")
	local _, none = Boards.rows("weekly", entries, 9, nil, {}, 10)
	check(none == nil, "no time, no pinned row")
	check(Boards.shouldPost(nil, 30000, false) and Boards.shouldPost(31000, 30000, false), "new bests post")
	check(not Boards.shouldPost(30000, 30000, false), "a tie does not post")
	check(not Boards.shouldPost(nil, 30000, true), "board-banned players do not post")
end)
test("brawl: arenas have 72 tiles in rings of 18, 24 and 30", function()
	local cfg = Config.Brawl
	for _, arena in cfg.arenas do
		local layout = BrawlMath.layout(arena.shape, cfg.tileSpacing)
		check(#layout.tiles == 72, arena.id .. " has 72 tiles (got " .. #layout.tiles .. ")")
		local counts = { 0, 0, 0 }
		for _, tile in layout.tiles do
			counts[tile.ring] += 1
		end
		check(counts[1] == 18 and counts[2] == 24 and counts[3] == 30, arena.id .. " rings 18 / 24 / 30")
		-- Every tile is found from its own centre and from just inside its edge
		local ok = true
		for _, tile in layout.tiles do
			if BrawlMath.tileAt(layout, tile.x, tile.z) ~= tile.index then
				ok = false
			end
			if BrawlMath.tileAt(layout, tile.x + cfg.tileSpacing * 0.45, tile.z) ~= tile.index then
				ok = false
			end
		end
		check(ok, arena.id .. " tileAt finds every tile")
		check(BrawlMath.tileAt(layout, layout.radius + 30, 0) == nil, arena.id .. " nothing past the edge")
		-- Neighbours are one spacing apart (no gaps to fall through)
		local a, b = layout.tiles[1], nil
		local nearest = math.huge
		for _, t in layout.tiles do
			if t ~= a then
				local d = math.sqrt((t.x - a.x) ^ 2 + (t.z - a.z) ^ 2)
				if d < nearest then
					nearest, b = d, t
				end
			end
		end
		near(nearest, cfg.tileSpacing, 1e-6, arena.id .. " neighbour spacing")
		check(b ~= nil, "found a neighbour")
		-- Rings go outward
		local maxInner, minOuter = 0, math.huge
		for _, t in layout.tiles do
			local d = math.sqrt(t.x * t.x + t.z * t.z)
			if t.ring == 1 then
				maxInner = math.max(maxInner, d)
			elseif t.ring == 3 then
				minOuter = math.min(minOuter, d)
			end
		end
		check(maxInner < minOuter, arena.id .. " inner ring inside the outer ring")
		local spawns = BrawlMath.spawnTiles(layout, 8)
		local seen = {}
		for _, index in spawns do
			check(layout.tiles[index].ring == 2, arena.id .. " spawns on the middle ring")
			check(not seen[index], arena.id .. " spawn tiles differ")
			seen[index] = true
		end
		check(#spawns == 8, arena.id .. " 8 spawns")
	end
	local ring = BrawlMath.layout("ring", cfg.tileSpacing)
	check(BrawlMath.tileAt(ring, 0, 0) == nil, "the geyser hole in the middle of the ring")
	local practice = BrawlMath.layout("practice", cfg.tileSpacing)
	check(#practice.tiles == 19, "practice arena has 19 tiles")
	check(BrawlMath.tileAt(practice, 0, 0) ~= nil, "practice has a middle tile")
end)

test("brawl: the drop plan follows the schedule", function()
	local cfg = Config.Brawl
	local layout = BrawlMath.layout("ring", cfg.tileSpacing)
	local plan = BrawlMath.dropPlan(layout, 12345, cfg)
	local byTime: { [number]: number } = {}
	local dropped = {}
	for _, d in plan do
		byTime[d.at] = (byTime[d.at] or 0) + 1
		check(not dropped[d.tile], "a tile drops once")
		dropped[d.tile] = true
		local ring = layout.tiles[d.tile].ring
		if d.at == 40 then
			check(ring == 3, "40 s drops the outer ring")
		elseif d.at == 75 then
			check(ring == 2, "75 s drops the middle ring")
		else
			check(ring == 1 and d.at >= 95, "inner tiles from 95 s")
		end
	end
	check(byTime[40] == 30 and byTime[75] == 24, "whole rings drop together")
	for _, t in { 95, 99, 103, 107, 111, 115, 119 } do
		check(byTime[t] == 1, "one inner tile at " .. t .. " s")
	end
	check(byTime[96] == nil and byTime[118] == nil, "nothing between the 4 s drops")
	for t = 120, 130 do
		check(byTime[t] == 1, "sudden death: one tile at " .. t .. " s")
	end
	check(byTime[131] == nil, "the inner ring is gone by 131 s (18 tiles)")
	local again = BrawlMath.dropPlan(layout, 12345, cfg)
	local same = #again == #plan
	for i, d in plan do
		if again[i].tile ~= d.tile or again[i].at ~= d.at then
			same = false
		end
	end
	check(same, "the same seed gives the same plan everywhere")
	local other = BrawlMath.dropPlan(layout, 999, cfg)
	local differs = false
	for i, d in plan do
		if other[i].tile ~= d.tile then
			differs = true
		end
	end
	check(differs, "another seed shuffles the inner ring")
	local r = BrawlMath.rng(7)
	local okRange = true
	for _ = 1, 200 do
		local v = r()
		if v < 0 or v >= 1 then
			okRange = false
		end
	end
	check(okRange, "rng stays in 0..1")
end)

test("brawl: knockback, hit checks and KO credit", function()
	local k = Config.Brawl.knockback
	near(BrawlMath.knockback(0, 1, 1, 1, nil, k), 20, 1e-9, "a standing bump is 20")
	near(BrawlMath.knockback(50, 1, 1, 1, nil, k), 50, 1e-9, "20 + 0.6 x 50")
	near(BrawlMath.knockback(50, 2.6, 0.6, 1, nil, k), 20 + 0.6 * 50 * 1.8, 1e-9, "mass ratio caps at 1.8")
	near(BrawlMath.knockback(50, 0.6, 2.6, 1, nil, k), 20 + 0.6 * 50 * 0.6, 1e-9, "mass ratio floors at 0.6")
	near(BrawlMath.knockback(200, 1, 1, 1, nil, k), 75, 1e-9, "capped at 75")
	near(BrawlMath.knockback(200, 1, 1, 1.25, nil, k), 75 * 1.25, 1e-9, "then x the buggy's 1.25")
	near(BrawlMath.knockback(200, 1, 1, 0.6, 1.6, k), 75 * 0.6 * 1.6, 1e-9, "spring bumper x1.6")
	local hc = { speedSlack = 1.15, gap = 8, pairCooldown = 0.4 }
	local base = { reported = 60, attackerTop = 100, targetSpeed = 0, gap = 2, sinceLast = 5 }
	check(BrawlMath.checkHit(base, hc) == 60, "a fair bump passes")
	local function with(field: string, value: number)
		local r = table.clone(base) :: any
		r[field] = value
		return r
	end
	check(select(2, BrawlMath.checkHit(with("sinceLast", 0.3), hc)) == "cooldown", "pair cooldown 0.4 s")
	check(select(2, BrawlMath.checkHit(with("gap", 9), hc)) == "far", "over 8 studs apart")
	check(select(2, BrawlMath.checkHit(with("reported", 116), hc)) == "speed", "over the top speed + 15%")
	check(BrawlMath.checkHit(with("reported", 114), hc) == 114, "within 15%")
	check(BrawlMath.koCredit(5, 10, 13.9, 4) == 5, "KO within 4 s is credited")
	check(BrawlMath.koCredit(5, 10, 14.1, 4) == nil, "after 4 s nobody gets it")
	check(BrawlMath.koCredit(5, 10, 100, nil) == 5, "an explosion credits the last bumper")
	check(BrawlMath.koCredit(nil, nil, 1, 4) == nil, "never bumped")
end)

test("brawl: placements, tiebreaks and pay", function()
	local placed = BrawlMath.placements({
		{ id = 1, outAt = 50, kos = 0, damage = 0 },
		{ id = 2, outAt = nil, kos = 1, damage = 10 },
		{ id = 3, outAt = 80, kos = 2, damage = 0 },
		{ id = 4, outAt = 80, kos = 2, damage = 30 },
	})
	check(placed[1].id == 2 and not placed[1].out, "the last car on the arena wins")
	check(placed[2].id == 4 and placed[3].id == 3, "out together: more damage dealt places higher")
	check(placed[4].id == 1 and placed[4].place == 4, "first out is last")
	local timeUp = BrawlMath.placements({
		{ id = 1, outAt = nil, kos = 1, damage = 90 },
		{ id = 2, outAt = nil, kos = 3, damage = 10 },
		{ id = 3, outAt = nil, kos = 3, damage = 20 },
	})
	check(timeUp[1].id == 3 and timeUp[2].id == 2 and timeUp[3].id == 1, "at 150 s: KOs, then damage")
	check(
		BrawlMath.alive({ { id = 1, kos = 0, damage = 0 }, { id = 2, outAt = 3, kos = 0, damage = 0 } }) == 1,
		"alive count"
	)
	local c = Config.Brawl.coins
	check(BrawlMath.coins(3, 0, false, c) == 20, "20 a round")
	check(BrawlMath.coins(2, 2, false, c) == 30, "+5 a KO")
	check(BrawlMath.coins(1, 9, false, c) == 20 + 20 + 40, "KOs max 4, +40 for the win")
	check(BrawlMath.coins(1, 3, true, c) == 0, "idle rounds earn nothing")
end)

test("brawl: ranked points, tiers and seasons", function()
	local r = Config.Brawl.ranked
	check(BrawlMath.rankedDelta(1, 8, false, false, r) == 25, "win +25")
	check(BrawlMath.rankedDelta(4, 8, false, false, r) == 10, "top half +10")
	check(BrawlMath.rankedDelta(5, 8, false, false, r) == 0, "bottom half 0")
	check(BrawlMath.rankedDelta(8, 8, false, false, r) == -10, "first out -10")
	check(BrawlMath.rankedDelta(2, 8, true, false, r) == -15, "AFK or quit -15")
	check(BrawlMath.rankedDelta(2, 8, false, true, r) == 0, "a bot win gives no points")
	check(BrawlMath.rankedDelta(8, 8, false, true, r) == 0, "a bot win costs no points either")
	check(BrawlMath.rankedDelta(2, 2, false, false, r) == -10, "2 cars: second is first out")
	local fresh = { season = 1, points = 0, placementsLeft = 5, bestTier = 0 }
	local after, applied = BrawlMath.applyRanked(fresh, -10, r)
	check(after.points == 0 and applied == 0 and after.placementsLeft == 4, "placements cannot lose points")
	local veteran = { season = 1, points = 5, placementsLeft = 0, bestTier = 0 }
	local floored = BrawlMath.applyRanked(veteran, -15, r)
	check(floored.points == 0, "Bronze floors at 0")
	local climber = { season = 1, points = 90, placementsLeft = 0, bestTier = 0 }
	local up, _, rankUp = BrawlMath.applyRanked(climber, 25, r)
	check(up.points == 115 and rankUp and up.bestTier == 1, "100 points is Silver Spark")
	local down = BrawlMath.applyRanked({ season = 1, points = 105, placementsLeft = 0, bestTier = 1 }, -10, r)
	check(down.points == 95 and down.bestTier == 1, "you can drop a tier; best tier stays")
	check(
		BrawlMath.tierName(0, r) == "Bronze Bolt" and BrawlMath.tierName(4, r) == "Diamond Drift",
		"tier names"
	)
	check(BrawlMath.tierName(5, r) == "Apex I" and BrawlMath.tierName(7, r) == "Apex III", "Apex tiers")
	check(BrawlMath.tierName(20, r) == "Apex 16", "Apex has no end")
	local first, none =
		BrawlMath.seasonRoll({ season = 0, points = 0, placementsLeft = 5, bestTier = 0 }, 1, r)
	check(first.season == 1 and #none == 0, "the first season only stamps the number")
	local same, nothing = BrawlMath.seasonRoll(up, 1, r)
	check(same.points == up.points and #nothing == 0, "same season: nothing changes")
	local gold = { season = 1, points = 345, placementsLeft = 0, bestTier = 3 }
	local rolled, rewards = BrawlMath.seasonRoll(gold, 2, r)
	check(rolled.points == 100 and rolled.season == 2 and rolled.bestTier == 1, "soft reset by 2 tiers")
	check(#rewards == 4 and rewards[1] == 0 and rewards[4] == 3, "a reward per tier reached")
	local bronze = BrawlMath.seasonRoll({ season = 1, points = 150, placementsLeft = 0, bestTier = 1 }, 2, r)
	check(bronze.points == 0, "never below Bronze")
	check(#r.seasonRewards >= #r.tierNames + 1, "a season reward for every named tier and Apex")
	for _, id in r.seasonRewards do
		local item = Catalog.byId[id]
		check(item ~= nil and item.source == "ranked" and item.coins == nil, id .. " is a ranked-only item")
	end
end)
---------------------------------------------------------------------------
test("highway: the road bends gently and locate finds s again", function()
	local cfg = Config.Highway
	local road = HighwayMath.road(12345, cfg.road)
	local x0, z0, h0 = HighwayMath.at(road, 0)
	check(x0 == cfg.road.origin[1] and z0 == cfg.road.origin[3], "s = 0 is the origin")
	local maxHeading, maxTurn = 0, 0
	local lastH = h0
	for s = 0, 20000, cfg.road.segment do
		local _, _, h = HighwayMath.at(road, s)
		maxHeading = math.max(maxHeading, math.abs(h))
		maxTurn = math.max(maxTurn, math.abs(h - lastH))
		lastH = h
	end
	check(maxHeading <= 0.141, "heading stays within 8 degrees")
	-- One road part per segment, each a stud longer: the outer edge gap stays under the overlap
	check(
		maxTurn * road.halfWidth < 0.6,
		string.format("segments meet with a 1-stud overlap (turn %.4f rad)", maxTurn)
	)
	-- Travel along the road is close to s (the bends are gentle)
	local xa, za = HighwayMath.at(road, 0)
	local xb, zb = HighwayMath.at(road, 10000)
	local straight = math.sqrt((xb - xa) ^ 2 + (zb - za) ^ 2)
	check(straight > 9800 and straight <= 10000.01, "10,000 studs of road cover nearly 10,000 studs")
	check(zb < za, "the road runs toward -Z")
	for _, probe in { { 0, 0 }, { 1234.5, 10 }, { 9876, -20 }, { -300, 5 }, { 30000, 26 } } do
		local px, pz = HighwayMath.place(road, probe[1], probe[2])
		local s, lateral = HighwayMath.locate(road, px, pz)
		near(s, probe[1], 0.3, "locate s " .. probe[1])
		near(lateral, probe[2], 0.3, "locate lateral " .. probe[1])
	end
	-- Lanes: lane 1 on the right (positive lateral), lane 4 on the left
	check(HighwayMath.laneOffset(road, 1) == 21 and HighwayMath.laneOffset(road, 4) == -21, "lane offsets")
	check(HighwayMath.laneAt(road, 20) == 1 and HighwayMath.laneAt(road, -3) == 3, "lane at a lateral")
	-- The same seed gives the same road; another seed bends differently
	local again = HighwayMath.road(12345, cfg.road)
	local other = HighwayMath.road(999, cfg.road)
	local ax = HighwayMath.at(again, 5000)
	local bx = HighwayMath.at(road, 5000)
	local cx = HighwayMath.at(other, 5000)
	check(ax == bx and ax ~= cx, "seeded")
	local tut = HighwayMath.road(12345, cfg.road, { origin = cfg.tutorial.origin, lanes = 2 })
	check(tut.lanes == 2 and HighwayMath.at(tut, 0) == cfg.tutorial.origin[1], "tutorial road")
end)

test("highway: traffic is the same everywhere, spaced and typed by the seed", function()
	local cfg = Config.Highway
	local road = HighwayMath.road(777, cfg.road)
	local t = 1234.5
	local cars = HighwayMath.carsBetween(road, 2000, 6000, t, cfg.traffic)
	check(#cars > 60, "plenty of traffic (" .. #cars .. ")")
	local byLane: { [number]: { number } } = {}
	local kinds: { [string]: number } = {}
	for _, car in cars do
		check(car.s >= 2000 and car.s <= 6000, "in range")
		check(car.speed == cfg.traffic.laneSpeeds[car.lane], "lane speed")
		byLane[car.lane] = byLane[car.lane] or {}
		table.insert(byLane[car.lane], car.s)
		kinds[car.kind.id] = (kinds[car.kind.id] or 0) + 1
		-- Rebuilt from its id alone (what the server does)
		local again = HighwayMath.car(road, car.id, t, cfg.traffic)
		check(again ~= nil and again.s == car.s and again.kind.id == car.kind.id, "rebuilt from the id")
		local lane, index = HighwayMath.slotOf(car.id)
		check(lane == car.lane and index == car.index, "slot id round trip")
	end
	for lane, list in byLane do
		table.sort(list)
		for i = 2, #list do
			check(list[i] - list[i - 1] >= 59.99, "lane " .. lane .. " cars at least 60 apart")
		end
	end
	check((kinds.compact or 0) > (kinds.foamTanker or 0), "compacts outnumber tankers")
	-- Time moves every car along its lane at its lane's speed
	local car = cars[1]
	local later = HighwayMath.car(road, car.id, t + 2, cfg.traffic) :: any
	near(later.s - car.s, 2 * car.speed, 1e-6, "cars move at lane speed")
	-- Negative slot indexes work (a long-running server)
	local farId = HighwayMath.slotId(3, -123456)
	local lane, index = HighwayMath.slotOf(farId)
	check(lane == 3 and index == -123456, "negative index round trip")
	-- Rush Hour halves the spacing; quiet (the tutorial) thins it
	local rush = HighwayMath.carsBetween(road, 2000, 6000, t, cfg.traffic, { event = cfg.events[2] })
	local quiet = HighwayMath.carsBetween(road, 2000, 6000, t, cfg.traffic, { quiet = 3 })
	check(#rush > #cars * 1.6 and #quiet < #cars * 0.5, "rush hour and quiet roads")
	local parade = HighwayMath.carsBetween(road, 0, 20000, t, cfg.traffic, { event = cfg.events[4] })
	local buses, normalBuses = 0, 0
	for _, c in parade do
		if c.kind.id == "partyBus" then
			buses += 1
		end
	end
	for _, c in HighwayMath.carsBetween(road, 0, 20000, t, cfg.traffic) do
		if c.kind.id == "partyBus" then
			normalBuses += 1
		end
	end
	check(buses > normalBuses * 2, "bus parade")
end)

test("highway: ramps, wrenches, props and events", function()
	local cfg = Config.Highway
	local road = HighwayMath.road(4321, cfg.road)
	local ramps = HighwayMath.rampsBetween(road, 0, 20000, cfg.ramps)
	for i = 2, #ramps do
		local gap = ramps[i].s - ramps[i - 1].s
		check(gap >= 350 and gap <= 500, "ramps 350 to 500 apart")
	end
	for _, r in ramps do
		check(r.lane >= 1 and r.lane + cfg.ramps.lanes - 1 <= road.lanes, "ramp lanes on the road")
	end
	local rampDay = HighwayMath.rampsBetween(road, 0, 2000, cfg.ramps, cfg.events[5])
	check(#rampDay == 10 and rampDay[1].s == 200, "ramp day: every 200")
	local wrenches = HighwayMath.wrenchesBetween(road, 0, 9000, cfg.wrench.every)
	check(#wrenches == 10 and wrenches[1].s == 450 and wrenches[2].s == 1350, "a wrench every 900")
	local props = HighwayMath.propsBetween(road, 0, 4000, cfg.props)
	check(#props > 60, "props line the road")
	for _, p in props do
		local again = HighwayMath.prop(road, p.id, cfg.props)
		check(again ~= nil and again.s == p.s and again.kind.id == p.kind.id, "prop rebuilt from id")
		check(math.abs(p.lateral) >= road.halfWidth - 2, "props off the lanes")
	end
	-- Events by UTC weekday: day 0 (1970-01-01) was a Thursday (Ramp Day)
	check(HighwayMath.eventFor(0, cfg.events).id == "rampDay", "Thursday")
	check(HighwayMath.eventFor(1, cfg.events).id == "pileupFriday", "Friday")
	check(HighwayMath.eventFor(3, cfg.events).id == "lowGravity", "Sunday")
	-- Run starts: behind the pack, or back at the start
	check(HighwayMath.startS({}, 120, 40000) == 0, "empty road starts at 0")
	check(HighwayMath.startS({ 3000, 1500 }, 120, 40000) == 1380, "behind the last car")
	check(HighwayMath.startS({ 50000 }, 120, 40000) == 0, "too far out starts over")
end)

test("highway: destruction score, combos, chains and pile-ups", function()
	local cfg = Config.Highway.score
	check(
		Score.speedFactor(10, cfg) == 0.5
			and Score.speedFactor(80, cfg) == 2
			and Score.speedFactor(500, cfg) == 2.5,
		"speed factor"
	)
	local steps = cfg.comboSteps
	check(
		Score.multiplier(1, steps) == 1
			and Score.multiplier(2, steps) == 2
			and Score.multiplier(4, steps) == 3,
		"x1 x2 x3"
	)
	check(
		Score.multiplier(29, steps) == 7
			and Score.multiplier(30, steps) == 8
			and Score.multiplier(99, steps) == 8,
		"x8 at 30"
	)
	local run = Score.newRun()
	-- First hit: a sedan at I 40 = 75 x 1 x 1 x 1
	check(Score.hit(run, 0, 75, 40, 0, cfg) == 75, "first hit")
	-- Second within 3 s: x2
	check(Score.hit(run, 1, 75, 40, 0, cfg) == 150, "second hit x2")
	check(run.bestMultiplier == 2, "best multiplier")
	-- A near miss keeps it alive past 3 s from the last hit
	check(Score.nearMiss(run, 3.5, cfg) == 25, "near miss 25")
	check(Score.hit(run, 6, 75, 40, 0, cfg) == 150, "combo kept alive by the near miss (3 hits: x2)")
	-- A chain hit pays 50% at the current combo and does not step it
	check(Score.hit(run, 6.5, 100, 40, 1, cfg) == 100, "chain link 1: 100 x 2 x 0.5")
	check(Score.hit(run, 6.5, 100, 40, 4, cfg) == 0, "no credit past link 3")
	check(run.combo == 3, "chains do not step the combo")
	-- A 3 s gap resets
	check(Score.hit(run, 10, 50, 40, 0, cfg) == 50, "reset to x1")
	-- Bone breaks: Crack bonus x combo, then the break multiplier
	local crack = Score.boneBreak(run, 10.5, cfg)
	check(crack == 150, "crack at x1")
	near(Score.hitValue(100, 40, 1, run.breaks, cfg), 110, 1e-9, "break multiplier 1.1")
	near(Score.breakMultiplier(12, cfg), 2.2, 1e-9, "2.2 at 12 breaks")
	-- Caps: 3,000 per event and 2,000 per second
	local capped = Score.newRun()
	check(Score.cap(capped, 0, 5000, cfg) == 2000, "per second first")
	check(Score.cap(capped, 0.5, 500, cfg) == 0, "nothing more in that second")
	check(Score.cap(capped, 1.1, 3500, cfg) == 2000, "per event 3,000 then the second's 2,000")
	-- Pile-up: 5 wrecks inside 4 s, paid once the window runs out
	local pile = Score.newRun()
	for i = 1, 4 do
		check(Score.wreck(pile, i * 0.5, cfg) == false, "not yet")
	end
	check(Score.wreck(pile, 2.5, cfg) == true, "5th wreck starts the pile-up")
	Score.wreck(pile, 3, cfg)
	Score.wreck(pile, 4, cfg)
	check(Score.pileupDue(pile, 7, 1, cfg) == nil, "still building")
	local points, cars = Score.pileupDue(pile, 8.1, 1, cfg)
	check(cars == 7 and points == 1500, "1,000 + 250 per car past 5")
	check(pile.pileups == 1 and Score.pileupDue(pile, 20, 1, cfg) == nil, "paid once")
	local friday = Score.newRun()
	for i = 1, 5 do
		Score.wreck(friday, i * 0.1, cfg)
	end
	check(Score.pileupDue(friday, 5, 2, cfg) == 2000, "Pile-up Friday doubles")
	local spread = Score.newRun()
	for i = 1, 6 do
		Score.wreck(spread, i * 3, cfg)
	end
	check(spread.pileCount == 0, "wrecks far apart are no pile-up")
	-- Tricks and coins
	check(Score.airPoints(1.6, cfg) == 75 and Score.airPoints(60, cfg) == 300, "air points, capped")
	check(Score.flipPoints(2, cfg) == 600 and Score.flipPoints(9, cfg) == 900, "flips, capped")
	check(
		Score.coins(12000, Config.Highway.coins) == 48 and Score.coins(99999, Config.Highway.coins) == 120,
		"coins"
	)
end)

test("highway: bones break in order, by side, with limits", function()
	local total = 0
	for _, bones in Score.BONES do
		total += #bones
	end
	check(total == 12 and Config.Highway.bones.total == 12, "12 bones")
	local broken = {}
	check(Score.pickPiece(broken, Score.piecesFor("Front")) == 1, "front: head first")
	check(Score.breakOn(broken, 1) == "Noggin", "noggin")
	check(Score.pickPiece(broken, Score.piecesFor("Front")) == 2, "front: then torso")
	check(Score.pickPiece(broken, Score.piecesFor("Roof")) == 2, "roof with no head bones: next piece")
	check(Score.breakOn(broken, 2) == "Ribs" and Score.breakOn(broken, 2) == "Spine", "torso order")
	check(Score.pickPiece(broken, Score.piecesFor("Left")) == 3, "left: left arm")
	for _ = 1, 2 do
		Score.breakOn(broken, 3)
	end
	check(Score.pickPiece(broken, Score.piecesFor("Left")) == 5, "left arm gone: left leg")
	check(Score.bonesLeft(broken) == 7, "7 left")
	for piece = 1, 6 do
		while (broken[piece] or 0) < #Score.BONES[piece] do
			Score.breakOn(broken, piece)
		end
	end
	check(Score.pickPiece(broken, { 4 }) == nil and Score.bonesLeft(broken) == 0, "all 12 gone")
	local limits = Config.Highway.bones
	local clock = Score.newBreakClock()
	check(Score.mayBreak(clock, 0, limits), "first")
	Score.noteBreak(clock, 0, limits)
	check(not Score.mayBreak(clock, 0.3, limits), "0.5 s cooldown")
	Score.noteBreak(clock, 0.6, limits)
	Score.noteBreak(clock, 1.2, limits)
	check(not Score.mayBreak(clock, 1.8, limits), "3 per crash")
	check(Score.mayBreak(clock, 3, limits), "a new crash")
end)

test("emotes: wheel, slots and poses", function()
	local free = { passes = {}, inventory = {}, rider = { emotes = {} } }
	local pass = { passes = { rider = true }, inventory = {}, rider = { emotes = {} } }
	-- Every emote in the catalog has a pose, and every pose is in the catalog
	local catalogEmotes = 0
	for _, item in Catalog.items do
		if item.kind == "emote" then
			catalogEmotes += 1
			check(Emotes.defs[item.id] ~= nil, item.id .. " has a pose")
			check(item.coins == nil, item.id .. " is never sold for coins")
		end
	end
	local defs = 0
	for id, def in Emotes.defs do
		defs += 1
		check(Catalog.byId[id] ~= nil and Catalog.byId[id].kind == "emote", id .. " is a catalog emote")
		check(def.duration >= 1 and def.duration <= 3, id .. " lasts 1 to 3 s")
		check(#def.label > 0 and #def.label <= 8, id .. " short preset label")
	end
	check(defs == catalogEmotes and defs == 8, "8 emotes (4 free, 4 Rider Pass)")
	-- Wheel sizes and the free start
	local w = Emotes.wheel(free)
	check(#w == 4, "4 slots without the pass")
	for i, id in Emotes.DEFAULT do
		check(w[i] == id and Emotes.canUse(free, id), "free emote " .. id .. " in slot " .. i)
	end
	local wp = Emotes.wheel(pass)
	check(#wp == 6 and wp[5] == "" and wp[6] == "", "6 slots with the pass, 5 and 6 empty")
	-- Pass emotes
	check(not Emotes.canUse(free, "emote_wave"), "wave needs the Rider Pass")
	check(Emotes.canUse(pass, "emote_wave"), "wave with the Rider Pass")
	check(Emotes.setSlot(free, 1, "emote_wave") == nil, "can't slot a pass emote without the pass")
	check(Emotes.setSlot(free, 5, "emote_thumbs") == nil, "no slot 5 without the pass")
	check(
		Emotes.setSlot(free, 0, "emote_thumbs") == nil and Emotes.setSlot(free, 1.5, "") == nil,
		"bad slots"
	)
	check(Emotes.setSlot(pass, 1, "nope") == nil, "unknown emote")
	local saved = Emotes.setSlot(pass, 5, "emote_wave") :: { string }
	check(
		saved ~= nil and #saved == 6 and saved[5] == "emote_wave" and saved[1] == "emote_thumbs",
		"slot 5 filled"
	)
	pass.rider.emotes = saved
	-- Moving an emote empties its old slot
	local moved = Emotes.setSlot(pass, 6, "emote_wave") :: { string }
	check(moved[6] == "emote_wave" and moved[5] == "", "an emote moves between slots")
	-- A refunded pass hides its emotes and slots, and buying it back restores them
	local lapsed = { passes = {}, inventory = {}, rider = { emotes = moved } }
	local lw = Emotes.wheel(lapsed)
	check(#lw == 4 and table.find(lw, "emote_wave") == nil, "pass emotes hidden without the pass")
	local kept = Emotes.setSlot(lapsed, 1, "") :: { string }
	check(kept[6] == "emote_wave" and kept[1] == "", "hidden pass slots kept while editing")
	-- An emptied wheel stays empty (not reset to the defaults)
	local cleared = { passes = {}, inventory = {}, rider = { emotes = { "", "", "", "", "", "" } } }
	check(Emotes.wheel(cleared)[1] == "", "an emptied slot stays empty")
	-- Poses: blend in, hold, blend out, and the spin ends where it started
	for id, def in Emotes.defs do
		local _, w0 = Emotes.pose(id, 0)
		local angles, wMid = Emotes.pose(id, def.duration / 2)
		local _, wEnd = Emotes.pose(id, def.duration)
		check(w0 == 0 and wMid == 1 and wEnd == 0, id .. " eases in and out")
		for _, piece in Emotes.PIECES do
			local a = angles[piece]
			check(a ~= nil and a.x == a.x and a.y == a.y and a.z == a.z, id .. " " .. piece .. " angles")
		end
	end
	local _, wNone = Emotes.pose("nope", 0.5)
	check(wNone == 0, "an unknown emote does nothing")
	local spinEnd = Emotes.pose("emote_spin", Emotes.defs.emote_spin.duration - 1e-3)
	check(
		math.abs(spinEnd.Torso.y % 360) < 1 or math.abs(spinEnd.Torso.y % 360 - 360) < 1,
		"spin ends facing forward"
	)
	-- The profile view sends the wheel
	local profile = ProfileSchema.default()
	local view = ProfileSchema.clientView(profile)
	check(view.rider.emotes ~= nil and #view.rider.emotes == 4, "profile view has the emote wheel")
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
				"DamageModel",
				"GhostCodec",
				"ProfileSchema",
				"StarterMaps",
				"MapSpace",
				"MapBuilder",
				"MapCodec",
				"MapNames",
				"MapRules",
				"MapStats",
				"Catalog",
				"Looks",
				"Quests",
				"ShopMath",
				"Round",
				"RaceMath",
				"Boards",
				"BrawlMath",
				"HighwayMath",
				"Score",
				"Emotes",
				"Place",
				"Movers",
				"PieceCatalog",
				"TracksMath",
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
				"Debris",
				"DamageController",
				"CrashReplay",
				"ProfileClient",
				"SettingsMenu",
				"TracksClient",
				"BuilderClient",
				"BrowseClient",
				"ShopClient",
				"RaceClient",
				"HubClient",
				"BrawlClient",
				"HighwayClient",
				"Telemetry",
				"AudioController",
				"EmoteClient",
			}
		do
			check(client ~= nil and client:FindFirstChild("Controllers"):FindFirstChild(name) ~= nil, name)
		end
		for _, name in { "DamageVisuals", "ExplosionFx", "MeshDents", "Confetti", "LookFx", "Mix", "JuiceFx" } do
			local fx = client and client:FindFirstChild("Fx")
			check(fx ~= nil and fx:FindFirstChild(name) ~= nil, "Fx." .. name)
		end
		local ui = client and client:FindFirstChild("Ui")
		check(ui ~= nil and ui:FindFirstChild("TracksHud") ~= nil, "Ui.TracksHud")
		check(ui ~= nil and ui:FindFirstChild("BuilderHud") ~= nil, "Ui.BuilderHud")
		check(ui ~= nil and ui:FindFirstChild("BrowseHud") ~= nil, "Ui.BrowseHud")
		check(ui ~= nil and ui:FindFirstChild("ShopHud") ~= nil, "Ui.ShopHud")
		check(ui ~= nil and ui:FindFirstChild("HubHud") ~= nil, "Ui.HubHud")
		check(ui ~= nil and ui:FindFirstChild("RaceHud") ~= nil, "Ui.RaceHud")
		check(ui ~= nil and ui:FindFirstChild("BrawlHud") ~= nil, "Ui.BrawlHud")
		check(ui ~= nil and ui:FindFirstChild("HighwayHud") ~= nil, "Ui.HighwayHud")
		for _, name in { "Road", "Traffic", "Clip" } do
			local highway = client and client:FindFirstChild("Highway")
			check(highway ~= nil and highway:FindFirstChild(name) ~= nil, "Highway." .. name)
		end
		local services = server and server:FindFirstChild("Services")
		for _, name in
			{
				"CollisionGroups",
				"DataService",
				"EconomyService",
				"BuilderService",
				"MapService",
				"MapStore",
				"MapPlayService",
				"ModerationService",
				"BrowseService",
				"ShopService",
				"PurchaseService",
				"QuestService",
				"RoundManager",
				"RaceService",
				"PartyService",
				"HubService",
				"TeleportHub",
				"BoardService",
				"BrawlService",
				"BrawlArena",
				"BrawlBots",
				"BoardStore",
				"HighwayService",
				"Analytics",
				"LiveCounts",
				"TestTrack",
				"TracksService",
				"VehicleService",
			}
		do
			check(services ~= nil and services:FindFirstChild(name) ~= nil, "Services." .. name)
		end
		local first = game:GetService("ReplicatedFirst"):FindFirstChild("LoadingScreen")
		check(first ~= nil and first.ClassName == "LocalScript", "ReplicatedFirst.LoadingScreen")
		check(game:GetService("Players").CharacterAutoLoads == false, "no avatar characters")
		check(game:GetService("Workspace").StreamingEnabled == true, "streaming on")
		check(game:GetService("Workspace"):GetAttribute("PlaceRole") == nil, "the hub place has no PlaceRole")
	end)
	-- The Cinder Cove place files are the same tree plus the Brawl role (and Ranked for the ranked one)
	test("Brawl place files", function()
		local fs = require("@lune/fs")
		local serde = require("@lune/serde")
		local base = serde.decode("json", fs.readFile("default.project.json"))
		for file, ranked in { ["brawl.project.json"] = false, ["ranked.project.json"] = true } do
			local project = serde.decode("json", fs.readFile(file))
			local attributes = project.tree.Workspace["$attributes"] or {}
			check(attributes.PlaceRole == "Brawl", file .. " PlaceRole")
			check((attributes.Ranked == true) == ranked, file .. " Ranked")
			check(attributes.Versus == nil, file .. " no Versus")
			for key in base.tree do
				check(project.tree[key] ~= nil, file .. " has " .. key)
			end
			check(
				serde.encode("json", project.tree.ServerScriptService)
					== serde.encode("json", base.tree.ServerScriptService),
				file .. " same server tree"
			)
		end
	end)
	-- The Sunny Pass place files: the same tree plus the Highway role (and Versus for the versus one)
	test("Highway place files", function()
		local fs = require("@lune/fs")
		local serde = require("@lune/serde")
		local base = serde.decode("json", fs.readFile("default.project.json"))
		for file, versus in { ["highway.project.json"] = false, ["versus.project.json"] = true } do
			local project = serde.decode("json", fs.readFile(file))
			local attributes = project.tree.Workspace["$attributes"] or {}
			check(attributes.PlaceRole == "Highway", file .. " PlaceRole")
			check((attributes.Versus == true) == versus, file .. " Versus")
			check(attributes.Ranked == nil, file .. " no Ranked")
			for key in base.tree do
				check(project.tree[key] ~= nil, file .. " has " .. key)
			end
			for _, key in { "ServerScriptService", "ReplicatedStorage", "ReplicatedFirst", "StarterPlayer" } do
				check(
					serde.encode("json", project.tree[key]) == serde.encode("json", base.tree[key]),
					file .. " same " .. key
				)
			end
		end
	end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
