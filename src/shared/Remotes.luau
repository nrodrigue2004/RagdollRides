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
		-- Clients send at most 4 per second; the server allows a little headroom for explosion and repair
		-- sends so a legit burst never counts toward the kick limit.
		rate = 5,
		burst = 6,
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
	-- mapId, the driver's timer, trail coins picked up (the server clamps it to the map's count)
	["Run.Finish"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "number" }, { t = "integer", min = 0, max = 200 } },
		rate = 2,
		burst = 2,
		since = "2",
	},
	["Run.Result"] = { dir = "S2C", since = "2" },
	["Run.Ghost"] = { dir = "S2C", since = "2" }, -- mapId, base64 ghost or nil
	["Run.Reset"] = { dir = "S2C", since = "2" }, -- the speed check put the car back to its last checkpoint
	["Map.Go"] = { dir = "C2S", schema = { { t = "string", max = 40 } }, rate = 0.5, burst = 2, since = "2" },
	["Profile.Data"] = { dir = "S2C", since = "2" }, -- the client's view of its own profile, on every change
	["Notice"] = { dir = "S2C", since = "2" }, -- a preset message key (our text only, never player text)
	-- Settings: the client sends at most once per 5 s; the burst covers a save right before leaving
	["Settings.Save"] = { dir = "C2S", schema = { { t = "any" } }, rate = 0.2, burst = 2, since = "2" },
	-- Studio and admins only: start over as a first-time player (to test onboarding)
	["Dev.ResetProfile"] = { dir = "C2S", schema = {}, rate = 0.2, burst = 1, since = "2" },

	-- Milestone 3: the map builder. Slots are 1..15; buffers are MapCodec maps (250 pieces = 2,755 bytes).
	-- Map.Build: open the builder on a draft slot (0 leaves it). Map.Drafts answers with every slot.
	["Map.Build"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 0, max = 15 } },
		rate = 1,
		burst = 3,
		since = "3",
	},
	["Map.RequestDrafts"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 2, since = "3" },
	["Map.Drafts"] = { dir = "S2C", since = "3" },
	-- Autosave every 30 s, on exit and on Save; the burst covers a save right before TEST or Publish
	["Map.SaveDraft"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1, max = 15 }, { t = "buffer", maxLen = 4096 } },
		rate = 0.5,
		burst = 3,
		since = "3",
	},
	-- TEST from the start gate: the server times it like a run (it proves the map can be finished)
	["Map.Test"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1, max = 15 }, { t = "buffer", maxLen = 4096 } },
		rate = 0.5,
		burst = 3,
		since = "3",
	},
	["Map.TestReady"] = { dir = "S2C", since = "3" }, -- slot, ok, reason key: the car is on the plot
	-- Publish: slot and the map (its pieces must match the TEST; name ids, tags and flags are in its header).
	-- The spec's 1 per 10 minutes is the server's publish cooldown; this limit only stops spam.
	["Map.Publish"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1, max = 15 }, { t = "buffer", maxLen = 4096 } },
		rate = 0.2,
		burst = 2,
		since = "3",
	},
	["Map.Published"] = { dir = "S2C", since = "3" }, -- { ok, reason key, mapId, name, wait }

	-- Milestone 4
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
	-- Map.Browse: a tab and a page; Map.List answers with up to 9 cards (spec: Browse)
	["Map.Browse"] = {
		dir = "C2S",
		schema = {
			{ t = "string", oneOf = { "featured", "popular", "newest", "friends", "mine", "review" } },
			{ t = "integer", min = 1, max = 50 },
		},
		rate = 1,
		burst = 3,
		since = "4",
	},
	["Map.List"] = { dir = "S2C", since = "4" }, -- { tab, page, pages, cards }
	-- Map.Play: load a published map and drive it; Map.Data sends its pieces first
	["Map.Play"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 } },
		rate = 0.5,
		burst = 2,
		since = "4",
	},
	["Map.Data"] = { dir = "S2C", since = "4" }, -- { mapId, data, offset, creatorMs, name, ... }
	["Map.Royalty"] = { dir = "S2C", since = "4" }, -- coins your maps earned
	["Map.Reported"] = { dir = "S2C", since = "4" }, -- mapId, ok, reason key
	-- Admin.Map: moderation from the browse card (DataService.isAdmin only)
	["Admin.Map"] = {
		dir = "C2S",
		schema = {
			{ t = "string", max = 40 },
			{
				t = "string",
				oneOf = { "feature", "unfeature", "hide", "unhide", "ban7", "ban30", "banForever", "unban" },
			},
		},
		rate = 1,
		burst = 3,
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
