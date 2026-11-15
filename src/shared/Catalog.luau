--!strict
-- Catalog: everything a player can own besides vehicles (spec: Progression, Economy > Coin sinks,
-- Robux catalog). Pure data, so tests/run.luau checks it in Lune. Every price is (tune).
-- Design pillar: nothing here changes how a car drives. Items are looks and sounds only.
--   kind      paint | rims | trail | horn | explosion | hat | part | decal | outfit | emote | key
--   slot      where it is equipped: vehicle looks (paint, rims, trail, horn, explosion, part, decal) or
--             the rider (hat, outfit, emotes). A vehicle item can be worn on any vehicle the player owns.
--   coins     the coin price, or nil if it is not sold for coins
--   rarity    crate odds and the duplicate refund (common, rare, epic, legendary)
--   source    "shop" (coins, can be in the daily rotation), "crate" (crate only), "pass" (a game pass),
--             "starter" (the Starter Pack), "mastery" (a vehicle's mastery level), "streak" (day 7),
--             "ranked" (a Bumper Brawl ranked season reward, one per tier reached), "free" (everyone has it:
--             the 4 starting emotes)
--   color     { r, g, b } and material for paints and rims, the main colour for the rest
-- PLACEHOLDER ART: every item is a colour, material or simple part until the art pass gives them meshes
-- and textures; horns have no sound until nate picks licensed sounds (Config.Sounds).

local Catalog = {}

export type Item = {
	id: string,
	kind: string,
	name: string,
	coins: number?,
	rarity: string,
	source: string,
	color: { number }?,
	material: string?,
	pass: string?, -- source "pass": which pass grants it
	mastery: number?, -- source "mastery": the level that unlocks it (on that vehicle only)
}

Catalog.RARITIES = { "common", "rare", "epic", "legendary" }

-- Crash Crate odds (spec), shiny chance and the duplicate refund
Catalog.CRATE = {
	odds = { common = 0.60, rare = 0.28, epic = 0.10, legendary = 0.02 },
	shinyChance = 1 / 50,
	duplicateRefund = 0.3,
	coinPrice = 1000,
	-- What a duplicate is worth when the item has no coin price
	rarityValue = { common = 300, rare = 700, epic = 1200, legendary = 2500 },
}

Catalog.ROTATION_SIZE = 4

local items: { Item } = {
	-- Paints: solid 200 to 400, pattern and metallic 600 to 900
	{
		id = "starter_paint",
		kind = "paint",
		name = "Sunny Yellow",
		coins = 200,
		rarity = "common",
		source = "shop",
		color = { 255, 214, 60 },
	},
	{
		id = "paint_cherry",
		kind = "paint",
		name = "Cherry Red",
		coins = 200,
		rarity = "common",
		source = "shop",
		color = { 230, 50, 60 },
	},
	{
		id = "paint_lime",
		kind = "paint",
		name = "Lime Pop",
		coins = 200,
		rarity = "common",
		source = "shop",
		color = { 140, 230, 60 },
	},
	{
		id = "paint_sky",
		kind = "paint",
		name = "Sky Blue",
		coins = 250,
		rarity = "common",
		source = "shop",
		color = { 110, 190, 255 },
	},
	{
		id = "paint_grape",
		kind = "paint",
		name = "Grape Soda",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 150, 80, 220 },
	},
	{
		id = "paint_tangerine",
		kind = "paint",
		name = "Tangerine",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 255, 140, 40 },
	},
	{
		id = "paint_mint",
		kind = "paint",
		name = "Mint Chip",
		coins = 350,
		rarity = "common",
		source = "shop",
		color = { 150, 235, 200 },
	},
	{
		id = "paint_bubblegum",
		kind = "paint",
		name = "Bubblegum",
		coins = 400,
		rarity = "common",
		source = "shop",
		color = { 255, 150, 200 },
	},
	{
		id = "paint_midnight",
		kind = "paint",
		name = "Midnight",
		coins = 400,
		rarity = "common",
		source = "shop",
		color = { 40, 45, 80 },
	},
	{
		id = "paint_pearl",
		kind = "paint",
		name = "Pearl Shine",
		coins = 700,
		rarity = "rare",
		source = "shop",
		color = { 245, 240, 235 },
		material = "Glass",
	},
	{
		id = "paint_chrome",
		kind = "paint",
		name = "Chrome Mirror",
		coins = 800,
		rarity = "rare",
		source = "shop",
		color = { 200, 205, 215 },
		material = "Metal",
	},
	{
		id = "paint_gold_flake",
		kind = "paint",
		name = "Gold Flake",
		coins = 900,
		rarity = "rare",
		source = "shop",
		color = { 230, 180, 50 },
		material = "Foil",
	},
	{
		id = "paint_neon_zest",
		kind = "paint",
		name = "Neon Zest",
		coins = 900,
		rarity = "epic",
		source = "shop",
		color = { 200, 255, 60 },
		material = "Neon",
	},
	{
		id = "paint_lava",
		kind = "paint",
		name = "Lava Lamp",
		rarity = "epic",
		source = "crate",
		color = { 255, 80, 30 },
		material = "Neon",
	},
	{
		id = "paint_galaxy",
		kind = "paint",
		name = "Galaxy Swirl",
		rarity = "legendary",
		source = "crate",
		color = { 70, 40, 140 },
		material = "Glass",
	},
	-- Rims: 300 to 700
	{
		id = "rims_black",
		kind = "rims",
		name = "Blackout Rims",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 30, 30, 35 },
	},
	{
		id = "rims_chrome",
		kind = "rims",
		name = "Chrome Rims",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 210, 215, 225 },
		material = "Metal",
	},
	{
		id = "rims_candy",
		kind = "rims",
		name = "Candy Rims",
		coins = 450,
		rarity = "common",
		source = "shop",
		color = { 255, 90, 160 },
	},
	{
		id = "rims_neon",
		kind = "rims",
		name = "Glow Rims",
		coins = 600,
		rarity = "rare",
		source = "shop",
		color = { 80, 255, 220 },
		material = "Neon",
	},
	{
		id = "rims_gold",
		kind = "rims",
		name = "Gold Rims",
		coins = 700,
		rarity = "rare",
		source = "shop",
		color = { 240, 190, 50 },
		material = "Metal",
	},
	{
		id = "rims_diamond",
		kind = "rims",
		name = "Diamond Rims",
		rarity = "legendary",
		source = "crate",
		color = { 190, 240, 255 },
		material = "Glass",
	},
	-- Trails: 400 to 1,500
	{
		id = "trail_sparkle",
		kind = "trail",
		name = "Sparkle Trail",
		coins = 400,
		rarity = "common",
		source = "shop",
		color = { 255, 250, 200 },
	},
	{
		id = "trail_smoke",
		kind = "trail",
		name = "Puffy Smoke",
		coins = 500,
		rarity = "common",
		source = "shop",
		color = { 220, 220, 230 },
	},
	{
		id = "trail_bubbles",
		kind = "trail",
		name = "Bubble Trail",
		coins = 600,
		rarity = "rare",
		source = "shop",
		color = { 150, 220, 255 },
	},
	{
		id = "trail_stars",
		kind = "trail",
		name = "Star Trail",
		coins = 900,
		rarity = "rare",
		source = "shop",
		color = { 255, 214, 10 },
	},
	{
		id = "trail_rainbow",
		kind = "trail",
		name = "Rainbow Trail",
		coins = 1500,
		rarity = "epic",
		source = "shop",
		color = { 255, 100, 100 },
	},
	{
		id = "trail_lightning",
		kind = "trail",
		name = "Zap Trail",
		rarity = "legendary",
		source = "crate",
		color = { 120, 200, 255 },
	},
	{
		id = "trail_confetti",
		kind = "trail",
		name = "Confetti Trail",
		rarity = "rare",
		source = "starter",
		color = { 255, 120, 200 },
	},
	-- Horns: 250
	{
		id = "horn_duck",
		kind = "horn",
		name = "Rubber Duck Horn",
		coins = 250,
		rarity = "common",
		source = "shop",
	},
	{
		id = "horn_kazoo",
		kind = "horn",
		name = "Kazoo Horn",
		coins = 250,
		rarity = "common",
		source = "shop",
	},
	{
		id = "horn_trumpet",
		kind = "horn",
		name = "Party Trumpet",
		coins = 250,
		rarity = "common",
		source = "shop",
	},
	{
		id = "horn_boing",
		kind = "horn",
		name = "Boing Horn",
		coins = 250,
		rarity = "common",
		source = "shop",
	},
	-- Explosion styles: 3 for coins (1,500), 3 in the Explosion Styles pass
	{
		id = "explosion_fizz",
		kind = "explosion",
		name = "Soda Fizz",
		coins = 1500,
		rarity = "epic",
		source = "shop",
		color = { 120, 220, 255 },
	},
	{
		id = "explosion_glitter",
		kind = "explosion",
		name = "Glitter Pop",
		coins = 1500,
		rarity = "epic",
		source = "shop",
		color = { 255, 150, 230 },
	},
	{
		id = "explosion_bubble",
		kind = "explosion",
		name = "Bubble Burst",
		coins = 1500,
		rarity = "epic",
		source = "shop",
		color = { 170, 230, 255 },
	},
	{
		id = "explosion_confetti",
		kind = "explosion",
		name = "Confetti Blast",
		rarity = "epic",
		source = "pass",
		pass = "explosions",
		color = { 255, 200, 60 },
	},
	{
		id = "explosion_paint",
		kind = "explosion",
		name = "Paint Splash",
		rarity = "epic",
		source = "pass",
		pass = "explosions",
		color = { 90, 200, 120 },
	},
	{
		id = "explosion_foam",
		kind = "explosion",
		name = "Foam Burst",
		rarity = "epic",
		source = "pass",
		pass = "explosions",
		color = { 250, 250, 255 },
	},
	-- Hats (rider): 300 to 1,200
	{
		id = "hat_cap",
		kind = "hat",
		name = "Racing Cap",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 230, 50, 60 },
	},
	{
		id = "hat_cone",
		kind = "hat",
		name = "Traffic Cone",
		coins = 400,
		rarity = "common",
		source = "shop",
		color = { 255, 140, 40 },
	},
	{
		id = "hat_chef",
		kind = "hat",
		name = "Chef Hat",
		coins = 500,
		rarity = "common",
		source = "shop",
		color = { 250, 250, 250 },
	},
	{
		id = "hat_propeller",
		kind = "hat",
		name = "Propeller Beanie",
		coins = 600,
		rarity = "rare",
		source = "shop",
		color = { 80, 160, 255 },
	},
	{
		id = "hat_crown",
		kind = "hat",
		name = "Tin Crown",
		coins = 1200,
		rarity = "epic",
		source = "shop",
		color = { 240, 200, 60 },
	},
	{
		id = "hat_golden_duck",
		kind = "hat",
		name = "Golden Duck",
		rarity = "legendary",
		source = "crate",
		color = { 255, 210, 40 },
	},
	{
		id = "hat_pip_foam",
		kind = "hat",
		name = "Pip Foam Hat",
		rarity = "rare",
		source = "starter",
		color = { 255, 176, 59 },
	},
	-- Visual parts and decals: 300 to 800
	{
		id = "part_roofrack",
		kind = "part",
		name = "Roof Rack",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 60, 60, 70 },
	},
	{
		id = "part_spoiler",
		kind = "part",
		name = "Big Spoiler",
		coins = 500,
		rarity = "common",
		source = "shop",
		color = { 40, 40, 45 },
	},
	{
		id = "part_bullbar",
		kind = "part",
		name = "Bull Bar",
		coins = 600,
		rarity = "rare",
		source = "shop",
		color = { 180, 185, 195 },
	},
	{
		id = "part_fins",
		kind = "part",
		name = "Shark Fins",
		coins = 800,
		rarity = "rare",
		source = "shop",
		color = { 100, 120, 140 },
	},
	{
		id = "decal_stripes",
		kind = "decal",
		name = "Racing Stripes",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 255, 255, 255 },
	},
	{
		id = "decal_number",
		kind = "decal",
		name = "Lucky Number",
		coins = 300,
		rarity = "common",
		source = "shop",
		color = { 255, 255, 255 },
	},
	{
		id = "decal_flames",
		kind = "decal",
		name = "Cartoon Flames",
		coins = 400,
		rarity = "common",
		source = "shop",
		color = { 255, 120, 30 },
	},
	{
		id = "decal_stars",
		kind = "decal",
		name = "Star Stickers",
		coins = 400,
		rarity = "rare",
		source = "shop",
		color = { 255, 214, 10 },
	},
	-- Free emotes: the first 4 wheel slots (Emotes.DEFAULT)
	{ id = "emote_thumbs", kind = "emote", name = "Thumbs Up", rarity = "common", source = "free" },
	{ id = "emote_point", kind = "emote", name = "Point", rarity = "common", source = "free" },
	{ id = "emote_laugh", kind = "emote", name = "Ha Ha", rarity = "common", source = "free" },
	{ id = "emote_shrug", kind = "emote", name = "Shrug", rarity = "common", source = "free" },
	-- Rider Pass: 8 outfits and 4 emotes
	{
		id = "outfit_racer",
		kind = "outfit",
		name = "Racer Suit",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 230, 50, 60 },
	},
	{
		id = "outfit_astro",
		kind = "outfit",
		name = "Astro Suit",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 240, 240, 245 },
	},
	{
		id = "outfit_knight",
		kind = "outfit",
		name = "Foil Knight",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 190, 195, 205 },
	},
	{
		id = "outfit_dino",
		kind = "outfit",
		name = "Dino Onesie",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 110, 200, 90 },
	},
	{
		id = "outfit_chef",
		kind = "outfit",
		name = "Head Chef",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 250, 250, 250 },
	},
	{
		id = "outfit_lifeguard",
		kind = "outfit",
		name = "Lifeguard",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 255, 90, 70 },
	},
	{
		id = "outfit_robot",
		kind = "outfit",
		name = "Cardboard Robot",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 200, 160, 110 },
	},
	{
		id = "outfit_pajamas",
		kind = "outfit",
		name = "Comfy Pajamas",
		rarity = "rare",
		source = "pass",
		pass = "rider",
		color = { 150, 180, 255 },
	},
	{
		id = "emote_wave",
		kind = "emote",
		name = "Big Wave",
		rarity = "rare",
		source = "pass",
		pass = "rider",
	},
	{ id = "emote_cheer", kind = "emote", name = "Cheer", rarity = "rare", source = "pass", pass = "rider" },
	{ id = "emote_flex", kind = "emote", name = "Flex", rarity = "rare", source = "pass", pass = "rider" },
	{
		id = "emote_spin",
		kind = "emote",
		name = "Dizzy Spin",
		rarity = "rare",
		source = "pass",
		pass = "rider",
	},
	-- Mastery: one per level on that vehicle, level 10 the shiny gold paint
	{
		id = "mastery_stripe",
		kind = "paint",
		name = "Two-Tone",
		rarity = "common",
		source = "mastery",
		mastery = 2,
		color = { 255, 255, 255 },
	},
	{
		id = "mastery_rims",
		kind = "rims",
		name = "Mastery Rims",
		rarity = "common",
		source = "mastery",
		mastery = 3,
		color = { 255, 214, 10 },
	},
	{
		id = "mastery_dust",
		kind = "trail",
		name = "Dust Trail",
		rarity = "common",
		source = "mastery",
		mastery = 4,
		color = { 220, 190, 140 },
	},
	{
		id = "mastery_honk",
		kind = "horn",
		name = "Proud Honk",
		rarity = "common",
		source = "mastery",
		mastery = 5,
	},
	{
		id = "mastery_badge",
		kind = "decal",
		name = "Mastery Badge",
		rarity = "rare",
		source = "mastery",
		mastery = 6,
		color = { 255, 214, 10 },
	},
	{
		id = "mastery_metal",
		kind = "paint",
		name = "Mastery Metallic",
		rarity = "rare",
		source = "mastery",
		mastery = 7,
		color = { 90, 140, 230 },
		material = "Metal",
	},
	{
		id = "mastery_spark",
		kind = "trail",
		name = "Spark Trail",
		rarity = "rare",
		source = "mastery",
		mastery = 8,
		color = { 255, 200, 80 },
	},
	{
		id = "mastery_flames",
		kind = "decal",
		name = "Hot Flames",
		rarity = "epic",
		source = "mastery",
		mastery = 9,
		color = { 255, 90, 30 },
	},
	{
		id = "mastery_gold",
		kind = "paint",
		name = "Shiny Gold",
		rarity = "legendary",
		source = "mastery",
		mastery = 10,
		color = { 255, 200, 40 },
		material = "Foil",
	},
	-- Login streak day 7: one per week, in turn
	{
		id = "streak_bow",
		kind = "hat",
		name = "Giant Bow",
		rarity = "rare",
		source = "streak",
		color = { 255, 100, 160 },
	},
	{
		id = "streak_checker",
		kind = "paint",
		name = "Checker Flag",
		rarity = "rare",
		source = "streak",
		color = { 250, 250, 250 },
	},
	{
		id = "streak_hearts",
		kind = "trail",
		name = "Heart Trail",
		rarity = "rare",
		source = "streak",
		color = { 255, 90, 130 },
	},
	{
		id = "streak_goggles",
		kind = "hat",
		name = "Aviator Goggles",
		rarity = "rare",
		source = "streak",
		color = { 140, 100, 60 },
	},
	-- Ranked season rewards (Bumper Brawl): one per tier reached, paid when a season ends
	{
		id = "decal_bronze_bolt",
		kind = "decal",
		name = "Bronze Bolt Badge",
		rarity = "rare",
		source = "ranked",
		color = { 205, 127, 50 },
	},
	{
		id = "trail_silver_spark",
		kind = "trail",
		name = "Silver Spark Trail",
		rarity = "rare",
		source = "ranked",
		color = { 210, 215, 230 },
	},
	{
		id = "rims_gold_gear",
		kind = "rims",
		name = "Gold Gear Rims",
		rarity = "epic",
		source = "ranked",
		color = { 255, 200, 40 },
		material = "Metal",
	},
	{
		id = "paint_platinum_piston",
		kind = "paint",
		name = "Platinum Piston",
		rarity = "epic",
		source = "ranked",
		color = { 225, 235, 245 },
		material = "Metal",
	},
	{
		id = "trail_diamond_drift",
		kind = "trail",
		name = "Diamond Drift Trail",
		rarity = "legendary",
		source = "ranked",
		color = { 150, 230, 255 },
	},
	{
		id = "hat_apex_crown",
		kind = "hat",
		name = "Apex Crown",
		rarity = "legendary",
		source = "ranked",
		color = { 255, 215, 60 },
	},
	-- A crate key opens one coin crate (login streak day 4)
	{ id = "crate_key", kind = "key", name = "Crate Key", rarity = "common", source = "streak" },
}

Catalog.items = items
Catalog.byId = {} :: { [string]: Item }
for _, item in items do
	Catalog.byId[item.id] = item
end

-- Vehicle look slots (one item each) and rider slots
Catalog.VEHICLE_SLOTS = { "paint", "rims", "trail", "horn", "explosion", "part", "decal" }
Catalog.RIDER_SLOTS = { "hat", "outfit" }

function Catalog.isVehicleKind(kind: string): boolean
	return table.find(Catalog.VEHICLE_SLOTS, kind) ~= nil
end

-- Items for sale for coins (the shop's full list and the daily rotation's pool)
function Catalog.shopItems(): { Item }
	local list = {}
	for _, item in items do
		if item.source == "shop" and item.coins then
			table.insert(list, item)
		end
	end
	return list
end

-- The crate pool by rarity: every shop and crate item (never pass, starter, mastery or streak items)
function Catalog.cratePool(): { [string]: { Item } }
	local pool: { [string]: { Item } } = { common = {}, rare = {}, epic = {}, legendary = {} }
	for _, item in items do
		if (item.source == "shop" or item.source == "crate") and pool[item.rarity] then
			table.insert(pool[item.rarity], item)
		end
	end
	return pool
end

function Catalog.coinValue(item: Item): number
	return item.coins or Catalog.CRATE.rarityValue[item.rarity] or 300
end

function Catalog.passItems(pass: string): { Item }
	local list = {}
	for _, item in items do
		if item.pass == pass then
			table.insert(list, item)
		end
	end
	return list
end

function Catalog.masteryItems(): { Item }
	local list = {}
	for _, item in items do
		if item.mastery then
			table.insert(list, item)
		end
	end
	table.sort(list, function(a, b)
		return (a.mastery :: number) < (b.mastery :: number)
	end)
	return list
end

function Catalog.streakCosmetics(): { Item }
	local list = {}
	for _, item in items do
		if item.source == "streak" and item.kind ~= "key" then
			table.insert(list, item)
		end
	end
	return list
end

return Catalog
