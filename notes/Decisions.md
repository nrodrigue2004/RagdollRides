# Decisions (one line each, newest last)

- 2026-11-15: Rojo 7.4.4 + Selene + StyLua + Lune, pinned in rokit.toml. Pure modules tested in Lune; feel tested in Studio by the DEV panel.
- 2026-11-15: Gravity set to 120 (Roblox default 196.2) so ramps give real air time and flips. Spec numbers (top speed, timeToTop, drop) are kept; tune in Studio.
- 2026-11-15: The car controller runs once per frame at PreSimulation (not 240 Hz) with a 1/30 s step cap; it is stable at 30 and 60 fps in the drop simulation.
- 2026-11-15: Wheel forces are summed into one VectorForce at the centre of mass plus one Torque (r×F), instead of one VectorForce per wheel. Same physics, fewer constraints.
- 2026-11-15: The damper is a velocity-change impulse (progressive above 15 studs/s, 1.5× on rebound, ×6 at the bump stop) with a one-frame lookahead ray. A force damper bounced 5 studs and was unstable at 30 fps.
- 2026-11-15: Players have no avatar (CharacterAutoLoads off). The rider is a client-built 6-piece rig; others see it through the Vehicle.Pose stream (10 Hz, 7 or 127 bytes).
- 2026-11-15: Ram test thresholds use closing speed × mass factor; static walls count as mass factor 2.0. Test speeds 6, 15 and 35 studs/s give Bump, HardHit and HugeCrash.
- 2026-11-15: Milestone 1 lets every vehicle be tried on the test track; ownership checks come with saves (milestone 2).
- 2026-11-15: Vibration works on gamepads only for now; phone vibration waits until the haptics API is checked on a real phone (verify).
- 2026-11-15 (1b): Damage spill goes front/rear to left+right, left/right to front+rear, roof to left+right (25% each). Wheel share is split between the two wheels on that end or side by where the hit landed.
- 2026-11-15 (1b): Landing wheel damage = max(0, fall speed - 50) x 1.2 to each wheel that touched down. Using the full impact formula would pop all four wheels off a 20-stud drop (fall speed 69 at gravity 120).
- 2026-11-15 (1b): Every look, detach and glass break is derived from the 9 zone numbers, so every device draws the same wreck from Damage.State. Glass cracks when its zone turns dented (same as the spec's "hit over I 30" for single hits).
- 2026-11-15 (1b): In looks-only modes (quick races) the engine keeps running at 0 front health, so damage never changes handling; it only smokes.
- 2026-11-15 (1b): Explosion shockwaves are applied by each owner to their own car when they see another car's exploded flag (the owner always moves its own car). Brawl's server-applied version comes in milestone 7.
- 2026-11-15 (1b): The crash replay never moves the real car (its position replicates to everyone). The real car is held still and hidden locally while a local copy plays back. It starts 0.3 s after the crash so the rider's flight is in it, and runs only when the rider was thrown. Other players' cars keep moving live during it.
- 2026-11-15 (1b): Mesh deformation uses the body shell part (Body_Shell, or Panel_Floor on the blockouts). Device memory cannot be read from a game script, so the benchmark uses fps plus the player's own manual graphics quality (under 4 = off).
- 2026-11-15 (1b): Damage.State server limit is 5 per s, burst 6 (clients send at most 4) so explosion and repair sends never count toward the kick limit. Owners resend every 3 s while damaged, which also covers late joiners.
- 2026-11-15 (1b): The HUD shows the damage silhouette on the test track too (the spec puts it in Brawl and Highway), so it can be checked now.
