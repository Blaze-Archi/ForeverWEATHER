# Rain Puddles & Droplets 1.0.1

## Fixes

- **Road flicker.** Two causes, both found with frame-by-frame captures in game:
  - The *stochastic glossy reflections* (on by default since 1.0 whenever a temporal upscaler was on) shot one random
    reflection ray per pixel and frame. In motion the upscaler cannot average that noise, so wet roads were grainy and
    flickered. They are off again for everyone (settings version 21); the switch stays, marked experimental.
  - The *dry ground under bridges and in tunnels* used a 9 x 9 grid of upward ray casts around the camera and stretched
    its edge samples out to the horizon. The grid moves with the camera in 4 m steps, so every step put other samples on
    the edge, and any bridge, lamp, sign or tree there switched long bands of the far road between dry and wet several
    times a second. Now: 13 x 13 casts (up to 24 m away), each cell needs two of three casts to agree (a lamp post or a
    sign no longer makes a dry patch), the cover fades out 12-22 m from the camera (smooth while driving), and further
    away only a tunnel the camera is inside keeps the ground dry.
- **Lens drops and falling rain at start-up.** The effects were created at the main menu and drew before a level was
  running. Nothing is drawn now until a level is loaded and its loading screen is gone; the lens drops gather again
  from none after every loading screen.

## Look

- **Calmer wet look, not a mirror.** New defaults (tested side by side in game): wet asphalt is darker with softer,
  blurrier reflections (reflection 0.75 -> 0.50, wet roughness 0.40 -> 0.55, puddle-like at max rain 0.20 -> 0.10,
  darkening 0.38 -> 0.45, ground blur 0.55 -> 0.70), puddles are water rather than glass (reflectivity 0.68 -> 0.40,
  roughness 0.16 -> 0.26, coverage 0.36 -> 0.28, blur 0.45 -> 0.55). All quick looks are calmer and each now also sets
  the blur and the light streaks. Settings version 22 moves values still at the old defaults (or at the first Midnight
  look) to the new ones; anything you tuned yourself stays.
- **Car drops look like water.** Each bead used to add a second, flat grey sky reflection on top of the paint's own,
  so at a distance the beads read as grey specks (plastic, or dust), and the tiny mist dots were light grey too. Now a
  bead replaces the paint's reflection with its own curved one: darker where it faces you, a thin dark edge, a bright
  crescent where light focuses, a soft highlight on its sky side and a small sharp glint. The mist dots are darker wet
  specks. Less extra gloss on the paint.
- **Drops clear quickly under roofs and in tunnels.** The body: about 90 s parked (was 150 s), about 3 s at 100 km/h
  (was 10 s). The windshield, rear and side glass have their own, quicker wetness: about 35 s parked (the drops run
  down), under 2 s at 100 km/h.

## New: Midnight

A night street-racer look (quick look *Midnight*, or the new *Midnight* section of the panel):

- the streets stay soaked whatever the rain does (a fine drizzle by default), dark asphalt mirrors every lamp, long
  vertical light streaks, glassy puddles;
- the clock goes to 00:00 and stays there while Midnight is on (your time comes back when it goes off);
- a night grade drawn after the upscaler: teal shadows (lifted a little, so the night stays readable), a light warm push on
  highlights (street lamps already light the city orange), a touch more contrast, calmer colours around
  saturated lights, a vignette, and night air: haze in the colour of the city's light and a soft glow around lamps,
  headlights and neon. Strength, haze and glow have sliders. *Tone* blends two tunings: 1 warm film (sepia highlights,
  the default) and 0 teal night (lifted teal shadows, a light warm push: better under orange street lamps).

Shaders moved to `shaders/common/postFx/rainPuddles23/` (new `rp_grade.cs.hlsl`).
