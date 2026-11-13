# Rain Puddles & Droplets v0.9.0

0.9.0: tyre spray rewritten as a world-space plume (visible from the chase camera, traffic too, follows wheelspin) and tyre wakes in puddles. See `CHANGES_v0.9.0.md`.

0.8.0: ground turns from wet asphalt into the puddle look with the rain, puddles on roads only, wet-up / drying, light streaks, puddle depth, game-weather follow. See `CHANGES_v0.8.0.md`.

0.7.1: the windshield is found per car by a probe in vehicle Lua (roof -> 5 cm down -> forward, plus a fan of rays), see `CHANGES_v0.7.1.md`.

0.7.0: working windshield + tandem wipers, 0.3 ripples (puddles only), separate Wet ground switch / pattern / distance, puddles kept off cars, droplet streams without speed cut-off and without interior drops. See `CHANGES_v0.7.0.md`.

0.6.2: puddle reflections no longer fall back to a flat ambient colour (visible-sky probe, edge extension, physical water Fresnel), see `CHANGES_v0.6.2.md`.
0.6.1: menu fix (settings reach Lua) and fully separate Wet ground / Puddles blocks, see `CHANGES_v0.6.1.md`.

## v0.6.0 at a glance
- **Settings UI is now Vue**: Pause menu -> **Mods** -> **Rain Puddles** (or `extensions.rainPuddles.openUI()` for the side panel with the scene visible). The old AngularJS app is gone from the UI Apps list.
- **Wet road (global)** and **Puddles** are separate sections; the road has its own roughness, wetness, intensity, darkening, normal detail and patchiness.
- **Vehicle droplets** redesigned (new droplet atlas, adhesion physics, runners with trails, mist).
- **Camera lens droplets**: swept from the centre to the screen edges, faster with speed.
See `CHANGES_v0.6.0.md`.


A universal screen-space wet-surface layer for BeamNG.drive 0.40.x: PBR puddles with a stable screen-space reflection / native sky-ambient fallback, volumetric vehicle droplets, cockpit windshield rain and wipers, aerodynamic droplet motion, tyre spray and dynamic rain/precipitation scaling.

The implementation follows BeamNG's documented [Post Process Effects](https://documentation.beamng.com/modding/postfx/), [Compute Shader Example](https://documentation.beamng.com/modding/postfx/compute_example/), [Creating an app](https://documentation.beamng.com/modding/ui/app_creation/), [Materials](https://documentation.beamng.com/modding/materials/), [Reflections](https://documentation.beamng.com/modding/lighting/reflections/), [Ambient Lighting](https://documentation.beamng.com/modding/lighting/ambientlighting/) and [LevelInfo](https://documentation.beamng.com/modding/levels/level_classes/levelinfo/) pages.

## v0.5.0 - chained into BeamNG's native reflection pipeline

Based on the official docs: [Reflections](https://documentation.beamng.com/modding/lighting/reflections/) and [Post Process Effects](https://documentation.beamng.com/modding/postfx/) (`PostFxSSSRObject`, `PostFXSSRQuality`, `PostFXSSRAvailable`, the `SssrSurfaces`/`SssrTrace` bins) and [Materials](https://documentation.beamng.com/modding/file_formats/materials/) (`roughnessFactor` per layer).

Native SSR is traced after lighting, follows **material roughness** and blends over the cubemap. A PostFX at `UpscaleDispatch` runs after that trace, so it cannot feed it. The correct place to chain in is therefore the material (the PBR input), not another trace:

| Layer | Who draws it | How |
|---|---|---|
| Wet-road film (all asphalt) | **BeamNG** (cubemap + native SSR) | `rainPuddlesWet.lua` scales `roughnessFactor` of the level's `DecalRoad`/`MeshRoad` materials by rain, restores the exact originals afterwards |
| Native SSR on/off/quality | **BeamNG** | optional `PostFXSSRQuality` Low/Medium/High while it rains, player's value restored |
| Puddles (masks, ripples, darkening, mirror) | this mod's compute shader | world-space mask + own depth trace + far-field lookup |
| Droplets, windshield, tyre spray | this mod | unchanged |

`reflectionMode`: **Auto** uses the native road film only once the material change really succeeded (otherwise the mod's own film); **Native** forces it; **Own** disables material changes. When the native film is active the shader sets `rpPuddleE.w = 1` and stops drawing its own road film, so the road is never reflected twice.

Native SSR needs Lighting Quality High/Ultra and Vulkan or Direct3D 12 and is Off in every preset (documented). The app shows the live state.

Limits: the native path cannot make *puddle-shaped* patches smoother (a material has no world-space mask); puddles stay with the compute shader. Material edits go through `Material:setField/reload` which is guarded with `pcall` and reported in the app if a build rejects it. Not runtime-verified by the author.

Linux/Vulkan notes: see `LINUX.md`. Vulkan needs `ambientSH9`/`ambientColor`/`fogColor` declared in each shader header (done).

## Install

1. Remove/back up older `rain_puddles*.zip` files from the BeamNG user `mods` folder.
2. Put `rain_puddles_v0.3.zip` in `...\BeamNG.drive\current\mods` (do not unzip it for normal play).
3. Enable it in the Mods Manager, load a map, press Esc and open **Mods -> Rain Puddles**.
4. Set **Rain amount** above 0 and optionally enable **Native rain**.
5. Use debug views 6 and 7 to inspect SSR and the shadow-independent sky fallback independently.

The settings UI is a Vue mod in `ui/ui-vue/mods/RainPuddles` (index.js entry point, pause-menu Mods button, side-panel route).

## v0.3.1 patch notes

- **Puddles:** every asphalt pixel now gets a rain-scaled mirror film (any rain > 0). The puddle mask modulates it; SSR confidence hands off smoothly to a horizon-clamped SH9 sky fallback.
- **Windshield:** glass plane is built from the vehicle basis + OBB extents with a rake angle and an eye-distance clamp. Wiper uses an eased out-and-back timeline (no sawtooth snap); R = blade profile, G = smear/trail from `wiper_sweep.data.png`.
- **UI:** sliders use literal min/max/step (AngularJS 1.5.8 has no native range handling, so interpolated bounds clamped sliders to 0-100), debounced edits that no longer fight Lua echoes, collapsible groups, auto re-sync, wheel count in diagnostics.
- **Tyre spray:** wheel axis nodes -> ground raycast -> screen projection, direction from `getVelocity()`; gated by the same puddle field as the road plus a per-pixel depth test.

## What changed in v0.3

### 1. Reflection stability and shadow-safe gloss

The v0.2 "SSR" projected a reflected direction and sampled one colour. That is not a depth-tested reflection and explains most of the crawling/flicker; off-screen rays were either clamped or discarded, so a puddle could pop when a reflected object left the frame.

v0.3 replaces it with:

- A depth-aware screen-space raymarch against `#prepass[Depth]`, with 8–48 configurable steps, exponential spacing, binary crossing refinement, screen-edge confidence and a distance fade.
- Confidence-weighted blending between a valid SSR hit and a stable sky/environment fallback. A miss, a screen exit, an SSR-disabled renderer or a high-roughness lobe all resolve to the fallback instead of a dark/bright pop.
- The fallback is the engine's auto-bound directional **SH9 sky ambient** (`ambientSH9`), with `ambientColor`/`fogColor` fallback. This is native, dynamic, exposure-aware scene lighting and, critically, is independent of the direct-sun shadow map.
- Puddle gloss is composited **after** wet darkening, so a vehicle shadow can no longer erase the puddle's Fresnel/ambient reflection. Debug view 7 shows exactly the shadow-independent term.
- A roughness-controlled 5-tap reflection reconstruction and screen-footprint mip selection suppress sparkling at distance.

**Important engine limitation:** native material SSR and the level cubemap are consumed inside the material shader. The documented `PostEffect` contract exposes colour, prepass, depth, named targets, and up to six 2D/six cube texture inputs, but does not expose the level's `globalEnviromentMap` cubemap or the internal SSR radiance buffer to a custom PostFX. This mod therefore uses the documented native SH9 sky ambient as the fallback; it does not pretend to sample an unavailable cubemap. On 0.40, native SSR itself additionally requires D3D12/Vulkan and High/Ultra lighting.

### 2. Puddle PBR tuning

- Water uses dielectric F0 = 0.02, not a flat overlay or metallic reflection.
- Roughness is lerped from the road G-buffer/water roughness only where the puddle mask is present; the reflection blur and Fresnel response follow it.
- The puddle normal is reconstructed from the mask gradient plus rain-ring slopes, with a user **Normal detail** control. This breaks up the flat, painted-on look and gives the rim a proper grazing response.
- Wet darkening is separate from reflection, restrained, and tinted toward a water/blue-grey absorption colour.
- A small ambient lift keeps the wet layer glossy inside shadow cascades while preserving a physically plausible dielectric response.

### 3. Vehicle body droplets

- Droplets are shaded as normal-mapped hemispheres, not billboard dots: hemispherical normal, Schlick Fresnel, sky reflection, highlight and a chromatic screen-space refraction (3 colour taps).
- A wet film multiplies the underlying paint first; each bead then refracts, reflects and darkens its rim. The result is refractive and three-dimensional at close range.
- Bead density uses a stable world/vehicle-local cell field and a mip footprint, with a distance fade.
- A per-vehicle relative-airflow vector drives slide direction and life cycle. The `core_interAero` system's real slipstream is physics-side; the visual layer reads vehicle velocity, `be:getWindAt()` and a light local wake estimate, so droplets shear backwards in still air and settle in a wake.

### 4. Windshield rain and wipers

- The cockpit layer is intersected with an approximate windshield plane in vehicle space. Beads stay on the glass when the camera yaws; it is not a screen-locked overlay.
- The plane and wiper geometry are derived from the player vehicle's OBB. The layer activates only in an interior/hood/driver camera inside the player's shell.
- Wiper clearing uses the R/G channels of `art/rainPuddles/wiper_sweep.data.png`: R supplies the blade profile and G the smear/water film. The blade sweeps, leaves a trail, clears droplets in its wake, and the wiped glass gets a subtle gloss change.
- **Automatic wipers** run while rain is above 4%; **Single wiper sweep** triggers a manual sweep. **Wiper speed** and **trail width** are exposed.
- Windshield beads use the same chromatic refraction technique as body droplets, with a speed-driven upward shear.

### 5. Aerodynamic / speed motion

Droplet slide uses the local relative airflow `wind - vehicleVelocity`, projected into the triplanar surface plane, plus gravity. Speed increases slide distance and bead stretch. The wake behind nearby vehicles reduces the effective airflow, approximating the visual effect of the engine's slipstream without writing to physics. The real aerodynamics remain owned by BeamNG's `core_interAero`.

### 6. Tyre spray

A fourth compute pass renders procedural spray at the player's wheel contact patches. The wheel positions are projected to screen space from actual wheel axis nodes and a static raycast to the ground. Spray is gated by the same puddle field as the road, by vehicle speed, by distance, and by a depth check at the contact point so it does not paint through the car. No particle datablocks or extra mesh assets are required.

### 7. Dynamic scaling

The master **Rain amount** now drives:

- Puddle coverage (`coverage × rain^0.72`) and patch size (`size × 0.92…1.08`).
- Droplet and windshield density.
- Tyre-spray gating and opacity.
- Native precipitation: one core `rain_medium` object at low rain, two objects (`rain_medium` + `rain_drop`) above 0.52, with `numDrops` scaled from the **Max precipitation particles** cap. Managed objects are deleted/restored cleanly; an existing level rain object is reused and its original state is restored on unload.

## Debug views

| View | Meaning |
| --- | --- |
| 1 | World grid; confirms depth reconstruction |
| 2 | World normals |
| 3 | Puddle mask field |
| 4 | Distance rings |
| 5 | Vehicle droplet shell tint |
| 6 | SSR hit/confidence only |
| 7 | Shadow-independent sky ambient only |
| 8 | Windshield aperture and wiper clear mask |
| 9 | Tyre spray puddle gate |

On a normal map, start with debug 7 facing the car's shadow; the puddle sheen should remain visible. Then debug 6 while driving to spot SSR confidence changes. If world detail slides over the ground, try **Depth** mode 1, then 2, before changing anything else.

## Settings and console API

The UI sends only `setSetting(key, value)`. All values are clamped in Lua and pushed back to the app.

```lua
extensions.rainPuddles.status()
extensions.rainPuddles.setSetting('rain', 0.85)
extensions.rainPuddles.setSetting('puddleReflection', 0.72)
extensions.rainPuddles.setSetting('puddleNormal', 0.7)
extensions.rainPuddles.sweep()            -- one manual wiper sweep
extensions.rainPuddles.rebuild()
extensions.rainPuddles.save()
```

Settings live in `/settings/rainPuddles.json`. Old v0.1/v0.2 settings are migrated in place; new controls get their defaults.

## Technical layout

```
lua/ge/extensions/rainPuddles.lua          settings, projection, vehicles, wheels, precipitation, PostFX lifecycle
lua/vehicle/extensions/rainPuddlesProbe.lua windshield probe (runs in each car's vehicle Lua)
scripts/rainPuddles/modScript.lua           extension load at session start
art/rainPuddles/*.data.png                  puddle fields + wiper blade/smear mask
shaders/common/postFx/rainPuddles/
  rp_lib.h.hlsl                             hash/field/box/projection/ripple helpers
  rp_puddles.h.hlsl / .cs.hlsl              hybrid SSR + SH9 fallback + PBR wet road
  rp_droplets.h.hlsl / .cs.hlsl             body droplets
  rp_windshield.h.hlsl / .cs.hlsl           glass plane + wiper mask
  rp_splashes.h.hlsl / .cs.hlsl             procedural tyre spray
ui/ui-vue/mods/RainPuddles/                 Vue settings UI (pause Mods card + side-panel route)
  rp_lens.h.hlsl / .cs.hlsl                 camera lens droplets (0.6)
art/rainPuddles/droplet_atlas.data.png      droplet shapes: normal xy, thickness, coverage (0.6)
```

All passes are compute PostFX (`PFX_COMPUTE`, `postFxComputeThread`, `pfxOut`) writing to `$backBuffer` in the documented `PFXBeforeBin` / `UpscaleDispatch` slot. The shared state block defines the documented sampler inputs. Every early-out writes the source colour, as required for compute effects.

## Validation status

- Package contents and archive paths were checked, and the app JSON parses.
- The AngularJS directive is a plain `beamng.apps` directive and its JavaScript passes `node --check`.
- The standard depth clear test is near=0 / far=1; ray/scene distance comparisons retain the engine's shared depth conversion helper. No reversed-Z `1-depth` transform is used.
- No BeamNG 0.40.x runtime or matching shader compiler is available in this packaging environment, so the four HLSL entry points have **not** been independently compiled here and in-game behavior has not been runtime-verified. Test the ZIP in a 0.40.x session and inspect `beamng.log` before treating it as a production release.

## Known limitations

- This is a screen-space effect, not a new road material. It cannot reflect geometry that is off-screen; the SH9 fallback takes over there. It also cannot replace native material SSR/cubemap quality, which is not exposed to custom PostFX.
- The windshield is an approximate rigid plane derived from the OBB, not per-vehicle curved glass or a custom material pass. Wiper pivots are a calibrated approximation; very wide/narrow or right-hand-drive cockpits may need tuning. A future version could add a per-vehicle `rainEffectController` that reads `electrics.values.wipers` where a vehicle exposes it.
- Body droplets still use the nearest six OBB shells. They are not clipped to the exact mesh or per-material, so a deeply recessed interior surface can be included by **Shell depth**.
- Native `Precipitation` field names are only partially documented. Creation is guarded and falls back to an existing level rain object; if neither is available the shader effects still run.
- Tyre spray is a screen-space procedural layer driven by wheel axis nodes and a ground raycast; it is not a fluid/particle simulation.
- Visual tuning still requires a live 0.40.1 session on the user's GPU. The shader code is statically compiled but not a substitute for testing sun angles, tunnels, night, rain transitions and every vehicle.
- Performance scales with screen resolution and SSR steps. 28 steps is a reasonable High starting point; lower it to 16–20 on integrated GPUs.

## License / credits

Original v0.1/v0.2 design and mask assets were supplied by the user. v0.3 refactor uses BeamNG's public shader/PostFX conventions. Do not redistribute BeamNG game assets with the mod; only the mod's own masks and code are included.
