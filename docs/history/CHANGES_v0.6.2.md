# 0.6.2 (fix for 0.6.1: puddles showed the flat "sky fallback" in daylight)

Cause: from a chase camera most puddle reflections point above the top of the screen, so the screen-space trace
cannot find them and the shader used its fallback, the SH9 ambient, unscaled. In daylight that is a bright, flat,
detail-less colour, and the old puddle reflectance (a 0.14 floor plus boost, ~36-40 % at any angle) put that colour
over every puddle: white patches. At night the same fallback was nearly black, so it went unnoticed.

Fixes (rp_puddles.cs.hlsl):
- Visible-sky probe: 16 fixed points in the upper part of the screen; the ones showing sky are averaged, weighted by
  direction. Missed reflections now show the sky that is actually on screen (colour, clouds, sunset, night).
- Edge extension: on a miss the trace reports what it last saw on screen (the sky pixel it crossed, the border pixel
  where it left the screen, or the far geometry it ran out of steps in front of) and the reflection continues with it.
- Ambient sky only as last resort (no sky on screen), now as radiance (irradiance / pi) instead of unscaled.
- Physical water reflectance: Fresnel with F0 = 0.02; 'Reflectivity' boosts it toward a mirror (1 = mirror).
  Default 0.65: ~19 % reflective looking down (was ~36 %), still mirror-like toward the horizon.
- New per-layer setting "When the reflection misses" (Wet ground > Reflections and Puddles > Reflections):
  visible sky + screen edges (default) / ambient sky colour only / nothing (real reflections only).
- "Sky fallback brightness" is now "Fallback brightness" (same settings, same values).
- Debug view 7 now shows exactly what a missed reflection displays.
- The probe only runs on pixels that actually draw a reflection.

Vehicle droplets (rp_droplets.cs.hlsl): reflections leaving the screen use the visible sky (8 probes) instead of the
unscaled ambient, so beads are no longer white specks in daylight.

Not changed: windshield shader, native ground reflections (BeamNG SSR), lens drops.
