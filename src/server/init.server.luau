-- Server entry point for Ragdoll Rides (milestone 3: Tracks on the starter maps and the map builder).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Services = script:WaitForChild("Services")
local BuilderService = require(Services.BuilderService)
local CollisionGroups = require(Services.CollisionGroups)
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MapService = require(Services.MapService)
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
VehicleService.init()

print(string.format("[RagdollRides] server ready (%s)", Config.Version))
