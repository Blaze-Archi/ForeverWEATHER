# v0.3.5 (cumulative over v0.3.1; supersedes v0.3.4 notes)
Same checks as v0.3.4 (restart BeamNG, single zip, header must show green "Lua 0.3.5", debug view 10 stripes = new shader).

New in 0.3.5:
- Header now shows: ray cast yes/NO, and per-vehicle box numbers (centre z, half extents, computed bottom, ray-cast ground, axis up.z).
  A screenshot of the app header gives the exact data needed to fix any remaining box problem.
- Droplet shell only lands on smooth surfaces (roughness < 0.65), so beads can no longer appear on asphalt near the car.
- Tyre-mark gloss slider (0..1, default 1 = current look): tyre decals are smoother than asphalt, so the wet film makes them polished.
  0 = treat all asphalt as the same roughness.
Includes everything in CHANGES_v0.3.4.md (kept below in spirit): puddle exclusion needs height AND smooth surface, normal-detail rework,
global road reflection, procedural masks, misty spray rewrite, acceleration inertia, bigger puddles.
