# Changelog

## [0.1.0] — 2026-10-27 — first release

### Added
- Terrain-first drawing for heavy physics: undug mud is the level terrain (vanilla decal roads,
  grass, colours, unlimited view distance); mud meshes only where wheels dug.
- Predictive stamping (adaptive lead from the measured rut-front latency).
- Fresh-rut-front scheduler: tiles with a fresh front in the camera view rebuild at up to 40 Hz
  outside the frame-rate governor; uploads coalesced every 2nd frame.
- `deepmud_main.rutLag().fresh` (rut front latency), `deepmud_main.pointInView`.
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
