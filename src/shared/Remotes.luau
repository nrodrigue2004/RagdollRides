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
				oneOf = {
					"feature",
					"unfeature",
					"hide",
					"confirm",
					"unhide",
					"ban7",
					"ban30",
					"banForever",
					"unban",
				},
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
	["Shop.Result"] = { dir = "S2C", since = "5" }, -- { ok, id, reason key, crate = { item, shiny, duplicate, refund } }
	-- Garage.Equip: vehicle id (or "rider"), slot, item id ("" takes it off)
	["Garage.Equip"] = {
		dir = "C2S",
		schema = {
			{ t = "string", max = 32 },
			{
				t = "string",
				oneOf = {
					"paint",
					"rims",
					"trail",
					"trail2",
					"horn",
					"explosion",
					"decal",
					"part",
					"hat",
					"outfit",
				},
			},
			{ t = "string", max = 40 },
		},
		rate = 4,
		burst = 6,
		since = "5",
	},
	-- Studio only (admins): grant a pass or product without Robux, for testing before the ids exist
	["Dev.Grant"] = {
		dir = "C2S",
		schema = {
			{
				t = "string",
				oneOf = {
					"rider",
					"vip",
					"stunt",
					"explosions",
					"starter",
					"coins_s",
					"coins_m",
					"coins_l",
					"coins_xl",
					"crate",
					"extra_slot",
					"bundle",
				},
			},
		},
		rate = 2,
		burst = 4,
		since = "5",
	},
	-- Shop.Seen: the Starter Pack offer was shown (it is offered once, after the first finish)
	["Shop.Seen"] = {
		dir = "C2S",
		schema = { { t = "string", oneOf = { "starter" } } },
		rate = 0.5,
		burst = 1,
		since = "5",
	},
	["Quest.Done"] = { dir = "S2C", since = "5" }, -- a quest reached its target: { text }
	["Mastery.Up"] = { dir = "S2C", since = "5" }, -- { vehicleId, level, itemId }
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
	["Party.Leave"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 2, since = "6" },
	["Party.State"] = { dir = "S2C", since = "6" }, -- { leader, members = { { userId, name } } } or {}
	["Party.Invited"] = { dir = "S2C", since = "6" }, -- { from, name, expires }
	-- Quick races (the round state machine): join from the hub, leave, skip the results
	["Race.Join"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 2, since = "6" },
	["Race.Leave"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 2, since = "6" },
	["Race.Skip"] = { dir = "C2S", schema = {}, rate = 1, burst = 2, since = "6" },
	["Round.State"] = { dir = "S2C", since = "6" }, -- { id, kind, phase, endsAt, players, map, order, goAt }
	["Race.Result"] = { dir = "S2C", since = "6" }, -- { mapName, places, mine }
	-- Map leaderboards
	["Board.Get"] = {
		dir = "C2S",
		schema = { { t = "string", max = 40 }, { t = "string", oneOf = { "friends", "weekly", "alltime" } } },
		rate = 1,
		burst = 3,
		since = "6",
	},
	["Board.Data"] = { dir = "S2C", since = "6" }, -- { mapId, tab, rows, mine }
	-- A hub mode card's PLAY for a mode in its own place (teleport with the party)
	["Hub.Mode"] = {
		dir = "C2S",
		schema = {
			{ t = "string", oneOf = { "brawl", "highway" } },
			{ t = "string", oneOf = { "casual", "ranked", "coop", "versus" } },
		},
		rate = 0.5,
		burst = 1,
		since = "6",
	},
	-- An eliminated Brawl driver cheers a finalist (target user id; bots are negative)
	["Cheer"] = { dir = "C2S2C", schema = { { t = "integer" } }, rate = 0.5, burst = 1, since = "7" },

	-- Milestone 7
	-- The hitter reports a bump: target (a user id, or a bot's negative id), closing speed, normal
	["Brawl.Hit"] = {
		dir = "C2S",
		schema = { { t = "integer" }, { t = "number", min = 0, max = 300 }, { t = "Vector3" } },
		rate = 6,
		burst = 6,
		since = "7",
	},
	-- To the car that was hit: { kind = "knock", dv, by } or { kind = "heal", amount } (Pit Wrench);
	-- to the hitter: { kind = "hit", target, power }
	["Brawl.Result"] = { dir = "S2C", since = "7" },
	["Brawl.Powerup"] = { dir = "C2S", schema = {}, rate = 1, burst = 1, since = "7" },
	-- Round events for everyone: ko, powerup grabs and uses, honk waves, rank ups, practice steps
	["Brawl.Event"] = { dir = "S2C", since = "7" },
	["Brawl.Round"] = { dir = "S2C", since = "7" }, -- the results card: { places, mine, arena }
	["Brawl.Queue"] = { dir = "C2S", schema = {}, rate = 1, burst = 2, since = "7" }, -- Queue next
	["Brawl.Leave"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 1, since = "7" }, -- back to the park
	["Brawl.Practice"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 1, since = "7" }, -- skip practice

	-- Milestone 8: Highway Havoc
	-- On join and when the UTC day changes: { seed, epoch (server time of road time 0), event, versus }
	["Highway.Seed"] = { dir = "S2C", since = "8" },
	-- A run starts: { run, s, lane, tutorial, origin?, lanes?, startAt, endsAt, length }
	["Highway.Start"] = { dir = "S2C", since = "8" },
	-- The hitter reports a hit: kind (0 traffic, 1 prop, 2 player in versus, 3 tutorial car), the slot,
	-- prop, user or tutorial car id, impact I, chain link (0 = your own car hit it; 1 to 3 = a car you sent
	-- flying hit it)
	["Highway.Hit"] = {
		dir = "C2S",
		schema = {
			{ t = "integer", min = 0, max = 3 },
			{ t = "integer" },
			{ t = "number", min = 0, max = 1000 },
			{ t = "integer", min = 0, max = 3 },
		},
		rate = 12,
		burst = 12,
		since = "8",
	},
	-- Tricks: "near" (a traffic slot id, speed), "air" (0, seconds airborne), "flip" (0, flips landed)
	["Highway.Trick"] = {
		dir = "C2S",
		schema = {
			{ t = "string", oneOf = { "near", "air", "flip" } },
			{ t = "integer" },
			{ t = "number", min = 0, max = 300 },
		},
		rate = 4,
		burst = 4,
		since = "8",
	},
	-- Confirmed totals (at most 4 a second): { score, multiplier, comboUntil, breaks, bestMultiplier }
	["Highway.Score"] = { dir = "S2C", since = "8" },
	-- Run events: pileStart, pileup, bone, wreck (to others: a car someone hit), meterFull, chest, flagged
	["Highway.Event"] = { dir = "S2C", since = "8" },
	-- The results card: { score, bones, bestMultiplier, pileups, coins, capped, best, newBest, havoc,
	-- target, chest, reason, tutorial, event }
	["Highway.End"] = { dir = "S2C", since = "8" },
	["Highway.Again"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 1, since = "8" }, -- Ride again
	["Highway.Leave"] = { dir = "C2S", schema = {}, rate = 0.5, burst = 1, since = "8" }, -- back to the park
	-- Highway boards: board ("score" or "bones"), tab ("friends", "daily", "weekly")
	["Highway.Board"] = {
		dir = "C2S",
		schema = {
			{ t = "string", oneOf = { "score", "bones" } },
			{ t = "string", oneOf = { "friends", "daily", "weekly" } },
		},
		rate = 1,
		burst = 3,
		since = "8",
	},
	["Highway.BoardData"] = { dir = "S2C", since = "8" },
	-- A bone broke: the rider piece (1 Head, 2 Torso, 3 LeftArm, 4 RightArm, 5 LeftLeg, 6 RightLeg) and I
	["Bone.Break"] = {
		dir = "C2S",
		schema = { { t = "integer", min = 1, max = 6 }, { t = "number", min = 0, max = 1000 } },
		rate = 1.5,
		burst = 3,
		since = "8",
	},
}

return Remotes
