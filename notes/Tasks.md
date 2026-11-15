# Tasks

Milestones in spec order (numbers as in the spec). Each one is done when its spec QA section passes on a low-end phone, a mid-range phone and a PC.

## Milestones
1. **1 Driving feel**: code done 2026-11-15. Done when: DEV panel Accel, Drift, Drop and Ram all PASS for every class; 3 testers crash and respawn on a phone at 30+ fps.
2. **1b Crashes and damage**: code done 2026-11-15. Done when: spec "Driving and damage" checks pass (DEV Crash 60, Zones, Race looks), 5 phone testers rate it heavy and responsive at 4 of 5 or higher, and the keep-or-cut call on mesh dents is recorded in Decisions.md.
3. **2 Core loop**: code done 2026-11-15. Checkpoints, finish, coins, ghosts, Pip's Hill, 5 maps, profile saves v1. Done when: 5 people finish a session with no server errors, and 5 first-time testers finish Pip's Hill in under 30 s.
4. **3 Map builder**: grid, pieces, test drive, publish.
5. **4 Browse and safety**: browse, ranking, ratings, reports, moderation.
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
- [ ] Every map (MAPS button): drivable start to finish, walls keep you on, no gaps at turns, ramps and gaps land. Tune each map's creator time so Gold takes a few tries (StarterMaps creatorTime).
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

## Placeholder art and sound
- PLACEHOLDER ART: all 6 vehicle bodies (VehicleBuilder BODIES blockouts), the rider rig and face, test track parts.
- PLACEHOLDER ART: dented and crushed panel looks (procedural push-in and darken; real looks go in ReplicatedStorage.Assets.PanelLooks), cracked glass (frosted, no decal), smoke, flame, glitter and explosion particles (built-in textures), explosion glow and ring (neon parts).
- PLACEHOLDER ART: starter map pieces (plain foam-coloured road, ramps, walls, arches, coins, spinners, pads, grass ground), finish confetti (default particle texture), Tracks UI glyphs (coin dot, star, cog, plain rounded panels), the ghost car (see-through copy of your car).
- All sound ids in Config.Sounds are empty (now including Coin, Finish, Honk, StarEarned); sounds need picking from licence-checked free sets (nate's OK first). No music yet (the Music volume setting is ready).
- Saved but not used yet: the "Fewer flashes" and "Effects" settings (the VFX pass reads them).
