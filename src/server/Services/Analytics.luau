-- Analytics: the spec's custom events and funnels through Roblox's AnalyticsService (spec: Analytics and
-- KPIs), so the Creator Dashboard shows them with no outside service. Roblox batches the sends.
-- * Analytics.event(player, name, value, a?, b?, c?): one custom event with up to 3 text fields
--   (CustomField01 to 03). Never throws.
-- * Funnels: Onboarding (EconomyService.funnel), Builder (EconomyService.builderFunnel), and here
--   "Mode entry" (1 hub view, 2 mode card tap, 3 round start, 4 round end, 5 requeue) and "Purchase"
--   (1 shop open, 2 item view, 3 buy tap, 4 success). A Mode entry crosses places, so its funnel session
--   id is saved in the profile (flags.entryId) and goes with the player to the mode place.
-- * Facts only the device knows (a huge crash, perf samples, a clip share, opening the shop or the mode
--   picker, viewing an item) arrive on Analytics.Client, rate-limited and checked against a short list.
-- * anti_cheat: logged at most once a minute per player and rule.
-- * Stages and quits (the studio-wide FunnelKit, stages in Shared.FunnelDef): the Progress and Returns
--   funnels, session_start (the stage players are at), stage_reached, and session_end /
--   first_session_end (stage, activity at quit and how long they were in it, quit reason, length).
--   A hop between our places (TeleportHub) is one session. Checked every 5 s per player.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local FunnelDef = require(Shared.FunnelDef)
local FunnelKit = require(Shared.FunnelKit)
local Net = require(Shared.Net)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)

local Analytics = {}

Analytics.MODE = { hubView = 1, cardTap = 2, roundStart = 3, roundEnd = 4, requeue = 5 }
Analytics.PURCHASE = { shopOpen = 1, itemView = 2, buyTap = 3, success = 4 }

local MODE_NAMES = { "Hub view", "Mode card tap", "Round start", "Round end", "Requeue" }
local PURCHASE_NAMES = { "Shop open", "Item view", "Buy tap", "Success" }

local service: AnalyticsService? = nil
local purchaseSessions: { [Player]: string } = {}
local cheatLogged: { [Player]: { [string]: number } } = {}

local function analytics(): AnalyticsService?
	if service == nil then
		local ok, s = pcall(function()
			return game:GetService("AnalyticsService")
		end)
		service = if ok then s else nil
	end
	return service
end

local function field(key: Enum.AnalyticsCustomFieldKeys): string
	return key.Name
end

-- AnalyticsService refuses values with a comma or quotes ("Pip's Hill"): drop them, keep 50 chars
local function clean(value: string): string
	return string.sub((string.gsub(value, "[,\"']", "")), 1, 50)
end

function Analytics.event(player: Player, name: string, value: number?, a: string?, b: string?, c: string?)
	local s = analytics()
	if s == nil or player.Parent ~= Players then
		return
	end
	local fields: { [string]: string } = {}
	if a then
		fields[field(Enum.AnalyticsCustomFieldKeys.CustomField01)] = clean(a)
	end
	if b then
		fields[field(Enum.AnalyticsCustomFieldKeys.CustomField02)] = clean(b)
	end
	if c then
		fields[field(Enum.AnalyticsCustomFieldKeys.CustomField03)] = clean(c)
	end
	pcall(function()
		(s :: AnalyticsService):LogCustomEvent(player, clean(name), value or 1, fields)
	end)
end

local function funnelStep(player: Player, funnel: string, session: string, step: number, name: string)
	local s = analytics()
	if s == nil then
		return
	end
	pcall(function()
		(s :: AnalyticsService):LogFunnelStepEvent(player, clean(funnel), session, step, clean(name))
	end)
end

-- The shared FunnelKit (stages, returns, quits). Events only send from published games, so Studio
-- prints them to the Output instead (the Studio test list checks them there).
local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}
local funnels = FunnelKit.new(FunnelDef, {
	funnel = function(player: Player, funnel: string, session: string, step: number, name: string)
		if RunService:IsStudio() then
			print(string.format("[Funnel] %s %s step %d %s", player.Name, funnel, step, name))
		end
		funnelStep(player, funnel, session, step, name)
	end,
	custom = function(player: Player, name: string, value: number, fields: { string })
		if RunService:IsStudio() then
			print(
				string.format("[Funnel] %s %s %d %s", player.Name, name, value, table.concat(fields, " | "))
			)
		end
		local s = analytics()
		if s == nil then
			return
		end
		local named: { [string]: string } = {}
		for i, text in fields do
			named[FIELD_KEYS[i]] = text
		end
		pcall(function()
			(s :: AnalyticsService):LogCustomEvent(player, name, value, named)
		end)
	end,
}, os.time)
Analytics.funnels = funnels
local idleAt: { [Player]: number } = {} -- the last Player.Idled report from the device
local IDLE_WINDOW = 150 -- a quit this soon after an idle report is an idle quit (Idled fires every ~2 min)

-- A teleport to another of our places is about to start (TeleportHub): not a quit
function Analytics.hop(player: Player)
	funnels:hop(player)
end

-- The teleport failed for good: the player stays here
function Analytics.hopFailed(player: Player)
	funnels:hopFailed(player)
end

-- What the player is doing, for the quit analytics: the builder, a track (starter maps by id), a mode
local function activityOf(player: Player): string
	local Place = require(Shared.Place) :: any
	local role = Place.role()
	if role == "Brawl" then
		return "Brawl"
	elseif role == "Highway" then
		return "Highway"
	end
	local BuilderService = require(Services.BuilderService) :: any
	if BuilderService.buildingSlot(player) ~= nil then
		return "Builder"
	end
	local TracksService = require(Services.TracksService) :: any
	local mapId = TracksService.currentMap(player)
	if mapId == nil then
		return "Hub"
	end
	local StarterMaps = require(Shared.StarterMaps) :: any
	return if StarterMaps.byId[mapId] then "Track " .. mapId else "Player map"
end

-- Roblox's exit reason (Enum.PlayerExitReason, 2025) and the device's idle reports, as a quit reason
local function quitReason(player: Player, exitReason: any?): string
	local name = if typeof(exitReason) == "EnumItem" then (exitReason :: EnumItem).Name else ""
	if name == "CreatorKick" then
		return "kicked"
	elseif name == "PlatformKick" then
		return "kicked_roblox"
	end
	local idle = idleAt[player]
	if idle and os.clock() - idle <= IDLE_WINDOW then
		return "idle"
	end
	return "left"
end

-- Mode entry: a hub view starts a new funnel session; the later steps (in any place) reuse it
function Analytics.modeStep(player: Player, step: number)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local flags = profile.flags
	if step == Analytics.MODE.hubView or flags.entryId == nil or flags.entryId == "" then
		flags.entryId = HttpService:GenerateGUID(false)
	end
	funnelStep(player, "Mode entry", flags.entryId, step, MODE_NAMES[step] or tostring(step))
end

-- Purchase: a shop open starts a new funnel session
function Analytics.purchaseStep(player: Player, step: number)
	if step == Analytics.PURCHASE.shopOpen or purchaseSessions[player] == nil then
		purchaseSessions[player] = HttpService:GenerateGUID(false)
	end
	funnelStep(player, "Purchase", purchaseSessions[player], step, PURCHASE_NAMES[step] or tostring(step))
end

-- A server check turned something down (once a minute per player and rule)
function Analytics.cheat(player: Player, rule: string)
	local logged = cheatLogged[player]
	if logged == nil then
		logged = {}
		cheatLogged[player] = logged
	end
	local t = os.clock()
	if t - (logged[rule] or -math.huge) < 60 then
		return
	end
	logged[rule] = t
	Analytics.event(player, "anti_cheat", 1, rule)
end

local function mode(): string
	return tostring(workspace:GetAttribute("Mode") or "Tracks")
end

local function onClient(player: Player, name: string, value: number, a: string, b: string)
	if name == "crash_huge" then
		Analytics.event(player, "crash_huge", math.floor(value), mode(), a)
	elseif name == "perf_sample" then
		-- value: average fps; a: "low fps / memory MB"; b: "graphics preset / device class"
		Analytics.event(player, "perf_sample", math.floor(value), a, b, mode())
	elseif name == "clip_share" then
		Analytics.event(player, "clip_share", 1, mode(), a)
	elseif name == "shop_open" then
		Analytics.purchaseStep(player, Analytics.PURCHASE.shopOpen)
		EconomyService.funnel(player, 7, "First shop view")
	elseif name == "item_view" then
		Analytics.purchaseStep(player, Analytics.PURCHASE.itemView)
	elseif name == "hub_view" then
		Analytics.modeStep(player, Analytics.MODE.hubView)
		EconomyService.funnel(player, 8, "Hub picker")
	elseif name == "idle" then
		idleAt[player] = os.clock()
	end
end

-- The settings the spec tracks (graphics, dents, steering assist)
local TRACKED_SETTINGS = { graphics = true, dents = true, steerAssist = true }

function Analytics.init()
	Net.on("Analytics.Client", onClient)
	DataService.SettingChanged:Connect(function(player: Player, key: string, value: any)
		if TRACKED_SETTINGS[key] then
			Analytics.event(player, "setting_change", 1, key, tostring(value))
		end
	end)
	-- Explosions: the car's damage state says it blew up (once per car)
	local VehicleService = require(Services.VehicleService) :: any
	local DamageModel = require(Shared.DamageModel)
	local exploded: { [Player]: Instance } = {}
	VehicleService.DamageChanged:Connect(function(player: Player, state: buffer)
		local decoded = DamageModel.decode(state)
		if decoded == nil or bit32.band(decoded.flags, DamageModel.FLAG_EXPLODED) == 0 then
			return
		end
		local model = VehicleService.getVehicle(player)
		if model == nil or exploded[player] == model then
			return
		end
		exploded[player] = model
		Analytics.event(player, "explosion", 1, mode(), "crash")
	end)
	-- Stages and quits (FunnelKit): join on load, a check every 5 s, the quit before the last save
	DataService.Loaded:Connect(function(player: Player, profile: { [string]: any })
		profile.funnel = FunnelKit.fill(profile.funnel)
		funnels:join(player, profile.funnel, profile)
	end)
	DataService.Reset:Connect(function(player: Player, profile: { [string]: any })
		funnels:join(player, profile.funnel, profile) -- a dev reset: a first-time player again
	end)
	DataService.Leaving:Connect(function(player: Player, _profile: any, exitReason: any?)
		funnels:leave(player, quitReason(player, exitReason))
		idleAt[player] = nil
	end)
	game:BindToClose(function()
		funnels:shutdown()
	end)
	task.spawn(function()
		while true do
			task.wait(5)
			for _, player in Players:GetPlayers() do
				local profile = DataService.get(player)
				if profile and not funnels:isTracking(player) and not funnels.closing then
					-- loaded before Analytics.init connected (Studio's first player can be that quick)
					profile.funnel = FunnelKit.fill(profile.funnel)
					funnels:join(player, profile.funnel, profile)
				end
				if profile and funnels:isTracking(player) then
					local ok, activity = pcall(activityOf, player)
					funnels:activity(player, if ok then activity else "Unknown")
					funnels:check(player, profile)
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		purchaseSessions[player] = nil
		cheatLogged[player] = nil
		exploded[player] = nil
	end)
end

return Analytics
