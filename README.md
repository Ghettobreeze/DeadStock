# Dead Stock — prototype

Zombies are coming for the livestock. Save, cure or cull.

Open this folder in Godot 4 (Import > pick `project.godot`) and press F5.

## Controls
- **WASD / arrows**: move. The pitchfork swings by itself at the nearest zombie in reach.
- **E**: pick up a bitten animal, carry it to the barn, press E again inside the glow to **save** it.
- **Q**: use a vaccine dart to **cure** a bitten animal on the spot.
- **X**: **cull** a bitten animal or a zombie animal (instant, but no more produce from it).
- **Space**: start the night / go to the next day.

## The loop
1. **Day**: buy repairs, vaccines, a sharper pitchfork, stronger fences or more animals.
2. **Night**: hordes arrive from one side at a time and chew through fence sections.
   Bitten animals turn into zombie animals after 6 seconds and start biting the herd.
3. **Dawn**: surviving animals pay out, plus a bonus for every zombie killed.
   Infected animals still on the field at sunrise are lost. Zombie animals burn and leave parts.
4. Lose every animal and the farm is lost.

## What to test
Is the save / cure / cull call under pressure fun? Everything else waits on that answer.

## Dev note
`godot --path . -- --autotest=<folder>` runs a bot through three nights and saves screenshots.
