--!strict
-- Config: every tuning number in the build spec, as data.
-- Values marked (tune) are starting values to adjust during playtests; when a value changes here,
-- note it in notes/Decisions.md so the spec and the code stay in step.
-- Pure data: no Roblox types, so the tests can load it outside Studio. Vectors are { x, y, z } and
-- colours are { r, g, b } in 0-255; use Config.vec3 / Config.color3 to convert inside Roblox.
-- Units: studs, seconds, studs/s. The speedometer shows mph = studs/s * Config.World.mphPerStudPerSecond.

local Config = {}

Config.Version = "1.0.0-m9"

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
	unlock: {
		coins: number,
		stars: number,
		mastery: { vehicle: string, level: number }?,
		pass: string?, -- granted by a game pass (Stunt Set side-grades), never sold for coins
	},
	tier: number?, -- 1 = the 6 launch vehicles (own all 6 to rebirth); nil = pass side-grades
	paint: { number }, -- RGB 0-255
	trim: { number },
}

Config.Vehicles = {
	starter_buggy = {
		id = "starter_buggy",
		tier = 1,
		displayName = "Starter Buggy",
		class = "Buggy",
		hopSpeed = 12,
		unlock = { coins = 0, stars = 0 },
		paint = { 255, 176, 59 },
		trim = { 60, 64, 80 },
	} :: VehicleDef,
	pocket_sedan = {
		id = "pocket_sedan",
		tier = 1,
		displayName = "Pocket Sedan",
		class = "Sedan",
		hopSpeed = 0,
		unlock = { coins = 1200, stars = 0 },
		paint = { 86, 170, 255 },
		trim = { 240, 240, 245 },
	} :: VehicleDef,
	dune_hopper = {
		id = "dune_hopper",
		tier = 1,
		displayName = "Dune Hopper",
		class = "Buggy",
		hopSpeed = 12,
		unlock = { coins = 600, stars = 0, mastery = { vehicle = "starter_buggy", level = 3 } },
		paint = { 120, 220, 110 },
		trim = { 70, 50, 40 },
	} :: VehicleDef,
	fizz_wagon = {
		id = "fizz_wagon",
		tier = 1,
		displayName = "Fizz Wagon",
		class = "Sedan",
		hopSpeed = 0,
		unlock = { coins = 3000, stars = 0 },
		paint = { 255, 105, 180 },
		trim = { 255, 240, 200 },
	} :: VehicleDef,
	haul_hog = {
		id = "haul_hog",
		tier = 1,
		displayName = "Haul Hog",
		class = "Truck",
		hopSpeed = 0,
		unlock = { coins = 5000, stars = 10 },
		paint = { 220, 70, 60 },
		trim = { 50, 50, 55 },
	} :: VehicleDef,
	bumble_bus = {
		id = "bumble_bus",
		tier = 1,
		displayName = "Bumble Bus",
		class = "Bus",
		hopSpeed = 0,
		unlock = { coins = 9000, stars = 25 },
		paint = { 255, 214, 10 },
		trim = { 35, 35, 40 },
	} :: VehicleDef,
	-- Stunt Set pass: side-grades with their class's exact stats (looks only, design pillar)
	hop_rod = {
		id = "hop_rod",
		displayName = "Hop Rod",
		class = "Buggy",
		hopSpeed = 12,
		unlock = { coins = 0, stars = 0, pass = "stunt" },
		paint = { 160, 90, 255 },
		trim = { 255, 214, 10 },
	} :: VehicleDef,
	zippy_coupe = {
		id = "zippy_coupe",
		displayName = "Zippy Coupe",
		class = "Sedan",
		hopSpeed = 0,
		unlock = { coins = 0, stars = 0, pass = "stunt" },
		paint = { 40, 210, 200 },
		trim = { 30, 30, 40 },
	} :: VehicleDef,
	mud_muncher = {
		id = "mud_muncher",
		displayName = "Mud Muncher",
		class = "Truck",
		hopSpeed = 0,
		unlock = { coins = 0, stars = 0, pass = "stunt" },
		paint = { 140, 100, 60 },
		trim = { 230, 230, 230 },
	} :: VehicleDef,
}

-- The 6 launch vehicles in shop order (own all 6 to rebirth)
Config.TierOneVehicles =
	{ "starter_buggy", "pocket_sedan", "dune_hopper", "fizz_wagon", "haul_hog", "bumble_bus" }

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
	-- Bumper Brawl
	BrawlBump = "", -- rubbery thud
	TileWarn = "", -- rising beeps
	TileDrop = "", -- crumble
	KO = "", -- comic whistle splash
	PowerupGrab = "", -- sparkle
	HonkWave = "",
	ShieldUp = "",
	RankUp = "", -- brass hit
	Cheer = "",
	-- Highway Havoc
	Smash = "", -- traffic hit: crunch plus a cartoon boing
	ComboUp = "", -- rising chime per multiplier step
	ComboLost = "",
	NearMiss = "", -- whoosh
	Trick = "", -- air and flips
	PileUp = "", -- big brass sting
	BoneCrack = "", -- cartoon crack (no screams)
	XRay = "", -- zap
	HavocFull = "", -- the server meter fills
	RunOver = "",
}

-- Audio design (spec: Audio design). Every id is empty until nate picks licence-checked sounds.
Config.Audio = {
	-- Music: one loop per place (calm hub, busy Brawl, driving Highway), crossfaded, ducked during results
	music = { Hub = "", Brawl = "", Highway = "" },
	musicVolume = 0.5, -- of the Music setting
	crossfade = 1.5,
	duckDb = 6, -- quieter by 6 dB while a results card shows
	-- Engines: a hum for your car and the 3 nearest others, pitched by speed; none past 150 studs
	engine = { cars = 4, minPitch = 0.8, maxPitch = 1.6, topSpeed = 110, volume = 0.35, maxDistance = 150 },
	-- Juice events that are interface sounds (the UI group); the rest are SFX
	uiSounds = {
		Coin = true,
		StarEarned = true,
		ComboUp = true,
		ComboLost = true,
		BuilderPlace = true,
		BuilderRemove = true,
		Publish = true,
		RankUp = true,
		Cheer = true,
	},
	-- Voice lines (generated or none): one short clip per juice event, from Highway Hal (Highway) and
	-- Marla Sprocket (Brawl); at most one line every 2.5 s
	voice = {
		Finish = { place = "Brawl", id = "" }, -- "Round one!" at BUMP!
		KO = { place = "Brawl", id = "" }, -- "Splash!"
		TileWarn = { place = "Brawl", id = "" }, -- "Watch your step!"
		PileUp = { place = "Highway", id = "" }, -- "Pile-up!"
		BoneCrack = { place = "Highway", id = "" }, -- "Ouch, that's a crack!"
		RunOver = { place = "Highway", id = "" }, -- "What a ride!"
	},
	voiceGap = 2.5,
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
	Checkpoint = { vibration = 0.3, vibrationTime = 0.04, hitStop = 0.05 },
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
	-- Bumper Brawl (hit-stop 80 ms on a bump is in BrawlClient)
	BrawlBump = { shake = 0.3, shakeTime = 0.1, vibration = 0.5, vibrationTime = 0.04, sparks = 8 },
	TileWarn = {},
	TileDrop = { shake = 0.1, shakeTime = 0.1 },
	KO = { shake = 0.4, shakeTime = 0.15, vibration = 0.6, vibrationTime = 0.08 },
	PowerupGrab = { vibration = 0.3, vibrationTime = 0.04 },
	HonkWave = { shake = 0.2, shakeTime = 0.1 },
	ShieldUp = {},
	RankUp = { vibration = 0.5, vibrationTime = 0.08 },
	Cheer = {},
	-- Highway Havoc (the hit's own crash tier still plays its shake; these add the score layer)
	Smash = { vibration = 0.4, vibrationTime = 0.04, sparks = 10 },
	ComboUp = {},
	ComboLost = {},
	NearMiss = { vibration = 0.2, vibrationTime = 0.03 },
	Trick = { vibration = 0.3, vibrationTime = 0.04 },
	PileUp = { shake = 0.5, shakeTime = 0.2, vibration = 0.8, vibrationTime = 0.12 },
	BoneCrack = { shake = 0.35, shakeTime = 0.1, vibration = 0.7, vibrationTime = 0.06 },
	XRay = {},
	HavocFull = { vibration = 0.5, vibrationTime = 0.1 },
	RunOver = {},
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
	maxStoredTracks = 500, -- player maps keep best times, stars and ratings for the newest 500 (spec: ratings, last 500)
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

-- Player maps: playing, browsing, ratings, royalties and moderation (spec: Browse, Moderation,
-- Creator royalties). Every number is (tune) except the moderation rules, which are spec numbers.
Config.Maps = {
	coinsPerPlay = 5, -- royalties to the creator per play by someone else (once per player per map per day)
	royaltyDailyCap = 200,
	ratingsBeforeShown = 10, -- under this a card says "New" and Popular counts the map as 3.5 stars
	newMapRating = 3.5,
	popularDays = 7,
	flushInterval = 60, -- plays, finishers and ratings are batched into the map record this often
	popularInterval = 600, -- and the Popular index is rewritten this often for maps that changed
	pageSize = 9, -- browse cards per page (3 x 3)
	listLength = 90, -- ids read from an index per tab (10 pages)
	friendsChecked = 30, -- the Friends tab reads this many friends' map lists
	listCache = 60, -- seconds a tab's id list is reused
	-- Loaded player maps on this server: one slot each, built in batches, unloaded when unused
	slotOrigin = { 0, 0, -6000 },
	slotSpacing = 1300,
	maxLoaded = 24,
	unloadAfter = 60, -- seconds with nobody on it
	-- Moderation. nate (2026-11-15): hiding a map or a creator must be hard, so these are stricter than
	-- the spec's 5 reports / 10% / 3 days / 30 days. An auto-hide needs BOTH rules; only an admin's
	-- confirmed hide is a creator strike.
	reportsToHide = 15, -- counted reports...
	reportShare = 0.25, -- ...and more than 25% of the players who finished it
	reportMinAccountDays = 30, -- a report counts only from an account 30+ days old that finished the map
	strikeWindowDays = 90,
	strikesForBan = 3, -- 3 confirmed hides in 90 days
	banDays = { 7, 30 }, -- then permanent
	forever = 2 ^ 31 - 1,
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

-- Robux catalog (spec: Economy > Robux catalog). Prices are guesses to A/B test. Ids are 0 until nate
-- creates each pass and product in the Creator Dashboard (Monetization) and pastes its id here; with
-- an id of 0 the shop shows the card but the buy button says "Coming soon".
Config.Monetization = {
	passes = {
		rider = { id = 0, robux = 249, name = "Rider Pass" },
		vip = { id = 0, robux = 399, name = "VIP" },
		stunt = { id = 0, robux = 199, name = "Stunt Set" },
		explosions = { id = 0, robux = 149, name = "Explosion Styles" },
	},
	products = {
		starter = {
			id = 0,
			robux = 79,
			name = "Starter Pack",
			coins = 1000,
			items = { "trail_confetti", "hat_pip_foam" },
		},
		coins_s = { id = 0, robux = 49, name = "Pile of Coins", coins = 500 },
		coins_m = { id = 0, robux = 129, name = "Bag of Coins", coins = 1500 },
		coins_l = { id = 0, robux = 299, name = "Chest of Coins", coins = 4000 },
		coins_xl = { id = 0, robux = 599, name = "Vault of Coins", coins = 9000 },
		crate = { id = 0, robux = 50, name = "Crash Crate" },
		extra_slot = { id = 0, robux = 49, name = "Extra Draft Slot" },
		-- Starter + Rider + Stunt, 25% under the separate prices, offered once you own one of them
		bundle = {
			id = 0,
			robux = 395,
			name = "Crash Crew Bundle",
			passes = { "rider", "stunt" },
			starter = true,
		},
	},
	coinShop = { "coins_s", "coins_m", "coins_l", "coins_xl" },
	shopLine = "Nothing here makes you faster or stronger.",
	-- After the first finish the Starter Pack is offered once (flags.starterOffered)
	starterOfferDelay = 1.5,
}

-- Progression (spec: Progression). Mastery: points per vehicle, levels at these cumulative points.
Config.Progression = {
	masteryLevels = { 0, 25, 75, 150, 250, 400, 600, 850, 1150, 1500 },
	masteryPoints = { tracksFinish = 5, bump = 1, brawlRound = 10, destructionPer = 500 },
	rebirthNeeds = "TierOneVehicles", -- own all 6 launch vehicles
	rebirthHold = 1.5, -- seconds to hold CONFIRM
	starUnlocks = { builderColours2 = 15 }, -- stars sinks available now (themes are Update 2)
}

-- Quests and streak (spec: Progression > Quests and streaks). Pools are in Shared/Quests.
Config.Quests = {
	dailyRewards = { 60, 80, 100 }, -- by quest tier
	weeklyReward = 300,
	weeklyStars = 5, -- for all 3 weekly quests
	chestCoins = 150,
	chestCosmeticChance = 0.3, -- otherwise the coins
	streakRewards = { 50, 75, 100, "crate_key", 150, 200, "cosmetic" },
	streakOwnedCoins = 250, -- day 7 when you already own this week's cosmetic
	giftCoins = 10,
	-- Modes quests come from. A mode counts only once its place exists (Shared/Place.modeLive).
	liveModes = { "tracks", "brawl", "highway" }, -- a mode counts only once Place.modeLive says so
}

---------------------------------------------------------------------------
-- Hub, rounds, quick races, parties, leaderboards (spec: Core loop, Hub and menus, Tracks: quick race,
-- Round state machine). Every number is (tune).
---------------------------------------------------------------------------
-- Tumble Park plaza: drive around it; drive into a stall to open its screen.
Config.Hub = {
	origin = { -4000, 0, 0 },
	size = 360, -- the plaza is a square this wide (studs)
	spawn = { 0, 0, 120 }, -- relative to the origin, facing -Z (toward the mode gates)
	-- Stalls you drive into (relative to the origin; size x, z). opens: the screen it opens.
	zones = {
		{
			id = "tracks",
			label = "TRACKS",
			pos = { -90, 0, -110 },
			size = { 44, 24 },
			color = { 86, 170, 255 },
		},
		{
			id = "brawl",
			label = "BUMPER BRAWL",
			pos = { 0, 0, -130 },
			size = { 44, 24 },
			color = { 255, 120, 90 },
		},
		{
			id = "highway",
			label = "HIGHWAY HAVOC",
			pos = { 90, 0, -110 },
			size = { 44, 24 },
			color = { 255, 200, 60 },
		},
		{
			id = "race",
			label = "RACE PAD",
			pos = { -120, 0, 20 },
			size = { 36, 36 },
			color = { 80, 210, 110 },
		},
		{
			id = "garage",
			label = "GARAGE",
			pos = { 130, 0, 10 },
			size = { 30, 24 },
			color = { 190, 195, 205 },
		},
		{ id = "shop", label = "SHOP", pos = { 130, 0, 70 }, size = { 30, 24 }, color = { 255, 150, 200 } },
		{
			id = "builder",
			label = "WORKSHOP",
			pos = { -120, 0, 90 },
			size = { 30, 24 },
			color = { 150, 80, 220 },
		},
	},
	-- Brawl and Highway cards show a silhouette until this much play time (spec: until minute 7 of
	-- the first session); after that they show their mode (Coming soon until milestones 7 and 8).
	modesUnlockSeconds = 420,
	zoneCooldown = 3, -- a stall opens again only after you leave it for this long
	countsInterval = 30, -- each server writes its live player counts this often (MemoryStore)
	countsExpiry = 90,
	countsStore = "LiveCounts_v1",
}

-- Mode places (Creator Dashboard place ids; 0 until those places exist: the card says Coming soon)
Config.Places = {
	start = 0, -- Tumble Park (the start place): where mode places send players back to
	brawlCasual = 0,
	brawlRanked = 0,
	highwayCoop = 0,
	highwayVersus = 0,
	teleportRetries = 3,
}

-- The round state machine (spec: Lobby -> Countdown -> Play -> Results -> Requeue) for quick races.
-- Lobby: starts lobbyFill s after the 2nd player joins, or at once when full.
Config.Race = {
	minPlayers = 2,
	maxPlayers = 8,
	lobbyFill = 10,
	countdown = 3, -- cars steerable but held
	playMax = 180,
	afterFirstFinish = 20,
	results = 6, -- skippable
	requeue = 8, -- auto-requeue: back in the lobby unless you leave
	placeCoins = { 80, 60, 45, 35, 25, 20, 15, 10 },
	dnfCoins = 10,
	slotOrigin = { -9000, 0, 0 },
	slotSpacing = 1300, -- along -Z
	maxRaces = 4, -- races at once per server
	gridSpacing = 7, -- studs between cars on the start grid
}

Config.Party = {
	maxSize = 4,
	inviteExpiry = 60, -- seconds an invite stays open
}

-- Map leaderboards (spec: MapTimes_v1, OrderedDataStore per map and week; lower is better)
Config.Boards = {
	storeName = "MapTimes_v1",
	topCount = 10,
	friendsPool = 100, -- the Friends tab picks friends from the all-time top 100 (one read)
	cacheSeconds = 60,
}

---------------------------------------------------------------------------
-- Bumper Brawl (spec: Game modes > Bumper Brawl; Brawl screens; Onboarding > Brawl practice).
-- Runs in its own places (Cinder Cove Casual and Ranked: brawl.project.json, ranked.project.json).
-- Every number is (tune) unless the spec fixes it.
---------------------------------------------------------------------------
Config.Brawl = {
	maxPlayers = 8, -- cars in a round (players plus bots)
	fillTo = 8, -- bots fill the empty slots up to this many cars
	botFillCasual = 10, -- s after the first player is in the pen (spec)
	botFillRanked = 20, -- (spec)
	countdown = 3,
	roundLength = 120, -- then sudden death (spec)
	maxLength = 150, -- sudden death ends here: most KOs wins, then most damage dealt (spec)
	results = 8, -- Queue next skips it
	requeue = 1,
	-- The schedule (spec): outer ring at 40 s, middle at 75 s, then one random inner tile every 4 s from
	-- 95 s, then one every 1 s in sudden death. Each drop flashes a warning for 3 s first.
	outerDropAt = 40,
	middleDropAt = 75,
	innerStart = 95,
	innerEvery = 4,
	suddenDeathEvery = 1,
	warnTime = 3,
	-- World: the arena, the foam pit under it and the pen (studs, Brawl place only)
	origin = { 0, 80, 0 },
	tileSpacing = 15, -- centre to centre (= flat to flat)
	tileHeight = 3,
	koDepth = 10, -- out when the car's centre falls this far under the tile tops
	pitDepth = 34, -- the foam pit's top, under the tile tops
	arenas = {
		{ id = "geyser", name = "Geyser Ring", shape = "ring" }, -- 72 tiles round a foam geyser hole
		{ id = "boardwalk", name = "Boardwalk", shape = "pier" }, -- 72 tiles, 9 by 8
	},
	ringColors = { { 255, 214, 120 }, { 120, 200, 255 }, { 255, 140, 170 } }, -- inner, middle, outer
	warnColor = { 255, 140, 30 },
	-- The lobby: a foam-ball pen next to the arena
	pen = { origin = { 0, 80, 320 }, size = 150, balls = 12, ballSize = 7 },
	-- Practice (first visit): a small arena per player, a slow bot ahead, knockback x1.5 (spec)
	practice = {
		origin = { 320, 80, 0 },
		spacing = 110, -- between practice arenas (along +X)
		slots = 8,
		botsToKnock = 2,
		knockbackBonus = 1.5,
		coins = 20,
		botAhead = 30, -- studs (3 car lengths)
	},
	-- Knockback (spec): dv = 20 + 0.6 x closing speed x clamp(mass ratio, 0.6, 1.8), capped at 75, then x
	-- the defender's class multiplier. Same pair cooldown 0.4 s. KO credit: the last bump within 4 s.
	knockback = {
		base = 20,
		factor = 0.6,
		ratioMin = 0.6,
		ratioMax = 1.8,
		cap = 75,
		up = 0.2, -- a little upward pop with every bump (x dv)
		pairCooldown = 0.4,
		koWindow = 4,
		minClosing = 6, -- a touch slower than this is not a bump
	},
	-- Hit checks (spec: Network model): speed within 15% of the car's max, under 8 studs apart
	hitCheck = { speedSlack = 1.15, gap = 8 },
	-- Gully the Gull drops a powerup every 12 s on a random standing tile; one held at a time (spec)
	powerups = {
		every = 12,
		firstAt = 6,
		maxOnArena = 3,
		pickupRadius = 7,
		dropTime = 0.9, -- the fall from Gully's beak
		kinds = { "spring", "shield", "wrench", "honk" },
	},
	spring = { mult = 1.6, bumps = 3, seconds = 8 },
	shield = { seconds = 4 },
	wrench = { heal = 50 },
	honk = { radius = 14, speed = 30 },
	-- Rewards (spec): 20 a round, +5 a KO (max 4), +40 for a win; 900 a day. Idle rounds earn nothing.
	coins = { round = 20, perKO = 5, maxKOs = 4, win = 40 },
	dailyCap = 900,
	afkDistance = 40, -- studs driven in a round (or one bump) to count as playing
	-- Bots: Captain Hiccup and friends, labelled BOT (spec). Original characters only.
	bots = {
		names = { "Captain Hiccup", "Dozer Dot", "Rusty", "Gizmo Gus", "Wobble Bot", "Pip", "Kaboom Cloud" },
		vehicles = { "starter_buggy", "bumble_bus", "haul_hog", "pocket_sedan", "dune_hopper", "fizz_wagon" },
		speed = 0.55, -- x the class top speed
		practiceSpeed = 0.18,
		accel = 45, -- studs/s^2
		turnRate = 140, -- degrees per second
		retarget = { 2.5, 5 }, -- seconds between picking a new car to chase
		hiccupChance = 0.08, -- per second: Captain Hiccup's crew stall for a moment
		hiccupTime = 0.7,
		edgeLook = 0.7, -- seconds ahead they check for a missing tile
		stun = 0.6, -- seconds a knocked bot coasts before driving again
		useDelay = { 0.8, 2.5 }, -- seconds before a bot uses a powerup
	},
	-- Ranked (spec): win +25, top half +10, bottom half 0, first out -10, AFK or quit -15. Tiers every
	-- 100 points. Bronze floors at 0. The first 5 rounds cannot lose points. Unlocks after 3 casual
	-- rounds. Seasons soft-reset by 2 tiers and pay a cosmetic per tier reached.
	ranked = {
		unlockRounds = 3,
		win = 25,
		topHalf = 10,
		firstOut = -10,
		afkOrQuit = -15,
		tierSize = 100,
		placements = 5,
		season = 1, -- bump this to start a new season (every 6 weeks)
		softResetTiers = 2,
		tierNames = { "Bronze Bolt", "Silver Spark", "Gold Gear", "Platinum Piston", "Diamond Drift" },
		-- Season rewards: one per tier reached (Apex tiers pay the Apex item); coins if already owned
		seasonRewards = {
			"decal_bronze_bolt",
			"trail_silver_spark",
			"rims_gold_gear",
			"paint_platinum_piston",
			"trail_diamond_drift",
			"hat_apex_crown",
		},
		seasonOwnedCoins = 250,
	},
	countsKey = "brawl", -- this place's live player count (the hub's mode card)
}

---------------------------------------------------------------------------
-- Highway Havoc (spec: Game modes > Highway Havoc; Bone breaks; Highway screens; Onboarding > Highway
-- tutorial lane). Runs in its own places (Sunny Pass Co-op and Versus: highway.project.json,
-- versus.project.json). Every number is (tune) unless the spec fixes it.
---------------------------------------------------------------------------
Config.Highway = {
	maxPlayers = 8,
	runLength = 210,
	startSpeed = 50, -- you join already moving
	resultsSkip = 2, -- the results card can be skipped after this
	-- Road (built on each device from the server's seed; Shared/HighwayMath)
	road = {
		origin = { 0, 0, 0 }, -- the road's s = 0; it runs toward -Z with gentle seeded curves
		laneWidth = 14,
		lanes = 4,
		shoulder = 8, -- each side, past the outer lane
		thickness = 2,
		segment = 50, -- one road part per 50 studs
		step = 10, -- the centreline is integrated in 10-stud steps
		curves = { { amp = 0.1, wave = 4000 }, { amp = 0.04, wave = 2000 } }, -- heading in radians
		ahead = 650, -- built this far ahead of your car
		behind = 150,
		groundSize = 2048, -- the grass plane under the road (recentred as you drive)
		maxS = 40000, -- past this a new run starts back at the beginning (keeps far-from-origin physics sane)
	},
	ramps = { grid = 425, jitter = 37, rampDayGrid = 200, length = 34, height = 7, lanes = 2 },
	wrench = { every = 900, heal = 30, radius = 6 },
	-- Traffic: deterministic from the seed and server time, so every device sees the same cars
	traffic = {
		count = 16, -- pooled cars around each player
		physics = 8, -- the nearest ones are real physics bodies; the rest glide on their lane
		physicsRange = 140,
		ahead = 600,
		behind = 150,
		laneSpeeds = { 45, 53, 61, 70 }, -- slow lane on the right (lane 1) to the fast lane
		grid = 100, -- one car slot per 100 studs per lane, moved up to 20 either way: 60 to 140 apart
		jitter = 20,
		empty = 0.35, -- share of slots with no car
		maxForce = 90, -- lane-keeping force (times the car's mass): hits easily overpower it
		stagger = 1.2, -- a hit under the wreck line knocks the car off its lane for this long
		despawnAfter = 6, -- wrecks are removed this long after wrecking (or when far behind)
		types = {
			{
				id = "compact",
				base = 50,
				size = { 6, 4.5, 11 },
				mass = 0.6,
				weight = 30,
				color = { 120, 200, 255 },
			},
			{
				id = "sedan",
				base = 75,
				size = { 6.5, 5, 13 },
				mass = 1.0,
				weight = 30,
				color = { 255, 214, 120 },
			},
			{
				id = "van",
				base = 100,
				size = { 7, 7, 14 },
				mass = 1.4,
				weight = 15,
				color = { 170, 230, 140 },
			},
			{
				id = "boxTruck",
				base = 150,
				size = { 8, 9, 20 },
				mass = 2.0,
				weight = 12,
				color = { 245, 245, 245 },
			},
			{
				id = "partyBus",
				base = 200,
				size = { 8, 9, 26 },
				mass = 2.6,
				weight = 7,
				color = { 255, 140, 200 },
			},
			{
				id = "foamTanker",
				base = 250,
				size = { 8, 8, 24 },
				mass = 3.0,
				weight = 6,
				color = { 255, 170, 60 },
			},
		},
	},
	wreck = { single = 40, double = 20 }, -- a traffic car wrecks at one hit of I 40+, or two of I 20+
	explode = { impact = 70, radius = 8, delay = 0.8 }, -- hit at I 70+, or near a blast: explodes in 0.8 s
	-- Roadside props (kind, base value, weight); slots every 40 studs on each shoulder
	props = {
		slot = 40,
		empty = 0.45,
		kinds = {
			{ id = "cone", base = 5, weight = 30 },
			{ id = "fence", base = 5, weight = 20 },
			{ id = "sign", base = 10, weight = 20 },
			{ id = "barrier", base = 20, weight = 20 },
			{ id = "billboard", base = 60, weight = 10 },
		},
	},
	-- Destruction Score (shared with the server: Shared/Score)
	score = {
		speedDiv = 40,
		speedMin = 0.5,
		speedMax = 2.5,
		comboWindow = 3,
		comboSteps = { 2, 4, 7, 11, 16, 22, 30 }, -- x2 at 2 hits ... x8 at 30
		nearMiss = { points = 25, gap = 2, speed = 70 },
		air = { points = 25, every = 0.5, maxSeconds = 6 },
		flip = { points = 300, max = 3 },
		chain = { 0.5, 0.25, 0.125 },
		pileup = { cars = 5, window = 4, base = 1000, per = 250 },
		crack = 150, -- per bone break, times the combo
		breakStep = 0.1, -- each break adds 0.1 to the break multiplier
		perSecond = 2000, -- server caps
		perEvent = 3000,
		maxImpact = 250,
		player = { base = 120, pairCooldown = 2 }, -- versus
		coopRadius = 80, -- co-op pile-ups pay every player this close
	},
	hitCheck = { radius = 12, speedAllowance = 0.15, wreckRadius = 70, wreckLife = 8, propRadius = 14 },
	-- Bone breaks (spec: Bone breaks, Highway Havoc only)
	bones = {
		total = 12,
		seatImpact = 45, -- a Hard hit or Huge crash at I 45+ breaks a bone in the seat
		ejectSpeed = 40, -- a thrown rider's piece hitting anything at 40+
		cooldown = 0.5,
		perCrash = 3,
		crashWindow = 1.5, -- breaks this close together count as one crash
		freeze = 0.2,
		xray = 0.25,
		finale = 1.2,
	},
	counterLabel = "Crack Count", -- BONE_COUNTER_LABEL (one string; nate may rename it)
	coins = { per = 250, max = 120 },
	dailyCap = 720,
	dailyTarget = 15000, -- today's total opens the daily Havoc chest once
	chest = { coins = 150, cosmeticChance = 0.5 },
	meter = { goal = 100000, coins = 30, minShare = 1000 }, -- the server's Havoc meter
	flaggedCoins = 0.5, -- a run with rejected hits earns half and never posts to a board
	rejectLimit = 6,
	packBehind = 120, -- a new run starts this far behind the last car on the road
	versusUnlockRuns = 2,
	-- First run (tut.highway): a quiet road of its own, 3 soft compacts ahead, a ramp, SMASH!
	tutorial = {
		length = 90,
		origin = { 6000, 0, 0 }, -- each first-timer gets a quiet copy of the road out here
		spacing = 220, -- studs between first-timers' copies
		lanes = 2,
		quiet = 3, -- traffic 3 times thinner
		cars = { 140, 175, 210 }, -- the 3 compacts, this far ahead in your lane
		carSpeed = 30,
		rampAt = 650,
		bumpAt = 20, -- the scripted bump that breaks the first bone, if none broke yet
	},
	-- Daily events (UTC weekday; announced by Highway Hal)
	events = {
		{
			id = "lowGravity",
			name = "LOW GRAVITY SUNDAY",
			line = "Everything floats a little today!",
			gravity = 0.6,
		},
		{ id = "rushHour", name = "RUSH HOUR", line = "Traffic is twice as thick!", spacing = 0.5 },
		{
			id = "foamTruck",
			name = "FOAM TRUCK DAY",
			line = "Foam tankers everywhere, and extra bouncy!",
			tankers = 3,
		},
		{ id = "busParade", name = "BUS PARADE", line = "Party buses on parade!", buses = 3 },
		{ id = "rampDay", name = "RAMP DAY", line = "Ramps every 200 studs!", ramps = true },
		{ id = "pileupFriday", name = "PILE-UP FRIDAY", line = "Pile-ups pay double!", pileup = 2 },
		{
			id = "nightLights",
			name = "NIGHT LIGHTS",
			line = "Dusk on the highway. Traffic glows!",
			night = true,
		},
	},
	countsKey = "highway",
}

-- Badges (Creator Dashboard ids; 0 until nate creates them)
Config.Badges = {
	rebirth = 0,
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
