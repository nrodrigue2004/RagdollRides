--!strict
-- FunnelKit v1: the studio's shared funnel layer. The SAME FILE ships in every game (copy it, never fork
-- it; game-specific parts live in that game's FunnelDef). Pure Luau with no Roblox types, so Lune tests it.
-- It answers two questions in the Creator Dashboard (Analytics > Funnels and Analytics > Custom events):
--   1. Which stage has the most players? -> "session_start" counted by CustomField01 (the stage).
--   2. Where do players drop off?        -> the "Progress" funnel (the game's stage ladder, once per
--      account), the "Returns" funnel (session 1, 2, 3, 5, 10, 20) and "session_end" /
--      "first_session_end" broken down by stage, activity at quit and quit reason.
-- Events (4 custom event names, 2 funnels; Roblox allows 100 names and 10 funnels per experience):
--   session_start      value: session number   F1 stage   F2 new | returning   F3 days away
--   stage_reached      value: minutes played    F1 stage   F2 session bucket
--   session_end        value: session seconds   F1 stage   F2 activity + time in it   F3 reason + length
--   first_session_end  same as session_end, for a player's first session only
-- The game owns the save: FunnelKit keeps its numbers in one plain table the game stores in the profile
-- (FunnelKit.blank()). A teleport between the game's own places is one session, not a quit: call hop()
-- before teleporting, and a rejoin within def.hopSeconds continues the session.
-- Every field is a short label (no names, no typed text), so the 8,000-combination field limit holds.

local FunnelKit = {}
FunnelKit.__index = FunnelKit
FunnelKit.VERSION = 1

FunnelKit.PROGRESS = "Progress"
FunnelKit.RETURNS = "Returns"
FunnelKit.LIFE_SESSION = "life" -- one funnel session per account: each step counts once per player
FunnelKit.DEFAULT_RETURNS = { 1, 2, 3, 5, 10, 20 }
FunnelKit.DEFAULT_HOP_SECONDS = 180

-- Quit reasons the game can pass to leave() (anything else is logged as "left")
FunnelKit.REASONS = { left = true, kicked = true, kicked_roblox = true, shutdown = true, idle = true }

export type Stage = { name: string, reached: (profile: any) -> boolean }
export type Def = {
	stages: { Stage }, -- the lifetime ladder in order; stage 1 should be "Joined" (always true)
	returns: { number }?, -- session numbers for the Returns funnel (default 1, 2, 3, 5, 10, 20)
	hopSeconds: number?, -- a rejoin within this many seconds of hop() is the same session (default 180)
}
export type Sink = {
	funnel: (player: any, funnel: string, sessionId: string, step: number, stepName: string) -> (),
	custom: (player: any, name: string, value: number, fields: { string }) -> (),
}
export type Save = {
	sessions: number, -- sessions started (place hops excluded)
	stage: number, -- furthest stage reached
	firstAt: number, -- unix time of the first session
	lastAt: number, -- unix time the last session started
	sessionAt: number, -- unix time this session started (kept across place hops)
	hopAt: number, -- unix time of the last hop() (0: none pending)
	played: number, -- seconds played, all sessions
}

type State = {
	save: Save,
	placeAt: number,
	activity: string,
	activityAt: number,
	hopping: boolean,
}

function FunnelKit.blank(): Save
	return { sessions = 0, stage = 0, firstAt = 0, lastAt = 0, sessionAt = 0, hopAt = 0, played = 0 }
end

-- Fill missing keys of a stored save (older profiles, or a profile made before analytics existed)
function FunnelKit.fill(save: any): Save
	local out = if type(save) == "table" then save else {}
	for key, value in FunnelKit.blank() :: any do
		if type(out[key]) ~= "number" then
			out[key] = value
		end
	end
	return out :: Save
end

-- Short, dashboard-safe text: letters, digits, spaces and - + . : _ only, at most 50 characters
function FunnelKit.clean(text: string): string
	local s = string.gsub(text, "[^%w %-%+%.:_]", "")
	return string.sub(s, 1, 50)
end

-- "03 First car": the stage label, zero-padded so the dashboard sorts it in ladder order
function FunnelKit.label(def: Def, stage: number): string
	local entry = def.stages[stage]
	if entry == nil then
		return "00 Unknown"
	end
	return FunnelKit.clean(string.format("%02d %s", stage, entry.name))
end

local function bucket(seconds: number, edges: { number }, names: { string }): string
	for i, edge in edges do
		if seconds < edge then
			return names[i]
		end
	end
	return names[#names]
end

-- Session length: under 1m, 1-3m, 3-5m, 5-10m, 10-20m, 20-40m, 40m+
function FunnelKit.lengthBucket(seconds: number): string
	return bucket(
		seconds,
		{ 60, 180, 300, 600, 1200, 2400 },
		{ "under 1m", "1-3m", "3-5m", "5-10m", "10-20m", "20-40m", "40m+" }
	)
end

-- Time spent in the current activity: under 30s, 30s-1m, 1-3m, 3-10m, 10m+
function FunnelKit.dwellBucket(seconds: number): string
	return bucket(seconds, { 30, 60, 180, 600 }, { "under 30s", "30s-1m", "1-3m", "3-10m", "10m+" })
end

-- Days since the last session: same day, 1d, 2-3d, 4-7d, 8-30d, 30d+
function FunnelKit.awayBucket(seconds: number): string
	return bucket(
		seconds,
		{ 86400, 2 * 86400, 4 * 86400, 8 * 86400, 31 * 86400 },
		{ "same day", "1d", "2-3d", "4-7d", "8-30d", "30d+" }
	)
end

-- Session number: 1, 2, 3-5, 6-10, 11-20, 21+
function FunnelKit.sessionBucket(n: number): string
	return bucket(n, { 2, 3, 6, 11, 21 }, { "1", "2", "3-5", "6-10", "11-20", "21+" })
end

-- The furthest stage whose test passes along with every stage before it (a broken test counts as false)
function FunnelKit.stageOf(def: Def, profile: any): number
	local stage = 0
	for i, entry in def.stages do
		local ok, reached = pcall(entry.reached, profile)
		if not (ok and reached) then
			break
		end
		stage = i
	end
	return stage
end

-- now: unix seconds (os.time in the game, a fake clock in tests)
function FunnelKit.new(def: Def, sink: Sink, now: () -> number): any
	local self = setmetatable({}, FunnelKit) :: any
	self.def = def
	self.sink = sink
	self.now = now
	self.returns = def.returns or FunnelKit.DEFAULT_RETURNS
	self.hopSeconds = def.hopSeconds or FunnelKit.DEFAULT_HOP_SECONDS
	self.states = {} :: { [any]: State }
	self.closing = false
	return self
end

function FunnelKit.send(self: any, player: any, name: string, value: number, fields: { string })
	local clean = {}
	for i, text in fields do
		clean[i] = FunnelKit.clean(text)
	end
	pcall(self.sink.custom, player, name, value, clean)
end

function FunnelKit.step(self: any, player: any, funnel: string, step: number, stepName: string)
	pcall(self.sink.funnel, player, funnel, FunnelKit.LIFE_SESSION, step, FunnelKit.clean(stepName))
end

-- Advance the Progress funnel to the profile's current stage (call on join and whenever the profile
-- changes; cheap). Each newly reached stage logs its funnel step and a stage_reached event, in order.
function FunnelKit.check(self: any, player: any, profile: any)
	local state: State? = self.states[player]
	if state == nil then
		return
	end
	local save = state.save
	local stage = FunnelKit.stageOf(self.def, profile)
	if stage <= save.stage then
		return
	end
	local minutes = math.floor((save.played + math.max(0, self.now() - state.placeAt)) / 60)
	for i = save.stage + 1, stage do
		self:step(player, FunnelKit.PROGRESS, i, self.def.stages[i].name)
		if i > 1 then
			self:send(
				player,
				"stage_reached",
				minutes,
				{ FunnelKit.label(self.def, i), "session " .. FunnelKit.sessionBucket(save.sessions) }
			)
		end
	end
	save.stage = stage
end

-- The player's save is loaded. Returns true when this is a new session (false: a hop between places).
function FunnelKit.join(self: any, player: any, save: Save, profile: any): boolean
	local t = self.now()
	local continuing = save.hopAt > 0 and t - save.hopAt <= self.hopSeconds and save.sessions > 0
	save.hopAt = 0
	self.states[player] = {
		save = save,
		placeAt = t,
		activity = "Joining",
		activityAt = t,
		hopping = false,
	}
	if not continuing then
		local away = if save.lastAt > 0 then t - save.lastAt else 0
		local isNew = save.sessions == 0
		save.sessions += 1
		save.sessionAt = t
		save.lastAt = t
		if save.firstAt == 0 then
			save.firstAt = t
		end
		local index = table.find(self.returns, save.sessions)
		if index then
			self:step(player, FunnelKit.RETURNS, index, "Session " .. save.sessions)
		end
		-- the stage counted is the one the player arrives with (before this session's progress)
		local stage = math.max(save.stage, 1)
		self:send(player, "session_start", save.sessions, {
			FunnelKit.label(self.def, stage),
			if isNew then "new" else "returning",
			if isNew then "first" else FunnelKit.awayBucket(away),
		})
	end
	self:check(player, profile)
	return not continuing
end

-- What the player is doing now ("Lobby", "Run", "Shop"...). Only a change resets the time-in-activity.
function FunnelKit.activity(self: any, player: any, name: string)
	local state: State? = self.states[player]
	if state == nil or state.activity == name then
		return
	end
	state.activity = name
	state.activityAt = self.now()
end

-- The player is about to teleport to another of this game's places: not a quit
function FunnelKit.hop(self: any, player: any)
	local state: State? = self.states[player]
	if state == nil then
		return
	end
	state.hopping = true
	state.save.hopAt = self.now()
end

-- A teleport failed for good: the player stays, so a later leave is a real quit again
function FunnelKit.hopFailed(self: any, player: any)
	local state: State? = self.states[player]
	if state == nil then
		return
	end
	state.hopping = false
	state.save.hopAt = 0
end

-- The player is leaving this server. Call before the save is written (played time and hopAt persist).
function FunnelKit.leave(self: any, player: any, reason: string?)
	local state: State? = self.states[player]
	if state == nil then
		return
	end
	self.states[player] = nil
	local t = self.now()
	local save = state.save
	save.played += math.max(0, t - state.placeAt)
	if state.hopping then
		return
	end
	local why = if self.closing
		then "shutdown"
		elseif reason and FunnelKit.REASONS[reason] then reason
		else "left"
	local length = math.max(0, t - save.sessionAt)
	self:send(player, if save.sessions <= 1 then "first_session_end" else "session_end", length, {
		FunnelKit.label(self.def, math.max(save.stage, 1)),
		state.activity .. " " .. FunnelKit.dwellBucket(t - state.activityAt),
		why .. " " .. FunnelKit.lengthBucket(length),
	})
end

-- The server is closing: log every open session now (events sent later may never leave the server).
-- A player already ended here is untracked, so their PlayerRemoving later logs nothing twice.
function FunnelKit.shutdown(self: any)
	self.closing = true
	local players = {}
	for player in self.states do
		table.insert(players, player)
	end
	for _, player in players do
		self:leave(player, "shutdown")
	end
end

function FunnelKit.isTracking(self: any, player: any): boolean
	return self.states[player] ~= nil
end

return FunnelKit
