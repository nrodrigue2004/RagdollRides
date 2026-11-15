# Ragdoll Rides

A Roblox physics driving game: weighty cars, heavy crashes, a rider who gets thrown clear, a map builder, Bumper Brawl and Highway Havoc. Built with Rojo so all code lives in this repo.

## Play the current build in Studio (Windows)

1. **Install Roblox Studio**: go to https://www.roblox.com/create, click **Start Creating**, run the installer, and sign in.
2. **Install Rojo 7.4.4**: download `rojo-7.4.4-windows-x86_64.zip` from https://github.com/rojo-rbx/rojo/releases/tag/v7.4.4 and put `rojo.exe` somewhere on your PATH (for example `C:\Users\<you>\tools\rojo\`). Then run `rojo plugin install` once, so Studio gets the Rojo plugin.
3. **Get the code**: clone this repo (or download it as a zip from GitHub).
4. **Open it** one of two ways:
   - Quick: in the repo folder run `rojo build default.project.json -o RagdollRides.rbxl`, then double-click `RagdollRides.rbxl`.
   - Live sync (best while building): run `rojo serve` in the repo folder, open a new Baseplate in Studio, open the Rojo plugin and click **Connect**.
5. Press **Play** (F5). You spawn in the Starter Buggy on Pip's Hill, the first map. Drive off to start the timer.
6. To test saving in Studio, turn on **Game Settings → Security → Enable Studio Access to API Services** (the place must be published first). Without it, progress is kept only until you stop playing.

## Controls
- Keyboard: W/S gas and brake (S reverses when stopped), A/D steer, Space jump, Q/E lean in the air, Left Shift handbrake, R reset (or respawn after a crash), F flip, G use a Brawl powerup, B emote wheel (1 to 6 pick a slot).
- Gamepad: RT gas, LT brake, left stick steer and lean, A jump, B handbrake, X reset or respawn, Y flip, RB use a Brawl powerup, d-pad up emote wheel.
- Phone: on-screen buttons. Tap anywhere while thrown to flail. **EMOTE** (under RESET) opens the emote wheel; fill its slots in GARAGE → RIDER.
- Top right: **MAPS** opens browse (Featured, Popular, Newest, Friends, My Maps, Starter; tap a card to drive it, rate and report from its results card), **BUILD** opens the map builder, the **cog** opens settings (button size, left-handed layout, steering help, shake, reduced motion, dents, volumes).
- Left, under the goal bar: **SHOP** (daily spotlight, coins, passes, Crash Crate), **GARAGE** (cars, paint, rims, trails, horns, explosions, parts, decals, rider, rebirth) and **QUESTS** (daily and weekly quests, daily chest, login streak, gifts). Robux buttons say "Coming soon" until the pass and product ids are in `Config.Monetization`; in Studio, DEV → Pick + GRANT gives any of them for free.
- **HUB** (top left, once Pip's Hill is done) goes to Tumble Park: the mode picker (Tracks Free Run or Quick Race; Bumper Brawl and Highway Havoc are Coming soon), stalls you drive into (race pad, garage, shop, workshop) and PARTY for friends in the server. **TOP** (top right, on a map) shows the map's leaderboard. Quick races need 2 players: in Studio use Test → Clients and Servers.
- **Bumper Brawl** runs in its own place, Cinder Cove. To try it in Studio, run `rojo build brawl.project.json -o CinderCove.rbxl` (or `ranked.project.json` for ranked) and open that file. Bump the other cars into the foam; **G** (RB on a gamepad, or the round button on a phone) uses the powerup you hold. Bots fill the round 10 s after you join, so you can play alone.
- **Highway Havoc** runs in its own place, Sunny Pass. To try it in Studio, run `rojo build highway.project.json -o SunnyPass.rbxl` (or `versus.project.json` for versus) and open that file. You drop onto a busy highway at speed: smash traffic and roadside props for the Destruction Score, keep hitting within 3 s for a combo up to x8, set off pile-ups, and crack your rider's 12 bones for a bigger multiplier. A run lasts 3:30; your first one is a 90 s practice road. **TOP** shows the Highway boards. On the results card, **CLIP** replays your best 10 s (and SHARE shares a picture of it), and **BEAT MY SCORE** invites a friend to beat your score.
- Builder (phone): tap a piece in the tray, tap the plot to place it; tap a placed piece to select it, drag to move it; one finger orbits, two fingers pan and pinch. TEST drives the map (from a selected checkpoint it is a practice run), BUILD comes back. MAP names, tags and publishes it.
- Builder (PC): number keys pick pieces (Shift for 11 to 20), R rotate, T tilt, F size, Q/E down and up, Delete, Ctrl+Z / Ctrl+Y, Esc deselects; right drag orbits, middle drag or WASD pans, the wheel zooms.

## Dev panel
In Studio there is a **DEV** button on the left edge. It swaps vehicle class and runs the spec's feel and crash tests with PASS/FAIL and numbers (they take you to the test track first). **Pip's Hill** and **Test track** jump between them, and **Fresh save** makes you a first-time player again (to replay the onboarding). See `notes/Tasks.md` for the full Studio test list.

## Repo notes
`CLAUDE.md` explains the layout; progress, tasks and decisions are in `notes/`. Before going public, work through `notes/Launch Checklist.md`.
