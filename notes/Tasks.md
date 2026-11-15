# Tasks

Milestones in spec order. Each one is done when its spec QA section passes on a low-end phone, a mid-range phone and a PC.

## Milestones
1. **Driving feel** — code done 2026-11-15. Done when: DEV panel Accel, Drift, Drop and Ram all PASS for every class; 3 testers crash and respawn on a phone at 30+ fps.
2. **1b Crashes and damage** — code done 2026-11-15. 9 damage zones, panel looks, debris, fire and explosions, shockwave, repairs, hit-stop, crash replay, mesh dents, damage sync, HUD silhouette. Done when: spec "Driving and damage" checks pass (DEV panel Crash 60, Zones, Race looks).
3. **2 Tracks**: Pip's Hill onboarding, free run, quick race, checkpoints, ghosts, saves and settings. Done when: 5 first-time testers finish Pip's Hill in under 30 s.
4. **3 and 4 Map builder and sharing**: grid, 20 pieces, test, publish, browse, ranking, moderation. Done when: spec "Tracks and builder" checks pass.
5. **5 Progression and shop**: vehicles, mastery, stars, quests, streaks, rebirth, coins, Robux catalog.
6. **6 Hub and social**: Tumble Park, parties, gifts, cheers.
7. **7 Bumper Brawl**. Done when: spec "Bumper Brawl" checks pass.
8. **8 Highway Havoc**, then the juice pass, analytics and launch checklist.

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

## Placeholder art and sound
- PLACEHOLDER ART: all 6 vehicle bodies (VehicleBuilder BODIES blockouts), the rider rig and face, test track parts.
- PLACEHOLDER ART: dented and crushed panel looks (procedural push-in and darken; real looks go in ReplicatedStorage.Assets.PanelLooks), cracked glass (frosted, no decal), smoke, flame, glitter and explosion particles (built-in textures), explosion glow and ring (neon parts).
- All sound ids in Config.Sounds are empty; sounds need picking from licence-checked free sets (nate's OK first).
