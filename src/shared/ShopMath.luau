--!strict
-- ShopMath: the shop's rules (spec: Economy, Progression). Pure, so tests/run.luau checks it in Lune.
--   Daily rotation: 4 coin items picked from the day number, the same in every server.
--   Crash Crate: rarity by the spec's odds, then an item of that rarity; 1 in 50 is Shiny. A duplicate
--   refunds 30% of its coin value. The coin crate and the Robux crate are the same crate.
--   Mastery: level from points; each level unlocks that vehicle's mastery item.
--   Vehicles: coins and stars (plus a mastery level for the Dune Hopper); pass side-grades come with
--   their pass. Rebirth: own all 6 launch vehicles.

local Catalog = if script then require(script.Parent.Catalog) else (require :: any)("./Catalog")
local Config = if script then require(script.Parent.Config) else (require :: any)("./Config")
local Quests = if script then require(script.Parent.Quests) else (require :: any)("./Quests")

local ShopMath = {}

-- Today's rotation: 4 different coin items (seeded by the day only, so every server shows the same)
function ShopMath.rotation(day: number): { string }
	local random = Quests.rng(day * 7919 + 17)
	local pool = Catalog.shopItems()
	local picked = {}
	while #picked < Catalog.ROTATION_SIZE and #pool > 0 do
		local index = math.floor(random() * #pool) + 1
		table.insert(picked, (table.remove(pool, index) :: Catalog.Item).id)
	end
	return picked
end

-- Roll a crate: returns the item, whether it is shiny, whether it is a duplicate and the refund.
-- random: a () -> number in [0, 1); owned: the player's inventory ({ [id] = entry }).
function ShopMath.rollCrate(
	random: () -> number,
	owned: { [string]: any }
): (Catalog.Item, boolean, boolean, number)
	local odds = Catalog.CRATE.odds
	local roll = random()
	local rarity = "common"
	local total = 0
	for _, name in Catalog.RARITIES do
		total += odds[name]
		if roll < total then
			rarity = name
			break
		end
	end
	local pool = Catalog.cratePool()
	local list = pool[rarity]
	if #list == 0 then
		list = pool.common
	end
	local item = list[math.floor(random() * #list) + 1]
	local shiny = random() < Catalog.CRATE.shinyChance
	local entry = owned[item.id]
	local duplicate = entry ~= nil and (not shiny or entry.shiny == true)
	local refund = if duplicate
		then math.floor(Catalog.coinValue(item) * Catalog.CRATE.duplicateRefund + 0.5)
		else 0
	return item, shiny, duplicate, refund
end

-- The share of each rarity, for the odds table on the crate screen (always visible)
function ShopMath.oddsTable(): { { rarity: string, percent: number, items: number } }
	local pool = Catalog.cratePool()
	local rows = {}
	for _, name in Catalog.RARITIES do
		table.insert(rows, { rarity = name, percent = Catalog.CRATE.odds[name] * 100, items = #pool[name] })
	end
	return rows
end

-- Mastery level (1..10) from a vehicle's points
function ShopMath.masteryLevel(points: number): number
	local level = 1
	for index, needed in Config.Progression.masteryLevels do
		if points >= needed then
			level = index
		end
	end
	return level
end

-- Points to the next level (nil at level 10)
function ShopMath.masteryNext(points: number): number?
	local level = ShopMath.masteryLevel(points)
	local needed = Config.Progression.masteryLevels[level + 1]
	return if needed then needed - points else nil
end

-- May this player buy this vehicle for coins now? Returns ok and a preset reason key.
function ShopMath.canBuyVehicle(profile: { [string]: any }, vehicleId: string): (boolean, string?)
	local def = Config.Vehicles[vehicleId]
	if def == nil then
		return false, "unknown"
	end
	local entry = profile.vehicles[vehicleId]
	if entry and entry.owned then
		return false, "owned"
	end
	local unlock = def.unlock
	if unlock.pass then
		return false, "pass"
	end
	if unlock.mastery then
		local base = profile.vehicles[unlock.mastery.vehicle]
		local points = if base then base.mastery or 0 else 0
		if ShopMath.masteryLevel(points) < unlock.mastery.level then
			return false, "mastery"
		end
	end
	if profile.stars < (unlock.stars or 0) then
		return false, "stars"
	end
	if profile.coins < (unlock.coins or 0) then
		return false, "coins"
	end
	return true, nil
end

-- May this item be worn on this vehicle (or by the rider)? Owned items, pass items with the pass, and
-- mastery items on a vehicle at that level.
function ShopMath.canEquip(profile: { [string]: any }, itemId: string, vehicleId: string?): boolean
	local item = Catalog.byId[itemId]
	if item == nil or item.kind == "key" or item.kind == "emote" then
		return false
	end
	if item.mastery then
		local entry = vehicleId and profile.vehicles[vehicleId]
		return entry ~= nil and ShopMath.masteryLevel(entry.mastery or 0) >= item.mastery
	end
	if item.pass then
		return profile.passes[item.pass] == true
	end
	return profile.inventory[itemId] ~= nil
end

function ShopMath.canRebirth(profile: { [string]: any }): (boolean, number, number)
	local owned = 0
	for _, id in Config.TierOneVehicles do
		local entry = profile.vehicles[id]
		if entry and entry.owned then
			owned += 1
		end
	end
	return owned >= #Config.TierOneVehicles, owned, #Config.TierOneVehicles
end

-- A rebirth: coins and stars to 0, everything else kept (vehicles, cosmetics, mastery, ranks, maps)
function ShopMath.rebirth(profile: { [string]: any })
	profile.coins = 0
	profile.stars = 0
	profile.rebirths += 1
end

-- The daily caps rise with the rebirth bonus (spec: so rebirth never breaks the economy)
function ShopMath.capMultiplier(rebirths: number): number
	local economy = Config.Economy
	return 1 + math.min(rebirths * economy.rebirthBonusPer, economy.rebirthBonusMax)
end

return ShopMath
