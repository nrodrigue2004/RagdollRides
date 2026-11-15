-- Server entry point for Ragdoll Rides. One codebase runs every place (Shared/Place):
-- * Tumble Park, the start place: Tracks, the map builder, browsing and moderating player maps, the
--   hub, quick races, parties and map leaderboards.
-- * Cinder Cove (Bumper Brawl, casual and ranked): the Brawl rounds.
-- * Sunny Pass (Highway Havoc, co-op and versus): the Highway runs and their boards.
-- All have saves, the shop and garage, Robux purchases, quests and streak, parties and teleports.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Place = require(Shared.Place)

local Services = script:WaitForChild("Services")
local BoardService = require(Services.BoardService)
local BoardStore = require(Services.BoardStore)
local BrawlService = require(Services.BrawlService)
local BrowseService = require(Services.BrowseService)
local BuilderService = require(Services.BuilderService)
local CollisionGroups = require(Services.CollisionGroups)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local HighwayService = require(Services.HighwayService)
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
DataService.init()
EconomyService.init()

local role = Place.role()
if role == "Brawl" then
	workspace:SetAttribute("PlaceRole", "Brawl")
	ShopService.init() -- coin shop, garage, mastery, rebirth
	PurchaseService.init() -- Robux passes and products, one receipt handler
	PartyService.init() -- parties of friends in this server
	TeleportHub.init() -- back to Tumble Park
	QuestService.init() -- quests, chest, login streak, gifts
	BrawlService.init() -- the pen, arenas, rounds, bots and practice (sets workspace Mode "Brawl")
	VehicleService.init()
elseif role == "Highway" then
	workspace:SetAttribute("PlaceRole", "Highway")
	ShopService.init()
	PurchaseService.init()
	PartyService.init()
	TeleportHub.init()
	QuestService.init()
	BoardStore.init() -- the Highway boards
	HighwayService.init() -- the seeded road, runs, hit checks, score and pay (sets workspace Mode "Highway")
	VehicleService.init()
else
	TestTrack.build() -- kept for the dev panel's feel and crash tests (Studio and admins: Map.Go "test_track")
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
	TeleportHub.init() -- hops to mode places
	BoardStore.init()
	BoardService.init() -- map leaderboards
	QuestService.init() -- quests, chest, login streak, gifts
	VehicleService.init()
end

print(string.format("[RagdollRides] %s server ready (%s)", role, Config.Version))
