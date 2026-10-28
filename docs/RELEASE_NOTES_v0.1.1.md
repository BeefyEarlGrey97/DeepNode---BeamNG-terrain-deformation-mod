# DeepNode v0.1.1 — grass flicker fix, faster tile rebuilds (2026-10-28)

## Fixed
- **Grass flickering while mud chunks rebuild.** The replaced mud mesh was hidden one frame after its
  replacement was uploaded, and the new mesh was not always drawn by then: for one frame the lowered
  terrain showed through with the lifted grass standing above it. The old mesh now stays visible for
  3 frames (`pool.hideFrames`). Measured on johnson_valley with forced rebuilds: 11 flicker frames in
  6 passes before, 0 in 12 passes after.

## Faster
- **Tile builds ~10x cheaper in Lua:** the mesh builder no longer shuffles thousands of reusable tables
  on every build (rut tile 0.98 → 0.10 ms).
- **Mesh uploads ~20 % cheaper:** finer padding size classes (`pool.tileClasses` 6, `pool.decalMinCorners` 96).
- No settings were lowered: rebuild rates, view distance and upload budgets are unchanged.

## Benchmark (gridmap_v2, 8 Percherons, fresh mud, vsync off)
| physics | v0.1.0 code fps (low1) | v0.1.1 fps (low1) | GE Lua per frame | memory |
|---|---|---|---|---|
| vanilla | 37.2–39.6 (25.8–30.7) | 38.5–42.5 (29.3–33.8) | 7.6 → 4.6–5.2 ms | 113 → 36–122 MB/min (noisy) |
| heavy | 45–47 (32–35) | not re-measured | – | – |

Mod off in the same session: 60 fps (frame cap). The 70–80 fps goal with 8 trucks is still not met: each
mesh upload also costs engine shadow and reflection time (see docs/OPEN_ISSUES.md).

## Install
Download `DeepNode-v0.1.1.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove `DeepNode-v0.1.0.zip` (or an unpacked copy) first.
Settings in `<user folder>/settings/deepnode/gui.json` are kept.

## Known issues
- Frame rate: ~41 fps with 8 trucks in vanilla mode (60 with the mod off).
- Rut deepening behind the front axle can lag seconds under heavy load; one 3 s outlier seen in the v0.1.1 runs.
- Sand and vanilla physics mode still use the full mud mesh and the alpha-clipped decal overlay.
- Heavy physics slows Percherons to ~3–4 m/s in deep mud.
- Tyre textures in art/deepnode are baked from BeamNG assets: check redistribution terms.
