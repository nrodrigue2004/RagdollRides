-- BrowseClient: finding and driving other players' maps on this device (spec: Browse, Ratings,
-- Moderation). MAPS on the Tracks HUD opens the browse screen (Ui/BrowseHud).
-- * Tabs ask the server for a page (Map.Browse -> Map.List); the STARTER tab is built here from the
--   starter maps. Cards draw a sketch from the map's own pieces.
-- * Tapping a card sends Map.Play. The server answers with Map.Data (the pieces, so TracksClient knows
--   the checkpoints, cues and moving parts) and moves the car to the map's start.
-- * On a player map's results card: rate it 1 to 5 stars (sent once the taps settle), report it
--   (3 preset reasons), and NEXT drives the next card from the list you picked it from.
-- * Creator royalties arrive as Map.Royalty and show as a toast.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapCodec = require(Shared.MapCodec)
local MapNames = require(Shared.MapNames)
local Net = require(Shared.Net)
local PieceCatalog = require(Shared.PieceCatalog)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)

local Client = script.Parent.Parent
local BrowseHud = require(Client:WaitForChild("Ui"):WaitForChild("BrowseHud"))

local LocalPlayer = Players.LocalPlayer

local BrowseClient = {}

local RATE_SETTLE = 0.8 -- seconds after the last star tap before the rating is sent

export type MapInfo = {
	mapId: string,
	name: string,
	creator: string,
	owner: number,
	myRating: number?,
	hidden: boolean,
}

local controllers: any = nil
local tab = "featured"
local page = 1
local pages = 1
local shown: { BrowseHud.CardView } = {}
local playlist: { BrowseHud.CardView } = {} -- the cards the last played map was picked from
local pieceCache: { [string]: { data: string, pieces: { StarterMaps.Piece } } } = {}
local info: { [string]: MapInfo } = {}
local rateToken = 0
local reported: { [string]: boolean } = {}

local function isAdmin(): boolean
	return RunService:IsStudio() or table.find(Config.Admins, LocalPlayer.UserId) ~= nil
end

local function tabs(): { BrowseHud.Tab }
	local list = {
		{ id = "featured", label = "FEATURED" },
		{ id = "popular", label = "POPULAR" },
		{ id = "newest", label = "NEWEST" },
		{ id = "friends", label = "FRIENDS" },
		{ id = "mine", label = "MY MAPS" },
		{ id = "starter", label = "STARTER" },
	}
	if isAdmin() then
		table.insert(list, { id = "review", label = "REVIEW" })
	end
	return list
end

local EMPTY = {
	featured = "No featured maps yet. Try NEWEST!",
	popular = "No popular maps yet. Yours could be first: tap BUILD!",
	newest = "No maps shared yet. Tap BUILD and make the first one!",
	friends = "None of your friends have shared a map yet.",
	mine = "You haven't shared a map yet. Tap BUILD to make one!",
	review = "Nothing waiting for review.",
}

-- A shared map's pieces, decoded once (the same pieces the server builds)
local function piecesOf(mapId: string, data: string?): { StarterMaps.Piece }
	if type(data) ~= "string" then
		return {}
	end
	local cached = pieceCache[mapId]
	if cached and cached.data == data then
		return cached.pieces
	end
	local raw = GhostCodec.fromBase64(data)
	local map = raw and MapCodec.decode(raw)
	local pieces = if map then PieceCatalog.toMapDef(map.pieces, { id = mapId }).pieces else {}
	pieceCache[mapId] = { data = data, pieces = pieces }
	return pieces
end

local function plays(n: number): string
	if n >= 1000000 then
		return string.format("%.1fM plays", n / 1000000)
	elseif n >= 1000 then
		return string.format("%.1fK plays", n / 1000)
	end
	return string.format("%d %s", n, if n == 1 then "play" else "plays")
end

local function starterCards(): { BrowseHud.CardView }
	local cards = {}
	local current = LocalPlayer:GetAttribute("MapId")
	for _, def in StarterMaps.maps do
		local track = controllers.Profile.track(def.id)
		local stars = if track then track.stars or 0 else 0
		table.insert(cards, {
			id = def.id,
			name = def.name,
			sub = if track then "Best " .. TracksMath.formatTime(track.best / 1000) else "Not driven yet",
			stats = string.rep("★", stars) .. string.rep("☆", 3 - stars),
			tags = "Starter map",
			pieces = def.pieces,
			current = current == def.id,
		})
	end
	return cards
end

local function cardFrom(entry: { [string]: any }): BrowseHud.CardView
	local rating = entry.rating
	local stats = if entry.hidden
		then "Hidden for review"
		elseif rating then string.format("★ %.1f · %s", rating, plays(entry.plays or 0))
		else "NEW · " .. plays(entry.plays or 0)
	local badge, badgeColor = nil, nil
	if entry.hidden then
		badge, badgeColor = "HIDDEN", BrowseHud.RED
	elseif entry.featured then
		badge, badgeColor = "FEATURED", BrowseHud.GOLD
	end
	local track = controllers.Profile.track(entry.mapId)
	local sub = if entry.mine then "by you" else "by " .. tostring(entry.creator)
	if track then
		sub ..= " · best " .. TracksMath.formatTime(track.best / 1000)
	end
	return {
		id = entry.mapId,
		name = entry.name,
		sub = sub,
		stats = stats,
		tags = table.concat(MapNames.tagNames(entry.tags or 0), " · "),
		badge = badge,
		badgeColor = badgeColor,
		pieces = piecesOf(entry.mapId, entry.data),
		current = LocalPlayer:GetAttribute("MapId") == entry.mapId,
		admin = if isAdmin() and not (entry.mine and not RunService:IsStudio())
			then { featured = entry.featured == true, hidden = entry.hidden == true }
			else nil,
	}
end

local function request()
	if tab == "starter" then
		shown = starterCards()
		pages = 1
		BrowseHud.showCards(shown, 1, 1)
		return
	end
	BrowseHud.showLoading()
	Net.send("Map.Browse", tab, page)
end

local function selectTab(id: string)
	tab = id
	page = 1
	BrowseHud.setTab(id)
	request()
end

local function play(view: BrowseHud.CardView)
	playlist = shown
	BrowseHud.close()
	if controllers.Tracks.getRunState() == "running" then
		controllers.Tracks.toast("Off to " .. view.name .. "!")
	end
	if StarterMaps.byId[view.id] then
		Net.send("Map.Go", view.id)
	else
		Net.send("Map.Play", view.id)
	end
end

function BrowseClient.isOpen(): boolean
	return BrowseHud.isOpen()
end

function BrowseClient.close()
	BrowseHud.close()
end

function BrowseClient.open(startTab: string?)
	if BrowseHud.isOpen() then
		return
	end
	if startTab then
		tab = startTab
	end
	page = 1
	BrowseHud.open(LocalPlayer:WaitForChild("PlayerGui"), tabs(), tab, {
		onTab = selectTab,
		onPage = function(delta)
			page = math.clamp(page + delta, 1, pages)
			request()
		end,
		onPlay = play,
		onAdmin = function(view, action)
			Net.send("Admin.Map", view.id, action)
		end,
		onClose = BrowseHud.close,
	})
	request()
end

function BrowseClient.toggle()
	if BrowseHud.isOpen() then
		BrowseHud.close()
	else
		BrowseClient.open()
	end
end

-- What we know about a player map we are driving (from Map.Data)
function BrowseClient.info(mapId: string): MapInfo?
	return info[mapId]
end

-- The card after this map in the list it was picked from
function BrowseClient.nextAfter(mapId: string): BrowseHud.CardView?
	for index, view in playlist do
		if view.id == mapId then
			return playlist[index + 1]
		end
	end
	return nil
end

-- NEXT on a player map's results: the next card, or the browse screen at the end of the list
function BrowseClient.playNext(mapId: string)
	local view = BrowseClient.nextAfter(mapId)
	if view then
		play(view)
	else
		BrowseClient.open()
	end
end

-- Stars on the results card: sent once the taps settle (the server keeps one rating per player)
function BrowseClient.rate(mapId: string, stars: number)
	local entry = info[mapId]
	if entry then
		entry.myRating = stars
	end
	rateToken += 1
	local token = rateToken
	task.delay(RATE_SETTLE, function()
		if token == rateToken then
			Net.send("Map.Rate", mapId, stars)
		end
	end)
end

function BrowseClient.report(mapId: string, reason: string)
	if reported[mapId] then
		return
	end
	reported[mapId] = true
	Net.send("Map.Report", mapId, reason)
end

function BrowseClient.hasReported(mapId: string): boolean
	return reported[mapId] == true
end

function BrowseClient.init(all)
	controllers = all
end

function BrowseClient.start()
	-- First-time players start on the starter maps; everyone else on Featured
	controllers.Profile.Changed:Connect(function(view, previous)
		if previous == nil and not view.tut.pipHill then
			tab = "starter"
		end
	end)

	Net.listen("Map.List", function(list)
		if type(list) ~= "table" or list.tab ~= tab or not BrowseHud.isOpen() then
			return
		end
		page = list.page or 1
		pages = list.pages or 1
		shown = {}
		for _, entry in list.cards or {} do
			table.insert(shown, cardFrom(entry))
		end
		BrowseHud.showCards(shown, page, pages, EMPTY[tab])
	end)

	Net.listen("Map.Data", function(data)
		if type(data) ~= "table" or type(data.mapId) ~= "string" then
			return
		end
		local raw = GhostCodec.fromBase64(data.data)
		local map = raw and MapCodec.decode(raw)
		if map == nil then
			return
		end
		local def = PieceCatalog.toMapDef(map.pieces, {
			id = data.mapId,
			name = data.name,
			offset = data.offset,
			creatorTime = (data.creatorMs or 0) / 1000,
			fullDamage = MapCodec.fullDamage(map),
		})
		def.owner = data.owner
		info[data.mapId] = {
			mapId = data.mapId,
			name = data.name,
			creator = data.creator,
			owner = data.owner,
			myRating = data.myRating,
			hidden = data.hidden == true,
		}
		controllers.Tracks.registerMap(def)
	end)

	Net.listen("Map.Royalty", function(coins)
		if type(coins) == "number" and coins > 0 then
			controllers.Tracks.toast(string.format("Players drove your maps: +%d coins!", coins))
			controllers.Juice.fire("Coin")
		end
	end)
	Net.listen("Map.Reported", function()
		controllers.Tracks.toast("Thanks! We'll take a look.")
	end)
end

return BrowseClient
