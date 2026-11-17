# Launch checklist (milestone 9)

Everything the code can do is done. These steps need nate (Studio, the Creator Dashboard or a choice only nate can make). Do them roughly in this order; each line says where the result goes.

## 1. Places and ids (Creator Dashboard)
- [ ] Publish `build/RagdollRides.rbxl` as the start place (Tumble Park). Turn on Studio API access (Game Settings → Security) so saves, boards and maps work.
- [ ] In the same experience, add 4 places from the built files: Cinder Cove (`CinderCove.rbxl`), Cinder Cove Ranked (`CinderCoveRanked.rbxl`), Sunny Pass (`SunnyPass.rbxl`, max 8 players), Sunny Pass Versus (`SunnyPassVersus.rbxl`, max 8).
- [ ] Paste the 5 place ids into `Config.Places` (start, brawlCasual, brawlRanked, highwayCoop, highwayVersus).
- [ ] Put your Roblox user id in `Config.Admins` (the admin gear, REVIEW tab and Dev panel on live servers).
- [ ] Rebuild all 5 places (CLAUDE.md commands) and publish each over its place, so they all carry the ids.

## 2. Passes, products and badge
- [ ] Create the 4 game passes (Rider Pass 249, VIP 399, Stunt Set 199, Explosion Styles 149) and paste ids into `Config.Monetization.passes`.
- [ ] Create the 8 developer products (Starter Pack 79, Coins S/M/L/XL 49/129/299/599, Crash Crate 50, Extra Draft Slot 49, Crash Crew Bundle 395) and paste ids into `Config.Monetization.products`. Prices are guesses (tune after a week of data).
- [ ] Create the Rebirth badge and paste its id into `Config.Badges.rebirth`.
- [ ] Test each purchase once in Studio (Studio purchases are free) and once live with a cheap product; rejoin and check it is still granted.

## 3. Sound and music (nothing plays until these are filled)
- [ ] Pick about 70 sound effects and 3 music loops from licence-checked free Creator Store sets (log source, licence link and date in an asset sheet). Paste ids into `Config.Sounds` (51 empty ids), `Config.Audio.music` (Hub, Brawl, Highway) and `Config.Audio.voice` (Highway Hal and the Brawl announcer, 6 lines).
- [ ] Play each mode once and check the mix: music ducks under results cards, engines fade past 150 studs, voice lines never overlap.

## 4. Art pass (every PLACEHOLDER ART line in Tasks.md)
- [ ] Vehicles, rider and outfits, builder pieces, Tumble Park, Cinder Cove, Sunny Pass road kit, traffic, props, UI kit, the 9 original characters (Wobble Bot first, he is on the loading screen).
- [ ] Rider emote poses are rough block poses; redo them with the proper rider rig.
- [ ] Game icon and 5 thumbnails (in-game renders, original characters only, no real people or brands).

## 5. Rules and settings (verify each against current Roblox rules)
- [ ] Maturity and compliance questionnaire: answer for cartoon crashes, no blood, no free text (map names are preset words). Aim for the lowest label it allows.
- [ ] Paid random items: the Robux Crash Crate hides where PolicyService says paid random items are restricted (built); check the odds table shows on the card.
- [ ] Private servers: turn on in Game Settings (spec price 100 R$ a month, verify). They never count for boards or ranks (built).
- [ ] Rewarded video ads: not built (the spec says only where Roblox allows ads for the player's age; check the current rules first).
- [ ] CaptureService share and Experience invites ("Beat my score"): check both work on a phone and a PC; if Roblox has changed either API, the clip still plays without SHARE.
- [ ] Experience settings: Allow third-party teleports off, Allow copying off, genre Driving/Racing, devices phone, tablet, PC, console.

## 6. Final checks before going public
- [ ] Run the whole Studio test list in Tasks.md on a low-end phone, a mid-range phone and a PC.
- [ ] Creator Dashboard → Analytics: custom events (perf_sample, crash_huge, clip_share, run_finish, setting_change and the rest) and the 4 funnels (Onboarding, Builder, Mode entry, Purchase) show data after a test session.
- [ ] 8-player server for 15 minutes in each mode: no server frame spike over 20 ms, no errors in the live console.
- [ ] Soft launch to friends first (private, then public). Watch day-1 retention, the Onboarding funnel and perf samples before spending on ads.

## Marketing: paid ads (nate's rule, 2026-11-17)
Every paid push follows the shared playbook in project files `marketing/Paid Ads Playbook.md`. No Robux spent without nate's OK on that campaign.
- [ ] Only after the quiet launch: organic Day-1 return at least 15% and no known crash in the opening.
- [ ] Make 2 to 3 ad thumbnails (16:9) as well as the icon; submit them 3 days before the start (moderation takes up to 48 hours).
- [ ] Split the budget over 5 to 7 days as a daily budget (example: 10,000 Robux = about 1,400 to 2,000 a day). Objective Plays, audience All Players, no extra targeting at first.
- [ ] Day 1: CTR per thumbnail in Ads Manager (aim for 2.5% or more). Day 2: turn off the weakest thumbnail, and read day 1's FunnelKit data.
- [ ] Pause the campaign if more than 35% of first sessions end in under 1 minute (`first_session_end`, length "under 1m"), or under half of new players reach First round (Progress funnel; also the Onboarding funnel). Fix that step, then run ads again.
- [ ] Log each campaign in the playbook's campaign log.
