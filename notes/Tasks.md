# Tasks

Milestones in spec order (numbers as in the spec). Each one is done when its spec QA section passes on a low-end phone, a mid-range phone and a PC.

## Milestones
1. **1 Driving feel**: code done 2026-11-15. Done when: DEV panel Accel, Drift, Drop and Ram all PASS for every class; 3 testers crash and respawn on a phone at 30+ fps.
2. **1b Crashes and damage**: code done 2026-11-15. Done when: spec "Driving and damage" checks pass (DEV Crash 60, Zones, Race looks), 5 phone testers rate it heavy and responsive at 4 of 5 or higher, and the keep-or-cut call on mesh dents is recorded in Decisions.md.
3. **2 Core loop**: code done 2026-11-15. Checkpoints, finish, coins, ghosts, Pip's Hill, 5 maps, profile saves v1. Done when: 5 people finish a session with no server errors, and 5 first-time testers finish Pip's Hill in under 30 s.
4. **3 Map builder**: code done 2026-11-15. Done when: spec "Tracks and builder" checks pass for the builder (build, save, reload and play a map in under 10 minutes; limits enforced by the server; publish gates; preset names only).
5. **4 Browse and safety**: code done 2026-11-15. Browse tabs, play published maps with pay and royalties, ratings, Popular ranking, reports, auto-hide, strikes and bans, admin tools. Done when: spec "Browse and safety" checks pass (a published map shows in Newest and plays for a second player with pay; 15 counted reports from over 25% of its finishers hide it until an admin looks; the third admin-confirmed hide in 90 days bans publishing for 7 days; ratings move Popular).
6. **5 Shop, passes, quests and streak**: code done 2026-11-15. Shop (daily spotlight, coins, passes, Crash Crate with odds on the card), garage (cars, 7 look slots, rider, rebirth), mastery, Robux passes and products with one receipt handler, daily and weekly quests, the daily chest, the 7-day streak, gifts, the one-time Starter Pack offer. Done when: spec "Economy" checks pass (every purchase grants once and survives a rejoin; nothing sold changes handling; the crate odds match the card over 20,000 rolls (unit test); a new player earns their first shop look inside 15 minutes), and nate has created the passes, products and rebirth badge in the Creator Dashboard (ids in Config.Monetization and Config.Badges).
7. **6 Hub and round manager, plus the party queue**: code done 2026-11-15. Tumble Park hub plaza with stalls and mode gates, the mode picker with live counts, HUB button, the round state machine (RoundManager on Shared/Round), Tracks quick races on the race pad, parties of friends, map leaderboards (Friends / Weekly / All-time), the quest tracker. Done when: a returning player opens on the hub and is driving a mode in one tap; 2 to 8 players race on the race pad with places paid (80 / 60 / ... / DNF 10) and auto-requeue; a party of 2 queues together; a new best shows on the map's All-time and Weekly boards for a second player; live counts move within a minute on a live server.
8. **7 Bumper Brawl**: code done 2026-11-15. Cinder Cove places (casual and ranked), 2 arenas over a foam pit, the foam-ball pen lobby, labelled bots, the tile drop schedule with sudden death and tiebreak, 4 powerups dropped by Gully, practice on the first visit, KOs, spectate and cheer, results with coins, ranked points, tiers and seasons. Done when: spec "Bumper Brawl" checks pass (5 testers knock a bot off in 30 s with no help; 5 rounds in a row at 30+ fps with hits registering at 150 ms ping; tile drops match the schedule, sudden death and tiebreak work; bot fill after 10 s casual and 20 s ranked, bots labelled, bot wins give no ranked points; ranked points, placements and soft reset correct for 10 test accounts), and nate has created the two Brawl places and pasted their ids (plus the start place id) into Config.Places.
9. **8 Highway Havoc**: code done 2026-11-15. Sunny Pass places (co-op and versus), the seeded curving road with ramps, Pit Wrenches and breakable props, deterministic traffic (6 types, 8 nearest physics), Destruction Score with combos to x8, chains, near misses, air and flips, pile-ups, 12 bone breaks with X-ray and the Full Crack finale, 7 daily events, the 90 s tutorial lane, results with coins, the Havoc chest and the server Havoc meter, daily and weekly boards with Friends, versus unlock after 2 runs. Done when: spec checks pass (5 first-time testers land a 3-hit combo within 30 s on the tutorial lane; hits register at 150 ms ping and no honest run is flagged; 3 runs in a row at 30+ fps on a phone with 16 traffic cars; each daily event works; a run posts to the daily and weekly boards for a second player), and nate has created the two Sunny Pass places (max 8 players) and pasted their ids into Config.Places.
10. **9 Polish and launch**: code done 2026-11-15. Analytics (custom events, Mode entry and Purchase funnels, device perf samples), the audio mix (groups, music crossfade and ducking, engine loops, voice lines; ids empty), the rest of the juice table (speed lines, coin fly, star puff, respawn ring, confetti, checkpoint hit-stop, pile-up camera pull), the Highway Clip (best 10 s replay with screen capture and share) and "Beat my score" invites, the Wobble Bot loading and teleport screen, the emote wheel (4 free emotes, Rider Pass emotes and slots 5 and 6). Done when: the milestone 9 Studio checks pass, and every line of `notes/Launch Checklist.md` is ticked.

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
- [ ] Admin gear on a card (Studio): FEATURE puts it on FEATURED with a gold badge; HIDE removes it from every public tab, adds it to REVIEW and shows HIDDEN / "Hidden for review" in the creator's MY MAPS; on a hidden card CONFIRM HIDE and UNHIDE show, and UNHIDE brings it back to NEWEST. BAN 7D then PUBLISH answers "banned"; UNBAN clears it.
- [ ] Hide 3 of the same creator's maps with admin HIDE (or CONFIRM HIDE): the creator gets a 7-day publish ban automatically. A map hidden only by reports gives no strike until an admin confirms it.
- [ ] A hidden map edited and published again goes back on NEWEST once; a second hide locks it ("reviewLocked") until an admin unhides it.
- [ ] FRIENDS shows maps by your Roblox friends (needs a live server with friends who published; Studio test accounts have no friends).
- [ ] POPULAR fills within 10 minutes of plays (the index is rewritten every 10 minutes).
- [ ] Leave a player map and wait 60 s: the map's parts are gone from Workspace.Maps on the server.
- [ ] Phone: the browse tabs scroll sideways, the cards and arrows are easy to tap, the rating stars are big enough.

Milestone 5 (shop, garage, quests; DEV → Pick + GRANT gives any pass or product without Robux, Studio only):
- [ ] SHOP, GARAGE and QUESTS buttons sit on the left under the goal bar; QUESTS has a red dot when something is ready to claim (the streak on your first visit each day).
- [ ] SHOP → TODAY: the line "Nothing here makes you faster or stronger.", the Crash Crew Bundle, 4 spotlight looks (the same in every server on the same day), the crate. Each card shows one price, coins or Robux.
- [ ] Buy a look with coins: the coins count down, "... is yours! Wear it in the GARAGE." Not enough coins: the button is greyed out.
- [ ] CRATE: the odds table is on the card. Open one with 1,000 coins: the box shakes, opens at about 1.6 s with the rarity colour, closes by itself or with a tap. A duplicate shows "+N coins back". The Robux crate card only shows where PolicyService allows paid random items.
- [ ] Any Robux button answers "Coming soon!" while the ids are 0. DEV GRANT each pass and product: rider (outfits and hats in GARAGE → RIDER), vip (TRAILS → SWITCH TO FRONT works), stunt (3 stunt cars in CARS, DRIVE them), explosions (BOOM styles), starter, coins_s to coins_xl, crate (reveal), extra_slot (BUILD shows one more slot), bundle.
- [ ] GARAGE → CARS: owned cars show DRIVE and mastery; locked ones their price and needs (Dune Hopper: Starter Buggy mastery 3). DRIVE swaps the car at the map's start.
- [ ] GARAGE → PAINT, RIMS, TRAILS, HORNS, BOOM, PARTS, DECALS: EQUIP restyles your car at once and other players see it; TAKE OFF goes back to the car's own look. Trails draw behind the wheels; the crash explosion uses the BOOM style. Handling is the same with every look (drive a lap with and without).
- [ ] GARAGE → RIDER: hats sit on the helmet and fall off with the rider; outfits recolour the suit.
- [ ] Finish 5 Tracks runs on one car: "... mastery 2! New look: ..." and a red dot on GARAGE until you open it.
- [ ] QUESTS: 3 daily and 3 weekly quests with progress bars. Finish runs: "Quest done: ..." toasts, CLAIM pulses and pays. All 3 dailies claimed opens the daily chest (150 coins or a common look); all 3 weeklies give 5 stars.
- [ ] Login streak: CLAIM DAY 1 pays 50 coins, then COME BACK TOMORROW. (To test more days, change streak.lastClaim in the DataStore or use Fresh save.)
- [ ] Gifts (2 players who are Roblox friends, live server): GIFT sends 10 of your coins once a day; the friend sees "A friend sent you 10 coins!".
- [ ] First finish of a fresh save: about 1.5 s into the results card the Starter Pack offer shows once, the NEXT countdown stops, NO THANKS closes it, and it never shows again (also after a rejoin).
- [ ] REBIRTH: needs all 6 launch cars (DEV GRANT coins, buy them). HOLD TO REBIRTH for 1.5 s: coins and stars go to 0, cars and looks stay, finishes pay 5% more.
- [ ] Buy something, leave and rejoin: it is still owned. A Robux purchase in a live test (after ids exist) is granted once even if you leave during the prompt.
- [ ] Phone: shop tabs scroll sideways, cards and claim buttons are easy to tap.

Milestone 6 (hub, quick races, parties, boards; races need 2 players: Test → Clients and Servers → 2 players):
- [ ] A fresh save still starts on Pip's Hill with no HUB button. After the finish, HUB shows top left (gold, before the coins).
- [ ] Leave and play again (not a fresh save): you spawn in Tumble Park facing the 3 gates, and the mode picker opens with the TRACKS card glowing. PLAY (Free Run) drives your next starter map in one tap.
- [ ] DRIVE AROUND closes the picker; PLAY ▸ (top centre) opens it again. Drive around the plaza: foam walls, 3 kicker ramps, the Tumble Tower in a corner.
- [ ] Drive into each stall: GARAGE opens the garage, SHOP the shop, WORKSHOP the builder slot picker, the TRACKS / BRAWL / HIGHWAY gates open the picker. A stall opens again only after you drive out for 3 s.
- [ ] Every mode card is open from the first visit (no "?????" or timer). In Studio the Brawl and Highway cards say COMING SOON because the place ids are still 0; open CinderCove.rbxl or SunnyPass.rbxl to play those modes. RANKED and VERSUS chips stay locked until their unlock rules are met.
- [ ] The cards show "● N playing"; with API access on (MemoryStore) it updates every 30 s.
- [ ] Quick race: both players drive onto the RACE PAD (or TRACKS → QUICK RACE → PLAY). The pill says "QUICK RACE 2/8 · starts in 10" with LEAVE; leaving the hub (MAPS, BUILD) leaves the queue.
- [ ] At 0 the cars appear on a 4 x 2 grid on a starter map copy (never Pip's Hill), held: steering works, gas does not. 3, 2, 1, GO! The timer starts at GO.
- [ ] Racers bump each other (solid, fully visible); a free-run player on the same starter map elsewhere stays a ghost. Damage dents but never changes handling and never explodes (looks-only), and Vehicle swaps are blocked ("Finish the race first!").
- [ ] The pill shows your place ("1st of 2") as checkpoints are reached. Finishing pops "FINISHED 1ST!". The race ends 20 s after the first finisher (or when both finish).
- [ ] Results card: YOU WON! / 2ND PLACE!, both names and times, "+80 coins" (2nd: +60; a DNF: +10). RACE AGAIN ▶ 6 then both are back in the hub and queued for the next race; LEAVE stops that.
- [ ] HUB mid-race: the first tap says "Tap HUB again to leave the race", the second takes you to the hub (no pay).
- [ ] Party: in the picker tap PLAY WITH FRIENDS: PARTY (needs 2 accounts that are Roblox friends, so a live test): INVITE a friend; they get "X invites you to their party!" with JOIN. The party strip shows both names. The leader joining a quick race brings the friend into the queue too. LEAVE PARTY ends it.
- [ ] TOP (top right, on any map): the board opens on ALL-TIME with your time pinned at the bottom (gold). Finish faster: the new time shows after reopening (within a minute). WEEKLY and FRIENDS tabs switch. In Studio without API access the boards work in memory for the session.
- [ ] Quest tracker (top right, under the buttons): QUESTS n/3 with today's 3 quests and live counts; ready ones are gold; tap the header to fold it.
- [ ] Phone: the HUB button, picker cards, chips and race pill are easy to tap; nothing covers the driving buttons while racing.

Milestone 7 (Bumper Brawl). Build the places with `rojo build brawl.project.json -o CinderCove.rbxl` and `rojo build ranked.project.json -o CinderCoveRanked.rbxl` (or use the copies in project files) and open them directly; Studio counts as admin, so ranked is open:
- [ ] Hex tiles: each tile is a hexagon (UnionAsync of 3 blocks). If the Output shows a union failure, tiles become round pads instead; tell Claude.
- [ ] First visit (casual, use DEV → Fresh save first): you start on a small disc facing a slow bot with BUMP! over it. One bump sends it into the foam (+20), a second bot comes, the bar shows 1 / 2 then done ("NICE! NOW FOR REAL") and you are in the pen. Time it: under 30 s with no help. SKIP works.
- [ ] Pen: drivable, foam balls roll, the panel shows the slots filling. Alone, bots fill the round 10 s after you join (ranked: 20 s), each labelled BOT in the slots and over their cars.
- [ ] Countdown: on the arena facing the centre, held (steering works, the gas does not), 3, 2, 1, BUMP!. RESET is hidden on the arena.
- [ ] Bumping: driving into a bot or player knocks it back (thud, sparks, a tiny hit-stop); a heavier car hits harder and the Bus barely moves. A bot ramming you knocks you. Two players at 150 ms ping (Studio: File → Studio Settings → Network → Incoming Replication Lag 0.15): hits still register.
- [ ] Tiles: the outer ring flashes for 3 s and drops at 0:40 of the round (timer shows 1:20), the middle ring at 75 s (0:45), then one inner tile every 4 s from 95 s (0:25). At 2:00 with several cars left: SUDDEN DEATH, a tile a second; at 2:30 the most KOs wins.
- [ ] Gully flies over every 12 s and drops a powerup on a standing tile; drive through it to hold it (toast says what it does); ACTION (G, RB, or the round button) uses it: SPRING (green bar, next 3 bumps hit harder), SHIELD (bubble, you can't be knocked; "BLOCKED!"), WRENCH (your car is fixed), HONK (pink ring, cars within 14 studs fly back).
- [ ] KO: a car under the tiles is out (pop, feed line "X bumped Y out!" or "fell in the foam"). Your KO of someone shows KO!. RIVAL shows over the last car that knocked you.
- [ ] Out: KNOCKED OUT with WATCH (camera follows a finalist; tap again for the next), CHEER (the finalist sees "X is cheering for you!"), QUEUE NEXT (closes it). You are back in the pen after 2 s.
- [ ] Results: places with KOs and BOT tags, "+N coins · K KOs" (20 a round, +5 per KO up to 4, +40 for a win), QUEUE NEXT ▶ 8 and LEAVE. Idle all round: no coins. Then everyone is in the next round.
- [ ] Ranked place: the results show the tier, the bar and the points change (+25 win, +10 top half, -10 first out); the first 5 rounds never lose points; a bot win shows "A bot won, so nobody gets points". HUB mid-round asks for a second tap.
- [ ] Ranked lock (live only, needs a non-admin account under 3 casual rounds): joining ranked says ranked opens after 3 casual rounds and sends you back to Tumble Park.
- [ ] Performance: 5 rounds in a row with 8 cars (bots and players) at 30+ fps on a phone; no server frame spike over 20 ms.
- [ ] Live (after nate creates the places and pastes ids into Config.Places: start, brawlCasual, brawlRanked): the hub's Bumper Brawl card plays, a party goes together, HUB in Cinder Cove goes back to Tumble Park, live counts show players in Brawl.

Milestone 8 (Highway Havoc). Build with `rojo build highway.project.json -o SunnyPass.rbxl` (co-op) or `versus.project.json` (versus), or use the copies in project files, and open the file. Use DEV → Fresh save first to see the tutorial:
- [ ] Tutorial lane (first run): you drop onto a quiet 2-lane road already rolling, "DODGE THE TRAFFIC!", one slow compact with DODGE! over it. Steering around it gives NEAR MISS. Hitting it hard (or any Huge crash) starts WRECK MODE. The ramp 650 studs ahead launches you. PRACTICE DONE! with coins after Wreck Mode ends; RIDE AGAIN starts a real run.
- [ ] Road: 4 lanes, gentle curves, dashed lines, no gaps or steps between segments, grass all around. Ramps face the right way (low edge toward you; if they are backwards, tell Claude). No Pit Wrenches any more.
- [ ] Traffic: cars drive in their lanes at different speeds, slow lane on the right. Near cars feel solid; a hit knocks them and they find their lane again; a hard hit wrecks them; I 70+ blows one up a moment later and the blast pushes nearby cars, props and you. Wrecks vanish about 6 s later. No car pops or stutters as it switches between gliding and physics.
- [ ] Ride (Ride then Wreck): the bar shows "N m   SPEED xN"; distance pays more above 70% (x2) and 90% (x3) of top speed and pops SPEED x2 / x3; NEAR MISS (+150) when you pass within 2 studs at 70+; AIR and FLIP after jumps. Traffic starts light and gets clearly thicker the further you go (about 2.5 km to full). A light scrape (SCRAPE!) keeps the ride going. Does it get hard at the right pace, and does the crash threshold feel fair?
- [ ] The crash: a traffic hit at I 22+, a Huge crash into anything, being thrown, or a hard versus bump ends the ride: WRECK MODE! with a 10 s count. Then smash: combos up to x8, chains, PILE-UP!, bone breaks (freeze, crack, X-ray) and props all score as before. BOOM! (button, G or RB) works once per wreck: your car blows up, the rider is thrown and every car within 30 studs flies.
- [ ] Run end: Wreck Mode runs out (WRECKED!), the 12th bone (FULL CRACK!), or 25 s without moving. Results show DISTANCE, WRECK points, BONES and COINS, "furthest ride" when you beat your best, the daily Havoc bar and personal best; RIDE AGAIN lights up after 2 s.
- [ ] Two players (Test → Clients and Servers): each player has their own traffic (thicker the further they ride), and in co-op the other player's car is a see-through ghost you drive through. With 150 ms lag (Studio Settings → Network → Incoming Replication Lag 0.15) hits still register and the run is never flagged.
- [ ] Versus place: cars are solid; a hard bump from another player ends your ride, and in Wreck Mode bumping them scores. Joining with fewer than 2 runs (live, non-admin) sends you back to Tumble Park with a notice.
- [ ] Daily events (change the day by editing Config.Highway.events order, or wait): the chip shows the event; Rush Hour doubles traffic, Foam Truck and Bus Parade add tankers and buses, Ramp Day puts ramps every 200 studs, Pile-up Friday pays double, Night Lights is dusk with glowing traffic, Low Gravity Sunday floats.
- [ ] TOP: Highway boards with SCORE / DISTANCE and FRIENDS / TODAY / THIS WEEK; distance rows end in " m"; your row pinned. In Studio without API access they work in memory.
- [ ] Havoc meter (right edge) fills with everyone's points; when full, contributors get +30 coins. The Havoc chest opens on the results card once you pass 15,000 points today.
- [ ] Performance: 3 runs in a row at 30+ fps on a phone; no server frame spike over 20 ms with 8 players.
- [ ] Live (after nate creates the Sunny Pass places, max 8 players, and pastes ids into Config.Places highwayCoop and highwayVersus): the hub card plays, the Versus chip unlocks after 2 runs, a party goes together, live counts show players in Highway.

Playtest 1 fixes (2026-11-15):
- [ ] Highway ride: hands off, the car holds its lane through curves; a tap moves exactly one lane, holding keeps changing lanes, it never leaves the road, and it stays flat. Does a lane change feel quick enough (about 1 s)? A flipped or stuck car goes to Wreck Mode within about 2 s.
- [ ] Tracks: crash hard several times without RESET; the car still drives exactly like the first run (dents and torn panels still show).
- [ ] Driving feels smooth at 60 fps and on a phone: the suspension fix (2026-11-16) removed a body shake that grew at low fps. Is the choppy feel gone?
- [ ] Respawn: RESPAWN shows after 1.6 s, Pip's Hill and Highway respawn by themselves after 2 s. About right now?
- [ ] Paint a car in the garage, crash it, then repair: no flicker of the old paint at any point.
- [ ] Lighting: shadows, haze, bloom and sun rays look better? Settings → Effects Low turns bloom, sun rays and the grade off.

Calm pass (2026-11-15):
- [ ] Driving in Tracks shows only coins and stars, the timer, MENU, RESET and the speed. MENU opens the panel (goal bar on top; HUB, MAPS, BUILD, TOP, SHOP, GARAGE, QUESTS, EMOTE, SETTINGS); tapping outside or CLOSE shuts it; every item still opens its screen. A claimable quest puts a red dot on MENU and on QUESTS.
- [ ] Highway ride: only distance, speed and score at the top; combo, Havoc meter and Crack Count appear in Wreck Mode. Never more than 3 point pops or 1 banner at once.
- [ ] Does it still look busy anywhere? Tell Claude which screen.

Milestone 9 (polish and launch):
- [ ] Loading: joining shows the Wobble Bot screen (sky blue, RAGDOLL RIDES); tapping him bounces him and changes the line; it fades once you can drive (never stuck: 25 s at most). A mode hop (hub card) shows the same screen during the teleport.
- [ ] Juice: speed lines at the screen edges above about 80 studs/s (none with Reduced motion); a coin flies to the coin counter, which bounces; star puff when the rider is thrown; a glow ring on respawn; confetti on a quest or chest claim; a tiny freeze on each checkpoint; the camera pulls back on a Highway pile-up. Too much or about right?
- [ ] Audio: with test ids pasted into Config.Audio.music and Config.Sounds.Engine, music crossfades between places and drops under every results card; engines rise in pitch with speed and you hear only the 3 nearest other cars. Music and SFX volume sliders still work.
- [ ] Emotes: EMOTE (under RESET), B or d-pad up opens the ring with 4 slots (6 with the Rider Pass, Dev panel grant). Each emote plays on your rider in the seat and a second player sees it; the hands go back to the wheel. You can't spam them (one per 2 s). Garage → RIDER: NEXT SLOT and PUT IN fill the wheel; pass emotes are locked without the pass. Does the EMOTE button overlap anything in Brawl or Highway?
- [ ] Highway Clip: after a run with a few hits, CLIP on the results card replays your best 10 s from 3 angles (your car, rider and nearby traffic); DONE stops it; SHARE opens Roblox's share sheet for the captured picture (phone and PC). A run with no action has no CLIP button.
- [ ] Beat my score: BEAT MY SCORE opens the friend invite; a friend who joins from it sees "X's score to beat: N" on their results and "You beat X's N!" once they beat it.
- [ ] Analytics (live, with API access): after a session the Creator Dashboard shows the custom events and the Mode entry and Purchase funnels; perf_sample rows carry fps, 1% low, memory and device.

## Placeholder art and sound
- PLACEHOLDER ART: all 6 vehicle bodies (VehicleBuilder BODIES blockouts), the rider rig and face, test track parts.
- PLACEHOLDER ART: dented and crushed panel looks (procedural push-in and darken; real looks go in ReplicatedStorage.Assets.PanelLooks), cracked glass (frosted, no decal), smoke, flame, glitter and explosion particles (built-in textures), explosion glow and ring (neon parts).
- PLACEHOLDER ART: starter map pieces (plain foam-coloured road, ramps, walls, arches, coins, spinners, pads, grass ground), finish confetti (default particle texture), Tracks UI glyphs (coin dot, star, cog, plain rounded panels), the ghost car (see-through copy of your car).
- All sound ids in Config.Sounds are empty (now including Coin, Finish, Honk, StarEarned); sounds need picking from licence-checked free sets (nate's OK first). No music yet (the Music volume setting is ready).
- PLACEHOLDER ART: builder pieces (plain parts; the spec's lower part costs assume single-mesh prefabs from the art pass), the plot grid (SurfaceGui lines), tray labels instead of piece icons, the finish line checker (SurfaceGui squares), the placement outline (blue neon box). The Wobble Bot builder helper is not built yet (art pass).
- New empty sound ids: BuilderPlace, BuilderRemove, Publish, PistonPush.
- Saved but not used yet: the "Fewer flashes" and "Effects" settings (the VFX pass reads them); a builder map's Full damage flag (free runs already use full damage; quick races in milestone 6 read it to pick TracksFullDamage over TracksRace).
- PLACEHOLDER ART: browse cards (plain frames, a sketch made of flat coloured frames, text badges), the rating stars and report flag (text glyphs).
- PLACEHOLDER ART: shop, garage and quest screens (flat cards, colour swatches, text glyphs for coins, stars and Robux), the crate box and reveal (a shaking frame), look parts (spoiler, bull bar, roof rack, fins, decal strips and mastery badge are plain blocks), hats (blocks and cylinders), trails (plain colour Roblox Trails).
- Horns have no sound (HORNS can be equipped; the honk plays nothing until sounds are picked). The emote wheel is built (milestone 9).
- PLACEHOLDER ART: Tumble Park (flat plaza, foam walls, stall pads and sign arches, kicker wedges, the Tumble Tower of stacked blocks), the mode picker cards (flat colours; locked cards a grey silhouette with "?????"), the race pill and results card, the party and leaderboard panels. The Wobble Bot loading and teleport screen is built (milestone 9; PLACEHOLDER ART: Wobble Bot is rounded frames).
- Not built yet: the Tumble Tower's Park Party meter (the spec names it but gives no rules; it waits for a design), the harder star-rated map tier after a rebirth (needs curated maps), Featured player maps in quick races (starter maps only for now).
- PLACEHOLDER ART: Cinder Cove (foam pit, pen walls, foam balls, carnival posts and flags, the NEXT ROUND sign), hex tiles in flat ring colours, the geyser (default particles), powerups (neon blocks), Gully the Gull, the shield bubble, spring bar and honk ring, the Brawl lobby, round bar, out panel and results card. Bots use the Buggy and other car blockouts with rider looks from the catalog.
- New empty sound ids: BrawlBump, TileWarn, TileDrop, KO, PowerupGrab, HonkWave, ShieldUp, RankUp, Cheer.
- PLACEHOLDER ART: the Sunny Pass road kit (asphalt blocks, dash parts, grass plane, yellow wedge ramps, neon Pit Wrench cube), traffic cars (body, cabin and wheel-strip blocks in type colours), roadside props (plain cones, fence, sign, foam barrier, billboard), the bone crack (frame lines), star puffs (neon balls), the X-ray skeleton (rounded frames), the Highway run bar, banners, results card and boards panel.
- New empty sound ids: Smash, ComboUp, ComboLost, NearMiss, Trick, PileUp, BoneCrack, XRay, HavocFull, RunOver. Highway Hal has no voice lines yet (milestone 9).
- The results Clip button and "Beat my score" are built (milestone 9). PLACEHOLDER ART: traffic in a clip are plain blocks.
- Milestone 9 placeholders: emote poses (rough block-rider poses), the emote ring (plain round buttons), speed lines, flying coin, star puff, glow ring and confetti (plain frames and neon parts). Empty ids: Config.Audio.music (3 loops), Config.Audio.voice (6 lines), Config.Sounds.Engine.
