-- DataService: each player's saved profile (spec: Data model > Player profile, Saving).
-- * One DataStore key per player, written only by the server, with UpdateAsync and a session lock
--   { jobId, time } so two servers never both write one profile (a teleport or a fast rejoin).
--   Stored value: { data = profile, lock = { jobId, time }? }.
-- * Load: wait for another server's lock to clear (Config.Data.lockWaitTries x lockWaitTime), take over a
--   lock older than lockStealAfter (a crashed server's). Still locked: the player is asked to rejoin.
-- * Save: autosave every 60 s (refreshing the lock), on leave (releasing it) and on shutdown. A save that
--   finds another server's lock stops saving for that player instead of overwriting.
-- * DataStore down at load: the player plays on a fresh profile that is never saved, and is told so.
-- * Studio without API access (or an unpublished place): profiles live in memory for the session.
-- Clients only ever see ProfileSchema.clientView, sent on Profile.Data whenever something changes.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)
local Signal = require(Shared.Util.Signal)

local DataService = {}

DataService.Loaded = Signal.new() -- (player, profile)
DataService.Reset = Signal.new() -- (player, profile): a dev reset made it a first-time profile
-- (player, profile): the player is leaving; handlers run before the last save (a ranked quit penalty)
DataService.Leaving = Signal.new()

type Session = {
	profile: { [string]: any },
	canSave: boolean,
	saving: boolean,
	pendingSave: boolean,
	sendQueued: boolean,
	released: boolean,
	playClock: number, -- os.clock() play time was last added to stats.playSeconds
}

local store: DataStore? = nil
local memoryMode = false
local memoryProfiles: { [number]: any } = {} -- memory mode: kept across rejoins for this server's life
local sessions: { [Player]: Session } = {}
local waiting: { [Player]: { thread } } = {}

local function keyFor(player: Player): string
	return Config.Data.keyPrefix .. tostring(player.UserId)
end

local function lockIsForeign(lock: any, now: number): boolean
	if type(lock) ~= "table" or lock.jobId == game.JobId then
		return false
	end
	return now - (tonumber(lock.time) or 0) < Config.Data.lockStealAfter
end

-- Returns the profile, or nil plus a reason ("locked" or "error")
local function loadFromStore(player: Player): ({ [string]: any }?, string?)
	local cfg = Config.Data
	local lastReason = "error"
	for attempt = 1, cfg.lockWaitTries do
		local loaded: { [string]: any }? = nil
		local locked = false
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(keyFor(player), function(old)
				loaded, locked = nil, false
				if type(old) == "table" and lockIsForeign(old.lock, os.time()) then
					locked = true
					return nil -- leave it alone; try again shortly
				end
				local data = if type(old) == "table" then old.data else nil
				local profile = ProfileSchema.load(ProfileSchema.deepCopy(data))
				loaded = profile
				return { data = profile, lock = { jobId = game.JobId, time = os.time() } }
			end)
		end)
		if ok and loaded then
			return loaded, nil
		end
		if player.Parent ~= Players then
			return nil, "left"
		end
		if not ok then
			warn(
				string.format(
					"[DataService] load %d failed (try %d): %s",
					player.UserId,
					attempt,
					tostring(err)
				)
			)
			lastReason = "error"
			task.wait(2 ^ attempt)
		else
			lastReason = if locked then "locked" else "error"
			task.wait(cfg.lockWaitTime)
		end
	end
	return nil, lastReason
end

local function saveToStore(player: Player, session: Session, release: boolean): boolean
	local snapshot = ProfileSchema.deepCopy(session.profile)
	for attempt = 1, Config.Data.saveRetries do
		local lost = false
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(keyFor(player), function(old)
				lost = false
				if type(old) == "table" and type(old.lock) == "table" and old.lock.jobId ~= game.JobId then
					lost = true -- another server owns this profile now
					return nil
				end
				return {
					data = snapshot,
					lock = if release then nil else { jobId = game.JobId, time = os.time() },
				}
			end)
		end)
		if ok then
			if lost then
				warn(
					string.format(
						"[DataService] %d: another server took the profile; this one stops saving",
						player.UserId
					)
				)
				session.canSave = false
				return false
			end
			return true
		end
		warn(
			string.format("[DataService] save %d failed (try %d): %s", player.UserId, attempt, tostring(err))
		)
		task.wait(attempt)
	end
	return false
end

-- Play time goes into stats.playSeconds at every save (the publish gate needs 15 minutes)
local function addPlayTime(session: Session)
	local now = os.clock()
	session.profile.stats.playSeconds += math.max(0, now - session.playClock)
	session.playClock = now
end

function DataService.playSeconds(player: Player): number
	local session = sessions[player]
	if not session then
		return 0
	end
	addPlayTime(session)
	return session.profile.stats.playSeconds
end

function DataService.isMemoryMode(): boolean
	return memoryMode
end

-- Save now. release = the player is leaving (drops the session lock).
function DataService.save(player: Player, release: boolean?): boolean
	local session = sessions[player]
	if not session or not session.canSave or session.released then
		return false
	end
	addPlayTime(session)
	if memoryMode then
		memoryProfiles[player.UserId] = ProfileSchema.deepCopy(session.profile)
		if release then
			session.released = true
		end
		return true
	end
	if session.saving then
		-- One write at a time per key: queue another after this one (always for a release)
		session.pendingSave = true
		while session.saving do
			task.wait(0.1)
		end
		if session.released then
			return false
		end
	end
	session.saving = true
	session.pendingSave = false
	local ok = saveToStore(player, session, release == true)
	session.saving = false
	if release then
		session.released = true
	end
	return ok
end

local function sendView(player: Player)
	local session = sessions[player]
	if session then
		Net.fire("Profile.Data", player, ProfileSchema.clientView(session.profile))
	end
end

-- The live profile (nil until loaded). Callers change it, then call DataService.changed(player).
function DataService.get(player: Player): { [string]: any }?
	local session = sessions[player]
	if not session then
		return nil
	end
	ProfileSchema.rollDay(session.profile, os.time())
	return session.profile
end

-- Waits until the profile is loaded (or the player leaves). Returns the profile or nil.
function DataService.waitFor(player: Player): { [string]: any }?
	if sessions[player] then
		return DataService.get(player)
	end
	if player.Parent ~= Players then
		return nil
	end
	local list = waiting[player] or {}
	waiting[player] = list
	table.insert(list, coroutine.running())
	coroutine.yield()
	return DataService.get(player)
end

-- Tell the client its profile changed (coalesced to one send per frame)
function DataService.changed(player: Player)
	local session = sessions[player]
	if not session or session.sendQueued then
		return
	end
	session.sendQueued = true
	task.defer(function()
		session.sendQueued = false
		sendView(player)
	end)
end

function DataService.isSaving(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.canSave
end

local function resume(player: Player)
	local list = waiting[player]
	waiting[player] = nil
	if list then
		for _, thread in list do
			task.spawn(thread)
		end
	end
end

local function onPlayerAdded(player: Player)
	local profile: { [string]: any }? = nil
	local canSave = true
	if memoryMode then
		profile = ProfileSchema.load(ProfileSchema.deepCopy(memoryProfiles[player.UserId]))
	else
		local reason
		profile, reason = loadFromStore(player)
		if reason == "left" then
			resume(player)
			return
		elseif reason == "locked" then
			player:Kick("Your progress is still saving from your last server. Please rejoin in a moment!")
			resume(player)
			return
		elseif profile == nil then
			profile = ProfileSchema.default()
			canSave = false
			Net.fire("Notice", player, "saveDown")
		end
	end
	if player.Parent ~= Players then
		-- Left while loading: give the lock back
		if not memoryMode and canSave then
			sessions[player] = {
				profile = profile :: any,
				canSave = true,
				saving = false,
				pendingSave = false,
				sendQueued = false,
				released = false,
				playClock = os.clock(),
			}
			DataService.save(player, true)
			sessions[player] = nil
		end
		resume(player)
		return
	end
	local session: Session = {
		profile = profile :: { [string]: any },
		canSave = canSave,
		saving = false,
		pendingSave = false,
		sendQueued = false,
		released = false,
		playClock = os.clock(),
	}
	sessions[player] = session
	ProfileSchema.rollDay(session.profile, os.time())
	sendView(player)
	resume(player)
	DataService.Loaded:Fire(player, session.profile)
end

local function onPlayerRemoving(player: Player)
	if sessions[player] then
		local ok, err = pcall(DataService.Leaving.Fire, DataService.Leaving, player, sessions[player].profile)
		if not ok then
			warn("[Data] leaving handler: " .. tostring(err))
		end
		DataService.save(player, true)
		sessions[player] = nil
	end
	resume(player)
end

-- Studio and admins: start over as a first-time player (onboarding tests)
function DataService.resetProfile(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	local fresh = ProfileSchema.default()
	for key in session.profile do
		session.profile[key] = nil
	end
	for key, value in fresh do
		session.profile[key] = value
	end
	ProfileSchema.rollDay(session.profile, os.time())
	DataService.changed(player)
	DataService.Reset:Fire(player, session.profile)
end

local function isAdmin(player: Player): boolean
	return RunService:IsStudio() or table.find(Config.Admins, player.UserId) ~= nil
end
DataService.isAdmin = isAdmin

function DataService.init()
	if game.PlaceId == 0 then
		memoryMode = true
	else
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(Config.Data.storeName)
		end)
		if ok then
			store = result
			if RunService:IsStudio() then
				-- Studio needs "Enable Studio Access to API Services"; without it every call errors
				local probeOk = pcall(function()
					(store :: DataStore):GetAsync("__probe")
				end)
				memoryMode = not probeOk
			end
		else
			memoryMode = true
		end
	end
	if memoryMode then
		warn("[DataService] DataStores unavailable here: profiles are kept in memory for this session only")
	end

	Net.on("Settings.Save", function(player: Player, input: any)
		local session = sessions[player]
		if not session then
			return
		end
		local clean = ProfileSchema.sanitizeSettings(input)
		if clean == nil then
			return
		end
		for key, value in clean do
			session.profile.settings[key] = value
		end
		DataService.changed(player)
	end)

	Net.on("Dev.ResetProfile", function(player: Player)
		if isAdmin(player) then
			DataService.resetProfile(player)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Autosave (also refreshes the session lock so it never looks stale)
	task.spawn(function()
		while true do
			task.wait(Config.Data.autosaveInterval)
			for player in sessions do
				task.spawn(DataService.save, player, false)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				DataService.save(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
