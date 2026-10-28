# Changelog

## [Unreleased]

### Fixed
- Grass (and the ground under it) flickered while mud chunks rebuilt: the replaced mesh was
  hidden one frame after its replacement was uploaded, and the new mesh was not always drawn by
  then, so for one frame the lowered terrain showed with the lifted grass standing above it.
  Measured on johnson_valley with forced sector rebuilds: 11 undrawn frames in 6 passes with a
  one-frame hold, 0 in 12 passes with 2 or 3. New `pool.hideFrames` (default 3).

### Changed
- Mesh builder: submesh arrays keep their last length and take spare element tables back only
  when a build grows; a submesh returns to its last material. Before, every tile build moved
  thousands of tables to and from the stash when submeshes changed size (tile build
  0.98 → 0.10 ms in a micro-benchmark of a 590-vertex rut tile).
- Mesh size classes: tile meshes padded to sixths instead of thirds of the largest tile, decal
  overlay submeshes from 96 instead of 384 corners (`pool.tileClasses`, `pool.decalMinCorners`).
  createMesh of a rut tile: padded to thirds 1.41 ms, exact 1.08 ms.

### Results (gridmap_v2, 8 Percherons, vanilla physics, user GUI settings, vsync off)
- Fresh mud: 38.4 fps (low1 27.6), GE Lua 7.6 ms → 40.7–41.9 fps (low1 30.9–31.5), GE Lua 4.6–5.2 ms;
  mod frame time 5.2 → 2.8–3.6 ms. Memory growth not higher (36–122 vs 113 MB/min, noisy).

## [0.1.0] — 2026-10-28 — first release

### Renamed
- Mod renamed from "Deep Mud" to **DeepNode**: extensions `deepnode_*`, folders `lua/*/extensions/deepnode`,
  `art/deepnode`, `settings/deepnode`, `scripts/deepnode`, user settings `<user folder>/settings/deepnode/`,
  benchmark helpers `dntest*`. Distributed as `DeepNode-v0.1.0.zip`.

### Added
- Terrain-first drawing for heavy physics: undug mud is the level terrain (vanilla decal roads,
  grass, colours, unlimited view distance); mud meshes only where wheels dug.
- Predictive stamping (adaptive lead from the measured rut-front latency).
- Fresh-rut-front scheduler: tiles with a fresh front in the camera view rebuild at up to 40 Hz
  outside the frame-rate governor; uploads coalesced every 2nd frame.
- `deepnode_main.rutLag().fresh` (rut front latency), `deepnode_main.pointInView`.
- Benchmark tooling (`tools/benchmark`), engine findings, open issues, contributing guide.

### Changed
- Meshed mud view distance 50 → 70 m (`sectors.loadRadius`, `ring.meshRange`, `ring.frozenOwnMeshRadius`).
- `sectors.autoSize`: sector size chosen per map from the meshed soft area in view (`sectors.autoMaxObjects` 200,
  `autoMaxTiles` 8, `sectors.tiles` is the minimum). gridmap_v2 keeps 10 m sectors.
- Heavy physics: mud `floorLift` 0.3 → full, mud `defaultDepth` 0.2 → 0.25 (same maximum sink);
  the rut floor lowers terrain only under carved cells.
- Vehicle reports 15 → 20 Hz, chassis nodes every 2nd report; rebuild waits shortened.
- Tyre mud material flushes and per-frame transforms only for trucks in view.
- Grass lift uses the visual sink depth (fixes floating grass in heavy mode).

### Results (gridmap_v2, 8 Percherons)
- Release build, 70 m view: heavy 45–47 fps fresh mud (63 MB/min), 47.5–49 fps repeat (25 MB/min);
  vanilla 39–41 fps fresh (253 MB/min), 34–48 fps repeat (132 MB/min). Heavy physics is recommended.
- Rut front latency 0.40–0.54 s → ~0.10 s; memory +199 → ~15 MB/min (fresh-mud runs); fps 53 → 54–56.
