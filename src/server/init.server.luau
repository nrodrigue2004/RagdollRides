-- Server entry point for the Tumble Park place (milestone 1: test track).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local Services = script:WaitForChild("Services")
local CollisionGroups = require(Services.CollisionGroups)
local TestTrack = require(Services.TestTrack)
local VehicleService = require(Services.VehicleService)

workspace.Gravity = Config.World.gravity
workspace:SetAttribute("Mode", "TestTrack")
workspace:SetAttribute("ConfigVersion", Config.Version)

CollisionGroups.init()
Net.initServer()
TestTrack.build()
VehicleService.init()

print(string.format("[RagdollRides] server ready (%s)", Config.Version))
