-- ShopClient: the shop, garage and quests screens (spec: Screens and UI > Shop, Garage, Quests; Economy;
-- Progression). It reads the player's profile (ProfileClient) and sends Shop.Buy, Garage.Equip,
-- Quest.Claim, Streak.Claim, Gift.Send and Rebirth.Confirm; the server decides every result and answers
-- on Shop.Result. ShopHud draws the screens.
-- * SHOP: TODAY (the daily spotlight of 4, the bundle, the crate), COINS, PASSES, CRATE (odds always on
--   the card). One price per card, coins or Robux. Robux cards answer "Coming soon" until nate pastes
--   the ids into Config.Monetization.
-- * GARAGE: cars, then each look slot for the car you're driving, the rider, and rebirth. Every shop
--   item is always on sale here; the rotation only puts some in the spotlight (no scarcity).
-- * QUESTS: daily and weekly quests, the daily chest, the 7-day login streak and gifts. The QUESTS
--   button shows a red dot when something is ready to claim.
-- * The Starter Pack offer shows once, over the results card of the first finish (no timer; NO THANKS
--   is as big as BUY).
-- Also starts LookFx (trails on every car). Text is ours only.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Catalog)
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local ProfileSchema = require(Shared.ProfileSchema)
local ShopMath = require(Shared.ShopMath)

local Client = script.Parent.Parent
local LookFx = require(Client.Fx.LookFx)
local ShopHud = require(Client.Ui.ShopHud)
local TracksHud = require(Client.Ui.TracksHud)

local LocalPlayer = Players.LocalPlayer

local ShopClient = {}

local M = Config.Monetization
local controllers: any = nil
local screen: string? = nil -- "shop" | "garage" | "quests"
local tab = ""
local trailSlot = "trail" -- the garage's TRAILS tab: "trail" (rear) or "trail2" (front, VIP)
local garageDot = false
local offerShown = false
local friendCache: { [number]: boolean } = {}

local function view(): { [string]: any }?
	return controllers.Profile.get()
end

local function today(): number
	return ProfileSchema.dayNumber(math.floor(Workspace:GetServerTimeNow()))
end

local function toast(message: string, seconds: number?)
	TracksHud.toast(message, seconds)
end

local function coins(n: number): string
	return "● " .. tostring(n)
end

local function robux(n: number): string
	return "R$ " .. tostring(n)
end

-- The profile view in the shape ShopMath's rules read (inventory as a set)
local function rulesProfile(v: { [string]: any }): { [string]: any }
	local inventory = {}
	for _, id in v.inventory do
		inventory[id] = { count = 1 }
	end
	local vehicles = {}
	for id, looks in v.vehicles do
		vehicles[id] = { owned = true, mastery = looks.mastery or 0 }
	end
	return {
		coins = v.coins,
		stars = v.stars,
		inventory = inventory,
		vehicles = vehicles,
		passes = v.passes or {},
	}
end

local function has(list: { string }?, id: string): boolean
	return list ~= nil and table.find(list, id) ~= nil
end

local function itemName(id: string?): string
	local item = id and Catalog.byId[id]
	return if item then item.name else (id or "")
end

local function vehicleName(id: string?): string
	local def = id and Config.Vehicles[id]
	return if def then def.displayName else (id or "")
end

---------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------

local SHOP_TABS: { ShopHud.Tab } = {
	{ id = "today", label = "TODAY" },
	{ id = "coins", label = "COINS" },
	{ id = "passes", label = "PASSES" },
	{ id = "crate", label = "CRATE" },
}

local GARAGE_TABS: { ShopHud.Tab } = {
	{ id = "cars", label = "CARS" },
	{ id = "paint", label = "PAINT" },
	{ id = "rims", label = "RIMS" },
	{ id = "trail", label = "TRAILS" },
	{ id = "horn", label = "HORNS" },
	{ id = "explosion", label = "BOOM" },
	{ id = "part", label = "PARTS" },
	{ id = "decal", label = "DECALS" },
	{ id = "rider", label = "RIDER" },
	{ id = "rebirth", label = "REBIRTH" },
}

local PASS_LINES: { [string]: { string } } = {
	rider = { "8 rider outfits and 4 emotes", "Hats for your rider" },
	vip = { "A second trail on the front wheels", "10 map slots and the fine grid", "15 shared maps" },
	stunt = { "3 stunt cars: Hop Rod, Zippy Coupe and Mud Muncher", "Same speed as the other cars" },
	explosions = { "3 explosion styles for your crashes" },
}

local function buy(id: string, currency: string)
	Net.send("Shop.Buy", id, currency)
end

local function oddsLines(): { string }
	local lines = {}
	for _, row in ShopMath.oddsTable() do
		table.insert(
			lines,
			string.format("%s %s%%  (%d looks)", string.upper(row.rarity), row.percent, row.items)
		)
	end
	return lines
end

local function crateCards(v: { [string]: any }): { ShopHud.Card }
	local cards: { ShopHud.Card } = {}
	local keys = v.crateKeys or 0
	table.insert(cards, {
		id = "crate_coins",
		title = "Crash Crate",
		sub = if keys > 0
			then string.format("You have %d crate key%s", keys, if keys == 1 then "" else "s")
			else "1 random look. Duplicates give 30% back. 1 in 50 is Shiny.",
		lines = oddsLines(),
		wide = true,
		button = if keys > 0 then "OPEN WITH KEY" else coins(Catalog.CRATE.coinPrice),
		buttonColor = ShopHud.GOLD,
		enabled = keys > 0 or v.coins >= Catalog.CRATE.coinPrice,
		onPress = function()
			buy("crate", "coins")
		end,
	})
	-- The Robux crate is the same crate; hidden where paid random items aren't allowed
	if LocalPlayer:GetAttribute("PaidCratesHidden") == false then
		table.insert(cards, {
			id = "crate_robux",
			title = "Crash Crate",
			sub = "The same crate and odds as above",
			lines = oddsLines(),
			wide = true,
			button = robux(M.products.crate.robux),
			buttonColor = ShopHud.GREEN,
			onPress = function()
				buy("crate", "robux")
			end,
		})
	end
	return cards
end

local function itemCard(v: { [string]: any }, item: Catalog.Item): ShopHud.Card
	local owned = has(v.inventory, item.id)
	return {
		id = item.id,
		title = item.name,
		sub = string.upper(item.rarity) .. " " .. string.upper(item.kind),
		swatch = if item.color then Config.color3(item.color) else nil,
		rarity = item.rarity,
		badge = if has(v.shiny, item.id) then "SHINY" elseif owned then "OWNED" else nil,
		button = if owned then nil else coins(item.coins or 0),
		enabled = not owned and v.coins >= (item.coins or 0),
		onPress = function()
			buy(item.id, "coins")
		end,
	}
end

local function bundleCard(v: { [string]: any }): ShopHud.Card?
	local bundle = M.products.bundle
	local passes = v.passes or {}
	if v.starterBought or (passes.rider and passes.stunt) then
		return nil
	end
	return {
		id = "bundle",
		title = bundle.name,
		sub = "Starter Pack + Rider Pass + Stunt Set, 25% less than apart",
		lines = { "1,000 coins, a trail and a hat", "8 outfits, 4 emotes, hats", "3 stunt cars" },
		wide = true,
		button = robux(bundle.robux),
		buttonColor = ShopHud.GREEN,
		onPress = function()
			buy("bundle", "robux")
		end,
	}
end

local function shopCards(v: { [string]: any }): { ShopHud.Card }
	local cards: { ShopHud.Card } = {}
	if tab == "today" then
		local bundle = bundleCard(v)
		if bundle then
			table.insert(cards, bundle)
		end
		for _, id in ShopMath.rotation(today()) do
			local item = Catalog.byId[id]
			if item then
				table.insert(cards, itemCard(v, item))
			end
		end
		table.insert(cards, crateCards(v)[1])
	elseif tab == "coins" then
		for _, id in M.coinShop do
			local product = M.products[id]
			table.insert(cards, {
				id = id,
				title = product.name,
				sub = coins(product.coins),
				swatch = ShopHud.GOLD,
				button = robux(product.robux),
				buttonColor = ShopHud.GREEN,
				onPress = function()
					buy(id, "robux")
				end,
			})
		end
		local slot = M.products.extra_slot
		table.insert(cards, {
			id = "extra_slot",
			title = slot.name,
			sub = "One more map to build",
			swatch = ShopHud.BLUE,
			button = robux(slot.robux),
			buttonColor = ShopHud.GREEN,
			onPress = function()
				buy("extra_slot", "robux")
			end,
		})
	elseif tab == "passes" then
		local passes = v.passes or {}
		if not v.starterBought then
			local starter = M.products.starter
			table.insert(cards, {
				id = "starter",
				title = starter.name,
				sub = "Once per player",
				lines = {
					coins(starter.coins) .. " coins",
					itemName(starter.items[1]) .. " trail",
					itemName(starter.items[2]) .. " hat",
				},
				wide = true,
				button = robux(starter.robux),
				buttonColor = ShopHud.GREEN,
				onPress = function()
					buy("starter", "robux")
				end,
			})
		end
		local bundle = bundleCard(v)
		if bundle then
			table.insert(cards, bundle)
		end
		for _, id in { "rider", "vip", "stunt", "explosions" } do
			local pass = M.passes[id]
			local owned = passes[id] == true
			table.insert(cards, {
				id = id,
				title = pass.name,
				lines = PASS_LINES[id],
				wide = true,
				badge = if owned then "OWNED" else nil,
				button = if owned then nil else robux(pass.robux),
				buttonColor = ShopHud.GREEN,
				onPress = function()
					buy(id, "robux")
				end,
			})
		end
	elseif tab == "crate" then
		cards = crateCards(v)
	end
	return cards
end

-- The vehicles in garage order: the 6 launch cars, then the Stunt Set
local function vehicleOrder(): { string }
	local list = table.clone(Config.TierOneVehicles)
	local extra = {}
	for id, def in Config.Vehicles do
		if not table.find(list, id) and def.unlock and def.unlock.pass then
			table.insert(extra, id)
		end
	end
	table.sort(extra)
	for _, id in extra do
		table.insert(list, id)
	end
	return list
end

local function carCards(v: { [string]: any }): { ShopHud.Card }
	local cards: { ShopHud.Card } = {}
	local rules = rulesProfile(v)
	for _, id in vehicleOrder() do
		local def = Config.Vehicles[id]
		local looks = v.vehicles[id]
		local card: ShopHud.Card = {
			id = id,
			title = def.displayName,
			swatch = Config.color3(def.paint),
		}
		if looks then
			local points = looks.mastery or 0
			local level = ShopMath.masteryLevel(points)
			local nextAt = ShopMath.masteryNext(points)
			card.sub = if nextAt
				then string.format("Mastery %d · %d / %d", level, points, nextAt)
				else string.format("Mastery %d · MAX", level)
			if v.equippedVehicle == id then
				card.badge = "DRIVING"
			else
				card.button = "DRIVE"
				card.buttonColor = ShopHud.GREEN
				card.onPress = function()
					controllers.Vehicle.equip(id)
				end
			end
		else
			local unlock = def.unlock
			local ok, reason = ShopMath.canBuyVehicle(rules, id)
			if unlock.pass then
				card.sub = "In the " .. M.passes[unlock.pass].name
				card.button = "SEE PASS"
				card.buttonColor = ShopHud.BLUE
				card.onPress = function()
					ShopClient.open("shop", "passes")
				end
			else
				local needs = {}
				if unlock.mastery and reason == "mastery" then
					table.insert(
						needs,
						string.format(
							"%s mastery %d",
							vehicleName(unlock.mastery.vehicle),
							unlock.mastery.level
						)
					)
				end
				if (unlock.stars or 0) > 0 then
					table.insert(needs, "★ " .. unlock.stars)
				end
				card.sub = if #needs > 0 then "Needs " .. table.concat(needs, " and ") else def.class
				card.button = coins(unlock.coins or 0)
				card.enabled = ok
				card.onPress = function()
					buy(id, "coins")
				end
			end
		end
		table.insert(cards, card)
	end
	return cards
end

local function lockedSub(item: Catalog.Item): string
	if item.pass then
		return "In the " .. M.passes[item.pass].name
	elseif item.mastery then
		return "Mastery " .. item.mastery .. " on this car"
	elseif item.source == "crate" then
		return "From the Crash Crate"
	elseif item.source == "streak" then
		return "Day 7 login streak"
	elseif item.source == "starter" then
		return "In the Starter Pack"
	end
	return string.upper(item.rarity)
end

-- One look slot (on the car you're driving, or the rider): wear, take off, or buy
local function slotCards(v: { [string]: any }, slot: string, kind: string): { ShopHud.Card }
	local isRider = slot == "hat" or slot == "outfit"
	local target = if isRider then "rider" else v.equippedVehicle
	local current = if isRider then v.rider[slot] else (v.vehicles[target] or {})[slot]
	local rules = rulesProfile(v)
	local cards: { ShopHud.Card } = {}
	table.insert(cards, {
		id = "none",
		title = "None",
		sub = "The car's own look",
		badge = if current == nil then "EQUIPPED" else nil,
		button = if current == nil then nil else "TAKE OFF",
		buttonColor = ShopHud.WHITE,
		onPress = function()
			Net.send("Garage.Equip", target, slot, "")
		end,
	})
	local wearable, buyable, locked = {}, {}, {}
	for _, item in Catalog.items do
		if item.kind == kind then
			if ShopMath.canEquip(rules, item.id, if isRider then nil else target) then
				table.insert(wearable, item)
			elseif item.source == "shop" and item.coins then
				table.insert(buyable, item)
			else
				table.insert(locked, item)
			end
		end
	end
	for _, item in wearable do
		local on = current == item.id
		table.insert(cards, {
			id = item.id,
			title = item.name,
			sub = string.upper(item.rarity),
			swatch = if item.color then Config.color3(item.color) else nil,
			rarity = item.rarity,
			badge = if on then "EQUIPPED" elseif has(v.shiny, item.id) then "SHINY" else nil,
			button = if on then nil else "EQUIP",
			buttonColor = ShopHud.GREEN,
			onPress = function()
				Net.send("Garage.Equip", target, slot, item.id)
			end,
		})
	end
	for _, item in buyable do
		table.insert(cards, itemCard(v, item))
	end
	for _, item in locked do
		table.insert(cards, {
			id = item.id,
			title = item.name,
			sub = lockedSub(item),
			swatch = if item.color then Config.color3(item.color) else nil,
			rarity = item.rarity,
		})
	end
	return cards
end

local function trailCards(v: { [string]: any }): { ShopHud.Card }
	local vip = (v.passes or {}).vip == true
	local slotCard: ShopHud.Card = {
		id = "trailSlot",
		title = if trailSlot == "trail" then "Rear wheel trail" else "Front wheel trail (VIP)",
		sub = if vip then "VIP gives you a second trail" else "VIP adds a second trail on the front wheels",
		wide = true,
		button = if vip
			then (if trailSlot == "trail" then "SWITCH TO FRONT" else "SWITCH TO REAR")
			else "SEE VIP",
		buttonColor = ShopHud.BLUE,
		onPress = function()
			if vip then
				trailSlot = if trailSlot == "trail" then "trail2" else "trail"
				ShopClient.refresh()
			else
				ShopClient.open("shop", "passes")
			end
		end,
	}
	local cards = { slotCard }
	for _, card in slotCards(v, if vip then trailSlot else "trail", "trail") do
		table.insert(cards, card)
	end
	return cards
end

local function riderCards(v: { [string]: any }): { ShopHud.Card }
	local cards: { ShopHud.Card } = {}
	for _, slot in Catalog.RIDER_SLOTS do
		for _, card in slotCards(v, slot, slot) do
			if card.id == "none" then
				card.id = "none_" .. slot
				card.title = if slot == "hat" then "No hat" else "Plain suit"
				card.sub = nil
			end
			table.insert(cards, card)
		end
	end
	return cards
end

local function showRebirth(v: { [string]: any })
	local rules = rulesProfile(v)
	local ok, owned, need = ShopMath.canRebirth(rules)
	local rebirths = v.rebirths or 0
	local bonus = math.floor((ShopMath.capMultiplier(rebirths + 1) - 1) * 100 + 0.5)
	ShopHud.showCards({
		{
			id = "rebirthInfo",
			title = string.format("Rebirth %d", rebirths + 1),
			sub = string.format("Own all %d launch cars: %d / %d", need, owned, need),
			lines = {
				"Your coins and stars go back to 0",
				"You keep every car, look, map and best time",
				string.format("Earn +%d%% coins from now on, and higher daily limits", bonus),
			},
			wide = true,
		},
	})
	local content = ShopHud.content()
	if content and ok then
		local hold = ShopHud.holdButton(content, "HOLD TO REBIRTH", 1.5, function()
			Net.send("Rebirth.Confirm")
		end)
		hold.LayoutOrder = 99
		hold.Size = UDim2.new(0.5, 0, 0, Config.UI.minTapTarget * 1.3)
	end
end

local function garageCards(v: { [string]: any }): { ShopHud.Card }
	if tab == "cars" then
		return carCards(v)
	elseif tab == "trail" then
		return trailCards(v)
	elseif tab == "rider" then
		return riderCards(v)
	end
	return slotCards(v, tab, tab)
end

local function streakLabels(): { string }
	local labels = {}
	for index, reward in Config.Quests.streakRewards do
		labels[index] = if type(reward) == "number"
			then coins(reward)
			elseif reward == "crate_key" then "CRATE KEY"
			else "A LOOK"
	end
	return labels
end

local function questRows(list: { any }): { ShopHud.QuestRow }
	local rows = {}
	for _, q in list do
		local ready = not q.claimed and q.progress >= q.target
		table.insert(rows, {
			id = q.id,
			text = q.text,
			progress = math.min(q.progress, q.target),
			target = q.target,
			reward = coins(q.reward),
			claimed = q.claimed,
			onClaim = if ready
				then function()
					Net.send("Quest.Claim", q.id)
				end
				else nil,
		})
	end
	return rows
end

local function allClaimed(list: { any }): boolean
	if #list == 0 then
		return false
	end
	for _, q in list do
		if not q.claimed then
			return false
		end
	end
	return true
end

-- Friends in this server (IsFriendsWith yields, so it is cached and the screen redraws when known)
local function giftTargets(): { { name: string, onGift: () -> () } }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer then
			local known = friendCache[player.UserId]
			if known == nil then
				friendCache[player.UserId] = false
				task.spawn(function()
					local ok, isFriend = pcall(function()
						return LocalPlayer:IsFriendsWith(player.UserId)
					end)
					friendCache[player.UserId] = ok and isFriend == true
					if ok and isFriend and screen == "quests" then
						ShopClient.refresh()
					end
				end)
			elseif known then
				table.insert(list, {
					name = player.DisplayName,
					onGift = function()
						Net.send("Gift.Send", player.UserId)
					end,
				})
			end
		end
	end
	return list
end

local function showQuests(v: { [string]: any })
	local q = v.quests
	local streak = v.streak
	ShopHud.showQuests({
		daily = questRows(q.daily),
		weekly = questRows(q.weekly),
		chest = {
			ready = q.chestReady,
			claimed = q.chestClaimed,
			onClaim = function()
				Net.send("Quest.Claim", "chest")
			end,
		},
		weeklyStars = {
			ready = allClaimed(q.weekly) and not q.weeklyStarsClaimed,
			claimed = q.weeklyStarsClaimed,
			onClaim = function()
				Net.send("Quest.Claim", "weeklyStars")
			end,
		},
		streak = {
			day = streak.day,
			nextDay = streak.nextDay,
			canClaim = streak.canClaim,
			rewards = streakLabels(),
			onClaim = function()
				Net.send("Streak.Claim")
			end,
		},
		gifts = giftTargets(),
		giftSent = q.giftSent,
	})
end

-- Something on the quests screen is ready to claim
local function questsReady(v: { [string]: any }): boolean
	local q = v.quests
	if q == nil then
		return false
	end
	if v.streak and v.streak.canClaim then
		return true
	end
	if q.chestReady or (allClaimed(q.weekly) and not q.weeklyStarsClaimed) then
		return true
	end
	for _, list in { q.daily, q.weekly } do
		for _, quest in list do
			if not quest.claimed and quest.progress >= quest.target then
				return true
			end
		end
	end
	return false
end

local function updateDots(v: { [string]: any })
	TracksHud.setDot("Quests", questsReady(v))
	TracksHud.setDot("Garage", garageDot)
end

local function headerLine(v: { [string]: any }): string
	if screen == "shop" then
		return M.shopLine
	elseif screen == "garage" then
		if tab == "cars" or tab == "rebirth" then
			return string.format("● %d   ★ %d", v.coins, v.stars)
		elseif tab == "rider" then
			return "Styling your rider"
		end
		return "Styling your " .. vehicleName(v.equippedVehicle)
	end
	return "Quests reset every day at the same time worldwide"
end

function ShopClient.refresh()
	local v = view()
	if v == nil or screen == nil or not ShopHud.isOpen() then
		return
	end
	local content = ShopHud.content()
	local scroll = if content then content.CanvasPosition else Vector2.zero
	ShopHud.setLine(headerLine(v))
	if screen == "shop" then
		ShopHud.showCards(shopCards(v))
	elseif screen == "garage" then
		if tab == "rebirth" then
			showRebirth(v)
		else
			ShopHud.showCards(garageCards(v))
		end
	else
		showQuests(v)
	end
	if content then
		content.CanvasPosition = scroll
	end
end

function ShopClient.isOpen(): boolean
	return screen ~= nil and ShopHud.isOpen()
end

function ShopClient.close()
	screen = nil
	ShopHud.close()
end

local TITLES = { shop = "SHOP", garage = "GARAGE", quests = "QUESTS" }

function ShopClient.open(which: string, startTab: string?)
	local v = view()
	if v == nil then
		return
	end
	if controllers.Browse.isOpen() then
		controllers.Browse.close()
	end
	if controllers.Settings.isOpen() then
		controllers.Settings.close()
	end
	screen = which
	local tabs = if which == "shop" then SHOP_TABS elseif which == "garage" then GARAGE_TABS else {}
	tab = startTab or (if #tabs > 0 then tabs[1].id else "")
	if which == "garage" then
		garageDot = false
		updateDots(v)
	end
	ShopHud.open(LocalPlayer:WaitForChild("PlayerGui"), TITLES[which], nil, tabs, tab, function(id)
		tab = id
		ShopHud.setTab(id)
		local content = ShopHud.content()
		if content then
			content.CanvasPosition = Vector2.zero
		end
		ShopClient.refresh()
	end, ShopClient.close)
	ShopClient.refresh()
end

function ShopClient.toggle(which: string)
	if screen == which and ShopHud.isOpen() then
		ShopClient.close()
	else
		ShopClient.open(which)
	end
end

---------------------------------------------------------------------------
-- Server answers
---------------------------------------------------------------------------

local REASONS = {
	coins = "Not enough coins yet. Finish maps and quests to earn more!",
	stars = "You need more stars for that one. Earn them from gold times!",
	owned = "You already have that!",
	pass = "That one comes with a pass.",
	mastery = "Level up the car's mastery first!",
	notForSale = "That isn't in the shop.",
	comingSoon = "Coming soon! Robux purchases open when the game launches.",
	restricted = "That isn't available where you are.",
	notFriend = "Gifts go to friends in this server.",
	needVehicles = "Own all 6 launch cars to rebirth.",
}

local function onResult(result: any)
	if type(result) ~= "table" then
		return
	end
	if not result.ok then
		local message = REASONS[result.reason]
		if message then
			toast(message, 4)
		end
		return
	end
	if result.crate then
		local crate = result.crate
		ShopHud.crateReveal(LocalPlayer:WaitForChild("PlayerGui"), {
			name = itemName(crate.item),
			rarity = crate.rarity,
			shiny = crate.shiny == true,
			duplicate = crate.duplicate == true,
			refund = crate.refund or 0,
		}, function()
			if crate.duplicate then
				toast(string.format("Duplicate: +%d coins back", crate.refund or 0), 3)
			end
		end)
		return
	end
	local id = result.id
	if id == "rebirth" then
		toast(string.format("Rebirth %d! Coins earn more from now on.", result.rebirths or 1), 5)
		ShopClient.refresh()
	elseif id == "gift" then
		toast("Gift sent to " .. tostring(result.to) .. "!", 3)
	elseif id == "streak" then
		toast(
			if result.item
				then string.format("Day %d: %s!", result.day or 1, itemName(result.item))
				else string.format("Day %d: +%d coins!", result.day or 1, result.coins or 0),
			3
		)
	elseif id == "chest" then
		toast(
			if result.item
				then "Chest: " .. itemName(result.item) .. "!"
				else string.format("Chest: +%d coins!", result.coins or 0),
			3
		)
	elseif id == "weeklyStars" then
		toast(string.format("+%d stars for your weekly quests!", result.stars or 0), 3)
	elseif result.quest then
		toast(string.format("+%d coins!", result.coins or 0), 2)
	elseif result.vehicle then
		toast(vehicleName(id) .. " is in your garage! Tap DRIVE to try it.", 4)
	elseif result.robux then
		local entry = M.passes[id] or M.products[id]
		toast(string.format("Thanks! %s is yours.", if entry then entry.name else "It"), 4)
	elseif Catalog.byId[id] then
		toast(itemName(id) .. " is yours! Wear it in the GARAGE.", 3)
	end
end

-- The Starter Pack: offered once, over the first finish's results card
local function maybeOffer(result: any)
	local v = view()
	if
		offerShown
		or v == nil
		or v.starterOffered
		or v.starterBought
		or type(result) ~= "table"
		or result.ok ~= true
		or controllers.Tracks.getTest() ~= nil
	then
		return
	end
	offerShown = true
	task.delay(M.starterOfferDelay, function()
		if not TracksHud.resultsOpen() then
			offerShown = false -- try again on the next finish
			return
		end
		TracksHud.holdResults()
		Net.send("Shop.Seen", "starter")
		local starter = M.products.starter
		ShopHud.offer(LocalPlayer:WaitForChild("PlayerGui"), {
			title = "STARTER PACK",
			lines = {
				coins(starter.coins) .. " coins",
				itemName(starter.items[1]) .. " trail",
				itemName(starter.items[2]) .. " hat",
				"Once per player, looks only",
			},
			price = robux(starter.robux),
			onBuy = function()
				buy("starter", "robux")
			end,
			onClose = function() end,
		})
	end)
end

function ShopClient.init(all)
	controllers = all
end

function ShopClient.start()
	LookFx.start()
	Net.listen("Shop.Result", onResult)
	Net.listen("Run.Result", maybeOffer)
	Net.listen("Quest.Done", function(info)
		if type(info) == "table" and type(info.text) == "string" then
			toast("Quest done: " .. info.text .. "! Claim it in QUESTS.", 4)
		end
	end)
	Net.listen("Mastery.Up", function(info)
		if type(info) ~= "table" then
			return
		end
		local line = string.format("%s mastery %d!", vehicleName(info.vehicleId), info.level or 0)
		if info.itemId then
			line ..= " New look: " .. itemName(info.itemId)
		end
		toast(line, 5)
		garageDot = true
		local v = view()
		if v then
			updateDots(v)
		end
	end)
	controllers.Profile.Changed:Connect(function(v)
		updateDots(v)
		ShopClient.refresh()
	end)
	LocalPlayer:GetAttributeChangedSignal("PaidCratesHidden"):Connect(ShopClient.refresh)
	Players.PlayerRemoving:Connect(function(player)
		friendCache[player.UserId] = nil
	end)
	local v = view()
	if v then
		updateDots(v)
	end
end

return ShopClient
