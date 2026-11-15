--!strict
-- Round: the round state machine every round-based mode runs on (spec: Round state machine, Game
-- modes). Lobby -> Countdown -> Play -> Results -> Requeue -> Lobby. Pure, so tests/run.luau checks it
-- in Lune; the server's RoundManager feeds it the clock and the counts and acts on each change.
-- * Lobby: waits for minPlayers; starts lobbyFill s after that many are in, or at once when full.
--   Dropping below minPlayers stops the clock again. (Brawl adds bots after its own wait.)
-- * Countdown: cars steerable but held.
-- * Play: ends at playMax, afterFirstFinish s after the first finisher, when everyone has finished,
--   or when nobody is left.
-- * Results: results s (skippable: ends early when every player skipped). Requeue: requeue s, then a
--   fresh Lobby with whoever stayed.

local Round = {}

Round.PHASES = { "Lobby", "Countdown", "Play", "Results", "Requeue" }

export type Rules = {
	minPlayers: number,
	maxPlayers: number,
	lobbyFill: number,
	countdown: number,
	playMax: number,
	afterFirstFinish: number?,
	results: number,
	requeue: number,
}

export type State = {
	phase: string,
	since: number, -- when this phase began
	endsAt: number?, -- when it ends by the clock (nil: waiting, e.g. a lobby short of players)
	readyAt: number?, -- Lobby: when minPlayers was reached
	firstFinishAt: number?, -- Play: the first finish
	round: number, -- counts rounds on this machine (1 for the first)
}

export type Counts = {
	players: number, -- players in the round (racers in Play)
	finished: number?, -- Play: how many have finished (or are out)
	skipped: number?, -- Results: how many tapped to skip
}

function Round.new(now: number): State
	return { phase = "Lobby", since = now, endsAt = nil, readyAt = nil, firstFinishAt = nil, round = 1 }
end

local function enter(state: State, phase: string, now: number, rules: Rules)
	state.phase = phase
	state.since = now
	state.readyAt = nil
	state.firstFinishAt = nil
	if phase == "Countdown" then
		state.endsAt = now + rules.countdown
	elseif phase == "Play" then
		state.endsAt = now + rules.playMax
	elseif phase == "Results" then
		state.endsAt = now + rules.results
	elseif phase == "Requeue" then
		state.endsAt = now + rules.requeue
	else
		state.endsAt = nil
		state.round += 1
	end
end

-- The first finish of a Play phase (the afterFirstFinish clock starts)
function Round.noteFinish(state: State, now: number, rules: Rules)
	if state.phase ~= "Play" or state.firstFinishAt ~= nil then
		return
	end
	state.firstFinishAt = now
	if rules.afterFirstFinish then
		state.endsAt = math.min(state.endsAt or math.huge, now + rules.afterFirstFinish)
	end
end

-- Move the machine on. Returns the new phase when it changed (one step per call), else nil.
function Round.update(state: State, rules: Rules, now: number, counts: Counts): string?
	local phase = state.phase
	if phase == "Lobby" then
		if counts.players < rules.minPlayers then
			state.readyAt = nil
			state.endsAt = nil
			return nil
		end
		if state.readyAt == nil then
			state.readyAt = now
			state.endsAt = now + rules.lobbyFill
		end
		if counts.players >= rules.maxPlayers or now >= (state.endsAt :: number) then
			enter(state, "Countdown", now, rules)
			return "Countdown"
		end
		return nil
	elseif phase == "Countdown" then
		if counts.players == 0 then
			enter(state, "Results", now, rules)
			return "Results"
		end
		if now >= (state.endsAt :: number) then
			enter(state, "Play", now, rules)
			return "Play"
		end
		return nil
	elseif phase == "Play" then
		local finished = counts.finished or 0
		if counts.players == 0 or finished >= counts.players or now >= (state.endsAt :: number) then
			enter(state, "Results", now, rules)
			return "Results"
		end
		return nil
	elseif phase == "Results" then
		local skipped = counts.skipped or 0
		if now >= (state.endsAt :: number) or (counts.players > 0 and skipped >= counts.players) then
			enter(state, "Requeue", now, rules)
			return "Requeue"
		end
		return nil
	elseif phase == "Requeue" then
		if now >= (state.endsAt :: number) then
			enter(state, "Lobby", now, rules)
			return "Lobby"
		end
		return nil
	end
	return nil
end

-- Seconds left on the clock (nil while a lobby waits for players)
function Round.left(state: State, now: number): number?
	if state.endsAt == nil then
		return nil
	end
	return math.max(0, (state.endsAt :: number) - now)
end

return Round
