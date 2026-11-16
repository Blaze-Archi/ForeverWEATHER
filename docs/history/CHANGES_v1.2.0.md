# ForeverWEATHER 1.2.0

Includes the changes of 1.1.1, which was not released on its own.

## The mod is called ForeverWEATHER now

- The zip is **ForeverWEATHER.zip** (was `rainPuddles.zip`). Remove the old `rainPuddles.zip` from your `mods` folder when
  you install it: both would load the same files. Your settings stay (same settings file, same extension names).
- The game's mod manager shows its icon, title, tag line and description (`mod_info/FOREVERWEATHER/info.json` and
  `icon.jpg` inside the zip). The pause menu button and the settings panel say ForeverWEATHER.

## Drops on the cars: clear water, not bubbles

- **Fresnel 0.12** (was 1.0). At 1.0 the rim of every bead turned into a full mirror of the bright sky or the city's
  glow, so the beads looked like bubbles. Now a bead is clear water: you see through it, upside down, and its rim
  mirrors only a little.
- **Refraction 1.75** (was 1.0); the slider now goes to 2.5 (was 1.5).
- **The street lamps no longer colour the beads.** 1.1's lamp sparkles and its city-glow rims (and 1.1.1's calmer lamp
  glints) are gone; the beads mirror the sky and the scene as they did in 1.0.2.
- **New shape: the elongated teardrop**, a slim line that swells into a small round head. Moving drops use it, more of
  them the faster they run (most of them at highway speed); round beads and teardrops stay. The droplet atlas is now 4
  x 8 tiles (`art/rainPuddles/droplet_atlas2.data.png`, row 4 = four elongated teardrops).
- Settings version 26: an untouched Fresnel (1.0) or refraction (1.0, or the old maximum 1.5) moves to the new default;
  other values you picked stay.

## Glass drops: their own Fresnel and refraction

New in Windshield & wipers: **Glass drops: refraction** and **Glass drops: Fresnel (mirror rim)**, for the drops on the
windshield, the rear glass and the side windows. Until now the glass drops used the body drops' Refraction; the new
slider starts from the value they used, so they look the same until you change it.

## Lens drops all over the screen

- Rain lands anywhere on the lens, also in the middle of the screen (**Clear centre radius** is 0 by default, was 0.22;
  an untouched 0.22 moves to 0).
- Driving blows the drops toward the edges, more gently than before: at 126 km/h a drop a third of the way out reaches
  the edge in about 1.5 s, at 60 km/h in about 4 s (it was about 3 times faster). Parked, they barely move.
- Each drop spreads as it lands and dries away after 4 to 11 seconds, sooner at speed.
- Shape: a round drop whose side toward the centre is a little longer and narrower, a slight hint of a teardrop (it was
  a teardrop stretched up to 3x at speed).
- How it works: every drop belongs to the moment it landed, and all drops that landed together have been moved outward
  by the same factor since (from the flow Lua integrates from the speed). The shader keeps no state per drop and tests
  one cell of two grids for each of the last 12 moments.

## No puddles on slopes

- Water only stands on level ground: puddles fade out on slopes, from 3 % to 5 % grade by default. New slider in
  Puddles: **Steepest ground for puddles (%)** (1 to 30; 30 is close to the old behaviour).
- The slope is measured from the depth buffer, that is from the shape of the road itself. The puddle mask used to
  accept anything the G-buffer normal called flat, up to about 24 degrees, and that normal carries the road's bump map.
- A flooding road (Puddle-like at max rain) looks only a quarter as flooded on a slope.
- Hydroplaning feels the same: four downward casts around each tyre measure the slope there, so there is no deep water
  under a tyre on a hill.
- Debug view 20: the slope gate (green level enough, red too steep, a stripe for every 1 % of grade).

## From 1.1.1

- **Distance.** The puddles and the wet ground reach further (sliders up to 600 m and 800 m; defaults 250 m and 400 m,
  old defaults and maxima move up). The roads-only mask uses the 64 road pieces nearest to the camera, ahead of it first
  (it was the 48 nearest, which ended about 160 m ahead); reflections search up to 250 m (was 90 m); up to 24 street lamps
  within 300 m light the wet road and Midnight's air (was 12 within 140 m). Distance costs little: the cost follows the
  wet pixels and the trace steps.
- **Midnight.** The lights keep their own colour, a little stronger: sodium lamps warmer, white lamps cooler (1.1 pushed
  every highlight toward sodium orange). The city's glow on the sky takes the mean colour of the nearby lamps. The lamp
  halos are a little weaker and fade with distance in the haze.

## Other

- Shaders: `shaders/common/postFx/rainPuddles31/` (1.1.0 used `rainPuddles27`).
- `extensions.rainPuddles.hydroFlat(x, y, z)`: 0..1, how level the ground is for standing water at a point.
