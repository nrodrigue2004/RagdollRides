# Tasks

Milestones in spec order. Each one is done when its spec QA section passes on a low-end phone, a mid-range phone and a PC.

## Milestones
1. **Driving feel** — code done 2026-11-15. Done when: DEV panel Accel, Drift, Drop and Ram all PASS for every class; 3 testers crash and respawn on a phone at 30+ fps.
2. **1b Crashes and damage**: 9 damage zones, panel states, debris, explosions, repairs, mesh deformation test. Done when: spec "Driving and damage" checks pass.
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

## Placeholder art and sound
- PLACEHOLDER ART: all 6 vehicle bodies (VehicleBuilder BODIES blockouts), the rider rig and face, test track parts.
- All sound ids in Config.Sounds are empty; sounds need picking from licence-checked free sets (nate's OK first).
