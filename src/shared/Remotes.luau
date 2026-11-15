--!strict
-- Remotes: the single registry of every remote (spec: Scripts and remote events > Remotes).
-- Net creates them from this table, checks every argument against `schema` and rate-limits each player
-- with a token bucket (`rate` per second, `burst` max). Server-to-client remotes have no schema.
-- `since` is the milestone that first uses the remote; later ones are registered now so names and limits
-- are fixed in one place.

export type RemoteDef = {
	dir: string, -- "C2S", "S2C" or "C2S2C" (client sends, server checks and relays)
	unreliable: boolean?,
	schema: { any }?,
	rate: number?,
	burst: number?,
	since: string,
}

local POSE_BASE = 7 -- steer, throttle, flags, 4 compressions
local POSE_RAGDOLL = POSE_BASE + 6 * 20 -- plus 6 rider transforms

local Remotes: { [string]: RemoteDef } = {
	-- Milestone 1
	["Vehicle.Equip"] = {
		dir = "C2S",
		schema = { { t = "string", max = 32 } },
		rate = 0.5,
		burst = 1,
		since = "1",
	},
	["Vehicle.Pose"] = {
		dir = "C2S2C",
		unreliable = true,
		schema = { { t = "buffer", len = { POSE_BASE, POSE_RAGDOLL } } },
		rate = 12,
		burst = 6,
		since = "1",
	},
	["Vehicle.Spawned"] = { dir = "S2C", since = "1" },

	-- Milestone 1b
	["Damage.State"] = {
		dir = "C2S2C",
		unreliable = true,
		schema = { { t = "buffer", len = { 10 } } },
		rate = 4,
		burst = 4,
		since = "1b",
	},
	["Impact.Report"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 0 }, { t = "number", min = 0, max = 1000 }, { t = "Vector3" } },
		rate = 8,
		burst = 8,
		since = "1b",
	},

	-- Milestone 2
	["Run.Start"] = { dir = "C2S", schema = { { t = "string", max = 40 } }, rate = 2, burst = 2, since = "2" },
	["Run.Checkpoint"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "integer", min = 1, max = 10 }, { t = "number" } },
		rate = 2,
		burst = 2,
		since = "2",
	},
	["Run.Finish"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "number" } },
		rate = 2,
		burst = 2,
		since = "2",
	},
	["Run.Result"] = { dir = "S2C", since = "2" },
	["Settings.Save"] = { dir = "C2S", schema = { { t = "any" } }, rate = 0.2, burst = 1, since = "2" },

	-- Milestone 3 and 4
	["Map.Publish"] = {
		dir = "C2S",
		schema = { { t = "buffer", maxLen = 4096 }, { t = "buffer", len = { 3 } } },
		rate = 1 / 600,
		burst = 1,
		since = "3",
	},
	["Map.Rate"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "integer", min = 1, max = 5 } },
		rate = 1,
		burst = 1,
		since = "4",
	},
	["Map.Report"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "string", oneOf = { "Shape", "Impossible", "Spam" } } },
		rate = 0.2,
		burst = 1,
		since = "4",
	},
	["Map.Browse"] = {
		dir = "C2S",
		schema = { { t = "string", max = 16 }, { t = "integer", min = 1, max = 50 } },
		rate = 1,
		burst = 2,
		since = "4",
	},

	-- Milestone 5
	["Shop.Buy"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "string", oneOf = { "coins", "robux" } } },
		rate = 1,
		burst = 2,
		since = "5",
	},
	["Quest.Claim"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 } },
		rate = 1,
		burst = 3,
		since = "5",
	},
	["Streak.Claim"] = { dir = "C2S", schema = {}, rate = 1, burst = 1, since = "5" },
	["Gift.Send"] = { dir = "C2S", schema = { { t = "integer", min = 1 } }, rate = 1, burst = 1, since = "5" },
	["Rebirth.Confirm"] = { dir = "C2S", schema = {}, rate = 1, burst = 1, since = "5" },

	-- Milestone 6
	["Party.Invite"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1 } },
		rate = 0.5,
		burst = 1,
		since = "6",
	},
	["Party.Join"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1 } },
		rate = 0.5,
		burst = 1,
		since = "6",
	},
	["Cheer"] = { dir = "C2S2C", schema = { { t = "integer", min = 1 } }, rate = 0.5, burst = 1, since = "7" },

	-- Milestone 7
	["Brawl.Hit"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1 }, { t = "number", min = 0, max = 300 }, { t = "Vector3" } },
		rate = 6,
		burst = 6,
		since = "7",
	},
	["Brawl.Result"] = { dir = "S2C", since = "7" },
	["Brawl.Powerup"] = { dir = "C2S", schema = {}, rate = 1, burst = 1, since = "7" },

	-- Milestone 8
	["Highway.Hit"] = {
		dir = "C2S",
		schema = {
			{ t = "integer", min = 0, max = 4095 },
			{ t = "number", min = 0, max = 1000 },
			{ t = "integer" },
		},
		rate = 12,
		burst = 12,
		since = "8",
	},
	["Highway.Seed"] = { dir = "S2C", since = "8" },
	["Highway.Score"] = { dir = "S2C", since = "8" },
	["Bone.Break"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1, max = 6 }, { t = "number", min = 0, max = 1000 } },
		rate = 1.5,
		burst = 3,
		since = "8",
	},
}

return Remotes
