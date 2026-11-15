-- PurchaseService: Robux passes and products (spec: Economy > Robux catalog, Purchase rules).
-- * One ProcessReceipt handler for every product. It records the purchase id in the profile before
--   granting, grants, then saves; it answers PurchaseGranted only once that save worked (or the id was
--   already recorded), so a grant can never happen twice or be lost on a crash.
-- * Game passes are re-checked on join (UserOwnsGamePassAsync) and on PromptGamePassPurchaseFinished,
--   and cached in profile.passes. The bundle product grants the Rider Pass and Stunt Set the same way.
-- * Paid random items: where PolicyService says they are restricted, the Robux crate is hidden and
--   refused (player attribute PaidCratesHidden); the coin crate always works.
-- * Ids of 0 (not created in the Creator Dashboard yet) answer "comingSoon" instead of prompting.
-- No countdowns, no fake scarcity; nothing sold changes stats (design pillars).

local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local ShopService = require(Services.ShopService)

local PurchaseService = {}

local M = Config.Monetization
local productById: { [number]: string } = {}
local passById: { [number]: string } = {}
for name, product in M.products do
	if product.id ~= 0 then
		productById[product.id] = name
	end
end
for name, pass in M.passes do
	if pass.id ~= 0 then
		passById[pass.id] = name
	end
end

-- A pass's contents (also used by the bundle): the flag, plus the Stunt Set's 3 vehicles
function PurchaseService.grantPass(profile: { [string]: any }, name: string)
	profile.passes[name] = true
	if name == "stunt" then
		for id, def in Config.Vehicles do
			if def.unlock.pass == "stunt" then
				local entry = profile.vehicles[id] or { mastery = 0, parts = {} }
				entry.owned = true
				profile.vehicles[id] = entry
			end
		end
	end
end

local function grantStarter(player: Player, profile: { [string]: any })
	local starter = M.products.starter
	EconomyService.grantCoins(player, starter.coins, nil, "StarterPack")
	for _, itemId in starter.items do
		ShopService.giveItem(profile, itemId, false)
	end
	profile.flags.starterOffered = true
	profile.flags.starterBought = true
end

-- What each product gives (the player is in this server, their profile loaded)
local GRANTS: { [string]: (Player, { [string]: any }) -> () } = {
	starter = grantStarter,
	coins_s = function(player)
		EconomyService.grantCoins(player, M.products.coins_s.coins, nil, "Robux_coins_s")
	end,
	coins_m = function(player)
		EconomyService.grantCoins(player, M.products.coins_m.coins, nil, "Robux_coins_m")
	end,
	coins_l = function(player)
		EconomyService.grantCoins(player, M.products.coins_l.coins, nil, "Robux_coins_l")
	end,
	coins_xl = function(player)
		EconomyService.grantCoins(player, M.products.coins_xl.coins, nil, "Robux_coins_xl")
	end,
	crate = function(player)
		local result = ShopService.openCrate(player, "RobuxCrate")
		Net.fire("Shop.Result", player, { ok = true, id = "crate", crate = result, robux = true })
	end,
	extra_slot = function(_, profile)
		local cfg = Config.Builder
		local most = cfg.maxDraftSlots - cfg.draftSlots
		profile.maps.extraSlots = math.min((profile.maps.extraSlots or 0) + 1, most)
	end,
	bundle = function(player, profile)
		for _, name in M.products.bundle.passes do
			PurchaseService.grantPass(profile, name)
		end
		grantStarter(player, profile)
	end,
}

local function processReceipt(receipt): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local name = productById[receipt.ProductId]
	if player == nil or name == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = DataService.get(player)
	if profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not ProfileSchema.recordReceipt(profile, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already granted
	end
	local ok, err = pcall(GRANTS[name], player, profile)
	if not ok then
		warn(string.format("[Purchase] %s grant failed: %s", name, tostring(err)))
	end
	DataService.changed(player)
	if not DataService.save(player, false) and not DataService.isMemoryMode() then
		-- Recorded in this session; Roblox asks again and the next save keeps it
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	Net.fire("Shop.Result", player, { ok = true, id = name, robux = true, product = true })
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function checkPasses(player: Player)
	local profile = DataService.waitFor(player)
	if profile == nil then
		return
	end
	local changed = false
	for id, name in passById do
		if not profile.passes[name] then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if ok and owns then
				PurchaseService.grantPass(profile, name)
				changed = true
			end
		end
	end
	-- A pass bought before the Stunt Set vehicles existed still gives them
	if profile.passes.stunt then
		PurchaseService.grantPass(profile, "stunt")
	end
	if changed then
		DataService.changed(player)
	end
	local ok, policy = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	-- Unknown policy: hide the Robux crate to be safe
	local hidden = not ok or policy.ArePaidRandomItemsRestricted == true
	player:SetAttribute("PaidCratesHidden", hidden)
end

-- Shop.Buy(id, "robux"): prompt the pass or product
local function robuxBuy(player: Player, id: string)
	local pass = M.passes[id]
	local product = M.products[id]
	if pass == nil and product == nil then
		return
	end
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	if pass and profile.passes[id] then
		Net.fire("Shop.Result", player, { ok = false, id = id, reason = "owned" })
		return
	end
	if id == "crate" and player:GetAttribute("PaidCratesHidden") ~= false then
		Net.fire("Shop.Result", player, { ok = false, id = id, reason = "restricted" })
		return
	end
	if (id == "starter" or id == "bundle") and profile.flags.starterBought then
		Net.fire("Shop.Result", player, { ok = false, id = id, reason = "owned" })
		return
	end
	local entry = pass or product
	if entry.id == 0 then
		Net.fire("Shop.Result", player, { ok = false, id = id, reason = "comingSoon" })
		return
	end
	pcall(function()
		if pass then
			MarketplaceService:PromptGamePassPurchase(player, entry.id)
		else
			MarketplaceService:PromptProductPurchase(player, entry.id)
		end
	end)
end

-- Studio only: grant a pass or product without Robux, so every purchase can be tried before the ids
-- exist (Dev.Grant, from the dev panel)
local function devGrant(player: Player, name: string)
	if not game:GetService("RunService"):IsStudio() or not DataService.isAdmin(player) then
		return
	end
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	if M.passes[name] then
		PurchaseService.grantPass(profile, name)
	elseif GRANTS[name] then
		GRANTS[name](player, profile)
	end
	DataService.changed(player)
	Net.fire("Shop.Result", player, { ok = true, id = name, robux = true, dev = true })
end

function PurchaseService.init()
	Net.on("Dev.Grant", devGrant)
	MarketplaceService.ProcessReceipt = processReceipt
	ShopService.robuxBuy = robuxBuy
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, bought: boolean)
			local name = passById[passId]
			local profile = DataService.get(player)
			if bought and name and profile then
				PurchaseService.grantPass(profile, name)
				DataService.changed(player)
				Net.fire("Shop.Result", player, { ok = true, id = name, robux = true, pass = true })
			end
		end
	)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(checkPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(checkPasses, player)
	end
end

return PurchaseService
