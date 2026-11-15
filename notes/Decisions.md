# Decisions (one line each, newest last)

- 2026-11-15: Rojo 7.4.4 + Selene + StyLua + Lune, pinned in rokit.toml. Pure modules tested in Lune; feel tested in Studio by the DEV panel.
- 2026-11-15: Gravity set to 120 (Roblox default 196.2) so ramps give real air time and flips. Spec numbers (top speed, timeToTop, drop) are kept; tune in Studio.
- 2026-11-15: The car controller runs once per frame at PreSimulation (not 240 Hz) with a 1/30 s step cap; it is stable at 30 and 60 fps in the drop simulation.
- 2026-11-15: Wheel forces are summed into one VectorForce at the centre of mass plus one Torque (r×F), instead of one VectorForce per wheel. Same physics, fewer constraints.
- 2026-11-15: The damper is a velocity-change impulse (progressive above 15 studs/s, 1.5× on rebound, ×6 at the bump stop) with a one-frame lookahead ray. A force damper bounced 5 studs and was unstable at 30 fps.
- 2026-11-15: Players have no avatar (CharacterAutoLoads off). The rider is a client-built 6-piece rig; others see it through the Vehicle.Pose stream (10 Hz, 7 or 127 bytes).
- 2026-11-15: Ram test thresholds use closing speed × mass factor; static walls count as mass factor 2.0. Test speeds 6, 15 and 35 studs/s give Bump, HardHit and HugeCrash.
- 2026-11-15: Milestone 1 lets every vehicle be tried on the test track; ownership checks come with saves (milestone 2).
- 2026-11-15: Phone vibration uses HapticService where supported; unverified until tested on a phone.
