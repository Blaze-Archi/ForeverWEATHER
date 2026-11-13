# 0.6.1 (fix for 0.6.0)

## Menu fixed: settings now reach Lua
0.6.0 called `lua.extensions.rainPuddles.*` through the Vue bridge. On 0.40 the bridge only exposes Lua functions
it already knows, so that object was undefined and every edit failed
("Cannot read properties of undefined (reading 'setSetting')").
Now: calls go out as plain engine Lua (`bngApi.engineLua`, the path the old AngularJS app used; fallbacks: the
bridge's api.engineLua, then beamng.sendEngineLua). State comes back as the return value of
`extensions.rainPuddles.requestState()` and as the `RainPuddlesState` UI event, so it works even without callbacks.
Diagnostics shows which link is in use ("UI link: ...").
The side-panel button passes the 2nd argument to ui_router.push (no more signature-mismatch warning; the
"push is deprecated" note from BeamNG remains harmless).

## Wet ground and puddles: two separate blocks, each with Surface (PBR) and Reflections
- Wet ground (global)
  - Surface (PBR): wetness, roughness when wet, darkening, normal detail, patchiness, tyre-mark gloss
  - Reflections: engine (Auto / Native / Own) with a live "drawn by" line; native: wet-road materials, SSR quality,
    restore; own trace: intensity, sky fallback, blur, trace steps, trace thickness
- Puddles
  - Surface (PBR): coverage, size, edge softness, pattern size, darkening, water roughness, normal detail, ripples
  - Reflections: reflectivity, sky fallback, blur, trace steps, trace thickness
The own-trace settings used to be shared; the ground now has its own copies
(roadSkyReflection, roadReflectionBlur, roadSsrSteps, roadSsrThickness -> rpPuddleG.yzw / rpPuddleH.x).
Your current values are copied over once (ground steps = 60% of the puddle steps, as before).
Rain amount and Wet effect distance stay at the top because they drive both.
