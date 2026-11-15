-- ShopService: spending coins and stars, the garage and mastery (spec: Economy > Coin sinks, Progression,
-- Screens > Shop and Garage). Prices and rules are in Shared/Catalog, Shared/ShopMath and Config.
-- * Shop.Buy(id, "coins"): a vehicle (coins plus stars for the Haul Hog and Bumble Bus, a mastery level
--   for the Dune Hopper), any shop cosmetic (always on sale in the garage; the shop's daily rotation of
--   4 is a spotlight, not a timer), or the Crash Crate (1,000 coins, or a crate key). Shop.Result answers.
-- * Shop.Buy(id, "robux"): PurchaseService prompts the pass or product (ids from the Creator Dashboard).
-- * Garage.Equip(vehicleId or "rider", slot, itemId or ""): only items the player may wear (ShopMath),
--   on vehicles they own. The car restyles at once (VehicleService.applyLooks).
-- * Mastery: 5 points to the equipped vehicle per Tracks finish (Brawl and Highway points arrive with
--   their modes). Each level unlocks that vehicle's mastery item (Mastery.Up tells the player).
-- Nothing sold changes stats (design pillar): every item is looks or sound.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ShopMath = require(Shared.ShopMath)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local RaceService = require(Services.RaceService)
local TracksService = require(Services.TracksService)
local VehicleService = require(Services.VehicleService)

local ShopService = {}

ShopService.robuxBuy = nil :: ((Player, string) -> ())? -- PurchaseService

local random = Random.new()

local function answer(player: Player, result: { [string]: any })
	Net.fire("Shop.Result", player, result)
end

-- Give an item (from coins, a crate, a quest chest, the streak, a product). shiny upgrades an owned one.
function ShopService.giveItem(profile: { [string]: any }, itemId: string, shiny: boolean?)
	local entry = profile.inventory[itemId]
	if entry == nil then
		profile.inventory[itemId] = { count = 1, shiny = shiny == true }
	else
		entry.count = (entry.count or 1) + 1
		entry.shiny = entry.shiny == true or shiny == true
	end
end

-- Open one crate for this player (coins, key or Robux already paid). Returns the result for Shop.Result.
function ShopService.openCrate(player: Player, sku: string): { [string]: any }?
	local profile = DataService.get(player)
	if profile == nil then
		return nil
	end
	local item, shiny, duplicate, refund = ShopMath.rollCrate(function()
		return random:NextNumber()
	end, profile.inventory)
	if duplicate then
		EconomyService.grantCoins(player, refund, nil, "CrateRefund")
	else
		ShopService.giveItem(profile, item.id, shiny)
	end
	DataService.changed(player)
	pcall(function()
		game:GetService("AnalyticsService"):LogCustomEvent(player, "crate_open", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = sku,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = item.rarity,
		})
	end)
	return { item = item.id, rarity = item.rarity, shiny = shiny, duplicate = duplicate, refund = refund }
end

local function buyVehicle(player: Player, profile: { [string]: any }, vehicleId: string)
	local ok, reason = ShopMath.canBuyVehicle(profile, vehicleId)
	if not ok then
		answer(player, { ok = false, id = vehicleId, reason = reason })
		return
	end
	local unlock = Config.Vehicles[vehicleId].unlock
	if not EconomyService.spend(player, unlock.coins or 0, unlock.stars or 0, "Vehicle_" .. vehicleId) then
		answer(player, { ok = false, id = vehicleId, reason = "coins" })
		return
	end
	local entry = profile.vehicles[vehicleId] or { mastery = 0, parts = {} }
	entry.owned = true
	profile.vehicles[vehicleId] = entry
	DataService.changed(player)
	answer(player, { ok = true, id = vehicleId, vehicle = true })
end

local function buyItem(player: Player, profile: { [string]: any }, itemId: string)
	local item = Catalog.byId[itemId]
	if item == nil or item.source ~= "shop" or item.coins == nil then
		answer(player, { ok = false, id = itemId, reason = "notForSale" })
		return
	end
	if profile.inventory[itemId] then
		answer(player, { ok = false, id = itemId, reason = "owned" })
		return
	end
	if not EconomyService.spend(player, item.coins, 0, "Item_" .. itemId) then
		answer(player, { ok = false, id = itemId, reason = "coins" })
		return
	end
	ShopService.giveItem(profile, itemId, false)
	DataService.changed(player)
	answer(player, { ok = true, id = itemId })
end

local function buyCrate(player: Player, profile: { [string]: any })
	local key = profile.inventory.crate_key
	local sku
	if key and (key.count or 0) > 0 then
		key.count -= 1
		if key.count <= 0 then
			profile.inventory.crate_key = nil
		end
		sku = "CrateKey"
	elseif EconomyService.spend(player, Catalog.CRATE.coinPrice, 0, "CoinCrate") then
		sku = "CoinCrate"
	else
		answer(player, { ok = false, id = "crate", reason = "coins" })
		return
	end
	answer(player, { ok = true, id = "crate", crate = ShopService.openCrate(player, sku) })
end

local function onBuy(player: Player, id: string, currency: string)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	if currency == "robux" then
		if ShopService.robuxBuy then
			ShopService.robuxBuy(player, id)
		end
		return
	end
	if Config.Vehicles[id] then
		buyVehicle(player, profile, id)
	elseif id == "crate" then
		buyCrate(player, profile)
	else
		buyItem(player, profile, id)
	end
end

-- Which item kinds each slot takes
local SLOT_KINDS = {
	paint = "paint",
	rims = "rims",
	trail = "trail",
	trail2 = "trail",
	horn = "horn",
	explosion = "explosion",
	decal = "decal",
	part = "part",
	hat = "hat",
	outfit = "outfit",
}

local function onEquip(player: Player, vehicleId: string, slot: string, itemId: string)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local isRider = slot == "hat" or slot == "outfit"
	if isRider ~= (vehicleId == "rider") then
		return
	end
	local value: string? = if itemId == "" then nil else itemId
	if value then
		local item = Catalog.byId[value]
		if item == nil or item.kind ~= SLOT_KINDS[slot] then
			return
		end
		if not ShopMath.canEquip(profile, value, if isRider then nil else vehicleId) then
			return
		end
	end
	if isRider then
		profile.rider[slot] = value
	else
		local entry = profile.vehicles[vehicleId]
		if entry == nil or not entry.owned then
			return
		end
		if slot == "trail2" and value and profile.passes.vip ~= true then
			return -- the second trail slot is VIP's
		end
		if slot == "part" then
			entry.parts = if value then { value } else {}
		else
			entry[slot] = value
		end
	end
	DataService.changed(player)
	VehicleService.applyLooks(player)
end

-- Mastery points for the car the player is driving
function ShopService.addMastery(player: Player, points: number)
	local profile = DataService.get(player)
	if profile == nil or points <= 0 then
		return
	end
	local vehicleId = profile.equippedVehicle
	local entry = profile.vehicles[vehicleId]
	if entry == nil or not entry.owned then
		return
	end
	local before = ShopMath.masteryLevel(entry.mastery or 0)
	entry.mastery = (entry.mastery or 0) + points
	local after = ShopMath.masteryLevel(entry.mastery)
	DataService.changed(player)
	if after > before then
		local unlocked = nil
		for _, item in Catalog.masteryItems() do
			if item.mastery == after then
				unlocked = item.id
			end
		end
		Net.fire("Mastery.Up", player, { vehicleId = vehicleId, level = after, itemId = unlocked })
	end
end

-- Rebirth (spec: Progression > Rebirth): own all 6 launch vehicles; coins and stars go to 0, everything
-- else stays; +5% coins per rebirth (to +50%) and the daily caps rise with it. Never offered mid-run.
local function onRebirth(player: Player)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local ok = ShopMath.canRebirth(profile)
	if not ok then
		answer(player, { ok = false, id = "rebirth", reason = "needVehicles" })
		return
	end
	ShopMath.rebirth(profile)
	DataService.changed(player)
	task.spawn(DataService.save, player, false)
	if Config.Badges.rebirth ~= 0 then
		pcall(function()
			game:GetService("BadgeService"):AwardBadge(player.UserId, Config.Badges.rebirth)
		end)
	end
	pcall(function()
		game:GetService("AnalyticsService"):LogCustomEvent(player, "rebirth", profile.rebirths)
	end)
	answer(player, { ok = true, id = "rebirth", rebirths = profile.rebirths })
end

function ShopService.init()
	Net.on("Rebirth.Confirm", onRebirth)
	Net.on("Shop.Seen", function(player: Player)
		local profile = DataService.get(player)
		if profile and not profile.flags.starterOffered then
			profile.flags.starterOffered = true
			DataService.changed(player)
		end
	end)
	Net.on("Shop.Buy", onBuy)
	Net.on("Garage.Equip", onEquip)
	TracksService.Finished:Connect(function(player: Player, map: any)
		if not map.testOwner then
			ShopService.addMastery(player, Config.Progression.masteryPoints.tracksFinish)
		end
	end)
	RaceService.Finished:Connect(function(player: Player, _place: number, dnf: boolean)
		if not dnf then
			ShopService.addMastery(player, Config.Progression.masteryPoints.tracksFinish)
		end
	end)
end

return ShopService
