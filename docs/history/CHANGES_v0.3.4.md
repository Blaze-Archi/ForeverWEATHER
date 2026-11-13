# v0.3.4 (cumulative over v0.3.1)

## HOW TO CHECK THE RIGHT BUILD IS RUNNING (do this first)
BeamNG keeps loaded Lua extensions and compiled shaders until the game restarts, while the UI app reloads from the zip.
If you install over an older version without restarting, you get a NEW UI on OLD Lua/shaders - sliders appear but do nothing.
1. Fully quit and restart BeamNG after installing. Keep only ONE RainPuddles zip enabled.
2. The app header now shows "Lua 0.3.4" in green. Red "OLD - restart BeamNG" = old Lua is still loaded.
3. Debug view "Build check": magenta/cyan stripes along the top of the screen = the new puddle shader is running.
   Below the stripes: red = pixel treated as vehicle bodywork, green = road. The box should NOT be red any more.

## Fixed
- Black box / dry area around the car: bodywork exclusion now needs height above the ground (ray-cast ground + OOBB bottom)
  AND a smooth surface (paint/glass). Asphalt is rough, so road inside the car's box can never be excluded, even if the box height is wrong.
- "Normal detail" slider: now scales how much of the road's normal map shows through the water (0 flat, 0.55 default, 2 exaggerated).
- Debug dropdown blank: fixed.
- Tyre spray: replaced the blob with a trail of 8 advected, expanding, rising puffs with billowing noise (volumetric-looking mist),
  lit from the light level around the wheel so it stays pale on dark asphalt. Same gates as before (wet field, speed, depth).

## Added
- Global road reflection slider (0 = subtle film, 1 = whole wet road reflects like a puddle). Works without the mask textures.
- Procedural masks toggle (no texture dependency while BeamNG's texture cooker imports the .data.png files).
- Acceleration inertia for droplets; bigger default puddles (44 m pattern).
- status() logs each box's axes, bottom height and ray-cast ground; getDiagnostics reports the Lua version.

## Not verified
Not run in BeamNG. Lua/JS syntax-checked; helper HLSL functions and the spray density were compiled and run on a CPU harness
(spray rendered and inspected). The edited puddle/droplet main functions are not engine-compiled.
