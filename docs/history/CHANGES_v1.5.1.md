# ForeverWEATHER 1.5.1

The water the wipers leave at the ends of their sweep runs off instead of sitting there.

## Water lines that run off

Up to 1.5.0 the water a blade pushed to the end of its sweep stayed there as a line of big beads that only faded in
place, and the glass water simulation piled more water onto it with every wipe. Now:

- **The line drains.** Beyond the end of a sweep, where no blade comes back, the water the blades pushed together runs
  off in about a second (quicker in the airflow) instead of building up wipe after wipe.
- **Its big drops let go and run.** The biggest drops leave the line first, the smaller ones later. They follow the path
  the water on the glass really took since the blade turned (the running drops' travel over the last four seconds,
  which the mod now keeps): down the glass with gravity when the car stands, up and off it in the airflow at speed,
  sideways when you brake or turn. A big drop slides much faster than a small bead; in a strong airflow all of them are
  fast.
- **Wet trails.** Most runners are a slim streak with a round head, like the running drops on the body, and each leaves
  a thin wet trail behind it. The small drops stay on the line until the blade comes back; at speed most of them are
  blown away too.
- **Clear water.** Big, flat line water is a weak lens, so it no longer shows up as white blobs.
- The bulge of water a blade pushes ahead of itself during a sweep keeps its big, merged drops.
- Debug view 23 shows the drops of the lines in magenta.

## Technical

- Shaders: `shaders/common/postFx/rainPuddles69/`.
- The windshield pass draws, for each blade and each end of its sweep, the drops that stay plus three sets of runners
  (and the runners of the line before, still on their way). Each set moves as one along the shared path, so a pixel
  finds its drops in a few cells. `rpLineAge` (`rp_pane.h.hlsl`) tells when a blade last came in to an end.
- New constants `rpWindV0..3`: how far the running drops travelled in the last 0.5, 1 ... 4 s, from a ring of samples
  in Lua (`WAVE.travelStep`, `WAVE.travelConsts`).
- The glass water simulation drains water above 1 outside the blades' sweep; it used to pile up to the cap there.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request: the drops at the end of the wipe looked too
static and should run off with the airflow and gravity. Tested in game on East Coast USA (BeamNG.drive 0.40.5, DX12) on
the ETK with the Animated Wipers mod's blades: parked and at 90 km/h from the driver's seat, and from outside. On that
car the far end of the sweep lies right at the A-pillar, so from the seat most of that line is behind the pillar trim:
you see its drops running along the pillar edge and up from the bottom of the glass. Not tested: a car with a rear
wiper, Vulkan.
