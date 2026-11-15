-- RoundManager: runs one round of a round-based mode on the shared state machine (spec: Round state
-- machine; Shared/Round has the rules). It owns the clock and the player list and tells the mode
-- when each phase begins; the mode does the rest:
--   mode.init(round)     Countdown begins: build or claim the arena, put the cars on the grid, held
--   mode.start(round)    Play begins (GO)
--   mode.tick(round, dt) every step while playing
--   mode.finish(round)   Results begin: score and pay
--   mode.cleanup(round)  Requeue begins: put players back, free the arena
--   mode.counts(round)   the numbers Round.update needs ({ players, finished, skipped })
--   mode.info(round, player) extra fields for that player's Round.State (optional)
-- Each change sends Round.State to the round's players: { id, kind, phase, endsAt (server time),
-- round, players = { userIds } } plus the mode's info. Quick races use it now; Brawl and Highway in
-- milestones 7 and 8.

local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Round = require(Shared.Round)

local RoundManager = {}
RoundManager.__index = RoundManager

export type Mode = {
	init: (any) -> (),
	start: (any) -> (),
	tick: ((any, number) -> ())?,
	finish: (any) -> (),
	cleanup: (any) -> (),
	counts: (any) -> Round.Counts,
	info: ((any, Player) -> { [string]: any }?)?,
}

local nextId = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

function RoundManager.new(kind: string, rules: Round.Rules, mode: Mode)
	nextId += 1
	local self = setmetatable({}, RoundManager)
	self.id = nextId
	self.kind = kind
	self.rules = rules
	self.mode = mode
	self.players = {} :: { Player }
	self.state = Round.new(now())
	self.data = {} -- the mode's own fields for this round
	self.closed = false
	return self
end

function RoundManager:has(player: Player): boolean
	return table.find(self.players, player) ~= nil
end

function RoundManager:add(player: Player): boolean
	if self.closed or self:has(player) or #self.players >= self.rules.maxPlayers then
		return false
	end
	table.insert(self.players, player)
	self:broadcast()
	return true
end

function RoundManager:remove(player: Player)
	local index = table.find(self.players, player)
	if index then
		table.remove(self.players, index)
		Net.fire("Round.State", player, { id = self.id, kind = self.kind, phase = "Left" })
		self:broadcast()
	end
end

function RoundManager:phase(): string
	return self.state.phase
end

function RoundManager:stateFor(player: Player): { [string]: any }
	local ids = {}
	for _, p in self.players do
		table.insert(ids, p.UserId)
	end
	local out: { [string]: any } = {
		id = self.id,
		kind = self.kind,
		phase = self.state.phase,
		endsAt = self.state.endsAt,
		round = self.state.round,
		players = ids,
		max = self.rules.maxPlayers,
	}
	local info = self.mode.info and self.mode.info(self, player)
	if info then
		for k, v in info do
			out[k] = v
		end
	end
	return out
end

function RoundManager:broadcast()
	for _, player in self.players do
		Net.fire("Round.State", player, self:stateFor(player))
	end
end

function RoundManager:noteFinish()
	Round.noteFinish(self.state, now(), self.rules)
	self:broadcast()
end

-- One step (the owning service calls it on Heartbeat). Returns the new phase when it changed.
function RoundManager:step(dt: number): string?
	if self.closed then
		return nil
	end
	local counts = self.mode.counts(self)
	local before = self.state.endsAt
	local phase = Round.update(self.state, self.rules, now(), counts)
	if phase == "Countdown" then
		self.mode.init(self)
	elseif phase == "Play" then
		self.mode.start(self)
	elseif phase == "Results" then
		self.mode.finish(self)
	elseif phase == "Requeue" then
		self.mode.cleanup(self)
	end
	if phase or self.state.endsAt ~= before then
		self:broadcast()
	end
	if self.state.phase == "Play" and self.mode.tick then
		self.mode.tick(self, dt)
	end
	return phase
end

function RoundManager:close()
	self.closed = true
end

return RoundManager
