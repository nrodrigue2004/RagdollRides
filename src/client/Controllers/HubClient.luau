-- HubClient: the Tumble Park hub on this device (spec: Hub and menus; Core loop > returning sessions;
-- Always-on elements > Hub button; Leaderboards).
-- * HUB (top left, every mode once Pip's Hill is done) takes you to the hub. Mid-race it asks for a
--   second tap, because it leaves the race.
-- * Arriving in the hub opens the mode picker: Tracks (Free Run / Quick Race), Bumper Brawl
--   (Casual / Ranked) and Highway Havoc (Co-op / Versus) with live player counts. The last mode played
--   glows, so one tap goes straight back in. Brawl and Highway show a silhouette until 7 minutes of
--   play (spec: until minute 7 of the first session), then Coming soon until their milestones.
-- * Driving into a stall opens its screen: the gates open the picker, the race pad joins the quick
--   race queue, the garage door, shop stall and workshop open GARAGE, SHOP and BUILD.
-- * PARTY: invite Roblox friends in this server; the leader's quick race takes the party along.
-- * TOP (top right, on any map with boards) opens the map's leaderboard: Friends, Weekly, All-time.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local StarterMaps = require(Shared.StarterMaps)
local TracksMath = require(Shared.TracksMath)

local Client = script.Parent.Parent
local HubHud = require(Client.Ui.HubHud)
local TracksHud = require(Client.Ui.TracksHud)

local LocalPlayer = Players.LocalPlayer

local HubClient = {}

local HUB = "hub"
local cfg = Config.Hub

local controllers: any = nil
local chips = { tracks = "free", brawl = "casual", highway = "coop" }
local sessionStart = os.clock()
local basePlay: number? = nil
local inside: { [string]: boolean } = {}
local leftAt: { [string]: number } = {}
local party: { leader: number?, members: { { userId: number, name: string } } } = { members = {} }
local invited: { [number]: boolean } = {}
local friendCache: { [number]: boolean } = {}
local board = { mapId = "", tab = "alltime" }
local hubConfirmUntil = 0
local openedThisVisit = false

local function gui(): Instance
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function inHub(): boolean
	return LocalPlayer:GetAttribute("MapId") == HUB
end

local function playSeconds(): number
	local view = controllers.Profile.get()
	if view and basePlay == nil then
		basePlay = view.playSeconds or 0
		sessionStart = os.clock()
	end
	return (basePlay or 0) + (os.clock() - sessionStart)
end

local function panelOpen(): boolean
	return HubHud.isOpen("modes")
		or HubHud.isOpen("party")
		or HubHud.isOpen("board")
		or controllers.Shop.isOpen()
		or controllers.Browse.isOpen()
		or controllers.Settings.isOpen()
		or controllers.Builder.isBuilding()
end

-- The next starter map to drive: the first without Gold (the server agrees: TracksService.nextStarter)
local function nextStarter(): string
	local view = controllers.Profile.get()
	if view == nil or not view.tut.pipHill then
		return StarterMaps.FIRST_MAP
	end
	for _, map in StarterMaps.maps do
		local entry = view.tracks[map.id]
		if entry == nil or (entry.stars or 0) < 3 then
			return map.id
		end
	end
	return StarterMaps.FIRST_MAP
end

---------------------------------------------------------------------------
-- Mode picker
---------------------------------------------------------------------------

local function count(attribute: string): number
	return workspace:GetAttribute(attribute) or 0
end

local function partyNames(): { string }
	local names = {}
	for _, member in party.members do
		table.insert(names, member.name)
	end
	return names
end

local openParty: () -> ()

function HubClient.openModes()
	local view = controllers.Profile.get()
	if view == nil then
		return
	end
	local locked = playSeconds() < cfg.modesUnlockSeconds
	local minutes = math.max(1, math.ceil((cfg.modesUnlockSeconds - playSeconds()) / 60))
	local lastMode = view.lastMode or ""
	if lastMode == "race" and not openedThisVisit then
		chips.tracks = "quick"
	end
	local function chip(modeName: string)
		return function(id: string)
			chips[modeName] = id
			HubClient.openModes()
		end
	end
	local cards = {
		{
			id = "tracks",
			title = "TRACKS",
			line = if chips.tracks == "quick" then "Race up to 8 players" else "Drive maps, beat your ghost",
			players = count("LiveTracks") + count("LiveRace"),
			color = Color3.fromRGB(86, 170, 255),
			locked = false,
			soon = false,
			glow = lastMode == "tracks" or lastMode == "race",
			chips = { { id = "free", label = "FREE RUN" }, { id = "quick", label = "QUICK RACE" } },
			chip = chips.tracks,
			onChip = chip("tracks"),
			onPlay = function()
				HubHud.close("modes")
				if chips.tracks == "quick" then
					if controllers.Race.isQueued() then
						TracksHud.toast("You're in the queue! Drive around while it fills.", 3)
					else
						controllers.Race.join()
					end
				else
					Net.send("Map.Go", nextStarter())
				end
			end,
		},
		{
			id = "brawl",
			title = "BUMPER BRAWL",
			line = "Bump everyone off the arena",
			players = count("LiveBrawl"),
			color = Color3.fromRGB(255, 120, 90),
			locked = locked,
			lockedLine = string.format("Opens in %d min", minutes),
			soon = Config.Places.brawlCasual == 0,
			glow = lastMode == "brawl",
			chips = {
				{ id = "casual", label = "CASUAL" },
				{ id = "ranked", label = "RANKED", locked = true },
			},
			chip = chips.brawl,
			onChip = chip("brawl"),
			onPlay = function()
				Net.send("Hub.Mode", "brawl", chips.brawl)
			end,
		},
		{
			id = "highway",
			title = "HIGHWAY HAVOC",
			line = "Crash into everything for points",
			players = count("LiveHighway"),
			color = Color3.fromRGB(255, 200, 60),
			locked = locked,
			lockedLine = string.format("Opens in %d min", minutes),
			soon = Config.Places.highwayCoop == 0,
			glow = lastMode == "highway",
			chips = {
				{ id = "coop", label = "CO-OP" },
				{ id = "versus", label = "VERSUS", locked = true },
			},
			chip = chips.highway,
			onChip = chip("highway"),
			onPlay = function()
				Net.send("Hub.Mode", "highway", chips.highway)
			end,
		},
	}
	openedThisVisit = true
	HubHud.openModes(gui(), cards, { members = partyNames(), onParty = openParty }, function() end)
end

---------------------------------------------------------------------------
-- Party
---------------------------------------------------------------------------

local function friendsHere(): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer then
			local known = friendCache[player.UserId]
			if known == nil then
				friendCache[player.UserId] = false
				task.spawn(function()
					local ok, yes = pcall(function()
						return LocalPlayer:IsFriendsWith(player.UserId)
					end)
					friendCache[player.UserId] = ok and yes == true
					if ok and yes and HubHud.isOpen("party") then
						openParty()
					end
				end)
			elseif known then
				table.insert(list, player)
			end
		end
	end
	return list
end

openParty = function()
	local members = {}
	local inPartyIds = {}
	for _, member in party.members do
		inPartyIds[member.userId] = true
		table.insert(members, {
			name = member.name,
			leader = member.userId == party.leader,
			me = member.userId == LocalPlayer.UserId,
		})
	end
	if #members == 0 then
		table.insert(members, { name = LocalPlayer.DisplayName, leader = true, me = true })
	end
	local friends = {}
	for _, player in friendsHere() do
		if not inPartyIds[player.UserId] then
			table.insert(friends, {
				name = player.DisplayName,
				invited = invited[player.UserId] == true,
				onInvite = function()
					invited[player.UserId] = true
					Net.send("Party.Invite", player.UserId)
					openParty()
				end,
			})
		end
	end
	HubHud.openParty(gui(), {
		members = members,
		friends = friends,
		onLeave = if #party.members > 1
			then function()
				Net.send("Party.Leave")
				HubHud.close("party")
			end
			else nil,
	}, function() end)
end
HubClient.openParty = openParty

---------------------------------------------------------------------------
-- Leaderboards
---------------------------------------------------------------------------

local function boardable(map: any): boolean
	return map ~= nil and not map.race and controllers.Tracks.getTest() == nil
end

local function drawBoard(data: { [string]: any }?)
	local map = controllers.Tracks.getMap()
	local function row(r: { [string]: any }, me: boolean)
		return {
			rank = r.rank,
			name = r.name or "",
			time = TracksMath.formatTime((r.ms or 0) / 1000),
			me = me,
			friend = r.friend == true,
		}
	end
	local rows = {}
	for _, r in (data and data.rows) or {} do
		table.insert(rows, row(r, r.me == true))
	end
	local mine = data and data.mine
	HubHud.openBoard(gui(), {
		mapName = if map then map.name else "",
		tab = board.tab,
		loading = data == nil,
		rows = rows,
		mine = if mine then row(mine, true) else nil,
		noTimeLine = if board.tab == "weekly"
			then "You're not in this week's top 10 yet. Go for it!"
			else "Finish this map to get on the board!",
		onTab = function(tab: string)
			board.tab = tab
			drawBoard(nil)
			Net.send("Board.Get", board.mapId, tab)
		end,
	}, function() end)
end

function HubClient.openBoard()
	local map = controllers.Tracks.getMap()
	if not boardable(map) then
		TracksHud.toast("Top times show on maps.", 2)
		return
	end
	board.mapId = (map :: any).id
	drawBoard(nil)
	Net.send("Board.Get", board.mapId, board.tab)
end

---------------------------------------------------------------------------
-- HUB and the buttons
---------------------------------------------------------------------------

function HubClient.goHub()
	if controllers.Builder.isBuilding() then
		return
	end
	if controllers.Race.inRace() then
		if os.clock() > hubConfirmUntil then
			hubConfirmUntil = os.clock() + 3
			TracksHud.toast("Tap HUB again to leave the race.", 3)
			return
		end
		controllers.Race.leave()
		return
	end
	if inHub() then
		HubClient.openModes()
		return
	end
	Net.send("Map.Go", HUB)
end

local function updateButtons()
	local view = controllers.Profile.get()
	local ready = view ~= nil and view.tut.pipHill == true
	TracksHud.setButtonVisible("Hub", (ready and not inHub()) or controllers.Race.inRace())
	TracksHud.setButtonVisible("Top", boardable(controllers.Tracks.getMap()))
	HubHud.modesButton(gui(), inHub() and not panelOpen(), HubClient.openModes)
end

local function onMapChanged()
	inside = {}
	if inHub() then
		openedThisVisit = false
		-- Returning to the hub opens the picker (not after a race: you are queued for the next one)
		task.delay(0.6, function()
			if
				inHub()
				and not controllers.Race.isQueued()
				and not controllers.Race.inRace()
				and not panelOpen()
			then
				HubClient.openModes()
			end
		end)
	else
		HubHud.close("modes")
	end
	HubHud.close("board")
	updateButtons()
end

-- Driving into a stall
local function onZone(id: string)
	if id == "race" then
		if not controllers.Race.isQueued() then
			controllers.Race.join()
			TracksHud.toast("Joined the quick race! It starts when another racer joins.", 3)
		end
	elseif id == "garage" then
		controllers.Shop.open("garage")
	elseif id == "shop" then
		controllers.Shop.open("shop")
	elseif id == "builder" then
		controllers.Builder.onBuildButton()
	else
		-- The TRACKS, BUMPER BRAWL and HIGHWAY HAVOC gates
		HubClient.openModes()
	end
end

local function checkZones()
	if not inHub() then
		return
	end
	local chassis = controllers.Vehicle.getChassis()
	if chassis == nil then
		return
	end
	local o = cfg.origin
	local p = chassis.Position - Vector3.new(o[1], o[2], o[3])
	local now = os.clock()
	for _, zone in cfg.zones do
		local dx = math.abs(p.X - zone.pos[1])
		local dz = math.abs(p.Z - zone.pos[3])
		local isInside = dx <= zone.size[1] / 2 and dz <= zone.size[2] / 2 and p.Y < 20
		if isInside and not inside[zone.id] then
			inside[zone.id] = true
			if now - (leftAt[zone.id] or 0) >= cfg.zoneCooldown and not panelOpen() then
				onZone(zone.id)
			end
		elseif not isInside and inside[zone.id] then
			inside[zone.id] = nil
			leftAt[zone.id] = now
		end
	end
end

function HubClient.init(all)
	controllers = all
end

function HubClient.start()
	LocalPlayer:GetAttributeChangedSignal("MapId"):Connect(onMapChanged)
	controllers.Profile.Changed:Connect(function(_, previous)
		if previous == nil then
			playSeconds()
			if inHub() then
				onMapChanged()
			end
		end
		updateButtons()
	end)
	Net.listen("Party.State", function(state)
		if type(state) ~= "table" then
			return
		end
		party = { leader = state.leader, members = state.members or {} }
		invited = {}
		if HubHud.isOpen("party") then
			openParty()
		end
		if HubHud.isOpen("modes") then
			HubClient.openModes()
		end
	end)
	Net.listen("Party.Invited", function(info)
		if type(info) ~= "table" or type(info.from) ~= "number" then
			return
		end
		HubHud.invite(gui(), tostring(info.name), info.expires or 60, function()
			Net.send("Party.Join", info.from)
		end)
	end)
	Net.listen("Board.Data", function(data)
		if
			type(data) == "table"
			and data.mapId == board.mapId
			and data.tab == board.tab
			and HubHud.isOpen("board")
		then
			drawBoard(data)
		end
	end)
	Net.listen("Round.State", function()
		task.defer(updateButtons)
	end)
	Players.PlayerRemoving:Connect(function(player)
		friendCache[player.UserId] = nil
		invited[player.UserId] = nil
	end)
	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		if clock >= 0.2 then
			clock = 0
			checkZones()
			updateButtons()
		end
	end)
	onMapChanged()
end

return HubClient
