# ForeverWEATHER 1.3.1

## Tyre spray at night

At night the spray was a faint grey haze, or nothing at all: it took its brightness from the dark road and a fixed grey
floor and never the colour of the lights. Now it is lit like real spray at night:

- **The light around it, in that light's colour.** Street lamps, the car's own tail and brake lights, headlights.
  Wet asphalt returns about a fifth of the light that falls on it, a cloud of water drops nearly all of it, so the mist
  is several times brighter than the road under the same light.
- **The car's own tail lights.** A rear tyre's plume starts right under them. Their colour is read on screen where they
  should be, and they light the mist near them, so the spray behind a car glows red at night and flares up when it
  brakes.
- **A glow around bright lights next to the plume.** Mist scatters their light toward you.
- **No glowing haze in the dark.** In an unlit street the spray barely shows, as in reality.

By day nothing changes: the sky lights the mist as before. The switch follows the time of day.

## Windshield drops seen from outside

From a chase or showcase view the drops on the windshield were invisible: at a few metres a drop is a pixel or less, and
the shader faded such drops out. Now, seen from outside:

- **Drops show as distinct specks.** They are drawn at least 2 px wide, and only as many of them as keeps the glass's
  real wet coverage. They catch the sky by day and the street lamps at night. From the seat nothing changes.
- **The windshield is also found from outside.** A car without a windshield frame in its jbeam was only measured from
  the driver's seat, so a player who never sat in it (chase cameras) got no drops on its glass from outside. The driver
  camera's position now stands in for the eye while the car is still.
- **The rims catch the sky like the beads on the paint**, up to the glass drops' Light catch.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request, tested in game on West Coast USA, by day and at
night: spray from the chase camera at 90 km/h, the windshield from 4.6 m outside.
