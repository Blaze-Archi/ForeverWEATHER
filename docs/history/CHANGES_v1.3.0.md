# ForeverWEATHER 1.3.0

## Windshield and window drops: the body drops' optics, 1:1

By day the drops on the glass looked like bubbles, and at night you could hardly see them. They now use exactly the
same optics as the drops on the paint:

- **Refraction**: each drop is a strong little lens. It shows a small, upside-down image of the world around it
  (several drop radii away), most of all toward its rim. Before, the image behind a drop moved by 1.6 radii at most, so
  the drop mostly magnified what lay right behind it.
- **Fresnel**: the same scale as the beads, default 0.12 (it was 1.0, which turned every rim into a mirror).
- **From the seat** a drop is seen from inside the water: its curved surface mirrors the dim cabin toward the rim (total
  internal reflection), which gives the thin dark outline of a real drop, and the ray that leaves it bends toward its
  axis. Where that ray would see the cabin itself (roof liner, pillars, dashboard) or leave the screen, the drop shows
  the sky or the ground in that direction instead.
- **Gone**: the fixed white highlight at the upper left of every drop, the milky sky veil over all of them and the wide
  dark ring. Those made the bubble look.
- **New slider**: Glass drops: light catch (default 1.5), as the beads' Light catch.

Your settings: untouched old glass defaults (Fresnel 1.0, refraction 1.0) move to the new ones (0.12, 1.75). Values you
picked yourself stay.

## Light catch at night

At night the light catch did little: it only brightened rims that mirror something bright on screen, and the street
lamps hang above the screen. Now every one of the 8 nearest street lamps makes a tiny, sharp spark in the drops:

- **On the windshield from the seat**, each drop shows a tiny image of the lamps ahead, so the glass glitters under
  street lights, as it does in real rain at night.
- **On the paint and on the glass from outside**, beads that mirror a lamp get a small, mostly white spark.

The sparks are about a pixel in size, never a coloured glow, so the lamps don't tint the beads (1.1's sparks were broad
and lamp-coloured, which is why 1.2 removed them). Their brightness follows the frame's own brightness. Light catch 0
switches them off.

## Puddles and wet road

- **Reflectivity keeps the angle.** Real standing water is nearly clear looking straight down (about 2 %) and becomes a
  mirror toward the horizon. 'Reflectivity' now sets the water's reflectance straight down, and from there it rises
  with the angle like water does. At the default 0.6, the puddles right in front of you showed 15 % of the sky; now
  6 %, so you see their dark bed. Far away nothing changes, and 1 is still a mirror.
- **Light streaks from street lamps.** On rough wet asphalt a lamp's highlight now stretches into a long streak toward
  you: up to 5x longer at low viewing angles, with the 'Light streaks' slider. Deep puddles keep a sharp mirror image of
  the lamp.

## Fixes

- **Black flicker on cars and in the cabin.** It was not reproduced in testing (16 frames from the cockpit and outside,
  driving at night in rain, plus the vehicle-mask debug view). These likely causes are fixed:
  - No pass can write a broken (NaN or infinite) or negative pixel any more. The game's temporal anti-aliasing spreads
    a single bad pixel into flickering black blocks.
  - Shader values sent from Lua are checked the same way.
  - The in-car mask has a soft edge, so cabin surfaces at the edge of the car's box can no longer flip between "car"
    and "wet ground" from frame to frame.
  - The sky seen through the windshield, and spray against the sky, no longer read the game's reversed sky depth (0) as
    an infinite distance.
- Lens drops: the airflow's push is bounded, so drops are not lost on long drives.
- Wipers with Animated Wipers: after a vehicle reset the rain sensor sends the wiper mode again (the wipers could stay
  off).
- Hydroplaning: a broken value can no longer stick to a tyre, a tyre that comes back on applies no stale force, and a
  zero puddle size can't divide by zero.
- Windshield probe: a bent-glass fit with any broken value is rejected (only the first value was checked).
- Midnight grade: its contrast can no longer turn negative.

## Native PBR + SSR

A frame-time check with the rain going from 0.15 to 0.95: Native PBR + SSR rewrote all 59 road materials of West Coast
USA, with the longest frame at 33 ms (Auto: 30 ms, with the game capped at about 34 fps in the background) and no frame
over 50 ms. Native mode runs without stutter now. Auto stays the default, because native mode makes every road of the
same material shine, also in tunnels and under bridges.

## Made with AI

Written by Claude (Anthropic) in Claude Code: research by nine Haiku agents (real puddles, wet-road light streaks,
drops catching light), which then reviewed the new windshield optics and hunted bugs. Tested in game on West Coast USA
by day and at night, from the seat and from outside.
