# 0.7.1 - real windshield per car (probe)

Mesh names differ on every car, so the windshield is now found from geometry, inside the vehicle's own Lua
(new file lua/vehicle/extensions/rainPuddlesProbe.lua), the first time you sit in a car with an in-car camera:
1. The user's probe idea: from the driver's eye go up to the roof, step 5 cm down, then forward until the glass is
   touched (ray casts against the car's own collision triangles at their current node positions).
2. A fan of ~54 rays from the eye toward the front; a robust plane fit (best triplet + inliers, least-squares
   refinement) keeps the surface that faces forward and is straight ahead of the driver (not roof, dash, pillars).
3. Result in car-local coordinates (centre, normal, axes, size), sent to GE Lua and remembered for that car, so it
   follows the car afterwards. A new spawn / config change probes again. Pause menu > Rain Puddles > Windshield
   shows "Glass: real glass found by the probe (...)" or why it fell back; "Re-scan windshield" probes again.
Drops, haze, smear and both wiper blades now sit on the measured glass (the blades scale to its size); the depth
mask still clips everything to what you really see through it. If a car has no usable triangles there, the old
estimated plane is used and the reason is shown.

Tested offline: the probe file itself was run (fengari Lua VM) on a synthetic cabin (roof, raked glass, dashboard,
pillars, hood, doors) with the car yawed and pitched: centre within 4 cm, normal within 1 degree; a cabin without
glass triangles is rejected ("no glass straight ahead"). Not run in BeamNG.
