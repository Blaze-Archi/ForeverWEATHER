# 0.9.0 - tyre spray rewrite + tyre wakes in puddles

## What was wrong with the spray (0.8 and older)
1. Hidden from the chase camera: the depth test compared every pixel with the TYRE's contact depth. The plume trails
   behind the car toward the camera, so the road seen through it is nearer than the tyre and the spray was erased
   exactly where it should be visible; spray against the sky was always erased.
2. Puddles only at default settings: wet asphalt scored 0.35 on a gate that only opened from 0.35 (fully at 0.51).
3. Possibly misplaced: without getAbsNodePosition, node offsets (already in world axes) were rotated through the box
   axes again - only right for a car facing world +Y.
4. A flat 2D smudge sized by 1/depth and placed by a Lua-side projection that assumed the field of view.
5. Only the player's car, 4 wheels, nothing in the hood camera, nothing from traffic.
6. Vehicle speed only: tyre spin ignored (a burnout in a puddle threw nothing).

## New spray (rp_splashes.*)
- World-space plume per tyre from soft particles: 6 puffs leave the tread backward, rise and spread; in a puddle 4
  more form two side sheets. Per pixel the view ray is tested against every puff and against the depth buffer at
  that puff's own distance: spray shows over the road behind the car, behind the bodywork it is hidden, it shows
  against the sky and grows with perspective. Billowing noise, droplet sparkles near the tyre, lit like the road
  around the tyre (stays pale at night).
- Strength: water at the contact (wet road, more in puddles; "Only on puddles" 0 = any wet road) x tread speed;
  wheelspin and sliding add more. Positions follow integrated per-tyre spray clocks (no jumps on speed changes).
- Up to 8 tyres: the player's car (also in the hood camera), then the nearest other vehicles ("Other vehicles too").

## Tyre wakes in puddles (rp_puddles.cs.hlsl)
- Every tyre rolling through standing water leaves, in its own frame like a boat's wake: a churned band exactly as
  wide as the tyre (value-noise chop scrolled by the tread speed), two diverging bow waves from the tyre shoulders
  (a short train of crests, the V narrowing with speed), rings around a spinning tyre (burnout / wheelspin) and a
  short trough where the water is pushed aside (the tyre track looks less flooded). The slopes join the rain
  ripples, so they bend the reflection, shimmer the puddle bed and catch light. Slider "Tyre wakes in puddles".
- Tyres also squeeze the water film out of their track on a wet road.

## Tyre data (rainPuddles.lua, rainPuddlesProbe.lua)
- Node positions are validated against the car's box (both readings tried); cars without wheel data get four
  contact points estimated from the box. Half tread width from the wheel's hub nodes, radius from the ground ray.
- Tread speed per wheel from vehicle Lua (wheelRotators angular velocity x radius, else the average wheel speed),
  requested at 10 Hz; falls back to the ground speed.

Tests: fengari runs with mocked vehicles: contact points of a car yawed 40 degrees match exactly, a car without
wheel data gets box tyres, the vehicle-Lua spin report reaches the shader constants (ground 25 vs tread 48 m/s);
earlier wetness / roads tests still pass. Python ports of the spray (synthetic chase-camera scene) and of the wake
pattern rendered and inspected. HLSL not compiled here; nothing run in BeamNG.
