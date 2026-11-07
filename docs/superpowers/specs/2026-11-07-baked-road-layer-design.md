# Baked road layer (roads.mode 'bake') — design

2026-11-07. Status: draft for approval.

## Intent

Decal roads over dug mud are drawn today by **copies**: every road over a tile becomes extra
translucent submeshes in the tile mesh (`deepnode_roadCopy`). Each copy submesh costs its own
shadow and reflection pass, and the copies are rebuilt in Lua on mud builds. With 8 trucks in the
gridmap_v2 pit the copies cost about 6 fps (50.8–51.9 vs 57.4 without roads) plus up to several ms of
Lua.

Roads do not move. The new mode bakes, once per tile, every road over the tile top-down into five
small images (colour, opacity, normal, roughness, metallic), and the tile's own mud material gets
one extra layer that reads them. The road then lies in the mud surface itself: it follows every
rut, is lit like the ground (as the engine's decal blends into the G-buffer), needs no extra
submeshes and no Lua work per build.

## Goals

- Roads over dug mud with no copy submeshes and no per-build road work on baked tiles.
- Look at least as close to the vanilla decal as the copies (user rule: never trade visuals for fps).
- Never a plain-mud gap: a tile that is not baked yet keeps the copies.
- Fps gain on the gridmap_v2 4/8-truck bench vs `roads.mode 'copy'`.

## Non-goals

- Roads on far sector meshes (farMesh), startEndFade (road end fade), vanilla physics mode beyond
  what copies cover today, roads on non-mud objects.
- Removing `'copy'`: it stays the default until bake wins a bench and the look check.

## Anti-goals (failure even if it "works")

- Visible stutter from baking (bake work must stay inside a per-frame budget).
- Pop-in of plain mud on freshly dug tiles.
- Look worse than copies (paler, shinier, blurrier) at bench camera distance.
- Unbounded disk or VRAM growth (stale cache files never cleaned, materials never freed).

## Engine facts this rests on (measured 2026-11-07, see memory / ENGINE_FINDINGS)

- A stock Material cannot sample a `#named` render target. A PostEffect target **can** be saved to
  PNG: `require('screenshot').createScreenshotTracked{filename=..., bufferType='<target name
  without #>', superSampling=1}`. Saved alpha is forced to 255 (opacity needs its own image).
- `defaultMat.hlsl` layer maths: a layer with no base maps and detail maps at strength 1 gives
  colour = saturate(2·detail), opacity = saturate(2·opacityDetail.r), roughness = factor·saturate(2·r),
  metallic = factor·saturate(2·m), normal = normalize(flat + detailNormal.xy); layers lerp by
  opacity. So images store value/2 and the layer is an exact alpha "over".
- `detailScale` per layer; mud UV0 = terrain UV (`main.uvOf`), so `detailScale = 1/|Δuv per tile|`
  makes the detail map repeat once per tile; an offset `frac(uv0·scale)` (flipV: v offset 0.6 on
  gridmap_v2) is folded into the bake mapping.
- The engine cooks each referenced PNG to `temp/<path>.dds` asynchronously (`.color` → BC7 sRGB,
  `.data` → BC7, `.normal` → BC5); the material must be `reload()`ed after the cook. Files created
  outside the game are not seen; files the game writes (screenshot, GBitmap) are.
- Road quads: `getLeft/Right/MiddleEdgePosition(i)`, u 0..1 left→right, v = −distance/textureLength
  along the 3D middle line. Material maps: baseColorMap, opacityMap, normalMap, roughnessMap,
  factors baseColorFactor, opacityFactor, normalMapStrength, roughnessFactor, metallicFactor,
  alphaTest/alphaRef.
- **Draw order is NOT settled.** roadCopy draws higher renderPriority at the bottom; overlay.lua
  claims higher on top (checked by eye). The spike matched the copies' mean brightness only with
  higher on top, but that also gave water sheen the copies lack. It must be measured against the
  vanilla decal on undug terrain (calibration step below).

## Approaches considered

- **A. Bake on demand** when a tile first gets a mesh: no start cost, but a 2–5 s plain-mud gap per
  fresh tile (bake + cook). Rejected: the plain-rectangle complaint.
- **B. Pre-bake all road tiles at level start**, disk cache per level: no gap after the bake, first
  load cost, disk use. Alone it leaves a gap for tiles dug before their bake.
- **C. B + A as fallback (picked by the user).** Pre-bake in the background nearest vehicles first;
  a tile that meshes before its bake is ready jumps the queue and keeps the copies until its baked
  material is loaded.

## Design (decided parts)

### Mode and modules

- `roads.mode = 'bake'`: roadCopy starts as in `'copy'` (fallback and its tile→roads index), plus a
  new module `lua/ge/extensions/deepnode/roadBake.lua` (registered in main's module list next to
  roadCopy, started/stopped with it).
- Shaders in the mod: `shaders/common/postFx/deepnode/roadBakeP.hlsl` (one road material over one
  tile, composited over the previous result) and `roadBakeResolveP.hlsl` (accumulators → the five
  images). Built from the spike shaders (inverse-bilinear quads, mip level from texture size, road
  width and textureLength; normal re-expressed in the tile's tangent frame).

### Bake pipeline (per tile, GPU)

- Accumulators: two RGBA16F targets at `bakeSize²`: A = (colour·a premultiplied, A) and
  B = (normal enc, roughness, metallic) premultiplied with the same a. Static topology (no per-tile
  chain rebuild): one effect pair per **road material** reads the accumulators (ping-pong via copy
  passes as in the rut map) and composites all quads of that material over them. One material per
  frame: frame 1 clears, then each material group in draw order, then resolve; skips toggle with
  `skip` (never `disable()`).
- Resolve writes five RGBA8 targets; five named-buffer screenshots save them. The next tile starts
  after the screenshots report saved.
- Quads come from roadCopy's road records (same edges it already reads), clipped to the tile
  (+0.3 m). More than 64 quads of one material over one tile: split into several frames.

### Cache

- Files: `<user>/deepnode_cache/roadbake/<level>/<tileKey>_<sig>_{b.color,o.data,nm.normal,r.data,m.data}.png`.
- `sig` = hash of (bake shader version, bakeSize, draw-order setting, for each road over the tile:
  material name + fields used, renderPriority, textureLength, edge positions rounded to 1 mm).
- At start: a tile whose five files exist with the current sig is "baked" without GPU work. Files of
  that tile with another sig are deleted when the new bake is saved.

### Material per tile

- When a baked tile has a mesh: for each soft layer `e` in `t.matList`, a clone
  `deepnode_rb_<key>_<e>` of `main.matName(e)` (`assignFieldsFromObject`) with layer
  L = activeLayers: base/opacity/roughness/metallic factors 1, the five detail maps at strength 1,
  `detailScale` from the tile's UV. A mud material that already uses 4 layers keeps the copies.
- The clone is created when its PNG cooks exist (`/temp/.../*.dds`, polled), then `reload()`ed;
  only then the tile counts as ready and is marked dirty for one rebuild.
- Clones are deleted when the tile's mesh is released and at stop.

### Hooks into tileMesh / main

- `main.tileMatName(t, m)`: the baked clone when ready, else `main.matName(m)`; replaces
  `main.matName(m)` at the 4 `b:sub(...)` sites in tileMesh.
- Copy emission in tileMesh: skipped (copyOut = {}) on ready tiles, unchanged otherwise.
- `roadBake.ready(key)` false → copies as today (fallback, approach C).

### Scheduling

- Queue: all road tiles (roadCopy's tile index) within `roads.bakeRadius` of the camera or any
  vehicle, nearest first; a tile that gets a mesh while unbaked moves to the front.
- Budget: one material step per frame, at most `roads.bakeMaxPerSec` tiles started per second, and
  no bake step in a frame that already had a mesh upload (upload governor `reserveFrame` style).

### Config (docs/REFERENCE.md)

| key | default | meaning |
|---|---|---|
| `roads.mode` | `'copy'` | new value `'bake'` |
| `roads.bakeSize` | 512 | texels per tile side (5 m: ~1 cm) |
| `roads.bakeRadius` | 300 | pre-bake radius around camera and vehicles (m) |
| `roads.bakeMaxPerSec` | 10 | tiles started per second |
| `roads.bakeHighOnTop` | set by calibration | draw order of renderPriority |
| `roads.bakeCache` | true | keep PNGs on disk per level |

GUI: the decal-road mode selector gets "Bake"; Debug tab shows queued / baked / ready / fallback
tile counts and bake ms.

## Calibration and checks (part of the work)

1. **Vanilla reference rig**: bake an *undug* road tile and show a test patch (the tile surface +
   the baked layer, a few mm up) over the terrain; screenshot with/without at the bench camera and
   close up; compare mean and std per channel in the tile area against the vanilla decals.
   Settle `bakeHighOnTop` with it (both orders, pick the closer).
2. Same rig: fix the water sheen (std 51 vs 37 in the spike): check normal strength / tangent
   signs (flip tests), roughness and metallic mapping, until mean and std are within ~5 % of vanilla.
3. Look on a dug tile vs copies; band edge between mesh and vanilla terrain decal must not show a
   step.
4. Bench (gridmap_v2, 4 trucks, then 8; `bench2.py label 2 clear`, interleaved copy/bake/copy):
   fps mean/min, Lua ms; VRAM / texture count; bake time per tile; first-load and cached-load start
   time.

## Left to the builder

- Exact shader constant layout, effect names, ping-pong details, how the screenshot "saved" is
  detected (screenshot.lua callbacks or file polling), hash function.
- Whether rough and metallic share one image (only if a detail slot can read another channel —
  current evidence: all read `.x`, so five images).
- Status-light / GUI wording.

## Risks

- VRAM: ~1.75 MB per tile at 512² with mips (gridmap pit ~80 road tiles ≈ 140 MB). Mitigation:
  clones and their textures only while the tile has a mesh; `bakeSize` 256 as fallback.
- Many material clones = many distinct materials in the render; unmeasured.
- The sheen / draw-order calibration may not converge to vanilla; then the mode stays opt-in.
