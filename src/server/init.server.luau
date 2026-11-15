-- Server entry point for Ragdoll Rides (milestone 6: Tracks, the map builder, browsing and
-- moderating player maps, the shop, passes, quests and streak, and the hub, quick races, parties and
-- map leaderboards).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Services = script:WaitForChild("Services")
local BoardService = require(Services.BoardService)
local BrowseService = require(Services.BrowseService)
local BuilderService = require(Services.BuilderService)
local CollisionGroups = require(Services.CollisionGroups)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local HubService = require(Services.HubService)
local MapPlayService = require(Services.MapPlayService)
local MapService = require(Services.MapService)
local ModerationService = require(Services.ModerationService)
local PartyService = require(Services.PartyService)
local PurchaseService = require(Services.PurchaseService)
local QuestService = require(Services.QuestService)
local RaceService = require(Services.RaceService)
local ShopService = require(Services.ShopService)
local TeleportHub = require(Services.TeleportHub)
local TestTrack = require(Services.TestTrack)
local TracksService = require(Services.TracksService)
local VehicleService = require(Services.VehicleService)

workspace.Gravity = Config.World.gravity
workspace:SetAttribute("ConfigVersion", Config.Version)

CollisionGroups.init()
Net.initServer()
TestTrack.build() -- kept for the dev panel's feel and crash tests (Studio and admins: Map.Go "test_track")
DataService.init()
EconomyService.init()
TracksService.init() -- sets workspace Mode to "Tracks" and decides where each player spawns
BuilderService.init() -- plots, drafts and TEST runs
MapService.init() -- publishing
MapPlayService.init() -- playing published maps, plays, ratings, royalties
ModerationService.init() -- reports, hides, strikes, bans, admin tools
BrowseService.init() -- the browse tabs
ShopService.init() -- coin shop, garage, mastery, rebirth
PurchaseService.init() -- Robux passes and products, one receipt handler
PartyService.init() -- parties of friends in this server
RaceService.init() -- quick races on the round state machine
HubService.init() -- the Tumble Park plaza and live player counts
TeleportHub.init() -- hops to mode places (milestones 7 and 8)
BoardService.init() -- map leaderboards
QuestService.init() -- quests, chest, login streak, gifts
VehicleService.init()

print(string.format("[RagdollRides] server ready (%s)", Config.Version))
