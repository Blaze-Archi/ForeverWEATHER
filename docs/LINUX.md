# RainPuddles 0.4.6 - Vulkan / Linux fix

Root cause (from a real BeamNG 0.40.1 Vulkan beamng.log):
  rp_puddles.h.hlsl / rp_windshield.h.hlsl: error: use of undeclared identifier 'ambientSH9' / 'ambientColor' / 'fogColor'
The droplets header declares these three engine-bound uniforms itself and compiled fine; the puddle and windshield headers did not,
so those two shaders failed to compile on Vulkan and the effects were silently skipped.
Fix: the same three declarations were added to rp_puddles.h.hlsl and rp_windshield.h.hlsl (inside the perDraw cbuffer).

Not runtime-confirmed (no game here). Windows/D3D11 note: if a Windows build ever reports a *redefinition* of ambientSH9,
remove those three lines from the two headers.
Also in this build: dry-box diagnostics (debug views 11/12, 'Vehicle mask' checkbox), portable single-exit SSR code,
extensions.rainPuddles.scanLog() to search beamng.log for shader errors.

## 0.4.7 - SSR actually traces now
Cause of flat, detail-less puddles (screenshots at rain 0.93 / 0.10): camFwd was cross(dyr, dxr) = backward, so rayZ was negative and
rpTraceReflection returned on its first step every time (also skipping the far-field lookup). camFwd is now cross(dxr, dyr) and
flipped toward the pixel's own eye ray if needed. Not runtime-confirmed.
Native BeamNG SSR (PostFxSSSRObject, SssrSurfaces/SssrTrace bins) runs right after lighting and reads receiver data written in the
prepass; a PostFX at UpscaleDispatch cannot feed it, and the docs only describe READING #prepass, so it is not used.
Default Reflection strength lowered 0.80 -> 0.65 (settings v7) so full-road puddle coverage does not read as a white sheet.
