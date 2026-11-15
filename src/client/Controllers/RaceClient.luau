-- RaceClient: quick races on this device (spec: Tracks: quick race; Round state machine). The server
-- runs the round (RaceService) and sends Round.State on every change; this shows it:
-- * Lobby: a pill with racers waiting and the start clock, and LEAVE. You keep driving in the hub.
-- * Countdown: your car is on the grid, held (steering works, the gas does not), 3, 2, 1, GO!
-- * Play: the timer runs from GO; the pill shows your place (by checkpoints). Racers are solid and
--   fully visible to each other; free-run players stay ghosts.
-- * Finish: your place pops; Race.Result opens the results card (places, times, coins) with
--   RACE AGAIN (you stay queued) and LEAVE.
-- The race map is a copy of a starter map at the race slot's offset; it is registered with TracksClient
-- so checkpoints, coins and the finish work as on any map.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local RaceMath = require(Shared.RaceMath)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)

local Client = script.Parent.Parent
local HubHud = require(Client.Ui.HubHud)
local RaceHud = require(Client.Ui.RaceHud)
local TracksHud = require(Client.Ui.TracksHud)

local LocalPlayer = Players.LocalPlayer

local RaceClient = {}

local controllers: any = nil
local state: { [string]: any }? = nil
local registered: { [string]: string } = {} -- race map id -> the base map and round it was built for
local lastCue = -1

local function playerGui(): Instance
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function phase(): string?
	return state and state.phase
end

function RaceClient.isQueued(): boolean
	return phase() == "Lobby"
end

function RaceClient.inRace(): boolean
	local p = phase()
	return p == "Countdown" or p == "Play" or p == "Results"
end

function RaceClient.join()
	Net.send("Race.Join")
end

function RaceClient.leave()
	Net.send("Race.Leave")
end

local function registerMap(s: { [string]: any })
	local info = s.map
	if type(info) ~= "table" then
		return
	end
	local key = tostring(info.base) .. "#" .. tostring(s.id)
	if registered[info.id] == key then
		return
	end
	local base = StarterMaps.byId[info.base]
	if base == nil then
		return
	end
	local def = table.clone(base) :: any
	def.id = info.id
	def.offset = info.offset
	def.race = s.id
	def.tut = nil
	def.reward = nil
	registered[info.id] = key
	controllers.Tracks.registerMap(def)
end

local function placeLine(s: { [string]: any }): string?
	local order = s.order
	if type(order) ~= "table" then
		return nil
	end
	local index = table.find(order, LocalPlayer.UserId)
	if index == nil then
		return nil
	end
	return string.format("%s of %d", RaceMath.ordinal(index), #order)
end

local function refresh()
	local s = state
	if s == nil then
		RaceHud.status(playerGui(), nil)
		controllers.Input.setHold(false)
		return
	end
	local now = Workspace:GetServerTimeNow()
	if s.phase == "Lobby" then
		local count = #(s.players or {})
		local line
		if count < 2 then
			line = "QUICK RACE: waiting for racers"
		elseif s.endsAt then
			line = string.format(
				"QUICK RACE %d/%d · starts in %d",
				count,
				s.max or 8,
				math.ceil(s.endsAt - now)
			)
		else
			line = string.format("QUICK RACE %d/%d · waiting for a track", count, s.max or 8)
		end
		RaceHud.status(playerGui(), line, RaceClient.leave)
		controllers.Input.setHold(false)
	elseif s.phase == "Countdown" then
		RaceHud.status(playerGui(), if s.building then "Building the track..." else "GET READY!", nil)
		controllers.Input.setHold(true)
	elseif s.phase == "Play" then
		controllers.Input.setHold(false)
		RaceHud.status(playerGui(), placeLine(s) or "GO GO GO!", nil)
	else
		controllers.Input.setHold(false)
		RaceHud.status(playerGui(), nil)
	end
end

local function onState(s: any)
	if type(s) ~= "table" or s.kind ~= "race" then
		return
	end
	if s.phase == "Left" then
		if state and state.id == s.id then
			state = nil
			RaceHud.hideResults()
		end
		refresh()
		controllers.Tracks.reshadeCars()
		return
	end
	local previous = phase()
	state = s
	registerMap(s)
	if s.phase == "Countdown" and previous ~= "Countdown" then
		lastCue = -1
		controllers.Browse.close()
		controllers.Shop.close()
		for _, name in { "modes", "party", "board" } do
			HubHud.close(name)
		end
	end
	if s.phase == "Play" and previous ~= "Play" then
		TracksHud.showCue("GO!", 1)
		controllers.Juice.fire("Finish", { volume = 0.4 })
	end
	refresh()
	controllers.Tracks.reshadeCars()
end

local function onRun(result: any)
	if type(result) ~= "table" then
		return
	end
	if result.ok and result.place then
		TracksHud.showCue(string.format("FINISHED %s!", string.upper(RaceMath.ordinal(result.place))), 2.5)
	elseif not result.ok then
		TracksHud.toast("That run didn't count, so it's a DNF (still 10 coins).", 4)
	end
end

local function onResult(result: any)
	if type(result) ~= "table" or type(result.places) ~= "table" then
		return
	end
	local rows = {}
	for _, p in result.places do
		table.insert(rows, {
			place = p.place,
			name = p.name,
			time = if p.time then TracksMath.formatTime(p.time) else "--",
			me = p.userId == LocalPlayer.UserId,
			dnf = p.dnf == true,
		})
	end
	local mine = result.mine or {}
	local title = if mine.dnf
		then "RACE OVER"
		elseif mine.place == 1 then "YOU WON!"
		else string.format("%s PLACE!", string.upper(RaceMath.ordinal(mine.place or 0)))
	if mine.place == 1 then
		controllers.Juice.fire("StarEarned")
	end
	local coinsLine = string.format("+%d coins", mine.coins or 0)
	if mine.capped then
		coinsLine ..= " (today's Tracks coin limit)"
	end
	RaceHud.showResults(playerGui(), {
		title = title,
		mapName = result.mapName or "",
		rows = rows,
		coinsLine = coinsLine,
		seconds = (result.requeue or 6),
		onSkip = function()
			Net.send("Race.Skip")
		end,
		onLeave = RaceClient.leave,
	})
end

local function update()
	local s = state
	if s == nil then
		return
	end
	local now = Workspace:GetServerTimeNow()
	if s.phase == "Countdown" and s.endsAt and not s.building then
		local left = math.ceil(s.endsAt - now)
		if left ~= lastCue and left >= 1 and left <= 3 then
			lastCue = left
			TracksHud.showCue(tostring(left), 0.9)
			controllers.Juice.fire("Coin", { pitch = 0.8, volume = 0.5 })
		end
	elseif s.phase == "Play" and s.goAt then
		-- The car reached the grid after GO arrived: start the timer now (still timed from GO)
		local map = controllers.Tracks.getMap()
		if map and (map :: any).race == s.id and controllers.Tracks.getRunState() == "ready" then
			controllers.Tracks.startRace(s.goAt)
		end
	end
end

function RaceClient.init(all)
	controllers = all
end

function RaceClient.start()
	Net.listen("Round.State", onState)
	Net.listen("Race.Result", onResult)
	controllers.Tracks.RaceRun:Connect(onRun)
	local function watch(player: Player)
		player:GetAttributeChangedSignal("RaceId"):Connect(function()
			controllers.Tracks.reshadeCars()
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		update()
		clock += dt
		if clock >= 0.25 then
			clock = 0
			if phase() == "Lobby" then
				refresh()
			end
		end
	end)
end

return RaceClient
