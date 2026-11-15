-- QuestService: daily and weekly quests, the daily chest, the login streak and gifts
-- (spec: Progression > Quests and streaks, Economy > Gift). Rules and pools are in Shared/Quests.
-- * Quests are picked per player from the day (or week) on first use, so a rejoin never rerolls them.
--   Quests come from the modes in Config.Quests.liveModes whose place exists (Shared/Place.modeLive),
--   so until a mode's place is created, no quest asks for it. Events are counted here from what the
--   server saw happen (BrawlService sends the Bumper Brawl ones).
-- * Quest.Claim(id) pays a finished quest (60 / 80 / 100 daily, 300 weekly); "chest" opens the daily
--   chest once all 3 dailies are claimed (150 coins or a common cosmetic you don't own); "weeklyStars"
--   pays 5 stars once all 3 weeklies are claimed.
-- * Streak.Claim: once per UTC day. A 7-day loop of 50, 75, 100, a crate key, 150, 200 and a weekly
--   cosmetic (250 coins if you already have it). Each missed day steps back one day, never below 1.
-- * Gift.Send(userId): 10 of your own coins to a Roblox friend in this server, once a day.
-- Claim buttons pulse on the client; nothing here has a countdown (design pillar: no fake urgency).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Place = require(Shared.Place)
local ProfileSchema = require(Shared.ProfileSchema)
local Quests = require(Shared.Quests)
local StarterMaps = require(Shared.StarterMaps)

local Services = script.Parent
local BuilderService = require(Services.BuilderService)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MapPlayService = require(Services.MapPlayService)
local RaceService = require(Services.RaceService)
local ShopService = require(Services.ShopService)
local TracksService = require(Services.TracksService)

local QuestService = {}

local random = Random.new()

local function today(): number
	return ProfileSchema.dayNumber(os.time())
end

-- Make sure today's and this week's quests exist (the daily table resets at the UTC day)
local function ensure(player: Player, profile: { [string]: any })
	local day = today()
	local modes = {}
	for _, mode in Config.Quests.liveModes do
		if Place.modeLive(mode) then
			table.insert(modes, mode)
		end
	end
	if #profile.daily.quests == 0 then
		profile.daily.quests = Quests.pickDaily(day * 7349 + player.UserId, modes)
	end
	local week = Quests.weekOf(day)
	if profile.weekly.week ~= week then
		profile.weekly = {
			week = week,
			quests = Quests.pickWeekly(week * 7919 + player.UserId, modes),
			starsClaimed = false,
		}
	end
end

-- Count an event for a player's quests
function QuestService.event(player: Player, event: string, amount: number?, key: string?)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	ensure(player, profile)
	local done = Quests.apply(profile.daily.quests, event, amount or 1, key)
	for _, state in Quests.apply(profile.weekly.quests, event, amount or 1, key) do
		table.insert(done, state)
	end
	DataService.changed(player)
	for _, state in done do
		Net.fire("Quest.Done", player, { text = Quests.text(state) })
	end
end

local function answer(player: Player, result: { [string]: any })
	Net.fire("Shop.Result", player, result)
end

-- A common cosmetic the player doesn't own yet (the chest's prize), or nil
local function unownedCommon(profile: { [string]: any }): string?
	local options = {}
	for _, item in Catalog.shopItems() do
		if item.rarity == "common" and profile.inventory[item.id] == nil then
			table.insert(options, item.id)
		end
	end
	if #options == 0 then
		return nil
	end
	return options[random:NextInteger(1, #options)]
end

local function onClaim(player: Player, id: string)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	ensure(player, profile)
	local cfg = Config.Quests
	if id == "chest" then
		if profile.daily.chestClaimed or not Quests.allClaimed(profile.daily.quests) then
			return
		end
		profile.daily.chestClaimed = true
		local item = if random:NextNumber() < cfg.chestCosmeticChance then unownedCommon(profile) else nil
		if item then
			ShopService.giveItem(profile, item, false)
			DataService.changed(player)
			answer(player, { ok = true, id = "chest", item = item })
		else
			local coins = EconomyService.grantCoins(player, cfg.chestCoins, nil, "DailyChest")
			answer(player, { ok = true, id = "chest", coins = coins })
		end
		return
	end
	if id == "weeklyStars" then
		if profile.weekly.starsClaimed or not Quests.allClaimed(profile.weekly.quests) then
			return
		end
		profile.weekly.starsClaimed = true
		local stars = EconomyService.grantStars(player, cfg.weeklyStars, "WeeklyStars")
		answer(player, { ok = true, id = "weeklyStars", stars = stars })
		return
	end
	for _, list in { profile.daily.quests, profile.weekly.quests } do
		for _, state in list do
			if state.id == id and not state.claimed and Quests.isDone(state) then
				state.claimed = true
				local coins =
					EconomyService.grantCoins(player, Quests.reward(state, cfg), nil, "Quest_" .. id)
				answer(player, { ok = true, id = id, coins = coins, quest = true })
				return
			end
		end
	end
end

local function onStreak(player: Player)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local day = today()
	local nextDay, canClaim = Quests.streakNext(profile.streak.day or 0, profile.streak.lastClaim or 0, day)
	if not canClaim then
		return
	end
	profile.streak.day = nextDay
	profile.streak.lastClaim = day
	local reward = Config.Quests.streakRewards[nextDay]
	local result: { [string]: any } = { ok = true, id = "streak", day = nextDay }
	if type(reward) == "number" then
		result.coins = EconomyService.grantCoins(player, reward, nil, "Streak_" .. nextDay)
	elseif reward == "crate_key" then
		ShopService.giveItem(profile, "crate_key", false)
		result.item = "crate_key"
	else
		-- Day 7: this week's streak cosmetic, in turn
		local list = Catalog.streakCosmetics()
		local item = list[Quests.weekOf(day) % #list + 1]
		if profile.inventory[item.id] then
			result.coins = EconomyService.grantCoins(player, Config.Quests.streakOwnedCoins, nil, "Streak_7")
		else
			ShopService.giveItem(profile, item.id, false)
			result.item = item.id
		end
	end
	DataService.changed(player)
	answer(player, result)
end

local function onGift(player: Player, userId: number)
	local profile = DataService.get(player)
	local friend = Players:GetPlayerByUserId(userId)
	if profile == nil or friend == nil or friend == player or profile.daily.giftSent then
		return
	end
	if not EconomyService.areFriends(player, friend) or DataService.get(friend) == nil then
		answer(player, { ok = false, id = "gift", reason = "notFriend" })
		return
	end
	local coins = Config.Quests.giftCoins
	if not EconomyService.spend(player, coins, 0, "GiftSent") then
		answer(player, { ok = false, id = "gift", reason = "coins" })
		return
	end
	profile.daily.giftSent = true
	DataService.changed(player)
	EconomyService.grantCoins(friend, coins, nil, "GiftReceived")
	Net.fire("Notice", friend, "giftReceived")
	answer(player, { ok = true, id = "gift", to = friend.Name })
end

function QuestService.init()
	Net.on("Quest.Claim", onClaim)
	Net.on("Streak.Claim", onStreak)
	Net.on("Gift.Send", onGift)
	DataService.Loaded:Connect(function(player: Player, profile)
		ensure(player, profile)
		DataService.changed(player)
	end)

	TracksService.Finished:Connect(function(player: Player, map: any, firstFinish: boolean, info: any)
		if map.testOwner then
			return
		end
		info = info or {}
		QuestService.event(player, "finish", 1)
		if StarterMaps.byId[map.id] then
			QuestService.event(player, "finishStarter", 1, map.id)
		elseif map.custom and map.owner ~= player.UserId then
			QuestService.event(player, "playerMapFinish", 1, map.id)
		end
		if info.tier == 3 then
			QuestService.event(player, "gold", 1)
		end
		if info.isBest and not firstFinish then
			QuestService.event(player, "best", 1)
		end
		if (info.trailCoins or 0) > 0 then
			QuestService.event(player, "trailCoins", info.trailCoins)
		end
	end)
	-- A finished quick race counts as a finished run
	RaceService.Finished:Connect(function(player: Player, _place: number, dnf: boolean)
		if not dnf then
			QuestService.event(player, "finish", 1)
		end
	end)
	MapPlayService.Rated:Connect(function(player: Player)
		QuestService.event(player, "rate", 1)
	end)
	BuilderService.TestFinished:Connect(function(player: Player)
		QuestService.event(player, "test", 1)
	end)
end

return QuestService
