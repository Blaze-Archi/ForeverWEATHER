# ForeverWEATHER 1.5.0

Simulated water and air: the ripples in the puddles, the mist behind the tyres and the water on the glass are now
simulated on the graphics card instead of drawn from patterns.

## Simulated ripples

The water in the puddles near the camera is a simulation: a damped wave equation (the shallow-water form of
Navier-Stokes for small waves, with its viscous term) on a 16 m grid of 3 cm cells that follows the camera and keeps
its place in the world.

- Every raindrop makes a small crater with a raised rim; a tyre rolling through pushes the water aside in a bow wave.
- The rings spread at about 0.3 m/s, cross, reflect and fade on their own.
- Switch: *Puddles > Simulated ripples* (on by default). Debug view 21 shows the water.

## Navier-Stokes tyre mist

The fine spray tyres throw up on a wet road hangs in the air and goes where the air goes. The air above the road is
three layers (0-0.5 m, 0.5-1 m, 1-2 m), each a 128 x 128 grid of 31 cm cells (40 m) that follows the camera, each an
incompressible 2D fluid solved the stable-fluids way every frame: advection, vorticity confinement, 14 pressure
iterations and the projection.

- Cars drag the air along: a wake behind them, swirls at their sides. Tyres throw spray into it.
- The mist spreads, rises a little and fades within about 1.5 s. A car passing leaves a trail hanging over the road.
- Lit like the tyre spray: by the sky by day, at night by the lights around it (red behind the tail lights).
- The near-tyre spray plume stays as it was.
- Switch and slider: *Tyre spray & wakes > Simulated mist*, *Mist amount*. Debug view 22. About 0.4 ms per frame.

## Glass water

The water on the windshield and on the rear / hatch glass is simulated (256 x 128 over the pane, in the glass's own
coordinates, so it moves with the car). Wiping no longer just hides the drops:

- **The wiped glass fills up again.** Rain beads it up as a new set of drops over the wiped area, while the water left
  on the glass runs off with gravity, the airflow and the car's acceleration once those beat its hold on the glass.
  At the next wipe the new water is the old one, and so on.
- **Water lines at the edges.** Every blade sweeps the water ahead of it and leaves it as a line of big drops where it
  turns and along its parked position. From outside, water pushed or blown off the glass sits a while on the body
  right beside it.
- **The smear after a wipe.** A blade leaves a thin, streaky film that blurs the view a little and scatters the light
  into a hazy veil; it clears in about a second (quicker at speed). *Wiper trail width* sets how much film is left.
- **The rear glass** follows how the air flows over the back of a car: a sloped rear window is shielded from new rain
  above about 40 km/h (the air leaving the roof runs down it), an upright one (hatchback, SUV, van) sits in the
  low-pressure wake, which pulls rain and road spray onto it. With its own rear wiper if the car has one.
- Switch: *Windshield & wipers > Simulated glass water*. Debug view 23. The side windows keep the earlier model.

## Lens drops drift

The drops on the camera lens stay round dots and drift: every batch in a direction of its own (a little down the lens
when slow, where gravity wins, faster at speed), with a slow wobble, until they fade. Up to 1.4 they were all blown
outward from the centre and stretched into teardrops. Wind-tunnel studies of car cameras show the same: drops on a
lens migrate across it and merge, they do not streak. The slider *Speed sweep* is now *Speed drift*.

## New defaults

- Wet-road reflections: **Native PBR + SSR** (was Auto, the mod's own film).
- Drops on the cars and on the glass: **Light catch 0.5** (was 1.5), **Fresnel 0** (was 0.12), **Refraction 2.5**
  (was 1.75). Real water reflects only about 2 % of the light head-on, and a bead is a strong little lens.
- Settings version 29: values you never changed move to the new defaults; values you picked stay.

## Fixes

- A parked car's wheels could report an impossible spin (seen: 9 x 10^8 m/s on the ETK rally car). The tyre spray then
  ran its whole plume for every pixel of the screen, and the new mist took the car for one in a wheelspin. Spin speeds
  no tyre can have are ignored, and the shaders clamp it.

## Technical

- Shaders: `shaders/common/postFx/rainPuddles63/` (new: `rp_waves`, `rp_mist`, `rp_glass`, and `rp_pane.h.hlsl`, the
  pane outline and wiper code the glass passes share).
- 24 new post effects: 3 for the ripples, 17 for the mist, 2 per glass pane. They run after the upscaler and keep
  their state in named targets between frames; the passes that draw read the state of the frame before.
- Engine facts that cost a few tries: a post effect has texture slots 0-5 only (slot 6 is silently dropped); a named
  target (`#name`) takes only one writer (a second one draws into the frame instead); every post effect has its own
  constant buffer, so each pass sets all its constants.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request: the Navier-Stokes ripples and mist, the glass
water with its three wiper effects, the rear glass, the drifting lens drops; Blaze-Archi chose the new drop defaults.
Tested in game on East Coast USA (BeamNG.drive 0.40.5, DX12): the ripples; the mist by day and at night from the chase
camera, a roadside camera and the driver's seat; the glass water from the seat, from outside and while driving; the rear
glass on an Ibishu Covet; the lens drops while driving. Not tested: a car with a rear wiper (the rear glass uses the
front wipers' code), Vulkan.
