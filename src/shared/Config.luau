--!strict
-- Config: every tuning number in the build spec, as data.
-- Values marked (tune) are starting values to adjust during playtests; when a value changes here,
-- note it in notes/Decisions.md so the spec and the code stay in step.
-- Pure data: no Roblox types, so the tests can load it outside Studio. Vectors are { x, y, z } and
-- colours are { r, g, b } in 0-255; use Config.vec3 / Config.color3 to convert inside Roblox.
-- Units: studs, seconds, studs/s. The speedometer shows mph = studs/s * Config.World.mphPerStudPerSecond.

local Config = {}

Config.Version = "0.4.0-m3"

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
Config.World = {
	-- Roblox's default is 196.2. At that value a kicker or bouncer gives well under 1 s of air, so the
	-- spec's air control, flips (300 points per flip) and 1.5 s air lean cannot happen. 120 keeps landings
	-- heavy but gives about 1.2 s of air off a bouncer pad. (tune) See notes/Decisions.md.
	gravity = 120,
	mphPerStudPerSecond = 0.63,
	killY = -60, -- falling below this resets the car to the last checkpoint
}

---------------------------------------------------------------------------
-- Vehicle classes (spec: Vehicle physics > Class tuning table). Same class = same stats, always.
---------------------------------------------------------------------------
export type ClassStats = {
	id: string,
	relativeMass: number,
	topSpeed: number,
	timeToTop: number,
	springFrequency: number,
	dampingRatio: number,
	suspensionTravel: number,
	grip: number,
	leanRate: number, -- deg/s
	zoneHealthMultiplier: number,
	knockbackTakenMultiplier: number,
	drive: string, -- "rear" or "all"
	-- Body geometry (placeholder art until the vehicle models are built in Studio)
	colliderSize: { number }, -- x, y, z
	wheelRadius: number,
	wheelWidth: number,
	halfTrack: number, -- wheel x offset from centre
	frontAxleZ: number, -- negative = forward (Roblox LookVector is -Z)
	rearAxleZ: number,
	mountY: number, -- suspension top, relative to chassis centre
	seatOffset: { number },
	riderScale: number,
	cameraDistance: number,
	cameraHeight: number,
}

Config.Classes = {
	Buggy = {
		id = "Buggy",
		relativeMass = 0.6,
		topSpeed = 100,
		timeToTop = 2.6,
		springFrequency = 3.4,
		dampingRatio = 0.65,
		suspensionTravel = 2.0,
		grip = 1.10,
		leanRate = 200,
		zoneHealthMultiplier = 0.8,
		knockbackTakenMultiplier = 1.25,
		drive = "all",
		colliderSize = { 5, 1.6, 8 },
		wheelRadius = 1.4,
		wheelWidth = 1.2,
		halfTrack = 2.9,
		frontAxleZ = -2.9,
		rearAxleZ = 2.7,
		mountY = 0.2,
		seatOffset = { 0, 0.2, 0.4 },
		riderScale = 0.85,
		cameraDistance = 15,
		cameraHeight = 5.5,
	} :: ClassStats,
	Sedan = {
		id = "Sedan",
		relativeMass = 1.0,
		topSpeed = 108,
		timeToTop = 2.9,
		springFrequency = 3.2,
		dampingRatio = 0.70,
		suspensionTravel = 1.2,
		grip = 1.20,
		leanRate = 140,
		zoneHealthMultiplier = 1.0,
		knockbackTakenMultiplier = 1.0,
		drive = "rear",
		colliderSize = { 6, 2.2, 11 },
		wheelRadius = 1.3,
		wheelWidth = 1.1,
		halfTrack = 2.9,
		frontAxleZ = -3.7,
		rearAxleZ = 3.6,
		mountY = -0.4,
		seatOffset = { -1.1, 0, 0.3 },
		riderScale = 0.8,
		cameraDistance = 17,
		cameraHeight = 6,
	} :: ClassStats,
	Truck = {
		id = "Truck",
		relativeMass = 1.8,
		topSpeed = 96,
		timeToTop = 3.1,
		springFrequency = 3.0,
		dampingRatio = 0.75,
		suspensionTravel = 1.5,
		grip = 1.00,
		leanRate = 100,
		zoneHealthMultiplier = 1.4,
		knockbackTakenMultiplier = 0.75,
		drive = "all",
		colliderSize = { 7, 2.6, 13 },
		wheelRadius = 1.7,
		wheelWidth = 1.4,
		halfTrack = 3.3,
		frontAxleZ = -4.4,
		rearAxleZ = 4.2,
		mountY = -0.3,
		seatOffset = { -1.3, 0.2, -2.6 },
		riderScale = 0.85,
		cameraDistance = 20,
		cameraHeight = 7,
	} :: ClassStats,
	Bus = {
		id = "Bus",
		relativeMass = 2.6,
		topSpeed = 88,
		timeToTop = 3.3,
		springFrequency = 3.0,
		dampingRatio = 0.75,
		suspensionTravel = 1.0,
		grip = 0.90,
		leanRate = 70,
		zoneHealthMultiplier = 1.8,
		knockbackTakenMultiplier = 0.6,
		drive = "rear",
		colliderSize = { 7.5, 5, 20 },
		wheelRadius = 1.6,
		wheelWidth = 1.4,
		halfTrack = 3.4,
		frontAxleZ = -6.6,
		rearAxleZ = 6.2,
		mountY = -1.6,
		seatOffset = { -2, -1.4, -7.4 },
		riderScale = 0.9,
		cameraDistance = 26,
		cameraHeight = 9,
	} :: ClassStats,
}

---------------------------------------------------------------------------
-- Vehicles (spec: Progression > Launch vehicles). Prices are used from milestone 5.
---------------------------------------------------------------------------
export type VehicleDef = {
	id: string,
	displayName: string,
	class: string,
	hopSpeed: number, -- 0 = no JUMP button
	unlock: { coins: number, stars: number, mastery: { vehicle: string, level: number }? },
	paint: { number }, -- RGB 0-255
	trim: { number },
}

Config.Vehicles = {
	starter_buggy = {
		id = "starter_buggy",
		displayName = "Starter Buggy",
		class = "Buggy",
		hopSpeed = 12,
		unlock = { coins = 0, stars = 0 },
		paint = { 255, 176, 59 },
		trim = { 60, 64, 80 },
	} :: VehicleDef,
	pocket_sedan = {
		id = "pocket_sedan",
		displayName = "Pocket Sedan",
		class = "Sedan",
		hopSpeed = 0,
		unlock = { coins = 1200, stars = 0 },
		paint = { 86, 170, 255 },
		trim = { 240, 240, 245 },
	} :: VehicleDef,
	dune_hopper = {
		id = "dune_hopper",
		displayName = "Dune Hopper",
		class = "Buggy",
		hopSpeed = 12,
		unlock = { coins = 600, stars = 0, mastery = { vehicle = "starter_buggy", level = 3 } },
		paint = { 120, 220, 110 },
		trim = { 70, 50, 40 },
	} :: VehicleDef,
	fizz_wagon = {
		id = "fizz_wagon",
		displayName = "Fizz Wagon",
		class = "Sedan",
		hopSpeed = 0,
		unlock = { coins = 3000, stars = 0 },
		paint = { 255, 105, 180 },
		trim = { 255, 240, 200 },
	} :: VehicleDef,
	haul_hog = {
		id = "haul_hog",
		displayName = "Haul Hog",
		class = "Truck",
		hopSpeed = 0,
		unlock = { coins = 5000, stars = 10 },
		paint = { 220, 70, 60 },
		trim = { 50, 50, 55 },
	} :: VehicleDef,
	bumble_bus = {
		id = "bumble_bus",
		displayName = "Bumble Bus",
		class = "Bus",
		hopSpeed = 0,
		unlock = { coins = 9000, stars = 25 },
		paint = { 255, 214, 10 },
		trim = { 35, 35, 40 },
	} :: VehicleDef,
}

Config.DefaultVehicle = "starter_buggy"
-- One vehicle per class for the milestone 1 test track's class picker.
Config.TestTrackVehicles = { "starter_buggy", "pocket_sedan", "haul_hog", "bumble_bus" }

---------------------------------------------------------------------------
-- Driving model (spec: Vehicle physics > Model)
---------------------------------------------------------------------------
Config.Driving = {
	baseMass = 100, -- mass of a sedan (relative mass 1.0)
	-- Engine force curve: 100% from 0 to 60% of top speed, then falling linearly to 0 at top speed.
	torqueFlatFraction = 0.6,
	-- "Reaches top speed" in the feel test means this fraction of top speed. Base acceleration is derived
	-- from the class's timeToTop so the class table stays the only source.
	topSpeedReachFraction = 0.98,
	brakeMultiplier = 1.6, -- brake decel = 1.6 x base accel
	reverseTopSpeedFraction = 0.35,
	handbrakeRearGripFraction = 0.55,
	rollingResistance = 6, -- studs/s^2 when coasting (tune)
	maxSteerAtZero = 32, -- degrees
	maxSteerAtTop = 10,
	steerRampTime = 0.12, -- keyboard and touch; sticks are instant
	-- Tyres: lateral force = clamp(-slip * stiffness, +-mu * load). Stiffness is per corner mass, per second. (tune)
	lateralStiffness = 28,
	-- Tyre forces are applied part way up from the contact patch to the centre of mass, to keep the
	-- roll moment sane (1 = at the contact patch, 0 = at the centre of mass). (tune)
	tireForceHeightFactor = 0.35,
	-- Damper (see VehicleMath.suspensionStep): progressive above this compression speed, stronger on
	-- rebound, plus a bump stop past full compression. Tuned in tests/run.luau's drop simulation so a
	-- 20-stud drop settles in about 0.2 s with no rebound at 60 and 30 fps. (tune)
	progressiveDampingSpeed = 15,
	reboundDampingMultiplier = 1.5,
	bumpStopStiffnessMultiplier = 3,
	bumpStopDampingMultiplier = 6,
	-- Grip never uses more than this many g of load per wheel (big landings would otherwise glue the car)
	maxGripLoadG = 4,
	-- Arcade assists (spec: downforce 0.5 x weight at top speed, scaled by speed^2; yaw damping 0.35)
	downforceAtTop = 0.5,
	antiRollStiffness = 10, -- 1/s^2 restoring roll accel per radian of roll, while grounded (tune)
	antiRollDamping = 4, -- 1/s (tune)
	yawDamping = 0.35, -- fraction of the unexplained yaw rate removed per 0.1 s (tune)
	yawDampingHandbrakeFactor = 0.25,
	countersteer = { Off = 0, Low = 0.2, High = 0.4 }, -- fraction of the slip angle (spec: 40%)
	-- Air control: active when 3 or more wheels are off the ground
	airWheelsOffForControl = 3,
	airRollFraction = 0.5, -- steer rolls the car at half the lean rate
	airMaxRateMultiplier = 1.5,
	airResponseTime = 0.15,
	-- Recovery
	flipAfter = 1.5, -- seconds resting on roof or side before FLIP pulses
	flipDuration = 0.4,
	resetDuration = 0.5,
	hopCooldown = 0.6,
	-- Physics update. The spec asks for 240 Hz; Luau can only run once per frame (PreSimulation), so the
	-- controller runs at frame rate and clamps the step. See notes/Decisions.md.
	maxStep = 1 / 30,
}

---------------------------------------------------------------------------
-- Weight cues and camera (spec: Weight cues)
---------------------------------------------------------------------------
Config.Camera = {
	lagAtRest = 0.08,
	lagAtTop = 0.18,
	fovAtRest = 70,
	fovAtTop = 82,
	brakePitchDegrees = 3,
	brakePitchDecel = 60, -- studs/s^2 of deceleration that counts as hard braking
	lookAhead = 4,
	orbitReturnDelay = 1.5,
	orbitReturnSpeed = 3,
	ragdollDistance = 14,
	ragdollHeight = 6,
	maxShake = 1.2,
}

Config.VisualBody = {
	maxRollDegrees = 6,
	maxPitchDegrees = 4,
}

Config.Surface = {
	skidSlipSpeed = 8, -- tyre squeal and skid marks above this lateral slip
	skidLifetime = 3,
	dustMaterials = { "Sand", "Ground", "Grass", "Mud", "LeafyGrass" },
	creakCompression = 0.7,
}

---------------------------------------------------------------------------
-- Impacts (spec: Crashes, damage and explosions > Impact)
---------------------------------------------------------------------------
Config.Impact = {
	massFactorMin = 0.5,
	massFactorMax = 2.0,
	staticMassFactor = 2.0,
	pairCooldown = 0.25,
	-- Minimum unexplained change in velocity in one frame before we treat it as a contact.
	detectMinDeltaV = 3,
	tiers = {
		{ name = "Scrape", min = 0 },
		{ name = "Bump", min = 10 },
		{ name = "HardHit", min = 25 },
		{ name = "HugeCrash", min = 60 },
	},
	-- A contact whose normal points within this dot of the car's up axis is a landing on the wheels or belly.
	landingNormalDot = 0.7,
	roofNormalDot = -0.6,
}

---------------------------------------------------------------------------
-- Damage (spec: Damage zones, Damage by mode, Explosions, Mesh deformation, Repairs). Every number (tune).
---------------------------------------------------------------------------
Config.Damage = {
	bodyHealth = 100, -- front, rear, left, right, roof; times the class zoneHealthMultiplier and the mode's
	wheelHealth = 60,
	impactOffset = 15, -- damage to the hit zone = max(0, I - 15) x 1.2
	impactScale = 1.2,
	spillFraction = 0.25, -- to each adjacent zone
	wheelShare = 0.5, -- wheels take 50% of front or side damage on that corner
	landingWheelSpeed = 50, -- landings above this fall speed damage the wheels that touched down
	-- Look thresholds as a fraction of zone health: clean 67-100%, dented 34-66%, crushed 1-33%, 0 destroyed
	dentedBelow = 0.67,
	crushedBelow = 0.34,
	handling = {
		frontDentedTopSpeed = 0.95,
		frontCrushedTopSpeed = 0.85,
		wheelDentedPull = 2, -- degrees toward the damaged wheel
		wheelCrushedPull = 5,
		maxPull = 8,
		wheelCrushedGrip = 0.8,
		wheelLostDrive = 0.25, -- drive force lost per missing wheel
		axleDragG = 0.6, -- friction of a dragging axle, in g of that corner's weight
	},
	fireTime = 3.0, -- front at 0: flames for 3 s, then the explosion
	wreckWheels = 3,
	shockwave = { radius = 18, push = 45, up = 20, damage = 30 },
	explosionPanels = { 4, 6 },
	ownExplosionHop = 18, -- the exploding car jumps a little (studs/s up)
	riderBlastUp = 45, -- rider thrown clear upward, unharmed
	maxFullExplosions = 2, -- per client at once; extras are a small pop with a smoke puff
	sendMaxRate = 4, -- Damage.State sends per second at most
	resendInterval = 3, -- while damaged, resend the state so a lost packet never sticks
	debris = { max = 12, fadeAt = 2.5, lifetime = 3.0, spin = 8, speed = 22, up = 18 },
	-- Damage by mode: looks, handling, explosions, health multiplier
	modes = {
		TestTrack = { looks = true, handling = true, explosion = true, health = 1.0 },
		Tracks = { looks = true, handling = true, explosion = true, health = 1.0 },
		TracksRace = { looks = true, handling = false, explosion = false, health = 1.0 },
		TracksFullDamage = { looks = true, handling = true, explosion = true, health = 1.0 },
		Brawl = { looks = true, handling = true, explosion = true, health = 1.5 },
		Highway = { looks = true, handling = true, explosion = true, health = 3.0 },
	},
	-- Mesh deformation on the body shell (EditableMesh, verify limits)
	deform = {
		maxCars = 4,
		range = 60,
		maxVertices = 1500,
		vertexSpacing = 1.0,
		radiusBase = 1.5, -- r = 1.5 + I / 40
		radiusPerImpact = 1 / 40,
		pushPerImpact = 1 / 100, -- push = min(0.8, I / 100)
		maxPush = 0.8,
		maxTotal = 1.2,
		benchmarkTime = 5,
		benchmarkMinFps = 45,
		minQualityLevel = 4, -- if the player set graphics quality by hand below this, dents start off
	},
}

-- Hit-stop and the slow-mo crash replay (spec: Impact). Physics never slows: the replay is a playback.
Config.CrashFx = {
	hitStopMin = 0.04, -- hard hit: 40 to 80 ms scaled by Impact
	hitStopMax = 0.08,
	hitStopHuge = 0.08,
	replayBuffer = 3.0,
	replayRate = 30,
	replayWindow = 0.6, -- the last 0.6 s plays at half speed for 1.2 s
	replaySpeed = 0.5,
	replayDelay = 0.3, -- wait this long after the crash so the replay shows the aftermath too
	replayModes = { TestTrack = true, Tracks = true, Highway = true },
	crashCamDistance = 16,
	crashCamHeight = 6,
}

---------------------------------------------------------------------------
-- Rider (spec: Rider ragdoll and bone breaks)
---------------------------------------------------------------------------
Config.Rider = {
	massFractionOfSedan = 0.08,
	jointCone = { neck = 40, shoulder = 110, hip = 80 },
	jointTwist = { neck = 30, shoulder = 45, hip = 30 },
	lifetime = 4.0,
	fadeTime = 0.3,
	respawnButtonAfter = 1.0,
	ejectVelocityFactor = 0.8,
	ejectUpSpeed = 25,
	flailImpulse = 18,
	ownCarNoCollideTime = 0.5,
	poseRate = 10, -- Hz
	interpolationDelay = 0.1,
	hazardKickUp = 20, -- extra upward speed when a hazard (a spinner) throws the rider
	-- Highway only: ejected rider auto-respawns into the moving car (used from milestone 8)
	highwayAutoRespawn = 1.5,
	colors = {
		suit = { 255, 120, 40 },
		skin = { 255, 214, 170 },
		helmet = { 250, 250, 255 },
		boots = { 50, 50, 60 },
	},
}

-- When the rider is thrown, per mode (spec: When the rider ejects)
Config.EjectRules = {
	TestTrack = { hugeCrash = true, roofLanding = true, roofLandingSpeed = 40, hazard = true },
	Tracks = { hugeCrash = true, roofLanding = true, roofLandingSpeed = 40, hazard = true },
	Brawl = { hugeCrash = false, roofLanding = false, roofLandingSpeed = 40, hazard = false },
	Highway = { hugeCrash = true, roofLanding = true, roofLandingSpeed = 40, hazard = false },
}

---------------------------------------------------------------------------
-- Milestone 1 test track: spots the dev panel's scripted feel tests use (ground level, facing -Z)
---------------------------------------------------------------------------
Config.TestTrack = {
	accelStart = { 0, 0, 30 },
	openGround = { 320, 0, -300 },
	dropSpot = { 320, 0, 100 },
	crashWallZ = -760,
	dropHeight = 20,
	ramSpeeds = { 6, 15, 35 }, -- into a static wall: expected Impact 12, 30, 70 (Bump, HardHit, HugeCrash)
}

Config.Pads = {
	bouncerUpSpeed = 70,
	speedPadBoost = 30,
}

---------------------------------------------------------------------------
-- UI (spec: Screens and UI)
---------------------------------------------------------------------------
Config.UI = {
	minTapTarget = 64, -- px at 1080p
	controlSizeMin = 0.8,
	controlSizeMax = 1.4,
	toastTime = 2,
}

---------------------------------------------------------------------------
-- Juice (spec: Audio, VFX and juice). Sound ids are empty until nate picks licensed sounds in Studio.
---------------------------------------------------------------------------
Config.Sounds = {
	Engine = "",
	Landing = "",
	Bump = "",
	HardHit = "",
	HugeCrash = "",
	Hop = "",
	RiderEject = "",
	Respawn = "",
	Checkpoint = "",
	TireSqueal = "",
	SuspensionCreak = "",
	PanelTear = "",
	GlassShatter = "",
	FireStart = "",
	Explosion = "",
	ExplosionSmall = "",
	Repair = "",
	Coin = "",
	Finish = "",
	Honk = "",
	StarEarned = "",
	BuilderPlace = "", -- click-snap
	BuilderRemove = "",
	Publish = "", -- fanfare
	PistonPush = "",
}

Config.Juice = {
	Landing = { shake = 0.25, shakeTime = 0.1, vibration = 0.2, vibrationTime = 0.04 },
	Bump = { shake = 0.15, shakeTime = 0.1, vibration = 0.4, vibrationTime = 0.04, sparks = 6 },
	HardHit = {
		shake = 0.6,
		shakeTime = 0.15,
		punch = 0.8,
		vibration = 0.7,
		vibrationTime = 0.08,
		sparks = 14,
	},
	HugeCrash = {
		shake = 1.0,
		shakeTime = 0.25,
		punch = 1.4,
		vibration = 1,
		vibrationTime = 0.12,
		sparks = 24,
	},
	Hop = {},
	RiderEject = { shake = 0.3, shakeTime = 0.1 },
	Respawn = {},
	Checkpoint = { vibration = 0.3, vibrationTime = 0.04 },
	PanelTear = { sparks = 8 },
	GlassShatter = {},
	FireStart = { vibration = 0.3, vibrationTime = 0.06 },
	-- Explosion shake is scaled by distance (1 at the blast, 0 at 60 studs)
	Explosion = { shake = 1.2, shakeTime = 0.35, vibration = 1, vibrationTime = 0.15 },
	ExplosionSmall = { shake = 0.3, shakeTime = 0.12 },
	Repair = {},
	Coin = {},
	Finish = { shake = 0.2, shakeTime = 0.1, vibration = 0.5, vibrationTime = 0.08 },
	Honk = {},
	StarEarned = { vibration = 0.4, vibrationTime = 0.05 },
}

---------------------------------------------------------------------------
-- Tracks (spec: Tracks: free run; Onboarding; Anti-exploit). Every reward number is (tune).
---------------------------------------------------------------------------
Config.Tracks = {
	silverFactor = 1.5, -- Silver = under creator time x 1.5 (2 stars)
	goldFactor = 1.1, -- Gold = under creator time x 1.1 (3 stars)
	coinsStarter = 50,
	coinsPlayerMap = 30,
	fullPayFinishesPerDay = 3, -- per map per day, then
	reducedCoins = 5,
	dailyCap = 1200,
	minTimeFactor = 0.6, -- a finish faster than creator time x 0.6 (floor 5 s) is rejected
	minTimeFloor = 5,
	speedCheckRate = 4, -- server position samples per second
	-- Speed and fly hacks: any 4 Hz step faster than this resets the car to its last checkpoint and flags
	speedLimitFactor = 1.4, -- max speed x 1.4 plus launch allowances
	launchAllowance = 90, -- studs/s added for bouncers, speed pads and falls
	-- Fake finish: over any 1 s window, ground covered (horizontal) above top speed x 1.25 rejects the run
	windowFactor = 1.25,
	windowSeconds = 1,
	speedFlagsToKick = 5,
	rejectsForBoardBan = 3, -- 3 rejects in 10 minutes = no leaderboard posts for the day
	ghostRate = 5, -- ghost samples per second
	maxGhostSeconds = 180,
	maxStoredGhosts = 20, -- most recent maps keep a ghost; starter maps always do
	autoNextTime = 5,
	resultsSkippableAfter = 2,
	idleHonkTime = 6, -- Pip's Hill: idle this long and Pip honks and points
	jumpCueLead = 1, -- JUMP pulses this long before the lip
	firstTracksAssist = "High", -- steering assist forced for the first 2 tracks
	trailCoinValue = 1, -- each trail coin is worth this at the finish, up to the map's coin count
	reportDistance = 80, -- a checkpoint or finish report counts only with the car this close (studs)
	respawnAllowance = 25, -- a jump that lands this close to a respawn point is a reset, not speed
	pipHillCoins = 100,
	pipHillStars = 1,
}

---------------------------------------------------------------------------
-- Map builder (spec: Map builder > Grid and limits, Publish rules). Piece limits live in Shared/MapRules.
---------------------------------------------------------------------------
Config.Builder = {
	draftSlots = 3, -- free
	vipDraftSlots = 10,
	maxDraftSlots = 15, -- with Extra Slot products
	livePublished = 5, -- free
	vipLivePublished = 15,
	publishCooldown = 600, -- 1 publish per 10 minutes
	minFinishes = 1, -- before the first publish: 1 finished Tracks run
	minPlaySeconds = 900, -- and 15 minutes of play
	-- Studio only, so the gates can be tried in one sitting: 1 minute of play and a 1 minute cooldown
	studioPlaySeconds = 60,
	studioCooldown = 60,
	boardResetChange = 0.1, -- a republish that moves the creator time over 10% resets the leaderboard
	autosaveInterval = 30,
	undoSteps = 50,
	-- Build plots: one per player in this server, far from the starter maps (map space is centred on it)
	plotOrigin = { 0, 0, 6000 },
	plotSpacing = 1300,
	maxPlots = 16,
	buildBatch = 40, -- server builds of player maps: pieces per frame (spec: Map loading)
	testTimeout = 4, -- seconds a TEST waits for the server to put the car on the plot
}

-- The next-goal bar shows the cheapest goal not yet afforded (the shop arrives in milestone 5).
Config.Goals = {
	{ id = "starter_paint", label = "Starter paint", coins = 200 },
	{ id = "pocket_sedan", label = "Pocket Sedan", coins = 1200 },
	{ id = "fizz_wagon", label = "Fizz Wagon", coins = 3000 },
	{ id = "haul_hog", label = "Haul Hog", coins = 5000, stars = 10 },
	{ id = "bumble_bus", label = "Bumble Bus", coins = 9000, stars = 25 },
}

-- Economy (spec: Coin faucets and caps)
Config.Economy = {
	friendBoostPerFriend = 0.10,
	friendBoostMax = 0.50,
	rebirthBonusPer = 0.05,
	rebirthBonusMax = 0.50,
}

-- Settings: defaults (same as the saved profile) and allowed values (spec: Settings screen)
Config.Settings = {
	defaults = {
		controlSize = 1.0,
		layout = "default",
		steerAssist = "high",
		shake = true,
		reducedMotion = false,
		reducedFlash = false,
		dents = "full",
		graphics = "auto",
		music = 0.6,
		sfx = 0.8,
	},
	choices = {
		layout = { "default", "lefthanded" },
		steerAssist = { "off", "low", "high" },
		dents = { "full", "panels" },
		graphics = { "auto", "low", "medium", "high" },
	},
	ranges = {
		controlSize = { 0.8, 1.4 },
		music = { 0, 1 },
		sfx = { 0, 1 },
	},
	saveInterval = 5, -- Settings.Save at most once per 5 s
}

-- Saves (spec: Data model). 1 read on join, 1 write per 60 s and on leave.
Config.Data = {
	storeName = "Player_v1",
	keyPrefix = "P_",
	autosaveInterval = 60,
	saveRetries = 3,
	lockStealAfter = 1800, -- a lock older than 30 minutes is a crashed server's: take it over
	lockWaitTries = 4, -- otherwise wait for the other server to let go (about 5 s apart)
	lockWaitTime = 5,
}

---------------------------------------------------------------------------
-- Admin and dev tools
---------------------------------------------------------------------------
Config.Admins = {
	-- nate's Roblox user id goes here (find it on the Roblox profile URL). Studio always counts as admin.
}

---------------------------------------------------------------------------
-- Net (spec: Remote rules)
---------------------------------------------------------------------------
Config.Net = {
	kickAfterFailures = 20,
	failureWindow = 60,
	kickInStudio = false,
}

function Config.vec3(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

function Config.color3(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

return Config
