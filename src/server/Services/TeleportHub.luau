-- TeleportHub: hops from the hub to a mode's place, with the party (spec: Scripts > TeleportService
-- wrapper; World and places). Config.Places holds the place ids; while a place id is 0 (the place
-- does not exist yet: Bumper Brawl is milestone 7, Highway Havoc milestone 8) the hop answers
-- "modeSoon" and nobody moves.
-- * A party leader sends every party member in this server; a member alone sends only themselves.
-- * TeleportAsync puts the group in one server of that place. Teleport data carries the party and the
--   mode chip (Casual / Ranked, Co-op / Versus) so the mode server can keep the party together.
-- * Ranked (Brawl) opens after Config.Brawl.ranked.unlockRounds casual rounds, Versus (Highway) after
--   Config.Highway.versusUnlockRuns co-op runs; the hub checks it here and the mode place checks it
--   again on arrival.
-- * home(player): from a mode place back to Tumble Park (Config.Places.start, or the place the player
--   came from), with their party if they lead one.
-- * A failed hop (TeleportInitFailed) retries up to Config.Places.teleportRetries times, then tells
--   the player (Notice "teleportFailed") and leaves them in the hub.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local DataService = require(script.Parent.DataService)
local PartyService = require(script.Parent.PartyService)

local TeleportHub = {}

-- The place for a mode card's chip
local PLACES = {
	brawl = { casual = "brawlCasual", ranked = "brawlRanked" },
	highway = { coop = "highwayCoop", versus = "highwayVersus" },
}

local attempts: { [Player]: { placeId: number, options: TeleportOptions, tries: number } } = {}

function TeleportHub.placeFor(modeName: string, chip: string): number
	local key = PLACES[modeName] and PLACES[modeName][chip]
	return if key then Config.Places[key] or 0 else 0
end

local function hop(player: Player, placeId: number, data: { [string]: any }): (boolean, string?)
	local group = if PartyService.isLeader(player) then PartyService.members(player) else { player }
	local ids = {}
	for _, member in group do
		table.insert(ids, member.UserId)
	end
	local options = Instance.new("TeleportOptions")
	data.party = ids
	data.from = game.PlaceId
	options:SetTeleportData(data)
	for _, member in group do
		attempts[member] = { placeId = placeId, options = options, tries = 0 }
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(placeId, group, options)
	end)
	if not ok then
		warn("[Teleport] " .. tostring(err))
		return false, "teleportFailed"
	end
	return true, nil
end

-- Ranked opens after a few casual rounds (spec: Ranked and Versus chips unlock after 3 and 2 plays)
function TeleportHub.rankedOpen(player: Player): boolean
	local profile = DataService.get(player)
	return profile ~= nil and (profile.stats.brawlRounds or 0) >= Config.Brawl.ranked.unlockRounds
end

function TeleportHub.versusOpen(player: Player): boolean
	local profile = DataService.get(player)
	return profile ~= nil and (profile.stats.highwayRuns or 0) >= Config.Highway.versusUnlockRuns
end

-- Send a player (and their party, if they lead it) to a mode. Returns false with a reason key.
function TeleportHub.send(player: Player, modeName: string, chip: string): (boolean, string?)
	local placeId = TeleportHub.placeFor(modeName, chip)
	if placeId == 0 then
		return false, "modeSoon"
	end
	if modeName == "brawl" and chip == "ranked" and not TeleportHub.rankedOpen(player) then
		return false, "rankedLocked"
	end
	if modeName == "highway" and chip == "versus" and not TeleportHub.versusOpen(player) then
		return false, "versusLocked"
	end
	return hop(player, placeId, { mode = modeName, chip = chip })
end

-- Back to Tumble Park from a mode place
function TeleportHub.home(player: Player): (boolean, string?)
	local placeId = Config.Places.start
	if placeId == 0 then
		local ok, joinData = pcall(function()
			return player:GetJoinData()
		end)
		local source = ok and type(joinData) == "table" and joinData.SourcePlaceId
		placeId = if type(source) == "number" then source else 0
	end
	if placeId == 0 or placeId == game.PlaceId then
		return false, "teleportFailed"
	end
	return hop(player, placeId, { mode = "hub" })
end

function TeleportHub.init()
	TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult)
		local attempt = attempts[player]
		if attempt == nil or result == Enum.TeleportResult.IsTeleporting then
			return
		end
		attempt.tries += 1
		if attempt.tries > Config.Places.teleportRetries then
			attempts[player] = nil
			Net.fire("Notice", player, "teleportFailed")
			return
		end
		task.delay(attempt.tries, function()
			if player.Parent == Players then
				pcall(function()
					TeleportService:TeleportAsync(attempt.placeId, { player }, attempt.options)
				end)
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		attempts[player] = nil
	end)
end

return TeleportHub
