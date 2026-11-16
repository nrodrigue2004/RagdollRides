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

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
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
	Players.PlayerRemoving:Connect(function(player: Player)
		purchaseSessions[player] = nil
		cheatLogged[player] = nil
		exploded[player] = nil
	end)
end

return Analytics
