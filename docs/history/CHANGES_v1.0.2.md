# ForeverWEATHER (Rain Puddles) 1.0.2

## Wet roads: wet asphalt, not a mirror, not dry

The biggest complaint was the ground reflection: either a mirror ("puddles turned to 11") or, with the values turned
down, a road that looks dry. No slider setting could fix it, because the reflection model had the wrong shape:

- **Reflection strength now follows the roughness.** Wet asphalt is a rough surface under a thin film. The ground uses
  the split-sum environment BRDF for its wet roughness: a faint sheen near the car, a bright but soft band toward the
  horizon. The old curve used the smooth-water Fresnel at every roughness, so any wet road mirrored the scene at
  70-80 % in the distance, and lowering the sliders only dimmed everything evenly.
- **Glossy blur.** Reflections on the wet road are soft, vertical smears (the roughness lobe, stretched at grazing
  views), not sharp copies of the scene. 3 x 7 bilinear taps, a fixed pattern per pixel, so nothing flickers.
- **Lamp highlights (new, night).** Under street lamps a wet road shines. The lamps hang above the top of the screen, so
  the screen-space reflection could never show them, and the game lights the road as dry asphalt. The 12 nearest
  lights of the map ahead of the camera now get a glossy highlight on the wet film. Their brightness is measured from the
  frame itself, so it matches the game's lighting at any exposure. Off by day. Slider: Wet ground > Lamp highlights.
- **New values**, tuned in game by day and at night: reflection 0.70, wet roughness 0.42, flooding 0.15, darkening
  0.50, ground blur 0.60; puddles 0.60 / roughness 0.18 / coverage 0.30 / blur 0.45. All looks retuned; Midnight is
  glossier (0.75 / 0.38, flooding 0.20, darkening 0.55).
- Settings version 23: the ground and puddle reflection values start from the new look (Midnight's while Midnight is
  on), because the old numbers mean something else with the new model. Coverage, wetness and everything else stay.

## BeamNG.Earth: the real weather drives ForeverWEATHER

The BeamNG.Earth bridge now ships inside the mod (extension `rainPuddlesEarth` 2.0; the separate 1.0 companion zip is
no longer needed). On the BeamNG.Earth map, with its weather on Real:

| Real weather | ForeverWEATHER |
|---|---|
| rain rate (BeamNG.Earth's own rain, in step with its sound) | rain amount |
| rain rate + weather code | raindrop size (fine drizzle, coarse showers and thunderstorms) |
| rain rate | how fast the road gets wet |
| temperature, wind, sun and cloud, fog | how long the road takes to dry (4-60 min) |
| rain over the last minutes | puddle coverage, flooding, tyre spray |
| rain rate + gusts | rain ripples in puddles |
| downpour vs. drizzle | smoother, glossier film in a downpour, damp asphalt in drizzle |
| snow (above freezing) | wet slush, no falling rain (BeamNG.Earth draws the snow) |
| wind, clock, clouds, fog | set in the game by BeamNG.Earth; the rain, drops and lamp highlights follow them |

- The look values are your own values scaled by the weather, so your taste stays.
- Nothing of it is saved. Your own values come back when BeamNG.Earth goes to Manual, the map is left, or either mod is
  switched off; sliders you move meanwhile are kept for then. The panel shows a banner while the weather drives it.
- Midnight on the BeamNG.Earth map: the real weather decides how wet it is, and BeamNG.Earth keeps its real clock
  (Midnight's grade still applies).
- New API for weather mods: `setExternalWeather(source, values, opts)`, `clearExternalWeather(source)`,
  `getExternalWeather()`, `getPlayerSettings()`.

## Shaders

`shaders/common/postFx/rainPuddles24/` (was `rainPuddles23`).
