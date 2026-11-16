# ForeverWEATHER (Rain Puddles) 1.1.0

## Midnight: night film

Reworked after a frame study of the wet night city in 2015-era street-racing games: a calm, filmic grade over warm
street lighting, soft halos in the moist air, and blurry stretched reflections (1.0.2 already does those).

- **Lamp halos in the air (new).** The 12 nearest street lamps light the wet night air: soft halos around them and light
  cones under them. It is computed per pixel as single scattering along the view ray (no screen-space blur, so a lamp
  behind you or off screen still lights the air in front of you). The halos stop at whatever the ray hits and are
  thicker in the haze and in heavier rain. The scattered light is paler than the lamp, warm white under sodium.
  Slider: Midnight > Lamp halos in the air.
- **Night film tone.** Tone 0 is now the night film: the city's warm light pulled toward teal-grey, calmer colours
  (tail lights, signals and neon keep theirs), milky teal-grey blacks instead of crushed ones, and lamps that stay warm
  white. Tone 1 is still the first, warm sepia Midnight look. Settings version 24 moves the old default (1) to 0; any
  other tone you picked stays.
- **City glow on the sky.** The overcast night sky glows with the city's light: warm near the horizon, teal-grey higher
  up, more of it in more haze.

## Random moody weather (new)

A **Random mood** button under the quick looks picks one of five moods:
- **Blue hour drizzle**: just after sunset.
- **Golden storm**: a low sun under storm clouds.
- **Grey downpour**: a flooded afternoon.
- **Dawn mist**: around sunrise.
- **Midnight**.

Each mood sets the matching look and rain, the time of day for it, a new sun direction and haze. The sun is turned with
the sky's north offset, the way photo mode does it. The same mood never comes twice in a row. A switch, **A random mood
on every map**, does it a few seconds after each map loads; it is off by default.

The map's own sun direction and haze come back on the next map, when the mod unloads, and from the console with
`extensions.rainPuddles.clearMood()`. Nothing changes while BeamNG.Earth's real weather drives the mod.

Console: `extensions.rainPuddles.randomMood()`, or `randomMood('bluehour' | 'golden' | 'downpour' | 'dawn' | 'midnight')`.

## Drops on the car bodies: water, not bubbles

- **Much stronger refraction.** A bead is a strong little lens: it now shows a small, upside-down image of what lies
  several bead radii around it, read with bilinear filtering and a little dispersion. 1.0 shifted the image by only
  about one bead radius, so a bead mostly showed the paint under it, darkened by a heavy rim: a bubble. The dark rim is
  now thin.
- **Fresnel.** The water surface follows the Fresnel law (F0 0.02): clear where it faces you, a mirror toward its rim.
  The reflection replaces what is seen through it there, so no energy is added. Slider: Vehicle droplets > Fresnel
  (mirror rim).
- **Visible at night.** Every listed street lamp sparkles in each bead that can mirror it. The highlight is the lamp's
  reflection at water reflectance, so it is bright even at 2 %. The bead rims mirror the city's glow instead of a black
  sky.
- **Sky fix.** BeamNG 0.40 stores depth reversed (the sky is 0, not 1). The drops' sky test only knew 1, so they never
  saw the sky: no sky colour in their rims and no sun-side glints. Fixed for the drops and the Midnight grade; other
  passes are unchanged (their look was tuned as it is).

## Tyre spray: builds up and fades, no popping

Before, the whole plume (several metres of mist) switched on in the frame a tyre touched a puddle or left a tunnel,
and vanished in the frame it left the water.

- **A plume with a memory.** Every puff of mist carries the water of the spot where it left the tyre: the contact
  point as it was when the puff was thrown, since the tyre has moved on. Driving into a puddle, the plume grows backward
  from the tyre. Driving out, it detaches and drifts away behind the car.
- **Smooth fades.** Leaving a tunnel or a roofed area fades the spray in over about half a second, and going under
  cover fades it out. Other cars' spray fades in when they join the list and fades out toward the 60 m edge instead of
  vanishing. The wheel speed the cars report 10 times a second is smoothed (wheelspin bursts used to step).
- **More life.** The spray starts at half the threshold speed, is full a little above it, and keeps building a little up
  to about 120 km/h. Puffs differ in strength, so the plume looks gusty rather than uniform.

## For other mods

`extensions.rainPuddles.getRainNow()` returns `{ rain = 0..1, wet = 0..1, midnight = bool }`: how hard it rains now, how
wet the road is, and whether Midnight's grade is drawn. Speed Film FX 1.1 uses it for its rain mood.

## Other

- `scripts/rainPuddles/modScript.lua` sets the hydroplaning extension's unload mode (the game asked for it in its log).
- Shaders: `shaders/common/postFx/rainPuddles27/` (was `rainPuddles24`).
