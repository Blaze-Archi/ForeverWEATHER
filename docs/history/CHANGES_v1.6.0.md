# ForeverWEATHER 1.6.0

Fogged glass the wipers clear, a hint of mist on the cars, rain you can hear (and that goes quiet under a bridge),
calmer puddles, and a simulated mist that no longer runs away after a reset or around a car that stands still.

**Pre-release: untested.** This version has not been tested in game. It was checked outside the game only (see
*How it was checked* below). Please report bugs in the [Issues tab](https://github.com/Blaze-Archi/ForeverWEATHER/issues).

## Glass fog

A fine mist on the outside of the glass: drizzle and fog drops too small to bead, and condensation on glass the airflow
cools. It forms in damp air, and the wipers clear it.

- **The wipers wipe it off along their real sweep**, and it comes back gradually: in about 25 s parked, in about 5 s at
  100 km/h, as the air rushing over the glass brings the mist to it. The automatic wipers also wipe now and then in
  fog, more often the thicker it gets, as an optical rain sensor does.
- **Fogged glass blurs the view through it.** Shapes stay, contrast goes, street lamps and headlights bloom into
  halos. From outside the window turns milky and the dark cabin no longer shows through.
- **Drops and fog interact.** The drops on the glass stay clear in the mist, as real beads take the mist around them
  in. Running drops cut clear channels through it, and so do the lines of water the wipers leave. Mist left alone
  long enough grows into beads of its own, which join the glass water and run off once they are big enough.
- **Where the damp comes from:** drizzle and light rain mist the glass most (a downpour beads and sheets it instead),
  the map's own fog, the wet ground after the rain, a little more at night. On BeamNG.Earth: its real fog, visibility
  and drizzle. Under a roof less of it reaches the glass.
- **Every pane:** windshield, rear glass and side windows. On the windshield and the rear glass the mist is part of
  the simulated glass water; on panes without it, it comes back since the last wipe, or (side windows) follows a level
  of its own.
- From the seat, the falling rain outside shows less through a fogged windshield.
- Settings: *Glass fog & body mist > Glass fogging*, *Fogged view softness*. Debug view 24.
- Only the outside of the glass fogs here. Mist on the inside of a cabin (breath, wet clothes) is out of any wiper's
  reach and is not drawn.

## Body mist

A hint of condensation on cars that stand in damp air, like a car parked on a misty morning. It forms first where the
body faces the open sky (the roof, the hood and the boot lid cool fastest), barely on the sides and never underneath,
and not on a hood an engine has just warmed. Driving keeps it off.

It does not paint the car grey. The micro-drops soften the clear coat's sharp reflection a little, take some
saturation and add a faint veil of daylight. It shows on dark paint and is nearly invisible on white. The beads and
running drops sit on top of it. Settings: *Glass fog & body mist > Body mist*.

## Rain sound

The rain can be heard: a light patter, or a downpour's roar as it gets heavier.

- **Shelter.** Under a bridge, at a tunnel portal or under a roof, the open rain fades and a muffled rain takes over
  from the open sky around you. Deep in a tunnel it is almost gone. Leaving it, the roar comes back.
- **From the driver's seat** the car's body muffles the rain outside, and the rain drums on the roof, a little more
  when driving into it. Under a roof the drumming stops.
- It reuses the shelter grid the falling rain and the dry ground already keep (upward casts around the camera, a few
  per frame, cached), sampled five times a second. The volumes glide between samples, so nothing steps or pops.
- Four synthesised loops (nothing recorded or taken from anywhere), played through the game's own sound engine (FMOD)
  with the game's volume settings. While it is dry the sound emitters are freed.
- Settings: *Rain sound*, *Rain volume*. Any layer can be replaced by an FMOD event or another file from the console:
  `extensions.rainPuddlesAudio.setLayerSound('heavy', 'event:>...')`.

## Calmer puddles

The rings the rain makes in the puddles are **half as strong**, both in the water simulation near you and in the drawn
rings further away, so the puddles stay calm and readable. The tyres' wakes, bow waves and spin rings keep their full
strength, so a car rolling through still stands out clearly. *Rain ripples* keeps its meaning; at the same value the
rain's share is halved.

## Simulated mist: fixed after resets and around cars that stand still

Up to 1.5.2 the simulated mist could fill the air around a car after a reset, or pile up around a car standing still.
The causes, and what 1.6 does about each:

- **A reset or a teleport** made the car's speed readings meaningless for a moment (a jump of hundreds of metres
  between two frames). The first frame after it could drag the air at the range limit and spread mist over a 6 m
  circle. Now a car that jumped (the game's reset hook, or a box that moved further in a frame than a car can drive)
  has its tyres held out of the spray, the wakes and the mist for 0.6 s, and they fade back in afterwards. For the
  player's car the air starts again from calm. A speed no car reaches (over 150 m/s) is treated as no motion, and the
  shader keeps its own limits (the fastest tyre it believes, at most 1.2 m of path per frame).
- **A wheel spinning on the spot** threw mist with no air motion to carry it away, so it piled up toward the top of
  the range. Now the share that becomes hanging mist needs air rushing past the tyre (standing still, a third of it),
  the spinning tread drags the air behind it (the mist streams away), and dense mist falls out (its drops meet and
  rain back onto the road).
- **A parked car's wake never came to rest.** The air calms by under 1 % a frame, less than one storage step near
  rest, so rounding wrote the same value back and a coherent drift of a few cm/s stayed for good. The stored air speed
  is now rounded stochastically, so it keeps decaying to an incoherent noise floor.
- **Feedback in still air.** Vorticity confinement (which gives back swirls the coarse grid smears out) now only acts
  where the air really moves. The warm start of the pressure solve is damped, so a stale pressure stops pushing. The
  air's speed is capped as a vector instead of per component (clipping one component turned the flow, a false swirl
  the confinement fed on), and a broken value becomes calm air.

## Pre-release builds

New builds are published as GitHub **pre-releases** by a workflow (`.github/workflows/release.yml`). The release
notes open with a notice that the build is untested and that bugs go to the Issues tab, and the zip carries the same
notice (`PRERELEASE_README.txt`; the game ignores it). The settings panel shows it at the top and the log says it once.
There is a *Bug report* form in the Issues tab.

## Technical

- Shaders: `shaders/common/postFx/rainPuddles72/` (new: `rp_kawase`).
- **Dual Kawase blur** (Bjorge 2015): five post effects in the glass passes' bin (UpscaleDispatch, priorities
  98.96-98.92, between the droplets and the glass passes), each a named target of its own sized relative to its input
  (`targetScale`): 1/2, 1/4, 1/8 down, 1/4, 1/2 up. Downsample: centre x4 + four diagonal taps one input texel out;
  upsample: four axis taps one texel out + four diagonal taps half a texel out (x2). Bilinear taps on a linear-sampler
  state block. Premultiplied: the first pass weighs the frame by its depth, so from the seat the cabin in front of the
  glass weighs 0.03 (the hood beyond the windshield plane counts as outside) and the glass passes divide by alpha:
  the blur never smears the dashboard into the view. Each level holds a calibration texel at (0, 0) (8-bit sRGB-read
  targets are put back, as for the simulations). Lua skips all five unless some glass of the player's car within 25 m
  of the camera is fogged. The glass passes read the result in slot 2, an unused puddle mask until 1.5.2.
- Glass water target (`#rpGlassA/B`): z holds the mist (0..1.5). New constants `rpGlassC` (target, form / clear rate,
  wash rate) and `rpWindW` (pane level, regrow time, blur valid, strength).
- Body mist: `rpDropE`, `rpVehI0..5` (mist, hood heat) in the droplet pass. The pass now also runs with no rain while
  there is body mist (bead density 0 when *Body drops* is off).
- Mist: new `rpMistG` (warm-start share 0.85 in the first Jacobi iteration, tyre speed cap 90 m/s, fallout 0.6 / s per
  unit of density, confinement fades out below 1.2 m/s) and `rpMistH` (frame, dither seed); `rpPack16D` in
  `rp_lib.h.hlsl`. Paused (no time step), the pressure and the projection leave the air as it is.
- Ripples: `WAVE.rainK = 0.5` on the drops' impact depth (`rpWaveD.w`) and the drawn rings' strength (`rpPuddleB.y`).
- Falling rain: `rpRainB.w` is now how much of the rain shows (was a brightness Lua always set to 1).
- Rain sound: `lua/ge/extensions/rainPuddlesAudio.lua` (its own extension), `art/sound/rainPuddles/*.ogg` (synthesised
  by `tools/gen_rain_audio.py`: circular buffers, so every loop is seamless), `extensions.rainPuddles.getAudioState()`.
- External weather: `setExternalWeather(src, values, { humidity = 0..1 })`; the BeamNG.Earth bridge sends it.
- The main extension's chunk was at LuaJIT's limit of 200 local variables (199). 1.6 keeps its new state in tables and
  removed three locals (the bisect probes of 0.4.6, the two precipitation names), and now uses 198.
- Settings version 30 (new settings only; nothing of yours changes).
- Tools (not in the zip): `tools/build_release.py` (the zip, version check, pre-release notice), `tools/release_notes.py`,
  `tools/ci/check_shaders.sh` with stand-in engine headers, `tools/gen_rain_audio.py`.

## How it was checked

Outside the game only, so it needs testing in game:

- Every Lua file compiles under LuaJIT 2.1 (the game's Lua). The main extension, the sound and the BeamNG.Earth bridge
  were run headless against stand-ins of the engine through a scripted session (191 checks): driving, a teleport, the
  reset hook, an impossible speed reading, a tunnel, a half-covered road and the driver's seat for the sound, fog
  building up in drizzle, the blur chain switching off when dry, body mist on parked cars in fog. Every post effect's
  constants were set each time without an error and never carried a NaN or infinite value.
- Every compute shader compiles to SPIR-V with glslang's HLSL front end against stand-in engine headers. The 1.5.2
  shaders compile against the same headers, which shows they match the real ones closely enough.
- The mist fix was checked on a numpy port of one layer of the mist solver (same grid, packing, forcing, pressure
  solve). Reset spike: 1.5.2 3.5x the mist and faster air, 1.6 normal decay even without the tyre hold. Static
  wheelspin: peak density 2.25 down to 0.46, and the mist now streams away. Parked: the frozen residual drift goes from
  0.021 m/s (coherent) to 0.007 m/s (noise).
- Not checked: anything on screen or through the speakers. That includes the look of the fog, the blur and the body
  mist; whether this build of the game honours `targetScale` for the blur levels (if not, they come out full size: a
  wider pass, the same look); the sound emitters and their volume changes on the game's FMOD; Vulkan / DX12 shader
  compilation in the game.

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request: screen-space window fog over a Dual Kawase blur
from the prepass depth, wiped by the wipers with gradual re-fogging and drops interacting with it; a subtle fog on the
car bodies; FMOD rain sound with shelter detection; half the rain ripples on the puddles; the Navier-Stokes mist fixed
for vehicle resets and static cars; GitHub pre-release tagging with an untested notice.
