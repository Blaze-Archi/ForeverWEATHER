# 0.7.0

## Windshield & wipers (rp_windshield.*, rainPuddles.lua)
- Why it never showed: BeamNG 0.40 names the in-car camera "occupant.FL"; the mod only knew "driver"/"interior"...
  and also treated the HOOD camera as a cockpit. Now: occupant / driver / passenger / interior / onboard... count as
  in-car, hood / bumper / orbit / chase / free do not (they get the lens drops).
- Glass mask from the depth buffer: drops only where the view really passes through the glass, so the dashboard,
  A-pillars and roof liner never get drops and each car's real glass opening is used.
- Wipers rebuilt: two tandem blades, drawn on the glass (switch "Draw wiper blades"), with a short water smear.
  The shader rebuilds the blade position from the Lua timeline and knows, for every point of the glass, when a blade
  last passed: the glass is clean right behind the blade and drops build up again gradually (faster in heavy rain
  and when driving into it); each wipe brings a new set of drops. The band the blades never reach keeps its drops.
- Drops: beads that stay where they land (blown off at speed) + running drops that slide slowly down when parked and
  are blown up the glass, stretched into streaks, above ~30 km/h. Out-of-focus refraction of the scene, dark rims,
  thin haze that builds up between wipes. Uses the droplet atlas.
- Auto wipers keep running while you look from outside; "Single wiper sweep" starts one sweep.
- Debug view 8: cyan = glass, yellow = just wiped, white = drops.

## Ripples (rp_puddles.cs.hlsl)
- The 0.3 ripple look is back: rings over all standing water, faded by distance only (0.4-0.6 also faded them by
  pixel footprint, which removed them from most of the road), plus the 0.3 puddle-edge normals. Limited to the
  puddle mask: never on the wet ground. A faint ring highlight keeps them visible when the puddle reflects plain sky.

## Wet ground and puddles fully separated
- New "Wet ground" switch next to "Puddles": each layer can be switched off alone (the native road materials follow
  the Wet ground switch).
- The ground's patchiness has its own pattern and "Patch size"; puddle coverage/size/pattern no longer change it.
- Separate distances: Wet ground > Distance, Puddles > Distance (your old value is copied to both).

## Puddles drawn on cars (vehicle mask)
- Inside a car's box, anything more than "Keep off cars: mask height" (default 0.15 m, Puddles section) above the
  road is the car, whatever its roughness. Before, matte bumpers, diffusers, splitters and skirts below 0.5 m counted
  as road. Just below the height, glossy or non-flat surfaces are the car too. Lower it if puddles still show on low
  bodywork, raise it if a dry patch appears around the car. Debug view 11 colours follow the setting.

## Vehicle droplets (rp_droplets.cs.hlsl)
- No more drops inside the car: none on the car the camera sits in (in-car views), and inside the box only body
  panels (within ~0.22 m of the box) plus upward lids outside the cabin band (hood, boot, engine cover, bed).
  Seats, dashboard and parcel shelf are rejected.
- Running drops no longer cut off at a certain speed: two layers of drops on grids that translate along the body
  (backward with the airflow, down with gravity, surging forward when braking); Lua integrates the offsets per
  vehicle, so the travel is unbounded and speed changes never make them jump. Drops fade in and out individually,
  the layers move at different speeds and wobble, streaks stretch with speed and leave wet trails.
- More variety: wide bead size spread with merged flat drops, darker rims, glints of the brightest visible sky.
- "Run-off droplets" is now "Moving droplets".

Checks: Lua parse, Vue compile, JS syntax, settings/uniform/function cross-checks; Python ports of the windshield
(glass space incl. wiper timeline) and of the droplet stream layers rendered and inspected. HLSL not compiled here,
nothing run in BeamNG.
