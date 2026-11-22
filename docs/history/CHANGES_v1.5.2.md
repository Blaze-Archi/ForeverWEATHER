# ForeverWEATHER 1.5.2

Clearer big drops on the glass, and drops on the camera lens that land at random, spread out with speed and slide down
when the car is slow.

## Clearer big glass drops

Up to 1.5.1, how far a drop on the glass bent the view behind it grew with the drop's size, so a big drop showed a
far-off patch of sky and read as a white blob. Real drops much bigger than about 3 mm are flattened by gravity: flat on
top and curved only around the rim, and a flat top neither bends nor flips the view. Now:

- A big round or merged drop keeps its curve only in its rim. Its middle shows what is behind it, a little magnified,
  inside a thin outline.
- How far a round drop bends the view stops growing past the size of a drop a little bigger than the bead radius.
- The flat middle no longer focuses light into a bright patch on the drop's lower side, and it shows no second sun
  glint.
- Small beads, running teardrops and the slim drops of the water lines look as before, and *Glass drops: refraction*
  works as before.

## Lens drops that move with the air and gravity

- **They land at random.** Every batch of drops has a random grid of its own, so the drops never line up into rows.
- **Driving:** they spread out from the point the camera moves toward. For a camera that looks where the car goes, that
  is the middle of the screen, on the horizon ahead. Drops near that point barely move; drops farther out move faster
  and leave the screen. The faster you drive, the faster they go. Moving sideways carries them across.
- **Slow or parked:** they slide down the lens with gravity (down as the world sees it, also when the camera rolls),
  every batch at a pace of its own, and some small drops stay where they landed. As you speed up, the air takes over.
- More drops land at speed, as the lens sweeps through the rain: at 126 km/h up to 3.4 times as many as parked (was
  1.8).
- They stay round dots. *Speed drift* sets how fast they spread out: at 1 and 126 km/h a drop doubles its distance from
  that point in about 1.4 s.

## Technical

- Shaders: `shaders/common/postFx/rainPuddles71/`.
- Windshield pass: round and merged drops keep their slope only in a rim 1.1 r0 / radius wide (r0 = the bead radius),
  and the lens size is capped at 1.1 r0; caustic, glint and soft highlight scale with the remaining slope.
- Lens drops: all drops of an epoch move by one affine map, x = exp(F) x_landed + T (screen heights from the middle, y
  down). Lua integrates F and T for the last 16 epochs from the lens's smoothed velocity (the player's car, else the free
  camera): F grows at alpha = Speed drift x 0.5 / 35 x the forward speed (1/s), T at alpha T + b, where b is the
  sideways motion (it puts the centre of the spread where the camera moves toward) plus gravity: 0.05 screen heights per
  second parked, a fifth of that at speed. The shader gets the 12 newest epochs (`rpLensE..G` for F, `rpLensH..M` for
  T) and maps each pixel back into every epoch's landing space with one multiply-add. Each batch has its own grid
  offset and pace (0.6-1.4x; a quarter of the small batches cling); the cells are larger (12.8 and 6.5 drop radii), so
  a drop can sit anywhere in the middle 70 % of its cell.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request: the big glass drops should look clearer, and the
dots on the camera lens should spawn at random, drift away from the centre of the camera as the speed rises and run down
when the car is slower. Tested in game on East Coast USA (BeamNG.drive 0.40.5, DX12) on the ETK: parked and at about
90 km/h with the chase camera, and from the driver's seat, parked and with the wipers running. Not tested: night,
Vulkan.
