# Current Progress (2026-11-16)

## Done
- Milestones 1, 1b and 2 code: driving feel, crashes and damage; the core loop (saves, coins and stars, 5 starter maps, server-timed runs, ghosts, results, settings, onboarding, funnel).
- Milestones 3 and 4 code: the map builder (20 pieces, undo, drafts, moving pieces, preset names, publish gates) and browse and safety (tabs, plays, pay, royalties, ratings, reports, auto-hide, strikes, bans, admin tools).
- Milestones 5 and 6 code: shop, garage, mastery, rebirth, passes and products (ids still 0), quests, chest, streak, gifts; Tumble Park hub, mode picker, rounds, quick races, parties, map boards.
- Milestones 7 and 8 code: Bumper Brawl (Cinder Cove casual and ranked) and Highway Havoc (Sunny Pass co-op and versus).
- Milestone 9 code: analytics and funnels, audio mix, the rest of the juice table, Highway Clip and Beat my score, Wobble Bot loading screen, emote wheel. Version 1.0.0-m9.
- Playtest 1 fixes (2026-11-15): Tracks damage is looks only, smoother camera, slower respawn, all modes open, paint flicker fixed, lighting pass. Highway Havoc redesigned as Ride then Wreck (distance ride that gets harder, then 10 s of Wreck Mode with BOOM).
- Studio rounds 4 to 9 on nate's PC (2026-11-16): fixed cars shaking themselves over (dampers solved for the rigid body, softer roll/pitch springs, grip as an impulse); Highway lane-based steering; stuck/flipped rides end fast; no stale boom or double placement; Tracks brakes after the finish.
- Tests pass (6,745), Selene clean, the 5 places build. Pushed to GitHub on branch claude/project-thread-p3wmkm; the bundle and place files are also in project files.
- PAUSED 2026-11-16 (nate: Capeline first). Since then only the studio-wide funnel analytics (FunnelKit: Progress and Returns funnels, session_start / session_end with stage, activity and quit reason; guide in project files analytics/). Resume with nate's hand playtest of the Tasks.md Studio list.

## In progress
- nate's Studio checks for milestones 1 to 9 and the playtest 1 fixes (Tasks.md "Studio test list"); the Highway checks are rewritten for Ride then Wreck.

## Next
- nate: work through `notes/Launch Checklist.md` (place ids, passes and products, sounds and music, art pass, questionnaire, icon and thumbnails, soft launch).
- After launch: tune prices and caps from a week of analytics; Update 2 items in the spec (season pass, follow).
