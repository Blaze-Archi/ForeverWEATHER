# 0.6.0
Builds on 0.5.0 (global native road reflections + dry-box fix are unchanged).

## 1. Global wet road: own PBR controls
New "Wet road (global)" section, independent of the puddles:
- Road wetness: how wet the road gets for the current rain (native material film, own film and darkening).
- Wet roughness (1 = dry, low = mirror): replaces "Wet-road smoothness". It is written into the road materials
  (native PBR + SSR path) AND used by the own film, so both paths agree. Raise it to stop the mirror look.
  Applies within ~0.25 s of moving the slider.
- Reflection intensity (own film), Wet darkening, Normal detail, Patchiness, Tyre-mark gloss.
Your 0.5 values are migrated once (roughness = 1 - old smoothness; old shared darkening/normal seed both sides).

## 2. Puddles separated
Puddle darkening, reflectivity, water roughness, ripples, normal detail, coverage, size, softness and pattern size
now only affect standing water. Road sliders never change the inside of a puddle and vice versa
(new shader constants rpPuddleF / rpPuddleG; puddleReflection no longer scales the road film).

## 3. UI moved from AngularJS to Vue
- ui/ui-vue/mods/RainPuddles (index.js entry point, structure follows BeamNG's Anna's Toolbox example; its Lua is not used).
- Pause menu -> Mods -> Rain Puddles: full settings card.
- "Open side panel": a route with the settings docked on the left and the scene visible for live tuning.
  Console: extensions.rainPuddles.openUI()
- All previous controls are present, plus Automatic wipers, droplet life rate, run-off, trails and all lens controls.
- The AngularJS app (ui/modules/apps/RainPuddles) is removed; it no longer appears in the UI Apps list.

## 4. Vehicle droplets redesigned (rp_droplets.cs.hlsl + new art/rainPuddles/droplet_atlas.data.png)
- New 512x512 droplet atlas: 8 irregular beads, 4 run-off teardrops, 3 flat merged glass droplets (normal, thickness, coverage).
  A calibration tile is checked at runtime; if the texture is not loaded yet, analytic shapes are used instead.
- Physics: tangential force = gravity + quadratic airflow drag (stronger on surfaces facing the wind) + inertia.
  Size-dependent adhesion: small beads cling, big ones break free first; beads creep before they let go.
- Three populations: beads (rain hits, grow, evaporate), runners (stretched teardrops running along the force with a
  wet trail), mist (tiny beads on upward surfaces, blown off at speed). Undersides stay dry.
- Per-vehicle flow clock from Lua: speed changes make droplets move/respawn faster without positions jumping.
- Shading: screen-space environment reflection (street lights, sky) with Fresnel, refraction projected from the
  real droplet slope, dark total-internal-reflection rim, caustic, contact shadow ring, wet-paint film reflection.
- Debug view 15: droplet force field.

## 5. Camera lens droplets (new pass rp_lens.cs.hlsl, "Lens drops" toggle)
- Log-polar droplet grid scrolled outward: droplets travel from the centre to the edges and are gone once they leave.
- Clear central zone; spawn radius biased outward. Sweep speed and spawn rate follow a smoothed vehicle speed
  (calm when parked, swept off in about half a second at 130 km/h). Density scales with rain and speed.
- Stops new rain under roofs/bridges/tunnels (ray cast up from the camera).
- Controls: intensity, maximum density, size, clear-centre radius, speed sweep, refraction, also-in-cockpit.

Static checks: Lua parse (luaparse 5.1), Vue SFC compile (@vue/compiler-sfc), JS module syntax, UI key / shader
uniform cross-check, Python port of the lens shader rendered over a test image. HLSL not compiled here and nothing
was run in BeamNG.
