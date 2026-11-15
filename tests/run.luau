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
			}
		do
			check(client ~= nil and client:FindFirstChild("Controllers"):FindFirstChild(name) ~= nil, name)
		end
		for _, name in { "DamageVisuals", "ExplosionFx", "MeshDents", "Confetti", "LookFx" } do
			local fx = client and client:FindFirstChild("Fx")
			check(fx ~= nil and fx:FindFirstChild(name) ~= nil, "Fx." .. name)
		end
		local ui = client and client:FindFirstChild("Ui")
		check(ui ~= nil and ui:FindFirstChild("TracksHud") ~= nil, "Ui.TracksHud")
		check(ui ~= nil and ui:FindFirstChild("BuilderHud") ~= nil, "Ui.BuilderHud")
		check(ui ~= nil and ui:FindFirstChild("BrowseHud") ~= nil, "Ui.BrowseHud")
		check(ui ~= nil and ui:FindFirstChild("ShopHud") ~= nil, "Ui.ShopHud")
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
				"TestTrack",
				"TracksService",
				"VehicleService",
			}
		do
			check(services ~= nil and services:FindFirstChild(name) ~= nil, "Services." .. name)
		end
		check(game:GetService("Players").CharacterAutoLoads == false, "no avatar characters")
		check(game:GetService("Workspace").StreamingEnabled == true, "streaming on")
	end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
