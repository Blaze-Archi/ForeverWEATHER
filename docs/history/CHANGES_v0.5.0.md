# 0.5.0
- NEW rainPuddlesWet.lua: wet-road PBR (roughnessFactor on road materials, snapshot/restore) + native SSR quality control.
- Shader: rpPuddleE.w = native film flag; own road film suppressed when native path is active.
- UI rebuilt (AngularJS): Reflections panel (engine mode, native SSR quality, wet-road materials, live status), removed dead/duplicate sliders, own-trace controls shown only when relevant, diagnostics grouped.
- Removed from UI: tyre-mark gloss, duplicate "global road reflection"/"reflection strength" confusion (renamed), spray panel no longer holds reflection sliders.
- Fixes carried from 0.4.x: Vulkan header declarations, camera-forward sign, depth-unit calibration, march reach, ground-plane vehicle mask.
- Not runtime-verified.
