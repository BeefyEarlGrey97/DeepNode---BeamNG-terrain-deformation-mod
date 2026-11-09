# DeepNode v0.8.0 — road shader, liquid mud, shader tyre coat, SnowRunner ruts (2026-11-09)

## New
- **Decal roads drawn by shader on the mud** (`roads.mode` 'shader', the new default): the level's
  decal roads over soft ground follow the dug ruts, any number of stacked roads, lit with the
  engine's own light. Roads on sand look like the engine's (no sand ripples showing through).
- **Liquid mud**: the rut surface round a vehicle in mud flows back and fills in.
- **Tyre mud drawn by the tyre shader**: the coat starts at the contact patch, creeps round as the
  tyre turns and thickens per pass; fresh mud is dark and wet, dried mud lighter and cracked.
- **SnowRunner-style ruts**: deep trenches with firm walls and broad torn berms; trucks bog down
  in deep mud (heavy physics).

## Changed
- Undug soft ground is the terrain itself again; only dug squares are meshed.
- Tyre coat builds more slowly and matches the ground's colour (dried mud was far too bright).
- Smoother berms: rounded crests and lumps instead of rows of spikes.
- Tile meshes padded to 24 size classes: about 8 % less upload time per mesh.

## Fixed
- Liquid mud never ran in earlier builds; berms held at 2-3 cm.
- Wet tyre prints left on the bed under water.
- Road shader: rectangles cut out round vehicles, roads painted on tyres.

## Measured (heavy physics)
| | result |
|---|---|
| Ural-4320, gridmap_v2 mud, throttle 0.7 from a standstill | 12 km/h, 40 m in 15 s, body 0.33 m down (v0.7.x tuning: 22 km/h) |
| johnson_valley, 6 Percherons on the circle bench, run 2 | 48-51 fps, low 1 % 33-36 fps, no frame over 33 ms |
| gridmap_v2, 8 Percherons (BENCHMARK 21) | 30.5-31.7 fps, low 1 % 17-18 fps |

Not measured for this release: vanilla physics, and the final mud balance (rut / berm values set
after the johnson_valley runs) on the 8-truck bench. See docs/BENCHMARK.md 19-22 and
docs/OPEN_ISSUES.md 26, 31, 32 for open items.
