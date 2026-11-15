# CLAUDE.md: rules for this repo

Read this first. Keep it short. Quality comes first; efficiency never means lower quality.

## Project
- What it is: **Ragdoll Rides**, a Roblox physics driving game (Tracks + map builder, Bumper Brawl, Highway Havoc). Game 1 of nate's 13-game Roblox lineup.
- Source of truth for design: the build spec "Ragdoll Rides: Build Spec" (https://claude.ai/artifact/BTWzdUABUjnZoUMjq2dfoC). Never edit nate's docs; record any change to a spec number in `notes/Decisions.md`.
- Stack: Luau, Rojo 7.4.4 project (`default.project.json`), tools pinned in `rokit.toml`. Owner: nate.
- Commands:
  - `rojo build default.project.json -o build/RagdollRides.rbxl` (build the start place: Pip's Hill, Tracks, Tumble Park)
  - `rojo build brawl.project.json -o build/CinderCove.rbxl` and `rojo build ranked.project.json -o build/CinderCoveRanked.rbxl` (the Bumper Brawl places: same code, Workspace PlaceRole / Ranked attributes)
  - `rojo serve` (live sync into Studio with the Rojo plugin)
  - `lune run tests/run.luau build/RagdollRides.rbxl` (unit tests + place layout check)
  - `selene src tests` and `stylua src tests` (lint and format)

## Memory: read these, keep them current
- `notes/Current Progress.md`: done / in progress / next. Under 20 lines. Read it at the start of every session.
- `notes/Tasks.md`: milestones in order with their "done when" checks, plus what needs nate in Studio.
- `notes/Decisions.md`: every design or technical decision, one line each with the date. Check it before changing direction.
- `notes/Working Agreement.md`: how nate wants the work done.

## Code map
- `src/shared` (ReplicatedStorage.Shared): `Config` (every tuning number, pure data), `Net` + `NetSchema` + `Remotes` (all remotes, schema checks, rate limits), pure maths and data (`VehicleMath`, `Damage`, `DamageModel`, `PoseCodec`, `ProfileSchema`, `TracksMath`, `GhostCodec`, `StarterMaps`, builder `PieceCatalog`, `MapCodec`, `MapRules`, `MapNames`, `MapStats` (ratings, Popular, reports, strikes, royalties)), shop data and rules (`Catalog`, `ShopMath`, `Quests`), `Round` (round state machine), `RaceMath`, `BrawlMath` (arenas, drop plan, knockback, placements, ranked), `Place` (which place this is: Hub or Brawl), `Boards` (leaderboard keys and rows), `Looks` (cosmetics on cars and riders), `MapSpace`, `MapBuilder` (maps to parts, server and builder preview), `Movers` (moving pieces), `VehicleBuilder`, `Util/`.
- `src/server` (ServerScriptService.Server): `Services/` (DataService, EconomyService, TracksService, BuilderService, MapService (publish), MapStore (map DataStores), MapPlayService (play, plays, ratings, royalties), ModerationService (reports, hides, bans, admin), BrowseService (browse tabs), ShopService (coin buys, garage, mastery, rebirth), PurchaseService (Robux passes and products, receipts), QuestService (quests, chest, streak, gifts), RoundManager (runs a round), RaceService (quick races), PartyService, HubService (plaza, live counts), TeleportHub (mode hops and home), BoardService (map leaderboards), LiveCounts (players per mode), BrawlService (Brawl rounds, practice, ranked), BrawlArena (Cinder Cove, tiles, pen), BrawlBots, VehicleService, TestTrack, CollisionGroups).
- `src/client` (StarterPlayerScripts.Client): `Controllers/` (VehicleController, RagdollClient, CameraController, InputController, HudController, JuiceService, SurfaceEffects, RemoteVehicles, Debris, DamageController, CrashReplay, ProfileClient, SettingsMenu, TracksClient, BuilderClient, BrowseClient, ShopClient, RaceClient, HubClient, BrawlClient, DevPanel), `Fx/` (DamageVisuals, ExplosionFx, MeshDents, Confetti, LookFx) and `Ui/` (TracksHud, BuilderHud, BrowseHud, ShopHud, HubHud, RaceHud, BrawlHud).
- Pure modules have no Roblox types so `tests/run.luau` can run them in Lune.

## Quality
1. Extend what exists. Do not re-implement or restyle working systems, and do not revert nate's work.
2. Shipped-game quality. No placeholders left unmarked: placeholder art is labelled PLACEHOLDER ART in code and listed in Tasks.
3. Verify before saying done: lint clean, tests pass, place builds. Anything only Studio can prove goes on the Studio test list.
4. Design pillars and north star (reach and revenue) apply to every decision. Cartoon only, no free text, nothing sold changes stats.
5. Never download assets, spend money, or publish without nate's OK. Original characters only.
