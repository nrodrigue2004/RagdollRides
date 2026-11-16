--!strict
-- FunnelDef: Ragdoll Rides' stage ladder for the shared FunnelKit (the Progress funnel, the "stage" on
-- session_start and session_end). Each stage counts only when every stage before it is reached too, so
-- the ladder reads like pacing: rounds played (any mode) and cars bought, then rebirths. After a rebirth
-- the garage resets, so the car stages also pass for anyone who has rebirthed.
-- The first-session steps stay in the Onboarding funnel (EconomyService.funnel); this ladder is the
-- whole lifetime. Change names freely, but only ever ADD stages at the end once the game is live: the
-- dashboard keys steps by number.

local Config = if script then require(script.Parent.Config) else (require :: any)("./Config")

local FunnelDef = {}

-- Rounds of any mode: track finishes, quick races, Brawl rounds and Highway runs
function FunnelDef.rounds(profile: any): number
	local stats = profile.stats or {}
	return (stats.finishes or 0) + (stats.races or 0) + (stats.brawlRounds or 0) + (stats.highwayRuns or 0)
end

-- Launch cars owned (all 6 = rebirth ready); a rebirth counts as all 6
function FunnelDef.cars(profile: any): number
	if (profile.rebirths or 0) > 0 then
		return #Config.TierOneVehicles
	end
	local owned = 0
	for _, id in Config.TierOneVehicles do
		local vehicle = profile.vehicles and profile.vehicles[id]
		if vehicle and vehicle.owned then
			owned += 1
		end
	end
	return owned
end

local function rounds(n: number)
	return function(profile: any): boolean
		return FunnelDef.rounds(profile) >= n
	end
end

local function cars(n: number)
	return function(profile: any): boolean
		return FunnelDef.cars(profile) >= n
	end
end

local function rebirths(n: number)
	return function(profile: any): boolean
		return (profile.rebirths or 0) >= n
	end
end

FunnelDef.stages = {
	{
		name = "Joined",
		reached = function()
			return true
		end,
	},
	{ name = "First round", reached = rounds(1) },
	{ name = "5 rounds", reached = rounds(5) },
	{ name = "Second car", reached = cars(2) },
	{ name = "15 rounds", reached = rounds(15) },
	{ name = "Third car", reached = cars(3) },
	{ name = "40 rounds", reached = rounds(40) },
	{ name = "All 6 cars", reached = cars(6) },
	{ name = "First rebirth", reached = rebirths(1) },
	{ name = "100 rounds", reached = rounds(100) },
	{ name = "Third rebirth", reached = rebirths(3) },
}

-- Ragdoll Rides hops between Tumble Park, Cinder Cove and Sunny Pass: a teleport takes a few seconds
FunnelDef.hopSeconds = 180
FunnelDef.returns = { 1, 2, 3, 5, 10, 20 }

return FunnelDef
