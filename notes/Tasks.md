# Tasks

Milestones in spec order (numbers as in the spec). Each one is done when its spec QA section passes on a low-end phone, a mid-range phone and a PC.

## Milestones
1. **1 Driving feel**: code done 2026-11-15. Done when: DEV panel Accel, Drift, Drop and Ram all PASS for every class; 3 testers crash and respawn on a phone at 30+ fps.
2. **1b Crashes and damage**: code done 2026-11-15. Done when: spec "Driving and damage" checks pass (DEV Crash 60, Zones, Race looks), 5 phone testers rate it heavy and responsive at 4 of 5 or higher, and the keep-or-cut call on mesh dents is recorded in Decisions.md.
3. **2 Core loop**: code done 2026-11-15. Checkpoints, finish, coins, ghosts, Pip's Hill, 5 maps, profile saves v1. Done when: 5 people finish a session with no server errors, and 5 first-time testers finish Pip's Hill in under 30 s.
4. **3 Map builder**: code done 2026-11-15. Done when: spec "Tracks and builder" checks pass for the builder (build, save, reload and play a map in under 10 minutes; limits enforced by the server; publish gates; preset names only).
5. **4 Browse and safety**: code done 2026-11-15. Browse tabs, play published maps with pay and royalties, ratings, Popular ranking, reports, auto-hide, strikes and bans, admin tools. Done when: spec "Browse and safety" checks pass (a published map shows in Newest and plays for a second player with pay; 5 counted reports hide it; the third hide in 30 days bans publishing for 7 days; ratings move Popular).
6. **5 Shop, passes, quests and streak**.
7. **6 Hub and round manager, plus the party queue** (quick races fit here).
8. **7 Bumper Brawl**. Done when: spec "Bumper Brawl" checks pass.
9. **8 Highway Havoc**.
10. **9 Polish and launch**: the juice pass, analytics review and the launch checklist.

## Studio test list (needs nate's PC)
Milestone 1:
- [ ] Open the place (README steps), press Play. You spawn in the Starter Buggy on the test track.
- [ ] DEV panel → "All tests" for each class (Buggy, Sedan, Truck, Bus). Note any FAIL with its numbers.
- [ ] Drive the ramps, drop tower, air-time hill, bouncer and speed pad. Do the car's weight, grip and air control feel right?
- [ ] Crash into the wall at full speed: the rider ejects, ragdolls, fades at 4 s; RESPAWN shows at 1 s.
- [ ] Gravity 120: is air time too floaty or about right?
- [ ] Phone (Studio device emulator first, then a real phone): touch controls reachable, 30+ fps.
- [ ] 3 players (Studio Test → Start, 3 players): other players' cars, wheels and riders look smooth.

Milestone 1b:
- [ ] DEV → "Crash 60" for each class: dents, torn panels, explosion at about 3 s, min fps 30+, debris max 12 and gone by 3 s.
- [ ] DEV → "Zones": watch each zone go clean, dented, crushed, 0 (bumpers and doors tear off, door swings loose, glass cracks then shatters, wheels pop off, smoke then fire).
- [ ] DEV → "Race looks": PASS (looks-only damage never changes handling).
- [ ] Drive with a crushed wheel: the car pulls toward it; with a lost wheel the axle drags and the car tilts.
- [ ] Huge crash (ram the wall fast): hit-stop, then the 1.2 s slow-mo replay from the crash cam, then control comes back. Does it feel good or too long?
- [ ] Mesh dents: DEV shows dent status. If "unavailable", EditableMesh is not allowed in this place yet (check the creator eligibility rule). If dents render inside out, flip FLIP_WINDING in Fx/MeshDents. Check dents are off with Dents: Panels and that Repair resets them.
- [ ] 2 players: one explodes near the other; the other car is pushed away and both see the same damage.
- [ ] 8 players crash for 10 minutes: no server frame spike over 20 ms (Studio: Test → 8 players, View → Script Performance).

Milestone 2:
- [ ] Press Play: you land on Pip's Hill with no menu, DRIVE pulses on GAS (or "HOLD W TO DRIVE!"). Drive off: the timer starts.
- [ ] Pip's Hill beat by beat: coin trail dings rise in pitch, JUMP! shows about 1 s before the ramp lip, the coin arc is catchable, the landing zone is long enough, the roller always throws the rider, you respawn by yourself after 1 s just past it, the finish confetti fires. Under 30 s for a first-timer?
- [ ] Results card: time, stars pop in, +100 coins and 1 star on the first Pip's Hill finish, the goal bar fills toward Starter paint. Buttons lock for 2 s, then NEXT counts down 5 s and takes you to Lean Ledge.
- [ ] Lean Ledge: LEAN BACK! shows before the big drop; steering help is High on both first maps for a new player.
- [ ] Every map (MAPS → STARTER tab): drivable start to finish, walls keep you on, no gaps at turns, ramps and gaps land. Tune each map's creator time so Gold takes a few tries (StarterMaps creatorTime).
- [ ] Tumble Gulch spinner: dodgeable, hits only when the bar reaches you; Bounce Basin bouncers and speed pads work on the maps.
- [ ] Fall off a map: the car resets to the last checkpoint before it hits the ground below.
- [ ] Ghost: after one finish, retry; your best run drives beside you see-through. A new best replaces it.
- [ ] Splits: at each checkpoint on a retry, green minus if ahead of your best, red plus if behind.
- [ ] 2+ players (Test → 2 players): you drive through each other's cars, which are see-through.
- [ ] Settings cog: each option changes at once (button size, left hand, steering help, shake off, dents panels, volumes).
- [ ] Saving (publish the place and turn on Studio API access first): play, leave, rejoin; coins, stars, best times, ghosts and settings are all still there. On the live game, join a second server right after leaving one: the profile loads (it waits for the first server's save).
- [ ] DEV → Fresh save: you are back on Pip's Hill as a first-time player.
- [ ] Output shows no errors during a 5-map session; no "[Tracks] run rejected" warnings for clean runs (if one shows, note the reason).
- [ ] Phone: top bar, timer, MAPS and cog don't overlap the controls; results card buttons are easy to hit.

Milestone 3 (builder):
- [ ] BUILD (top right) shows your map slots: 3 free plus 7 locked VIP slots. Pick MAP 1: the camera flies over a green grid plot, your car waits at the plot's edge, the driving buttons are gone.
- [ ] Phone (device emulator, then a real phone): one finger orbits, two fingers pan, pinch zooms. Tap Road in the tray, tap the grid: it places with a click. Tap again: another. Is it easy to aim? Are the tray and buttons big enough?
- [ ] PC: number keys pick pieces (Shift for 11 to 20), R rotates 15 degrees (Shift+R back), T tilts, F sizes, Q/E down and up, Delete, Ctrl+Z / Ctrl+Y, Esc. Right drag orbits, middle drag or WASD pans, wheel zooms. The blue outline shows where a piece will go.
- [ ] Build a loop: Start, roads, a 90 curve, a slope, checkpoints, a ramp, the finish. Road pieces dropped near another road's end snap onto it. Any gaps or steps where pieces meet (most likely after 15 or 45 degree turns)?
- [ ] Select a piece: drag moves it, ROTATE/TILT/SIZE/COLOUR/UP/DOWN/DELETE work and undo. Tilted blocks, walls and platforms sit on the floor, not through it.
- [ ] Moving pieces: spinner spins 90 deg/s, the hammer swings across the road every 2.5 s, the piston punches every 2 s and shoves the car sideways, the tilt deck rocks 15 degrees every 3 s and the car can drive over it, the hazard bar throws the rider. Two players see the same phase.
- [ ] Limits: the tray greys a piece out at 250 pieces, 400 parts, 10 checkpoints, 12 moving pieces or 40 pads, with a short reason.
- [ ] TEST: the car is on your start gate in under 2 s with the driving HUD back. Finish: "FINISHED in 0:xx! Ready to publish." BUILD returns to the same camera. Select a checkpoint and TEST: you start at that checkpoint (practice, never counted).
- [ ] A map shorter than 5 s: the test finish says it is too short.
- [ ] Autosave: build, wait 30 s, leave (Stop) and play again: BUILD → MAP 1 has your pieces. EXIT saves too.
- [ ] MAP: the three word wheels and RANDOM make a name, up to 3 tags, FULL DAMAGE toggles. The checklist ticks START + FINISH, "Finish your map once" (after a TEST finish), "Pick a name".
- [ ] PUBLISH in Studio (Studio uses 1 minute of play and a 1 minute cooldown): the gates answer in order (finish a Tracks run first, play time, cooldown "Publishing by itself in 1 minute"). Then "PUBLISHED! Wobbly Pickle Canyon" with confetti and INVITE the first time. Publish again after an edit: it says UPDATE and keeps the same map.
- [ ] Change a piece after a TEST: the checklist un-ticks "Finish your map once" until you finish it again.
- [ ] With API access on: the map record appears in the Maps_v1 DataStore (key M_<id>).
- [ ] 2 players build at once: each gets their own plot, nobody sees the other's pieces.
- [ ] Gamepad: the left stick pans, the right stick orbits, triggers zoom, the UI buttons can be selected (Roblox's gamepad selection).

Milestone 4 (browse and safety; Studio API access on, so the map stores are real; without it they run in memory for the session):
- [ ] MAPS opens the browse screen: FEATURED, POPULAR, NEWEST, FRIENDS, MY MAPS, STARTER (and REVIEW, since Studio counts as admin). Grey cards pulse while a page loads. A first-time player opens on STARTER.
- [ ] Publish a map (milestone 3 steps), then NEWEST and MY MAPS show its card: a sketch of the map from above (does it read as the map?), the name, "by you", NEW · 0 plays, its tags.
- [ ] Tap the card: the map builds in a moment (no server hitch with a 250-piece map) and the car is on its start. Moving pieces move, checkpoints and the finish count, falling off resets.
- [ ] 2 players (Test → 2 players): player 2 plays player 1's map. The finish pays 30 coins (5 after 3 finishes in a day) and stars by the creator time. Player 1 gets "Players drove your maps: +5 coins!" within about a minute; a second run by player 2 the same day pays player 1 nothing more.
- [ ] Player 2's results card has RATE IT! with 5 stars under it. Tapping stops the NEXT countdown. Change the rating and finish again: YOUR RATING shows the new one. Player 1's own map shows no rating or report row.
- [ ] NEXT on a player map drives the next card from the list it was picked from; at the end of the list it opens browse.
- [ ] REPORT: three reasons (Rude shape, Can't finish, Spam copy), SEND enables after picking one, "Thanks for keeping maps fun!". A second report from the same account does nothing more.
- [ ] Admin gear on a card (Studio): FEATURE puts it on FEATURED with a gold badge; HIDE removes it from every public tab, adds it to REVIEW and shows HIDDEN / "Hidden for review" in the creator's MY MAPS; UNHIDE brings it back to NEWEST. BAN 7D then PUBLISH answers "banned"; UNBAN clears it.
- [ ] Hide the same creator's maps 3 times (admin HIDE): the creator gets a 7-day publish ban automatically.
- [ ] A hidden map edited and published again goes back on NEWEST once; a second hide locks it ("reviewLocked") until an admin unhides it.
- [ ] FRIENDS shows maps by your Roblox friends (needs a live server with friends who published; Studio test accounts have no friends).
- [ ] POPULAR fills within 10 minutes of plays (the index is rewritten every 10 minutes).
- [ ] Leave a player map and wait 60 s: the map's parts are gone from Workspace.Maps on the server.
- [ ] Phone: the browse tabs scroll sideways, the cards and arrows are easy to tap, the rating stars are big enough.

## Placeholder art and sound
- PLACEHOLDER ART: all 6 vehicle bodies (VehicleBuilder BODIES blockouts), the rider rig and face, test track parts.
- PLACEHOLDER ART: dented and crushed panel looks (procedural push-in and darken; real looks go in ReplicatedStorage.Assets.PanelLooks), cracked glass (frosted, no decal), smoke, flame, glitter and explosion particles (built-in textures), explosion glow and ring (neon parts).
- PLACEHOLDER ART: starter map pieces (plain foam-coloured road, ramps, walls, arches, coins, spinners, pads, grass ground), finish confetti (default particle texture), Tracks UI glyphs (coin dot, star, cog, plain rounded panels), the ghost car (see-through copy of your car).
- All sound ids in Config.Sounds are empty (now including Coin, Finish, Honk, StarEarned); sounds need picking from licence-checked free sets (nate's OK first). No music yet (the Music volume setting is ready).
- PLACEHOLDER ART: builder pieces (plain parts; the spec's lower part costs assume single-mesh prefabs from the art pass), the plot grid (SurfaceGui lines), tray labels instead of piece icons, the finish line checker (SurfaceGui squares), the placement outline (blue neon box). The Wobble Bot builder helper is not built yet (art pass).
- New empty sound ids: BuilderPlace, BuilderRemove, Publish, PistonPush.
- Saved but not used yet: the "Fewer flashes" and "Effects" settings (the VFX pass reads them); a builder map's Full damage flag (free runs already use full damage; quick races in milestone 6 read it to pick TracksFullDamage over TracksRace).
- PLACEHOLDER ART: browse cards (plain frames, a sketch made of flat coloured frames, text badges), the rating stars and report flag (text glyphs).
