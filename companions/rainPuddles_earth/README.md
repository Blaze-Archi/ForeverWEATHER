# Rain Puddles × BeamNG.Earth 1.0.0

A small companion mod for **BeamNG.drive 0.40**. On the **BeamNG.Earth** map, rain uses BeamNG.Earth's real weather, but **Rain Puddles** draws it. BeamNG.Earth's own rain particles are hidden while Rain Puddles is on.

Rain Puddles draws:
- wet roads and puddles;
- drops on the body, the windshield and the camera lens;
- tyre spray;
- falling rain.

On every other map the companion does nothing.

## Requirements

- BeamNG.drive 0.40.x
- Rain Puddles 1.0 (`rainPuddles.zip`)
- BeamNG.Earth 1.8.x (installed by its own app into `mods/unpacked/beamng_earth`)

The companion still loads without either mod. It just waits until both are present.

## Install

1. **Close the game.**
2. Copy `rainPuddles_earth.zip` into `<BeamNG user folder>/current/mods/`.
3. Start the game and open the BeamNG.Earth map.

When it takes over, a toast says "Rain Puddles draws the rain on this map".

## What it does on the BeamNG.Earth map

| Situation | Result |
|---|---|
| BeamNG.Earth weather **Real**, Rain Puddles **on** | Rain Puddles' *Rain* follows the rain BeamNG.Earth shows. That rain comes from Open-Meteo through BeamNG.Earth's server, fades in and out over about a minute, and stops above the cloud base. BeamNG.Earth's rain particles are hidden, and the falling rain is drawn with Rain Puddles' own rain recipe. |
| BeamNG.Earth weather **Manual** | You set the rain yourself. Rain Puddles gets back the *Rain* value you had before. |
| Rain Puddles switched **off**, or the mod is unloaded | BeamNG.Earth's own rain comes back exactly as BeamNG.Earth wants it. |
| You leave the map, or switch the companion off | All Rain Puddles settings it changed get your values back. |

**Arriving in real rain:** when you load the map where it is already raining, the ground is wet straight away, while BeamNG.Earth waits 20 s and then fades the falling rain in. After a teleport inside the map, the ground gets wet or dries over Rain Puddles' normal wet-up and drying times.

**Snow** stays BeamNG.Earth's, because Rain Puddles has no snow.

**Rain sound** stays BeamNG.Earth's. It follows the same real rain.

### Rain Puddles settings held while you are on the map

These stay off on the BeamNG.Earth map. Your own values come back on every other map.

| Rain Puddles setting | Why it is held off |
|---|---|
| *Follow the game's weather* | It would read BeamNG.Earth's rain objects wrongly. |
| *Cloud the sky over while it rains* | BeamNG.Earth drives the real clouds. Any other mod changing them makes BeamNG.Earth switch its whole real weather to **Manual**. |
| *Native rain* | Rain Puddles would take over BeamNG.Earth's rain or snow object. This companion draws the falling rain itself, with Rain Puddles' recipe, as long as your *Native rain* was on. |

- If you move Rain Puddles' *Rain* slider while BeamNG.Earth is on Real, the value goes back to the real rain, and a toast explains why. To choose the rain yourself, set BeamNG.Earth's weather to **Manual** (pause menu > BeamNG.Earth settings).
- Your own values are also saved in `settings/rainPuddles_earth_restore.json`. That way they come back even after a crash.

## Console (GE Lua, `~`)

```lua
rainPuddlesEarth.status()               -- what it is doing now (also written to beamng.log)
rainPuddlesEarth.setEnabled(false)      -- hand everything back; true to turn it on again
rainPuddlesEarth.set('rainGain', 1.2)   -- Rain Puddles rain = BeamNG.Earth rain share x gain (0-3, default 1)
rainPuddlesEarth.set('preWet', false)   -- don't wet the ground at once when arriving in rain
rainPuddlesEarth.set('particles', false) -- no falling rain from the companion (screen-space rain only)
```

Settings are saved in `settings/rainPuddles_earth.json`. Log lines are tagged `rainPuddlesEarth`.

## Troubleshooting

- **BeamNG.Earth says "Weather set to Manual because it was changed".** Some mod wrote the weather. With the companion off or not installed, that is Rain Puddles' cloud setting as soon as it rains. Switch the companion on first (`rainPuddlesEarth.setEnabled(true)`), then choose **Real** again in BeamNG.Earth's settings. In the other order, Rain Puddles puts the old cloud cover back once more and BeamNG.Earth catches it.
- **Switching the companion off or removing it on the BeamNG.Earth map** gives Rain Puddles its cloud setting back right there. Rain Puddles then writes the clouds whenever its own *Rain* slider is above zero, and BeamNG.Earth switches to Manual within a few seconds. Leave the map first if you want to keep Real weather.
- **No rain while it rains in reality.** Check that BeamNG.Earth's weather is on Real and that its server has weather data. `rainPuddlesEarth.status()` shows `rainNow` and `rainMmH`.
- **Falling rain missing.** Check that *Native rain* was on in Rain Puddles before you loaded the map, and that `particles` is `true`.

## Uninstall

Leave the BeamNG.Earth map (or run `rainPuddlesEarth.setEnabled(false)`), close the game, and delete `rainPuddles_earth.zip`. Your Rain Puddles settings are already back by then. If the game crashed on the BeamNG.Earth map, start the game once before deleting the zip, so the companion can give them back.

## How it works (for modders)

GE extension `rainPuddlesEarth` in `lua/ge/extensions/rainPuddlesEarth.lua`. It is loaded by `scripts/rainPuddles_earth/modScript.lua`.

It reads from BeamNG.Earth's `beamngEarth_weather` extension:
- `rainNow`, `getMode()`, `current()`, `precipPct()`;
- `LEVEL_ID`, `RAIN_NAME`, `RAIN_FULL_MMH`, `GRACE_S`.

It drives Rain Puddles through its public API:
- `getSettings()`, `setSetting()`, `snapWetness()`, `save()`.

It hides BeamNG.Earth's rain with `setHidden` on the level's Precipitation object `bngEarthRain`. It looks the object up by class, because BeamNG.Earth 1.8.2 also gives its rain *sound* emitter that name.

No file of either mod is changed. Everything else stays inside this extension, its two settings files and its two particle objects (`RainPuddlesEarth_Rain`, `RainPuddlesEarth_Spray`), so the mod can be bundled as it is.

## Credits

- BeamNG.Earth © 2026 TecnaGamer, MIT licence. This mod only calls its public Lua and copies none of its code.
- Weather data by Open-Meteo.com (CC BY 4.0), delivered by BeamNG.Earth.
- Rain Puddles by the same author as this companion.
