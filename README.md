# Ragdoll Rides

A Roblox physics driving game: weighty cars, heavy crashes, a rider who gets thrown clear, a map builder, Bumper Brawl and Highway Havoc. Built with Rojo so all code lives in this repo.

## Play the current build in Studio (Windows)

1. **Install Roblox Studio**: go to https://www.roblox.com/create, click **Start Creating**, run the installer, and sign in.
2. **Install Rojo 7.4.4**: download `rojo-7.4.4-windows-x86_64.zip` from https://github.com/rojo-rbx/rojo/releases/tag/v7.4.4 and put `rojo.exe` somewhere on your PATH (for example `C:\Users\<you>\tools\rojo\`). Then run `rojo plugin install` once, so Studio gets the Rojo plugin.
3. **Get the code**: clone this repo (or download it as a zip from GitHub).
4. **Open it** one of two ways:
   - Quick: in the repo folder run `rojo build default.project.json -o RagdollRides.rbxl`, then double-click `RagdollRides.rbxl`.
   - Live sync (best while building): run `rojo serve` in the repo folder, open a new Baseplate in Studio, open the Rojo plugin and click **Connect**.
5. Press **Play** (F5). You spawn in the Starter Buggy on the test track.

## Controls
- Keyboard: W/S gas and brake (S reverses when stopped), A/D steer, Space jump, Q/E lean in the air, Left Shift handbrake, R reset (or respawn after a crash), F flip.
- Gamepad: RT gas, LT brake, left stick steer and lean, A jump, B handbrake, X reset or respawn, Y flip.
- Phone: on-screen buttons. Tap anywhere while thrown to flail.

## Dev panel
In Studio there is a **DEV** button in the top left. It swaps vehicle class and runs the spec's feel tests (Accel, Drift, Drop, Ram) with PASS/FAIL and numbers. See `notes/Tasks.md` for the full Studio test list.

## Repo notes
`CLAUDE.md` explains the layout; progress, tasks and decisions are in `notes/`.
