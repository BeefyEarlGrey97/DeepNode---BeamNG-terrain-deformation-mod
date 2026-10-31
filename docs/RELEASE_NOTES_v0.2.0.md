# DeepNode v0.2.0 — ground look, decal roads in the ruts, faster with 8 trucks (2026-10-31)

## New
- **Experimental ground look** (GUI "Experimental tread prints", off by default): screen-space tyre
  prints, wet churned mud, crumbs, puddles in mud ruts, mud splats from spinning wheels, mud / sand
  carried onto hard ground, grass and dirt tracks, wet tracks that dry, glossy wet tyres.
- **Decal roads follow the ruts** (with the ground look on): the decal roads DeepNode hides over mud
  and sand are drawn again by the shader, on the rut floors and berms as dug, with tyre prints on
  top; not on kerbs, walkways or vehicles.

## Fixed
- HT-55 dump truck rear tyre mud (wheels sharing hub nodes were built as duals).
- Grass flicker next to dug mud in heavy mode reduced: terrain updates near grass ~4/s -> 1/s
  (grass beside a digging truck still blinks about once a second: an engine limit).

## Faster
8 Percherons on gridmap_v2, heavy physics, the author's GUI settings, vsync off, runs 2-5:
**48.6 -> 52.3 fps, low 1 % 35.9 -> 39.9**, mesh uploads per 5 runs 8 700 -> 3 900, GE Lua
3.5-4.1 -> 2.6 ms, shadow pass 6.3 -> 5.5 ms, memory flat per run. From `ring.bodyMaxWait` 1.5 s
(one upload per truck pass instead of one per axle) and a cheaper road look.
Vanilla physics mode was not re-measured for this release.

## Known issues
- Ruts can lag behind fast trucks in heavy mode (sand / mud are drawn by the terrain until the
  rut floor is lowered; the body hold also delays the front wheel's rut). A fix that keeps up at
  40 km/h exists but costs ~14 fps; work continues (docs/OPEN_ISSUES.md §16).
- Road look: faint stair-step edges where three decal roads overlap; ~0.5 fps GPU cost.
- See docs/OPEN_ISSUES.md for the full list.

## Install
Download `DeepNode-v0.2.0.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
