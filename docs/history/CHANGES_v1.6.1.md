# ForeverWEATHER 1.6.1

Rain on the glass in two layers. After every pass the wiped glass gathers fresh drops. Left alone, it merges back into
the glass around it with no seam. Also four fixes, one of them for the rain sound.

**Pre-release: untested.** This version has not been tested in game. It was checked outside the game only (see
*How it was checked* below). Please report bugs in the [Issues tab](https://github.com/Blaze-Archi/ForeverWEATHER/issues).
It includes everything in [1.6.0](https://github.com/Blaze-Archi/ForeverWEATHER/releases/tag/v1.6.0-pre) (glass fog,
body mist, rain sound, calmer puddles, mist fixes), which was also never tested in game.

## Glass drops in two layers

- **Layer 1 is the glass the blades never reach.** Each spot holds one drop at a time. The drop lands, stays a while,
  then gives way to the next one, on a slow turnover of the spot's own.
- **Layer 2 is what a blade leaves behind.** Fresh drops land on the wiped glass, each at its own moment. They land
  sooner in heavy rain and when you drive into it. A drop lands small and grows as the rain that lands after it joins
  it; the big merged drops take longest.
- **The two layers merge with no seam.** When a spot's turnover comes round, its fresh drop gives way like any other
  drop would. The drop that follows is layer 1's own. A wiped arc left alone therefore becomes the glass around it
  again, spot by spot, and nothing jumps.
  - The turnover takes 25 rain-clock units. In medium rain that is about 20 s parked and about 8 s at 100 km/h.
  - The next pass starts layer 2 over, with new drops every time.
- **On the windshield and the rear glass,** the simulated glass water still decides which of a pass's drops show: rain
  landing on the glass and water running in from the edges.
- **Drops on glass the blades never reach also land small and grow now.** With the glass water, a new drop there fades
  in instead of appearing at once.

## Fixes

- **Drops on wiped glass no longer come and go when you speed up or slow down.**
  - The shader used to measure the rain since the last wipe as the rain rate now times the time since. A change of
    speed changed that rate at once, for the whole arc.
  - Now Lua stamps the pane's own rain clock, and its rate, when each wiper cycle begins. A pass always happens in the
    sweep right after, so the shader knows where the clock stood at the pass, and the rain since then counts on exactly
    with the clock.
  - The same fix applies to the running drops on wiped glass and to the haze that builds up between wipes.
  - The clock stops under a roof, so a tunnel needs no extra rule.
- **The drops ahead of the blades no longer change just before they are wiped.**
  - Their identity was tied to the wiper cycle, so every drop on the wiped glass changed when a new cycle began, a
    moment before the blade reached it.
  - Now it is tied to the passes over that spot.
- **A spot the blades have not reached yet in this cycle now knows when it was last wiped.**
  - This was already true in a repeating run. It is now also true after a single wipe, and when the wipers are switched
    off and on again.
  - Before, such a spot counted as never wiped until the blade came: its drops filled in at once, and on panes without
    glass water the fog jumped to its full level.
- **Simulated mist: normal driving is back to 1.5.2.**
  - 1.6.0's wheelspin fix also lowered the mist of normal driving: less of the spray hung in the air below about
    43 km/h, and all of the mist fell out a little faster.
  - Now only a tyre that spins over the ground throws less hanging mist, and only very dense mist falls out (above a
    density of 1).
  - Normal driving, puddles included, throws the mist it did in 1.5.2: within -0.1 % to +3.6 % on the solver's numpy
    port, with the same peak density. Static wheelspin stays fixed (peak density 2.25 down to 0.56).
  - The puddle spray itself, the extra spray through a puddle, comes from the spray pass, which 1.6 never changed.
- **Rain sound: the drumming on the roof no longer jingles.** From the driver's seat it sounded like metal jingling.
  - Every drop on the roof was one of six synthesised metal pings at 1.7 to 3.6 kHz, ringing with a few bell-like
    overtones.
  - Now it is rain drumming on a lined steel roof: a dense patter of short, dull taps in 32 variants, the bigger drops
    with a quick thump of the panel that dies out within a few cycles (no pitch, no ring), over a low rush. The roof
    lining softens everything above about 2.5 kHz.
  - It is about as loud as before, so the mix is unchanged. Only the roof loop changed (`rain_roof.ogg`).
  - (Added to 1.6.1-pre after its first build: the release was re-spun with it.)
- **Release workflow:** a tag with a suffix, like `v1.6.1-pre`, now passes the version check. The workflow run for
  `v1.6.0-pre` failed on it, and that release was published by hand. A manual run can now also re-spin a pre-release
  from a newer commit (*retag*: its tag moves to that commit; never for a final release).

## Technical

- Shaders: `shaders/common/postFx/rainPuddles73/`. The folder is renamed so that the game compiles the new shaders
  instead of reusing cached ones.
- `rp_windshield`:
  - New constants:
    - `rpWindX`: the rain since the current and the previous wiper cycle began, and the clock's rate then.
    - `rpWindY`: seconds since the previous cycle began.
  - New functions:
    - `rpRainSince`: the rain since a pass is the rain since the cycle began, minus that rate times the seconds into
      the cycle at the pass.
    - `rpWipeLast`: a drop's identity after a pass is the number of passes over that spot so far. A pass of the cycle
      before counts as that cycle's last, so the identity does not change when a new cycle begins.
  - Layer test: a wiped spot is layer 2 while the rain since its last pass is less than how far its turnover has run.
  - Growth: the radius grows from 0.6 to 1 of its size over 1.2 rain-clock units after landing (3 for a merged drop).
  - The wipe timeline for the drops, the running drops and the haze uses the real previous cycle (`tlW`).
  - The water lines keep 1.5.1's timeline.
  - `rpLandAge` is removed.
- Lua: `WIPER.rainConsts(flow, wip)` stamps the clock on the cycle count. A cycle that began between two frames, or
  several at once after a hitch, is stamped with the clock as it was then.
  - No new top-level locals: the main chunk still uses 198 of LuaJIT's 200.
- `rp_mist.cs.hlsl`:
  - The mist share of a tyre's spray is `1 - 0.7 * slip * (1 - smoothstep(2, 12, ground speed))`, which is 1 for a
    rolling tyre.
  - Fallout is `rpMistG.z * max(density - 1, 0)`.
  - The drag target is capped at 0.9 × VMAX.
- Tools: `build_release.py --check-version` and `release_notes.py` read the version before a `-` or `+` in a tag.

## How it was checked

Outside the game only, so it needs testing in game:

- Every Lua file compiles under LuaJIT 2.1. Every compute shader compiles to SPIR-V with glslang's HLSL front end
  against stand-in engine headers (10 of 10).
- The headless harness, which runs the extension against stand-ins of the engine, got a new scenario with the wipers
  running in the rain: 232 checks, 0 failed. The new constants are set every frame, finite and sane.
- A model test of the two layers ran the real Lua stamping together with a port of the shader's logic. It covered
  2,500 spots over 7 minutes of driving: speeding up and braking, a tunnel, intermittent then fast wipers, a long rest
  and a single wipe.

  | Check | 1.6.1 | 1.6.0 |
  |---|---|---|
  | Visible drops that swapped or vanished with no blade passing | 0 | 47,585 swaps |
  | Wiped spots identical to the unwiped glass once the wipers had rested | 2,000 of 2,000 | 0 of 2,000 |

  The rain since a pass came within 0.19 rain-clock units of the true value (0.02 on average). The worst case was
  accelerating hard during a sweep.
- The mist change was checked on the numpy port of one layer of the mist solver: rolling at 18 to 130 km/h, the same
  with three times the spray, static wheelspin, a reset spike, and a car driving then parking.
- The roof loop was measured, decoded from the .ogg, against the 1.6.0 one:
  - its sharpest tonal line fell from +8.1 dB to +0.9 dB, so it has no pitched ringing left;
  - its loudest moments are as noise-like as plain rain (tonality 0.58, from 0.35; plain noise is about 0.56);
  - the energy above 2 kHz fell from 12.9 % to 4.1 %;
  - the taps are as distinct as before, the A-weighted level is within 0.6 dB and the loop has no click.
- **Not checked:** anything on screen or through the speakers in game. That includes how the drops look as the
  layers merge, the growth of new drops, the new roof sound in the game's mix, and the game's own shader compiler
  (DX12 / Vulkan).

## Made with AI

Written by Claude (Anthropic) in Claude Code at Blaze-Archi's request. The wiped glass gathers drops and merges smoothly
back into the glass around it until the next wipe, in two layers like the glass fog. It is released as an untested
pre-release.
