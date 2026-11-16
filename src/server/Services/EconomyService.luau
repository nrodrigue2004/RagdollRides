-- EconomyService: every coin and star a player earns goes through here (spec: Economy).
-- * Boosts: +10% per friend in the server (max +50%) and +5% per rebirth (max +50%), from TracksMath.boost.
-- * Daily caps per mode live in the profile's daily counters (UTC day); callers pass the cap.
-- * Every grant is logged to Roblox's economy analytics (in a pcall: analytics never blocks a reward).
-- Coins can also come from Robux coin packs (PurchaseService); nothing sold changes stats (design pillar).

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local TracksMath = require(Shared.TracksMath)

local DataService = require(script.Parent.DataService)

local EconomyService = {}

-- friends[a][b] = true when a and b are Roblox friends and both in this server
local friends: { [Player]: { [Player]: boolean } } = {}

function EconomyService.friendsInServer(player: Player): number
	local count = 0
	for other in friends[player] or {} do
		if other.Parent == Players then
			count += 1
		end
	end
	return count
end

function EconomyService.boostFor(player: Player): number
	local profile = DataService.get(player)
	local rebirths = if profile then profile.rebirths else 0
	return TracksMath.boost(EconomyService.friendsInServer(player), rebirths, Config.Economy)
end

-- AnalyticsService refuses values with a comma or quotes: drop them, keep 50 chars
local function clean(value: string): string
	return string.sub((string.gsub(value, "[,\"']", "")), 1, 50)
end

local function logEconomy(player: Player, currency: string, amount: number, balance: number, sku: string)
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			currency,
			amount,
			balance,
			Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
			clean(sku)
		)
	end)
end

-- Grant coins already worked out by the caller (boosts and caps applied). mode is the daily counter
-- ("tracks", "brawl", "highway") or nil. Returns the coins granted.
function EconomyService.grantCoins(player: Player, amount: number, mode: string?, sku: string): number
	local profile = DataService.get(player)
	if not profile or amount <= 0 then
		return 0
	end
	amount = math.floor(amount)
	profile.coins += amount
	if mode and profile.daily.coinsByMode[mode] ~= nil then
		profile.daily.coinsByMode[mode] += amount
	end
	logEconomy(player, "Coins", amount, profile.coins, sku)
	DataService.changed(player)
	return amount
end

-- Spend coins and stars together (a shop purchase). Returns false and spends nothing if either is short.
function EconomyService.spend(player: Player, coins: number, stars: number, sku: string): boolean
	local profile = DataService.get(player)
	if not profile or coins < 0 or stars < 0 or profile.coins < coins or profile.stars < stars then
		return false
	end
	profile.coins -= coins
	profile.stars -= stars
	for _, row in { { "Coins", coins, profile.coins }, { "Stars", stars, profile.stars } } do
		if row[2] > 0 then
			pcall(function()
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					row[1],
					row[2],
					row[3],
					Enum.AnalyticsEconomyTransactionType.Shop.Name,
					clean(sku)
				)
			end)
		end
	end
	DataService.changed(player)
	return true
end

-- Are these two players Roblox friends in this server? (gifts)
function EconomyService.areFriends(a: Player, b: Player): boolean
	return friends[a] ~= nil and friends[a][b] == true
end

function EconomyService.grantStars(player: Player, amount: number, sku: string): number
	local profile = DataService.get(player)
	if not profile or amount <= 0 then
		return 0
	end
	amount = math.floor(amount)
	profile.stars += amount
	logEconomy(player, "Stars", amount, profile.stars, sku)
	DataService.changed(player)
	return amount
end

-- Onboarding funnel steps (Creator Dashboard > Analytics > Funnels). Logged once per step per session.
local funnelLogged: { [Player]: { [number]: boolean } } = {}
function EconomyService.funnel(player: Player, step: number, name: string)
	local logged = funnelLogged[player] or {}
	funnelLogged[player] = logged
	if logged[step] then
		return
	end
	logged[step] = true
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, clean(name))
	end)
end

-- The builder funnel (spec: Analytics > Funnels): 1 Opened builder, 2 First piece, 3 10 pieces, 4 TEST,
-- 5 Finished test, 6 Publish. Each step is logged once per session.
local builderLogged: { [Player]: { [number]: boolean } } = {}
function EconomyService.builderFunnel(player: Player, step: number, name: string)
	local logged = builderLogged[player] or {}
	builderLogged[player] = logged
	if logged[step] then
		return
	end
	logged[step] = true
	pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, "Builder", nil, step, name)
	end)
end

local function onPlayerAdded(player: Player)
	friends[player] = friends[player] or {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			task.spawn(function()
				local ok, isFriend = pcall(function()
					return player:IsFriendsWith(other.UserId)
				end)
				if ok and isFriend and player.Parent == Players and other.Parent == Players then
					friends[player] = friends[player] or {}
					friends[other] = friends[other] or {}
					friends[player][other] = true
					friends[other][player] = true
				end
			end)
		end
	end
end

local function onPlayerRemoving(player: Player)
	for other in friends[player] or {} do
		if friends[other] then
			friends[other][player] = nil
		end
	end
	friends[player] = nil
	funnelLogged[player] = nil
	builderLogged[player] = nil
end

function EconomyService.init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return EconomyService
