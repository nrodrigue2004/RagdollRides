-- FunnelKit tests: the SAME FILE ships in every game beside the shared FunnelKit (copy, never fork).
-- The game's runner calls it with its own test and check helpers, its FunnelDef and a default profile:
--   require("./funnelkit_test")(test, check, FunnelKit, FunnelDef, ProfileSchema.default())

return function(
	test: (string, () -> ()) -> (),
	check: (boolean, string) -> (),
	FunnelKit: any,
	FunnelDef: any,
	defaultProfile: any
)
	local function rig(def: any?)
		local log = { funnel = {}, custom = {} }
		local clock = { t = 1_800_000_000 }
		local kit = FunnelKit.new(def or FunnelDef, {
			funnel = function(player, funnel, session, step, name)
				table.insert(
					log.funnel,
					{ player = player, funnel = funnel, session = session, step = step, name = name }
				)
			end,
			custom = function(player, name, value, fields)
				table.insert(log.custom, { player = player, name = name, value = value, fields = fields })
			end,
		}, function()
			return clock.t
		end)
		return kit, log, clock
	end

	-- A tiny ladder: stage 2 needs a >= 1, stage 3 needs b >= 1 (and stage 2), stage 4 throws
	local LADDER = {
		stages = {
			{
				name = "Joined",
				reached = function()
					return true
				end,
			},
			{
				name = "A",
				reached = function(p)
					return p.a >= 1
				end,
			},
			{
				name = "B",
				reached = function(p)
					return p.b >= 1
				end,
			},
			{
				name = "Broken",
				reached = function(p)
					return p.nope.field == 1
				end,
			},
		},
		returns = { 1, 2, 3 },
		hopSeconds = 180,
	}

	test("FunnelKit: saves, labels and buckets", function()
		local save = FunnelKit.fill(nil)
		check(save.sessions == 0 and save.stage == 0 and save.played == 0, "fill(nil) is a blank save")
		local partial = FunnelKit.fill({ sessions = 4, stage = "x" })
		check(
			partial.sessions == 4 and partial.stage == 0 and partial.hopAt == 0,
			"fill keeps numbers, fixes the rest"
		)
		check(FunnelKit.clean('Pip\'s Hill, "x"') == "Pips Hill x", "clean drops quotes and commas")
		check(#FunnelKit.clean(string.rep("a", 80)) == 50, "clean keeps 50 characters")
		check(FunnelKit.label(LADDER, 3) == "03 B", "labels are zero-padded")
		check(FunnelKit.label(LADDER, 9) == "00 Unknown", "an unknown stage label")
		check(
			FunnelKit.lengthBucket(59) == "under 1m" and FunnelKit.lengthBucket(60) == "1-3m",
			"length edges"
		)
		check(FunnelKit.lengthBucket(99999) == "40m+", "length top bucket")
		check(
			FunnelKit.dwellBucket(29) == "under 30s" and FunnelKit.dwellBucket(600) == "10m+",
			"dwell edges"
		)
		check(FunnelKit.awayBucket(100) == "same day" and FunnelKit.awayBucket(86400 * 2.5) == "2-3d", "away")
		check(FunnelKit.sessionBucket(1) == "1" and FunnelKit.sessionBucket(7) == "6-10", "session buckets")
	end)

	test("FunnelKit: stage ladder is contiguous and safe", function()
		check(FunnelKit.stageOf(LADDER, { a = 0, b = 1 }) == 1, "B without A stays at stage 1")
		check(FunnelKit.stageOf(LADDER, { a = 1, b = 1 }) == 3, "A and B reach 3; a broken test stops there")
	end)

	test("FunnelKit: first session, progress and quit", function()
		local kit, log, clock = rig(LADDER)
		local save = FunnelKit.blank()
		local profile = { a = 0, b = 0 }
		check(kit:join("p1", save, profile) == true, "a first join is a new session")
		check(save.sessions == 1 and save.firstAt == clock.t and save.sessionAt == clock.t, "session numbers")
		check(log.funnel[1].funnel == "Returns" and log.funnel[1].name == "Session 1", "Returns step 1")
		check(log.funnel[1].session == FunnelKit.LIFE_SESSION, "lifetime funnels use one session id")
		check(log.custom[1].name == "session_start" and log.custom[1].value == 1, "session_start sent")
		local f = log.custom[1].fields
		check(f[1] == "01 Joined" and f[2] == "new" and f[3] == "first", "session_start fields")
		check(log.funnel[2].funnel == "Progress" and log.funnel[2].step == 1, "Progress step 1 on join")
		check(save.stage == 1, "stage 1 saved")
		-- progress two stages at once: both steps in order, one stage_reached each
		clock.t += 600
		profile.a, profile.b = 1, 1
		kit:check("p1", profile)
		check(
			log.funnel[3].step == 2 and log.funnel[4].step == 3 and log.funnel[4].name == "B",
			"steps in order"
		)
		check(save.stage == 3, "stage 3 saved")
		check(log.custom[2].name == "stage_reached" and log.custom[2].value == 10, "stage_reached in minutes")
		check(
			log.custom[3].fields[1] == "03 B" and log.custom[3].fields[2] == "session 1",
			"stage_reached fields"
		)
		local before = #log.funnel
		kit:check("p1", profile)
		check(#log.funnel == before, "no repeat steps")
		-- activity and quit
		kit:activity("p1", "Lobby")
		clock.t += 90
		kit:activity("p1", "Lobby") -- no change: the time in it keeps counting
		clock.t += 30
		kit:leave("p1", "nonsense")
		local last = log.custom[#log.custom]
		check(last.name == "first_session_end", "first session quit has its own name")
		check(last.value == 720, "session length in seconds")
		check(last.fields[1] == "03 B", "quit stage")
		check(last.fields[2] == "Lobby 1-3m", "activity and time in it")
		check(last.fields[3] == "left 10-20m", "unknown reason logs as left, with length")
		check(save.played == 720, "play time saved")
		check(not kit:isTracking("p1"), "untracked after leaving")
		kit:leave("p1", "left")
		check(log.custom[#log.custom] == last, "a second leave logs nothing")
	end)

	test("FunnelKit: place hops are one session", function()
		local kit, log, clock = rig(LADDER)
		local save = FunnelKit.blank()
		local profile = { a = 1, b = 0 }
		kit:join("p1", save, profile)
		clock.t += 100
		kit:hop("p1")
		local n = #log.custom
		kit:leave("p1", "left")
		check(#log.custom == n, "leaving for a hop logs no quit")
		check(save.hopAt == clock.t and save.played == 100, "hop time and play time saved")
		clock.t += 20
		check(kit:join("p1", save, profile) == false, "rejoin within hopSeconds continues")
		check(save.sessions == 1 and save.hopAt == 0, "no new session")
		check(#log.custom == n, "no session_start on a hop")
		clock.t += 50
		kit:leave("p1", "kicked")
		local last = log.custom[#log.custom]
		check(last.value == 170 and last.fields[3] == "kicked 1-3m", "length spans both places")
		check(save.played == 150, "play time adds up across places (not the teleport)")
		-- a failed hop: the player stays, so the later quit counts
		kit:join("p1", save, profile)
		kit:hop("p1")
		kit:hopFailed("p1")
		kit:leave("p1", "idle")
		check(log.custom[#log.custom].fields[3] == "idle under 1m", "a quit after a failed hop logs")
		-- a hop that never arrives: the next join much later is a new session
		kit:join("p1", save, profile)
		kit:hop("p1")
		kit:leave("p1")
		clock.t += 3600
		check(kit:join("p1", save, profile) == true, "a stale hop is a new session")
	end)

	test("FunnelKit: returning players and shutdown", function()
		local kit, log, clock = rig(LADDER)
		local save = FunnelKit.blank()
		local profile = { a = 0, b = 0 }
		kit:join("p1", save, profile)
		kit:leave("p1")
		clock.t += 86400 * 2 + 5
		kit:join("p1", save, profile)
		check(save.sessions == 2, "second session")
		local start = log.custom[#log.custom]
		check(start.name == "session_start" and start.fields[2] == "returning", "returning")
		check(start.fields[3] == "2-3d", "days away")
		local returns = {}
		for _, e in log.funnel do
			if e.funnel == "Returns" then
				table.insert(returns, e.step)
			end
		end
		check(#returns == 2 and returns[2] == 2, "Returns step 2")
		kit:join("p2", FunnelKit.blank(), profile)
		kit:shutdown()
		local ends = 0
		for _, e in log.custom do
			if
				(e.name == "session_end" or e.name == "first_session_end")
				and string.find(e.fields[3], "^shutdown")
			then
				ends += 1
			end
		end
		check(ends == 2, "shutdown ends every open session")
		local n = #log.custom
		kit:leave("p1", "left")
		check(#log.custom == n, "no double quit after shutdown")
		-- a sink that throws never breaks the game
		local bad = FunnelKit.new(LADDER, {
			funnel = function()
				error("boom")
			end,
			custom = function()
				error("boom")
			end,
		}, os.time)
		local ok = pcall(function()
			bad:join("p3", FunnelKit.blank(), profile)
			bad:leave("p3")
		end)
		check(ok, "sink errors are contained")
	end)

	test("FunnelKit: this game's FunnelDef", function()
		local stages = FunnelDef.stages
		check(#stages >= 3 and #stages <= 100, "3 to 100 stages (Roblox: 100 steps a funnel)")
		local names = {}
		for i, stage in stages do
			check(type(stage.name) == "string" and not names[stage.name], "stage " .. i .. " named once")
			names[stage.name] = true
			check(FunnelKit.clean(stage.name) == stage.name, "stage " .. i .. " name is dashboard-safe")
			check(#FunnelKit.label(FunnelDef, i) <= 50, "stage " .. i .. " label fits")
		end
		check(FunnelKit.stageOf(FunnelDef, defaultProfile) == 1, "a new profile is at stage 1")
		check(stages[1].reached(defaultProfile) == true, "stage 1 is always reached")
		local returns = FunnelDef.returns or FunnelKit.DEFAULT_RETURNS
		for i = 2, #returns do
			check(returns[i] > returns[i - 1], "returns ascend")
		end
	end)
end
