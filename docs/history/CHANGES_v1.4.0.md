# ForeverWEATHER 1.4.0

Leaner: the stylized, arcade-style extras are gone, the realistic rain stays.

## Removed: Midnight

The night street-racer look of 1.0.1 to 1.3.1 is gone, with everything that belonged only to it:

- the night film grade (teal shadows, contrast, vignette, the city's glow on the overcast sky), the haze and glow around
  the lights and the lamp halos in the night air, with their sliders (Tone, Night grade, Night air, Glow, Lamp halos);
- holding the clock at midnight;
- the soaked streets that stayed wet whatever the rain did;
- the 'Midnight' Quick look button;
- the grade shader pass (`rp_grade.cs.hlsl`, `rp_grade.h.hlsl`), one full-screen pass less at night.

## Removed: Random mood

The 'Random mood' button and 'A random mood on every map' are gone. They changed the time of day, turned the sun to a
random direction and set the haze. ForeverWEATHER no longer touches the time of day, the sun or the fog.
`extensions.rainPuddles.randomMood()` and `clearMood()` are gone from the console API.

## Removed: the street-lamp boost

The mod no longer lists the map's street lamps (up to 24 within 300 m) to add light the game does not draw:

- the extra lamp highlights painted on the wet road at night, and the 'Lamp highlights (night)' slider;
- the tiny lamp sparks in the beads on the cars and in the drops on the glass.

At night the wet road and the drops now show the light the game itself draws: the wet road through its reflections,
the drops through their refraction and the light catch rims (which still brighten where a drop mirrors something much
brighter than the paint or the cabin, including lamps on screen). 'Light streaks' stays: it stretches the lights in the
wet road's reflections toward you. The tyre spray is still lit at night by the lights on screen around it, in their
colour; it only takes the time of day from the clock.

## Unchanged

Puddles, wet ground, reflections, drops on the cars, the glass and the lens, wipers, falling rain, tyre spray and
wakes, hydroplaning (Arcade / Simcade / Sim), shelter under roofs and in tunnels, the Damp / Wet / Storm / Flooded
looks, the Animated Wipers bridge and BeamNG.Earth.

## Settings and other mods

- Your settings stay. The removed settings (`midnight`, `midnightClock`, `midnightGrade`, `midnightHaze`,
  `midnightGlow`, `midnightTone`, `midnightHalos`, `moodOnLoad`, `lampHighlights`) are ignored and dropped from
  `settings/rainPuddles.json` the next time it is saved. A saved Midnight look keeps its values (rain, wetness,
  reflections) as ordinary settings.
- External weather API: the `noMidnightWet` and `noMidnightClock` options are ignored; `wetFloor` works as before.
  `getRainNow()` still returns a `midnight` field, always `false`.
- BeamNG.Earth bridge: with BeamNG.Earth's weather on Manual the bridge now hands the weather back to the player instead
  of staying engaged with no values (it only stayed engaged to keep Midnight's clock off).
- The shaders moved to `shaders/common/postFx/rainPuddles43/`, so the game compiles them afresh.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request. Checked outside the game: every Lua file
parses in LuaJIT, the main extension loads and runs its public entry points against stubbed game functions (also with an
old settings file that had Midnight on), and the settings panel compiles. Not yet tested in game.
