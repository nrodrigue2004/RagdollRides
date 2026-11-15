--!strict
-- MapNames: map names come only from three preset word wheels (spec: Map settings; nate 2026-11-13: no
-- free text anywhere). Adjective + Noun + Place, for example "Wobbly Pickle Canyon". Players pick word
-- ids; the server checks the ids exist. Words are picked to be silly and safe in any combination (no
-- body parts, no insults, nothing that reads badly next to another word). Ids are positions in these
-- lists: only ever add words at the end, never remove or reorder (published names would change).

local MapNames = {}

MapNames.ADJECTIVES = {
	"Wobbly",
	"Bouncy",
	"Zippy",
	"Fuzzy",
	"Sparkly",
	"Giggly",
	"Mighty",
	"Tiny",
	"Jolly",
	"Rusty",
	"Sunny",
	"Frosty",
	"Speedy",
	"Sleepy",
	"Noisy",
	"Sneaky",
	"Lucky",
	"Crunchy",
	"Squishy",
	"Shiny",
	"Wiggly",
	"Breezy",
	"Dizzy",
	"Turbo",
	"Super",
	"Mega",
	"Lumpy",
	"Bumpy",
	"Twisty",
	"Loopy",
	"Happy",
	"Brave",
	"Clever",
	"Cosmic",
	"Golden",
	"Silver",
	"Purple",
	"Orange",
	"Minty",
	"Fizzy",
	"Wild",
	"Wacky",
	"Jumpy",
	"Zany",
	"Snappy",
	"Toasty",
	"Chilly",
	"Rocky",
	"Sandy",
	"Leafy",
	"Swift",
	"Grand",
	"Little",
	"Royal",
	"Secret",
	"Hidden",
	"Rainbow",
	"Thunder",
	"Silly",
	"Merry",
}

MapNames.NOUNS = {
	"Pickle",
	"Waffle",
	"Noodle",
	"Penguin",
	"Rocket",
	"Teapot",
	"Banana",
	"Muffin",
	"Pancake",
	"Donut",
	"Turtle",
	"Rabbit",
	"Llama",
	"Panda",
	"Otter",
	"Walrus",
	"Moose",
	"Badger",
	"Hedgehog",
	"Goose",
	"Pretzel",
	"Cupcake",
	"Taco",
	"Pizza",
	"Cookie",
	"Jellybean",
	"Marshmallow",
	"Popcorn",
	"Pudding",
	"Biscuit",
	"Robot",
	"Wizard",
	"Pirate",
	"Knight",
	"Dragon",
	"Unicorn",
	"Yeti",
	"Dino",
	"Comet",
	"Meteor",
	"Bubble",
	"Button",
	"Sock",
	"Kazoo",
	"Trumpet",
	"Drum",
	"Banjo",
	"Kite",
	"Balloon",
	"Yo-yo",
	"Acorn",
	"Pebble",
	"Cactus",
	"Mushroom",
	"Pumpkin",
	"Carrot",
	"Lemon",
	"Melon",
	"Cherry",
	"Coconut",
	"Rubber Duck",
	"Snowman",
	"Sandcastle",
	"Treehouse",
	"Lighthouse",
	"Windmill",
	"Teacup",
	"Spoon",
	"Kettle",
	"Wagon",
	"Hamster",
	"Puffin",
	"Koala",
	"Squirrel",
	"Owl",
	"Frog",
	"Crab",
	"Lobster",
	"Seal",
	"Bumblebee",
}

MapNames.PLACES = {
	"Canyon",
	"Valley",
	"Speedway",
	"Hills",
	"Harbor",
	"Island",
	"Mountain",
	"Meadow",
	"Raceway",
	"Ridge",
	"Falls",
	"Lagoon",
	"Desert",
	"Forest",
	"Jungle",
	"Glacier",
	"Volcano",
	"Beach",
	"Bay",
	"Cliffs",
	"Park",
	"Plaza",
	"Alley",
	"Avenue",
	"Boulevard",
	"Loop",
	"Circuit",
	"Track",
	"Rally",
	"Run",
	"Peak",
	"Pass",
	"Gulch",
	"Dunes",
	"Marsh",
	"Grove",
	"Garden",
	"Station",
	"Junction",
	"Summit",
}

-- Tags: up to 3 from this fixed list (spec), stored as one bit each
MapNames.TAGS = { "Easy", "Hard", "Long", "Short", "Funny", "Jumps", "Race", "Puzzle" }
MapNames.MAX_TAGS = 3

function MapNames.valid(adjective: number, noun: number, place: number): boolean
	return MapNames.ADJECTIVES[adjective] ~= nil
		and MapNames.NOUNS[noun] ~= nil
		and MapNames.PLACES[place] ~= nil
end

-- The display name; number > 1 is added when the same three words are taken ("Wobbly Pickle Canyon 2")
function MapNames.format(adjective: number, noun: number, place: number, number: number?): string
	local name = string.format(
		"%s %s %s",
		MapNames.ADJECTIVES[adjective] or "?",
		MapNames.NOUNS[noun] or "?",
		MapNames.PLACES[place] or "?"
	)
	if number and number > 1 then
		name ..= " " .. tostring(number)
	end
	return name
end

function MapNames.tagCount(mask: number): number
	local count = 0
	for bit = 0, #MapNames.TAGS - 1 do
		if bit32.btest(mask, bit32.lshift(1, bit)) then
			count += 1
		end
	end
	return count
end

function MapNames.validTags(mask: number): boolean
	return mask >= 0
		and mask < bit32.lshift(1, #MapNames.TAGS)
		and MapNames.tagCount(mask) <= MapNames.MAX_TAGS
end

function MapNames.tagNames(mask: number): { string }
	local out = {}
	for index, name in MapNames.TAGS do
		if bit32.btest(mask, bit32.lshift(1, index - 1)) then
			table.insert(out, name)
		end
	end
	return out
end

return MapNames
