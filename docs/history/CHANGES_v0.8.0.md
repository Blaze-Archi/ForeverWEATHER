# 0.8.0

## Ground: wet asphalt that turns into a puddle with the rain
- "Reflection strength" now works with BeamNG's own reflections too: it sets how much glossier the wet road
  materials get (own trace: the reflectance). Default 0.6 = wet asphalt.
- New "Puddle-like at max rain" (default 1): a shared flood curve (starts at 25 % wetness, rises slowly) blends
  every ground value - reflectance, roughness, darkening, normal detail, trace and fallback settings - into the
  puddle settings; at full wetness the ground IS the puddle look (1:1). The native road materials follow the same
  curve (their roughness goes to the puddle water roughness). Ripples stay inside puddles only.
- With the native film on, the mod's own puddle-like ground reflection takes over as the road floods.

## Puddles on roads only
- "Roads only" (default on): the nearest 48 segments of the level's AI road network (map.getMap) are sent to the
  shader every second; puddles only inside a road's width and within ~2 m of its height (no sand, grass, kerbs
  off the road, trees, bridges above). Levels without a road network: grey, non-green surfaces only. The car mask
  from 0.7 still keeps puddles off vehicles.

## Windshield probe
- The probe now starts 5 cm above the driver's eye and goes straight forward; the fan of rays starts there too.
- Only forward-facing triangles count as glass (roof, dashboard and hood are near horizontal): in tests this fixed
  a 6 degree tilt caused by roof hits next to the glass. Inliers are re-selected with tighter tolerances between
  least-squares passes; the size is grown to cover the glass beyond the fan (the depth mask still clips).

## New
- Wet-up and drying (Weather & drying): the ground gets wet over "Wet-up time" (25 s) and dries over "Dry-out time"
  (6 min) after the rain; puddles fill ~2.5x slower and last ~1.6x longer. Ripples, rain particles, droplets and the
  windshield follow the rain itself; wet ground, puddles, road materials and tyre spray follow the water.
  "Skip to the current rain" jumps there.
- Follow the game's weather (optional): the rain amount is read from the level's own rain particles (scaled by
  "Maximum rain particles"); the mod then never touches them.
- Fix: when the mod's rain went to 0 it set the level's own rain object to 0 drops, which could switch off rain
  from the game's weather menu. It now restores that object's original values.
- Light streaks: wet-road reflections of lights are stretched vertically (anisotropic gather), longer on rough
  ground and at grazing views.
- Puddle depth: shallow rim, deeper and darker centre, flatter mirror in the middle; the puddle bed shimmers
  through the ripples.
- Experimental "Stochastic glossy reflections": one GGX-sampled ray per pixel and frame instead of a blur; the
  game's temporal AA / upscaler averages the noise (this pass runs before it). Off by default.

Tests: Lua parse, Vue compile, JS syntax, settings / uniform / function cross-checks. rainPuddles.lua and
rainPuddlesWet.lua were run in a Lua VM (fengari) with mocked BeamNG globals: wet-up / drying timeline, flood
curve, native roughness at full rain, road-segment selection and fallback, constants sent to the shader. The probe
was run on a synthetic cabin. HLSL not compiled here; nothing run in BeamNG.
