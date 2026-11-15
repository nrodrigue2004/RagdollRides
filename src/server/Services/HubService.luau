-- HubService: the Tumble Park hub (spec: Hub and menus > Hub; Core loop; World and places).
-- * Builds the plaza once: a foam-walled square to drive around, with a stall for each screen
--   (Config.Hub.zones: the TRACKS, BUMPER BRAWL and HIGHWAY HAVOC gates, the race pad, garage door,
--   shop stall and builder workshop), a couple of kicker ramps and the Tumble Tower landmark. Driving
--   into a stall opens its screen on the client (HubClient); the server only builds and counts.
-- * Returning players spawn here (TracksService: map id "hub"); first-time players start on Pip's Hill.
-- * Live player counts: every server writes its counts to a MemoryStore sorted map every 30 s (expires
--   after 90 s) and sums every server's; the totals go on workspace attributes LiveTracks, LiveRace,
--   LiveBrawl and LiveHighway for the mode cards. Brawl and Highway places write theirs the same way.
-- * Hub.Mode(mode, chip): a mode card's PLAY for Bumper Brawl or Highway Havoc (TeleportHub). Until
--   those places exist it answers "modeSoon".
-- PLACEHOLDER ART: the plaza, stalls, signs, ramps and tower are plain foam-coloured parts.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Services = script.Parent
local TeleportHub = require(Services.TeleportHub)
local TracksService = require(Services.TracksService)

local HubService = {}

-- How many players this server has in a quick race (RaceService sets it)
HubService.raceCount = nil :: (() -> number)?

local cfg = Config.Hub
local FONT = Enum.Font.FredokaOne
local FOAM = Color3.fromRGB(255, 244, 222)
local FLOOR = Color3.fromRGB(150, 205, 240)
local INK = Color3.fromRGB(35, 35, 45)

local folder: Model

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = collide ~= false
	p.CanTouch = false
	p.Parent = folder
	return p
end

local function sign(target: BasePart, face: Enum.NormalId, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = FONT
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = INK
	label.Parent = gui
end

local function at(x: number, y: number, z: number): CFrame
	local o = cfg.origin
	return CFrame.new(o[1] + x, o[2] + y, o[3] + z)
end

local function build()
	folder = Instance.new("Model")
	folder.Name = "TumblePark"
	folder.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local size = cfg.size
	-- Ground and plaza floor (top at the origin's height)
	local ground =
		part("Ground", Vector3.new(size + 400, 4, size + 400), at(0, -3.2, 0), Color3.fromRGB(120, 200, 90))
	ground.Material = Enum.Material.Grass
	part("Floor", Vector3.new(size, 2, size), at(0, -1, 0), FLOOR)
	-- Foam walls round the edge
	local half = size / 2
	for _, side in
		{ { 0, -half, size, 2 }, { 0, half, size, 2 }, { -half, 0, 2, size }, { half, 0, 2, size } }
	do
		part("Wall", Vector3.new(side[3] + 2, 6, side[4] + 2), at(side[1], 3, side[2]), FOAM)
	end
	-- Stalls: a coloured pad to drive onto, under an arch with the stall's name
	for _, zone in cfg.zones do
		local color = Config.color3(zone.color)
		local x, z = zone.pos[1], zone.pos[3]
		local w, d = zone.size[1], zone.size[2]
		local pad = part("Pad_" .. zone.id, Vector3.new(w, 0.3, d), at(x, 0.15, z), color, false)
		pad.CanQuery = false
		pad:SetAttribute("HubZone", zone.id)
		for _, s in { -1, 1 } do
			part("Post", Vector3.new(2, 14, 2), at(x + s * (w / 2 + 1), 7, z), FOAM)
		end
		local beam = part("Sign_" .. zone.id, Vector3.new(w + 4, 5, 1.5), at(x, 16.5, z), color)
		sign(beam, Enum.NormalId.Front, zone.label)
		sign(beam, Enum.NormalId.Back, zone.label)
	end
	-- Kicker ramps for fun between stalls
	for _, ramp in { { -30, 40, 0 }, { 40, 30, 180 }, { 0, -40, 90 } } do
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Kicker"
		wedge.Anchored = true
		wedge.Size = Vector3.new(16, 3, 14)
		wedge.CFrame = at(ramp[1], 1.5, ramp[2]) * CFrame.Angles(0, math.rad(ramp[3]), 0)
		wedge.Color = Color3.fromRGB(255, 170, 60)
		wedge.Material = Enum.Material.SmoothPlastic
		wedge.CanTouch = false
		wedge.Parent = folder
	end
	-- The Tumble Tower: a wobbly stack of foam blocks in the corner (a landmark)
	local tower = at(half - 40, 0, half - 40)
	for level = 0, 7 do
		local block = part(
			"Tower",
			Vector3.new(14 - level, 6, 14 - level),
			tower
				* CFrame.new(math.sin(level) * 1.5, 3 + level * 6, math.cos(level) * 1.5)
				* CFrame.Angles(0, math.rad(level * 17), math.rad((level % 2) * 4 - 2)),
			if level % 2 == 0 then Color3.fromRGB(255, 120, 90) else FOAM
		)
		block.CanCollide = level == 0
	end
	folder.Parent = workspace
end

---------------------------------------------------------------------------
-- Live player counts across every server
---------------------------------------------------------------------------

local function localCounts(): { [string]: number }
	local race = if HubService.raceCount then HubService.raceCount() else 0
	return { tracks = math.max(0, #Players:GetPlayers() - race), race = race }
end

local function publishCounts()
	local key = if game.JobId ~= "" then game.JobId else "studio"
	local totals = localCounts()
	local ok = pcall(function()
		local map = MemoryStoreService:GetSortedMap(cfg.countsStore)
		map:SetAsync(key, localCounts(), cfg.countsExpiry)
		local sum = { tracks = 0, race = 0, brawl = 0, highway = 0 }
		local exclusive: string? = nil
		repeat
			local items = map:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusive)
			for _, item in items do
				if type(item.value) == "table" then
					for name in sum do
						sum[name] += tonumber(item.value[name]) or 0
					end
				end
			end
			exclusive = if #items == 200 then items[#items].key else nil
		until exclusive == nil
		totals = sum
	end)
	if not ok then
		-- No MemoryStore (Studio without API access): this server's own counts
		totals = localCounts()
	end
	workspace:SetAttribute("LiveTracks", totals.tracks or 0)
	workspace:SetAttribute("LiveRace", totals.race or 0)
	workspace:SetAttribute("LiveBrawl", totals.brawl or 0)
	workspace:SetAttribute("LiveHighway", totals.highway or 0)
end

function HubService.init()
	build()
	Net.on("Hub.Mode", function(player: Player, modeName: string, chip: string)
		if TracksService.currentMap(player) ~= TracksService.HUB then
			return
		end
		local ok, reason = TeleportHub.send(player, modeName, chip)
		if not ok and reason then
			Net.fire("Notice", player, reason)
		end
	end)
	task.spawn(function()
		while true do
			publishCounts()
			task.wait(cfg.countsInterval)
		end
	end)
	Players.PlayerAdded:Connect(function()
		task.defer(function()
			-- New arrivals see this server's numbers at once; the next write adds everyone else's
			local mine = localCounts()
			if (workspace:GetAttribute("LiveTracks") or 0) < mine.tracks then
				workspace:SetAttribute("LiveTracks", mine.tracks)
			end
		end)
	end)
end

return HubService
