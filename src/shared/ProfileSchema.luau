--!strict
-- ProfileSchema: the saved player profile v1 (spec: Data model > Player profile), its migrations and the
-- checks on anything a client sends (pure, unit tested). The server is the only writer.
--
-- Additions to the spec's v1 table (never delete a field in place; record changes in notes/Decisions.md):
--   tracks = { [mapId] = { best = ms, stars = 0..3, splits = { ms per checkpoint } } }  per-map results
--   ghosts = { [mapId] = base64 ghost }, ghostOrder = { mapIds, newest last }          best-run ghosts
--   flags.boardBanDay = yyyymmdd: 3 rejected runs in 10 minutes = no leaderboard posts that day
--   trackOrder = { mapIds } player maps with a tracks entry, newest last (kept to the newest 500)
--   ratings = { [mapId] = 1..5 } (spec field), trimmed with trackOrder
--   daily.mapStarts = { [mapId] = n } runs started today (a play counts once per player per map per day)
--   maps.drafts = { [tostring(slot)] = base64 map buffer } (string keys: DataStores need one key type)
--   maps.links = { [tostring(slot)] = mapId } a draft's published map (a republish keeps plays/ratings)
--   maps.lastPublish = unix time of the last publish (the 10 minute cooldown survives a rejoin)
--   stats.playSeconds = total play time (the 15 minute publish gate)
--   vehicles[id].paint/rims/trail/horn/explosion/decal = Catalog item id (spec fields; decal added),
--     .parts = { part item ids } (one part at a time for now), .trail2 = a second trail (VIP)
--   rider.hat / rider.outfit = Catalog item id; inventory[itemId] = { count, shiny } (spec)
--   passes[name] = true: a game pass (re-checked on join) or a pass from the bundle product
--   daily.quests = { Quests.State } today's 3; weekly = { week, quests, starsClaimed }
--   streak = { day = last day claimed 1..7, lastClaim = whole UTC day number (not yyyymmdd) }
--   flags.lastMode = "tracks" | "race" | "" : the hub's mode card that glows next session

-- Roblox finds Config beside this module; the Lune test runner (no `script`) uses the file path.
local Config = if script then require(script.Parent.Config) else (require :: any)("./Config")
local Quests = if script then require(script.Parent.Quests) else (require :: any)("./Quests")
local Emotes = if script then require(script.Parent.Emotes) else (require :: any)("./Emotes")

local ProfileSchema = {}

ProfileSchema.VERSION = 1

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end
ProfileSchema.deepCopy = deepCopy

function ProfileSchema.default(): { [string]: any }
	return {
		v = ProfileSchema.VERSION,
		coins = 0,
		stars = 0,
		rebirths = 0,
		vehicles = {
			[Config.DefaultVehicle] = { owned = true, mastery = 0, parts = {} },
		},
		equippedVehicle = Config.DefaultVehicle,
		rider = { emotes = {} },
		inventory = {},
		passes = {},
		daily = {
			day = 0,
			coinsByMode = { tracks = 0, brawl = 0, highway = 0 },
			mapFinishes = {},
			mapStarts = {},
			royalties = 0,
			giftSent = false,
			quests = {},
			chestClaimed = false,
			adClaims = 0,
			havoc = 0, -- Highway Destruction Score today (the daily Havoc target)
			havocChest = false,
		},
		weekly = { week = 0, quests = {}, starsClaimed = false },
		streak = { day = 0, lastClaim = 0 },
		stats = {
			finishes = 0,
			races = 0,
			brawlRounds = 0,
			brawlWins = 0,
			kos = 0,
			highwayRuns = 0,
			bestHighway = 0,
			bestBones = 0,
			pileups = 0,
			mapsPublished = 0,
			playSeconds = 0,
		},
		ranked = { season = 0, points = 0, placementsLeft = 5, bestTier = 0 },
		maps = { drafts = {}, published = {}, extraSlots = 0, links = {}, lastPublish = 0 },
		ratings = {},
		tut = {
			pipHill = false,
			lean = false,
			freePaint = false,
			featuredRated = false,
			highway = false,
			brawl = false,
			builder = false,
			ranked = false,
			versus = false,
		},
		settings = deepCopy(Config.Settings.defaults),
		receipts = {},
		flags = {
			banPublishUntil = 0,
			starterOffered = false,
			starterBought = false,
			boardBanDay = 0,
			lastMode = "",
			entryId = "", -- the Mode entry funnel's session (Analytics), carried across places
			challengeScore = 0, -- a friend's Beat my score card (0: none) and who sent it
			challengeBy = 0,
		},
		tracks = {},
		trackOrder = {},
		ghosts = {},
		ghostOrder = {},
	}
end

-- Fill any field missing from a loaded profile with its default (new fields arrive this way), without
-- touching what is there. Nested tables are filled too.
local function reconcile(target: { [string]: any }, template: { [string]: any })
	for key, value in template do
		if target[key] == nil then
			target[key] = deepCopy(value)
		elseif type(value) == "table" and type(target[key]) == "table" and next(value) ~= nil then
			-- Only reconcile record-like tables (non-empty templates); maps such as vehicles keep their keys
			if key ~= "vehicles" then
				reconcile(target[key], value)
			end
		end
	end
end

-- Migration steps: MIGRATIONS[n] turns a version n profile into version n + 1.
local MIGRATIONS: { [number]: (any) -> () } = {}

-- Load: migrate to the current version and fill new fields. Returns the profile (a fresh default for nil).
function ProfileSchema.load(data: any): { [string]: any }
	if type(data) ~= "table" then
		return ProfileSchema.default()
	end
	local version = tonumber(data.v) or 1
	while version < ProfileSchema.VERSION do
		local step = MIGRATIONS[version]
		if step then
			step(data)
		end
		version += 1
	end
	data.v = ProfileSchema.VERSION
	reconcile(data, ProfileSchema.default())
	return data
end

---------------------------------------------------------------------------
-- Days (UTC) for the daily and weekly counters
---------------------------------------------------------------------------

-- yyyymmdd for a unix time, in UTC
function ProfileSchema.dayKey(unixTime: number): number
	local d = os.date("!*t", math.floor(unixTime))
	return d.year * 10000 + d.month * 100 + d.day
end

-- Whole UTC days since 1970 (for counting days apart: streaks, weeks, the last 7 days of plays)
function ProfileSchema.dayNumber(unixTime: number): number
	return math.floor(unixTime / 86400)
end

-- Reset the daily counters when the UTC day changed. Returns true if it reset.
function ProfileSchema.rollDay(profile: { [string]: any }, unixTime: number): boolean
	local today = ProfileSchema.dayKey(unixTime)
	if profile.daily.day == today then
		return false
	end
	local fresh = ProfileSchema.default().daily
	fresh.day = today
	profile.daily = fresh
	return true
end

---------------------------------------------------------------------------
-- Settings from a client: only known keys, only allowed values. Returns the clean keys it sent (the server
-- merges them into the saved settings), or nil if anything in the call is wrong.
---------------------------------------------------------------------------

function ProfileSchema.sanitizeSettings(input: any): { [string]: any }?
	if type(input) ~= "table" then
		return nil
	end
	local cfg = Config.Settings
	local out = {}
	local count = 0
	for key, value in input do
		count += 1
		if count > 32 or type(key) ~= "string" then
			return nil
		end
		local default = cfg.defaults[key]
		if default == nil then
			return nil -- unknown key: reject the whole call
		end
		if type(value) ~= type(default) then
			return nil
		end
		if type(value) == "number" then
			if value ~= value then
				return nil
			end
			local range = cfg.ranges[key]
			if range then
				value = math.clamp(value, range[1], range[2])
			end
		elseif type(value) == "string" then
			local choices = cfg.choices[key]
			if not choices or not table.find(choices, value) then
				return nil
			end
		end
		out[key] = value
	end
	return out
end

---------------------------------------------------------------------------
-- Ghost storage: starter maps always keep theirs; other maps keep the most recent N
---------------------------------------------------------------------------

-- A finish on a map: player maps keep their tracks entry (best time, stars) and rating for the newest
-- Config.Tracks.maxStoredTracks maps, so a profile never grows without end. Starter maps always keep theirs.
function ProfileSchema.noteTrack(profile: { [string]: any }, mapId: string, keepAlways: { [string]: boolean })
	if keepAlways[mapId] then
		return
	end
	local order = profile.trackOrder
	local index = table.find(order, mapId)
	if index then
		table.remove(order, index)
	end
	table.insert(order, mapId)
	while #order > Config.Tracks.maxStoredTracks do
		local old = table.remove(order, 1) :: string
		profile.tracks[old] = nil
		profile.ratings[old] = nil
	end
end

function ProfileSchema.storeGhost(
	profile: { [string]: any },
	mapId: string,
	ghost: string,
	keepAlways: { [string]: boolean }
)
	profile.ghosts[mapId] = ghost
	local order = profile.ghostOrder
	local index = table.find(order, mapId)
	if index then
		table.remove(order, index)
	end
	table.insert(order, mapId)
	local others = 0
	for i = #order, 1, -1 do
		local id = order[i]
		if not keepAlways[id] then
			others += 1
			if others > Config.Tracks.maxStoredGhosts then
				profile.ghosts[id] = nil
				table.remove(order, i)
			end
		end
	end
end

-- Purchase idempotency: remember the last 100 purchase ids. Returns false if already seen.
function ProfileSchema.recordReceipt(profile: { [string]: any }, purchaseId: string): boolean
	if table.find(profile.receipts, purchaseId) then
		return false
	end
	table.insert(profile.receipts, purchaseId)
	while #profile.receipts > 100 do
		table.remove(profile.receipts, 1)
	end
	return true
end

-- What the client is told about its own profile (nothing it could use to cheat; it is display data)
local LOOK_SLOTS = { "paint", "rims", "trail", "trail2", "horn", "explosion", "decal" }

local function questView(list: { any }): { any }
	local out = {}
	for _, state in list do
		local def = Quests.byId[state.id]
		if def then
			table.insert(out, {
				id = state.id,
				text = Quests.text(state),
				progress = state.progress,
				target = def.target,
				claimed = state.claimed == true,
				reward = Quests.reward(state, Config.Quests),
				mode = def.mode,
			})
		end
	end
	return out
end

-- What the client may see (display only). now: unix time (for the streak's next claim).
function ProfileSchema.clientView(profile: { [string]: any }, now: number?): { [string]: any }
	local tracks = {}
	for mapId, entry in profile.tracks do
		tracks[mapId] = { best = entry.best, stars = entry.stars, splits = entry.splits }
	end
	local owned = {}
	local vehicles = {}
	for id, entry in profile.vehicles do
		if entry.owned then
			table.insert(owned, id)
			local looks = { mastery = entry.mastery or 0, part = entry.parts and entry.parts[1] or nil }
			for _, slot in LOOK_SLOTS do
				looks[slot] = entry[slot]
			end
			vehicles[id] = looks
		end
	end
	table.sort(owned)
	local inventory = {}
	local shiny = {}
	for id, entry in profile.inventory do
		if id ~= "crate_key" then
			table.insert(inventory, id)
			if type(entry) == "table" and entry.shiny then
				table.insert(shiny, id)
			end
		end
	end
	table.sort(inventory)
	local keyEntry = profile.inventory.crate_key
	local today = ProfileSchema.dayNumber(now or os.time())
	local nextDay, canClaim = Quests.streakNext(profile.streak.day or 0, profile.streak.lastClaim or 0, today)
	return {
		coins = profile.coins,
		stars = profile.stars,
		rebirths = profile.rebirths,
		equippedVehicle = profile.equippedVehicle,
		owned = owned,
		vehicles = vehicles,
		inventory = inventory,
		shiny = shiny,
		crateKeys = if type(keyEntry) == "table" then keyEntry.count or 0 else 0,
		passes = deepCopy(profile.passes),
		rider = { hat = profile.rider.hat, outfit = profile.rider.outfit, emotes = Emotes.wheel(profile) },
		tut = deepCopy(profile.tut),
		settings = deepCopy(profile.settings),
		tracks = tracks,
		tracksCoinsToday = profile.daily.coinsByMode.tracks,
		quests = {
			daily = questView(profile.daily.quests),
			weekly = questView(profile.weekly.quests),
			chestClaimed = profile.daily.chestClaimed == true,
			chestReady = Quests.allClaimed(profile.daily.quests) and not profile.daily.chestClaimed,
			weeklyStarsClaimed = profile.weekly.starsClaimed == true,
			giftSent = profile.daily.giftSent == true,
		},
		streak = { day = profile.streak.day or 0, nextDay = nextDay, canClaim = canClaim },
		starterOffered = profile.flags.starterOffered == true,
		starterBought = profile.flags.starterBought == true,
		lastMode = profile.flags.lastMode or "",
		playSeconds = profile.stats.playSeconds or 0,
		races = profile.stats.races or 0,
		brawlRounds = profile.stats.brawlRounds or 0,
		brawlWins = profile.stats.brawlWins or 0,
		kos = profile.stats.kos or 0,
		highwayRuns = profile.stats.highwayRuns or 0,
		bestHighway = profile.stats.bestHighway or 0,
		bestBones = profile.stats.bestBones or 0,
		havocToday = profile.daily.havoc or 0,
		havocChest = profile.daily.havocChest == true,
		ranked = {
			season = profile.ranked.season,
			points = profile.ranked.points,
			placementsLeft = profile.ranked.placementsLeft,
			bestTier = profile.ranked.bestTier,
		},
	}
end

return ProfileSchema
