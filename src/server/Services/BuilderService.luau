-- BuilderService: the map builder's server side (spec: Map builder). The builder itself runs on the
-- player's device (BuilderClient builds its preview with Shared/MapBuilder); the server owns what is
-- saved and what counts:
-- * Plots: each player in the server gets a private build plot (Config.Builder.plotOrigin, spaced
--   plotSpacing apart). Map space is centred on the plot; player attributes PlotIndex and PlotOrigin.
-- * Draft slots: 3 free, 10 with VIP, +1 per Extra Slot product, 15 at most. A draft is a MapCodec buffer
--   saved as base64 in profile.maps.drafts (Map.SaveDraft). Every save is checked by MapRules again, so a
--   modified client can never store more than the limits allow.
-- * TEST: the draft must be playable (1 start, 1 finish). It becomes a map definition on the plot,
--   registered with TracksService, and the car goes to its start gate. A finish from the start gate is a
--   server-timed run: it records the tested pieces and the creator time for this session (MapService
--   needs both to publish). A practice run from a checkpoint never reaches the server.
-- Builder funnel: Opened builder, First piece, 10 pieces, TEST, Finished test (Publish is MapService's).

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local GhostCodec = require(Shared.GhostCodec)
local MapCodec = require(Shared.MapCodec)
local MapRules = require(Shared.MapRules)
local Net = require(Shared.Net)
local PieceCatalog = require(Shared.PieceCatalog)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local TracksService = require(Services.TracksService)

local BuilderService = {}

export type Tested = { slot: number, fingerprint: string, creatorMs: number }

local plots: { [Player]: number } = {}
local building: { [Player]: number } = {} -- the draft slot open in the builder
local tested: { [Player]: Tested } = {} -- the last map finished from its start gate in TEST (session only)
local testMaps: { [Player]: string } = {}

local function base64(b: buffer): string
	return GhostCodec.toBase64(b)
end

function BuilderService.isVip(profile: { [string]: any }): boolean
	return profile.passes.vip == true
end

function BuilderService.maxSlots(profile: { [string]: any }): number
	local cfg = Config.Builder
	local base = if BuilderService.isVip(profile) then cfg.vipDraftSlots else cfg.draftSlots
	return math.min(base + (profile.maps.extraSlots or 0), cfg.maxDraftSlots)
end

function BuilderService.liveLimit(profile: { [string]: any }): number
	return if BuilderService.isVip(profile)
		then Config.Builder.vipLivePublished
		else Config.Builder.livePublished
end

function BuilderService.plotOffset(index: number): { number }
	local cfg = Config.Builder
	return { cfg.plotOrigin[1], cfg.plotOrigin[2], cfg.plotOrigin[3] + (index - 1) * cfg.plotSpacing }
end

local function plotFor(player: Player): number?
	if plots[player] then
		return plots[player]
	end
	local used = {}
	for _, index in plots do
		used[index] = true
	end
	for index = 1, Config.Builder.maxPlots do
		if not used[index] then
			plots[player] = index
			local o = BuilderService.plotOffset(index)
			player:SetAttribute("PlotIndex", index)
			player:SetAttribute("PlotOrigin", Vector3.new(o[1], o[2], o[3]))
			return index
		end
	end
	return nil
end

function BuilderService.getTested(player: Player): Tested?
	return tested[player]
end

function BuilderService.buildingSlot(player: Player): number?
	return building[player]
end

-- A draft from the profile as bytes (nil for an empty slot)
function BuilderService.draftBuffer(profile: { [string]: any }, slot: number): buffer?
	local text = profile.maps.drafts[tostring(slot)]
	if type(text) ~= "string" then
		return nil
	end
	return GhostCodec.fromBase64(text)
end

local function sendDrafts(player: Player)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local slots = {}
	local max = BuilderService.maxSlots(profile)
	local done = tested[player]
	for slot = 1, max do
		local key = tostring(slot)
		local text = profile.maps.drafts[key]
		local count = 0
		local fingerprint = nil
		if type(text) == "string" then
			local b = GhostCodec.fromBase64(text)
			if b then
				count = MapCodec.count(b)
				fingerprint = MapCodec.fingerprint(b, MapCodec.PIECES_FROM)
			end
		end
		table.insert(slots, {
			slot = slot,
			data = if type(text) == "string" then text else nil,
			pieces = count,
			mapId = profile.maps.links[key],
			tested = done ~= nil and done.slot == slot and done.fingerprint == fingerprint,
		})
	end
	Net.fire("Map.Drafts", player, {
		slots = slots,
		maxSlots = max,
		vip = BuilderService.isVip(profile),
		live = #profile.maps.published,
		liveLimit = BuilderService.liveLimit(profile),
		lastPublish = profile.maps.lastPublish or 0,
	})
end
BuilderService.sendDrafts = sendDrafts

-- Decode and check a draft from a client. Returns the map or nil and a reason key.
local function readDraft(
	player: Player,
	slot: number,
	b: buffer,
	playable: boolean
): (MapCodec.MapData?, string?)
	local profile = DataService.get(player)
	if profile == nil then
		return nil, "notLoaded"
	end
	if slot > BuilderService.maxSlots(profile) then
		return nil, "slotLocked"
	end
	local map, why = MapCodec.decode(b)
	if map == nil then
		warn(string.format("[Builder] %s sent a bad map: %s", player.Name, tostring(why)))
		return nil, "invalid"
	end
	local options = { vip = BuilderService.isVip(profile) }
	local ok, reason
	if playable then
		ok, reason = MapRules.checkPlayable(map, options)
	else
		ok, reason = MapRules.checkDraft(map, options)
	end
	if not ok then
		warn(string.format("[Builder] %s draft refused: %s", player.Name, tostring(reason)))
		return nil,
			if reason == "needs a start gate"
				then "needStart"
				elseif reason == "needs a finish arch" then "needFinish"
				else "invalid"
	end
	return map, nil
end

local function storeDraft(player: Player, slot: number, b: buffer, map: MapCodec.MapData)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	profile.maps.drafts[tostring(slot)] = base64(b)
	DataService.changed(player)
	local count = #map.pieces
	if count >= 1 then
		EconomyService.builderFunnel(player, 2, "First piece")
	end
	if count >= 10 then
		EconomyService.builderFunnel(player, 3, "10 pieces")
	end
end

local function clearTestMap(player: Player)
	local id = testMaps[player]
	if id then
		testMaps[player] = nil
		TracksService.unregisterMap(id)
	end
end

local function onBuild(player: Player, slot: number)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	if slot == 0 then
		if building[player] == nil then
			return
		end
		-- Leave the builder: back to the map the player was last on (their home map)
		building[player] = nil
		player:SetAttribute("BuildSlot", nil)
		clearTestMap(player)
		TracksService.enterMap(player, TracksService.homeMapFor(player))
		return
	end
	if slot > BuilderService.maxSlots(profile) or plotFor(player) == nil then
		Net.fire("Notice", player, if plotFor(player) == nil then "plotsFull" else "slotLocked")
		return
	end
	building[player] = slot
	player:SetAttribute("BuildSlot", slot)
	clearTestMap(player)
	TracksService.leaveMap(player)
	EconomyService.builderFunnel(player, 1, "Opened builder")
end

-- Close the builder without moving the car (Map.Play moves it next)
function BuilderService.exitBuild(player: Player)
	if building[player] == nil then
		return
	end
	building[player] = nil
	player:SetAttribute("BuildSlot", nil)
	clearTestMap(player)
end

local function onSaveDraft(player: Player, slot: number, b: buffer)
	if building[player] ~= slot then
		return
	end
	local map = readDraft(player, slot, b, false)
	if map then
		storeDraft(player, slot, b, map)
	end
end

local function onTest(player: Player, slot: number, b: buffer)
	if building[player] ~= slot then
		Net.fire("Map.TestReady", player, slot, false, "notBuilding")
		return
	end
	local map, reason = readDraft(player, slot, b, true)
	if map == nil then
		Net.fire("Map.TestReady", player, slot, false, reason)
		return
	end
	storeDraft(player, slot, b, map)
	local plot = plotFor(player) :: number
	local id = "test_" .. tostring(player.UserId)
	local def = PieceCatalog.toMapDef(map.pieces, {
		id = id,
		name = "TEST",
		offset = BuilderService.plotOffset(plot),
		fullDamage = MapCodec.fullDamage(map),
	}) :: any
	def.testOwner = player.UserId
	def.testSlot = slot
	def.testFingerprint = MapCodec.fingerprint(b, MapCodec.PIECES_FROM)
	testMaps[player] = id
	TracksService.registerMap(def)
	TracksService.enterMap(player, id)
	EconomyService.builderFunnel(player, 4, "TEST")
	Net.fire("Map.TestReady", player, slot, true, nil)
end

-- A finish on a builder map from its start gate (TracksService validated the run on the server clock)
local function onCustomFinish(player: Player, map: any, time: number): { [string]: any }
	if map.testOwner ~= player.UserId then
		return { ok = false, reason = "not your test" }
	end
	tested[player] = {
		slot = map.testSlot,
		fingerprint = map.testFingerprint,
		creatorMs = math.floor(time * 1000 + 0.5),
	}
	EconomyService.builderFunnel(player, 5, "Finished test")
	return { ok = true, test = true, slot = map.testSlot }
end

function BuilderService.init()
	TracksService.customFinish = onCustomFinish
	Net.on("Map.Build", onBuild)
	Net.on("Map.RequestDrafts", sendDrafts)
	Net.on("Map.SaveDraft", onSaveDraft)
	Net.on("Map.Test", onTest)
	Players.PlayerRemoving:Connect(function(player)
		clearTestMap(player)
		plots[player] = nil
		building[player] = nil
		tested[player] = nil
	end)
end

return BuilderService
