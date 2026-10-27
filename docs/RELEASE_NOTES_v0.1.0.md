# DeepNode v0.1.0 — first release (2026-10-27)

Deep, persistent mud and sand for BeamNG.drive 0.40: 0.2 m tyre ruts, chassis dents, tyre mud,
optional heavy physics with a terrain rut floor.

## Highlights
- **Decal roads fixed (heavy physics):** undug mud is the level terrain itself, so decal roads, grass and
  colours look exactly like vanilla at any distance; mud meshes are drawn only where wheels dug.
- **Ruts keep up with the wheels:** predictive stamping plus a camera-aware scheduler; rut front reaches
  the screen in ~0.10 s (was 0.40–0.54 s) and is carved slightly ahead, under the tyre.
- **Memory:** heavy physics 25–63 MB/min with 8 trucks (was ~200 MB/min).
- **View distance:** meshed mud (ruts, sand) to 70 m; sector size adapts to each map's soft ground.
- Benchmark tooling for 8 Percherons on gridmap_v2 and johnson_valley, engine findings, contributor docs.

## Install
Unzip into `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\` (or clone into `mods/unpacked/deepmud`).
**Recommended:** in the mod GUI (Run tab) switch *Physics* to **HEAVY**. The shipped default is vanilla physics,
which keeps the old decal overlay and uses much more memory.

## Benchmark (gridmap_v2, 8 Percherons, 70 m view)
| physics | fresh mud fps (low1) | repeat fps (low1) | memory fresh / repeat |
|---|---|---|---|
| heavy | 45–47 (32–35) | 47.5–49 (37–39) | 63 / 25 MB/min |
| vanilla | 39–41 (25–31) | 34–48 (24–36) | 253 / 132 MB/min |

Mod off on the same machine earlier the same day: 77–84 fps. Goal of 70–80 fps with 8 trucks is **not met**
yet; see the open issues list in the README / docs/OPEN_ISSUES.md.

## Known issues
- Frame rate ~6+ ms/frame over vanilla with 8 trucks (engine cost of rebuilt meshes).
- Rut deepening behind the front axle can lag seconds under heavy load.
- Sand and vanilla physics mode still use the full mud mesh and the alpha-clipped decal overlay.
- Heavy physics slows Percherons to ~3–4 m/s in deep mud.
- Tyre textures in art/deepmud are baked from BeamNG assets: check redistribution terms.
