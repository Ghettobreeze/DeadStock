# Dead Stock — prototype

Zombies are coming for the livestock. Save, cure, cull or chain. Raid rival farms. Fix fences.

**Play in the browser:** https://ghettobreeze.github.io/DeadStock/ (rebuilds automatically on every push to `main`).
Or open this folder in Godot 4.7 (Import > pick `project.godot`) and press F5.

Portrait (720x1280). Mouse clicks act as touches, so the phone controls work on desktop too.

## The loop
1. **Day:** spend coins in the Farm Store (repairs, vaccine darts, pitchfork, fences, planks, more animals),
   **train soldiers** from your herd, **raid rival farms**, or play **Fence Fixer** puzzles.
2. **Dusk (planning):** the forecast shows every wave tonight: when, which side, and what types.
   You get planks (3 + fence level + any you bought) to place on fence sections:
   - **Barricade** (1 plank): that section is twice as strong tonight
   - **Spikes** (2): hurt anything chewing that section (brutes take half)
   - **Scarecrow** (2): crows go for it first, and hordes arriving nearby head for its section, so you can funnel them into your spikes
   Tap a section to place, tap again to remove. Then HOLD THE LINE.
3. **Night:** each zombie type needs a different answer:
   - **Walkers** chew a fence section, then go for the herd
   - **Brutes** (from night 2) chew 3x faster and take 3x the hits
   - **Crows** (from night 3) fly over fences straight at your animals
   - **Bloaters** (from night 4) burst when they die or touch an animal and bite everything in the purple ring.
     Kill them **outside** the fence.
   From night 4, the last wave hits two sides at once. Your pitchfork costs **stamina** per swing, so you
   can't hold every side: pick your fights. A bitten animal turns after 8 seconds unless you
   **Save** it (carry into the barn glow, 3 slots; the barn cures it and sends it back out after 15 seconds), **Cure** it (vaccine dart), **Send it upstate** (hold), or
   **Chain** it (it becomes a Dead Stock soldier, 2 posts a night). At most 35% of the herd can turn in one night.
4. **Dawn:** surviving animals pay out, the army eats (feed costs coins), and the **Dawn Gazette** may warn you
   that a rival gang raids tomorrow night.

Balance check (human-like bot: ~2 s to notice a bite, one thing at a time, rebuys animals; 4 seeds x 10 nights):
a bot that reads the forecast and plans at dusk keeps 88% of its herd per night and never goes broke;
the same bot with no dusk plan keeps 79% and goes broke (herd 3 or less, can't afford to restock) in 4 of 4 runs.
Zombies breach the fence 2.5 times a night against a plan vs 16.8 without one. A full wipe is impossible by design.

## Simulated PvP (release-1 plan)
No servers and no other players yet. PvP is simulated:
- **Train soldiers** in the Farm Store: a hen becomes a **hen bomber** (kamikaze), a pig a **pig brawler**,
  a cow a **cow tank**. Soldiers stop paying produce and eat coins every night you play.
  Chained zombie animals become **Dead Stock** units (no feed, hit buildings hard).
  If you can't pay the feed, hungry soldiers wander back to the herd.
- **Rival Raids** (county map): 4 prebuilt rival farms unlock on days 1, 3, 5 and 7:
  Hog Heaven Retirement Ranch, Possum Hollow Feed Lot, GRO-GLO Feed Co. Depot, Mort Muckridge's Rotten Acres.
  Pick a unit, tap outside the fence to drop it in. 120 seconds. Stars for 50% flattened, the silo, and 100%.
  Loot comes from flattened buildings. **Units that fall are gone for good.** 2 raids a day.
  Rivals rebuild every week (new gaps, positions and more guards).
- **Rival raid nights:** from day 3, a rival gang may raid your farm. It's always announced a day ahead
  in the Dawn Gazette, never two nights in a row, and more likely if you just raided them (revenge).
  Raiders smash a fence section, run for the barn, steal a slice of your coins and run off.
  Bonk them first for a bounty and get the stolen coins back.

## Fence Fixer minigame
30 hand-made puzzle levels (levels 1–10 open here). Place fences, traps and decoys on a plank budget,
then watch the night. Earn up to 3 stars. Every new star pays 4 coins on the farm. "Peek" shows the
developer's solution.

## Controls
Touch / mouse: drag anywhere to move. Lift your thumb near a bitten animal for the Action Fan
(Save, Cure, Chain, hold Send Upstate). The pitchfork swings by itself.
Keys: WASD move, E carry, Q cure, X cull, C chain, F auto-carry on/off, T cycle the turn timer (test),
Space start night / next day.

## Dev tools
- `godot --path . -- --autotest=<folder>`: bot plays 3 nights, a rival raid, Fence Fixer and a rival raid
  night, and saves screenshots.
- `godot --headless --path . --fixed-fps 30 -- --sweep=8 --nights=8 --runs=3 [--lazy]`: balance bot
  (`--lazy` = skip dusk planning and just chase zombies; `--planner=none|auto|random`, `--set=NAME=VALUE` overrides any tuning number).
- Fence Fixer alone: run `ff.tscn` (`--verify` proves the levels solvable headless).

The prototype prints `[telemetry]` lines to the console only. It sends nothing over the network.
