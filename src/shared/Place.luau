-- Place: which place of the experience this is (spec: World and places). One codebase builds every
-- place. Each Rojo project sets the Workspace attribute PlaceRole: none (or "Hub") is Tumble Park, the
-- start place (default.project.json); "Brawl" is Cinder Cove (brawl.project.json, and
-- ranked.project.json, which also sets Ranked); "Highway" is Sunny Pass (highway.project.json, and
-- versus.project.json, which also sets Versus). A live server also knows a mode place by its place id
-- (Config.Places), so a place published from the wrong file still behaves.

local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)

local Place = {}

function Place.role(): string
	local id = game.PlaceId
	if id ~= 0 and (id == Config.Places.brawlCasual or id == Config.Places.brawlRanked) then
		return "Brawl"
	end
	if id ~= 0 and (id == Config.Places.highwayCoop or id == Config.Places.highwayVersus) then
		return "Highway"
	end
	local attribute = Workspace:GetAttribute("PlaceRole")
	if attribute == "Brawl" or attribute == "Highway" then
		return attribute
	end
	return "Hub"
end

function Place.isRanked(): boolean
	local id = game.PlaceId
	if id ~= 0 and id == Config.Places.brawlRanked then
		return true
	end
	if id ~= 0 and id == Config.Places.brawlCasual then
		return false
	end
	return Workspace:GetAttribute("Ranked") == true
end

-- Highway Havoc versus lanes (players score off each other) or co-op lanes
function Place.isVersus(): boolean
	local id = game.PlaceId
	if id ~= 0 and id == Config.Places.highwayVersus then
		return true
	end
	if id ~= 0 and id == Config.Places.highwayCoop then
		return false
	end
	return Workspace:GetAttribute("Versus") == true
end

-- A mode is live once its place exists (or this is that place): quests and cards use it
function Place.modeLive(mode: string): boolean
	if mode == "tracks" then
		return true
	elseif mode == "brawl" then
		return Config.Places.brawlCasual ~= 0 or Place.role() == "Brawl"
	elseif mode == "highway" then
		return Config.Places.highwayCoop ~= 0 or Place.role() == "Highway"
	end
	return false
end

return Place
