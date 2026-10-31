# BeamNG engine findings (measured)

Facts measured in game while developing DeepNode (BeamNG.drive 0.40, gridmap_v2 / johnson_valley).
They explain most design decisions; please extend this file when you measure something new.

## ProceduralMesh

- `createMesh` CPU cost: ~0.19 ms per call (burst) / ~0.35 ms (steady, once per frame), plus
  ~0.18 µs per face corner and ~0.38 µs per vertex. Face corners dominate (6 per grid cell).
- Every frame that first draws a freshly uploaded mesh costs ~1 ms in `RenderShadows`
  (+0.2 ms `RenderReflections`), independent of mesh size (4…40 cells) and of the material's
  `castShadows`. Hidden or out-of-view uploads cost ~0. Several uploads in one frame partly add up.
- Showing, hiding and moving existing meshes is free. Delaying the show of an uploaded mesh does not
  avoid the cost.
- No effect on that cost: `collisionType 'None'` (only a dynamic field), `hideInRenderView(63)`
  (reflection view), `ClusterShading.shadowMaxCasters = 0` (local-light shadows).
- Engine memory grows per upload with the variety of submesh sizes: pad submeshes to a few size classes.
- Malformed face tables (corners without `n`/`u`) crash the game in C++. Never test that live.
- A submesh with more than 65535 face corners hangs the game (16-bit counter).
- Collision of a ProceduralMesh only enters physics on `be:reloadCollision()` (~370 ms on gridmap_v2).
- A mesh uploaded into a hidden object and shown at once is not always drawn in the next frame:
  hiding the replaced object one frame later left some chunks undrawn for a frame (johnson_valley,
  forced sector rebuilds, 11 of ~200 rebuilds); two frames or more: none seen.
- createMesh time is mostly per face corner (~0.2 µs) and per call (a 590-vertex / 3120-corner
  tile: 1.08 ms exact, 1.41 ms padded to 4518 corners).
- First-draw cost split (2026-10-31, gridmap_v2, 441-vertex mesh 12 m in front of a static camera,
  `user/lua/ge/extensions/dntestEng.lua`, 12-14 samples per case): `RenderShadows` on the upload
  frame +0.65-0.76 ms for a never-drawn object, for a re-upload into the SAME object with the same
  sizes, for a never-drawn material, and with `collisionType 'None'` set before `createMesh` (read
  back as `None`; createMesh 1.10 vs 1.21 ms, the only difference). `Engine.Render.getShaderGenerationCount()`
  rose only twice (first new materials). So the cost is paid per `createMesh` event, not per object
  or material, and is not shader generation.
- Several uploads in one frame (same objects re-uploaded, k per frame): `RenderShadows` +0.80 /
  +1.24 / +2.33 / +4.13 ms for k = 1 / 2 / 4 / 8, ~0.5-0.6 ms each: nearly linear. Batching
  uploads into fewer frames does not cut this cost; fewer uploads do.
- `PSSMLightShadowMap.lastSplitCastersEnabled = false`: no change (1.68 vs 1.69 ms per upload frame).
- ProceduralMesh has object type bits 0 and 8 (`SOTStaticObject`, `SOTStaticShape`), the same as
  TSStatic: a render view's `shadowCasterObjectTypeBlacklistMask` cannot leave only the mud out.

## Terrain

- `tb:setHeightGrid` + `tb:updateGrid` take effect for physics at once; `updateGrid` costs 1–2.5 ms
  whatever the box size: merge all writes of a frame into one call.
- Heights are stored rounded to `maxHeight / 65536` (gridmap_v2: maxHeight 100, step 1.5 mm).
  Read-modify-write drifts downwards: 20 cycles of `h - 0.13` then `h + 0.13` ended 3.4 cm low;
  10 x `-0.004` gave -4.6 cm. Write absolute heights from a saved reference.
- `core_environment.reset()` / `reloadGroundModels()` (also mission start, ground-model file
  change, the ground-model debug panel's "Default") rebuild `core_environment.groundModels` from
  the files: live `be:setGroundModel` retunes are lost (measured: MUD defaultDepth 0.25 -> 0.15).
- Creating a second `TerrainBlock` at runtime and calling its `update*` methods crashed the game.
- `digSdf`/`placeSdf` is an experimental forward-lit SDF renderer, not usable for mud.

## Decal roads

- `DecalRoad.overObjects` drapes by a physics raycast onto collision meshes, not render meshes.
- `zBias` is a depth bias, not a vertical lift.
- With the terrain left at the mud surface (terrain-first) the engine draws decal roads exactly as vanilla.

## Other

- `Engine.Render.DynamicDecalMgr.addDecals` (box-projected colour decals, one frame) projects onto
  everything in the depth buffer inside the box, vehicles included: a wet imprint under a wheel
  coloured the tyre sidewalls (2026-10-31, red test colour). The ground under a wheel is hidden by
  the tyre anyway; the research idea VIS-1 was dropped.
- `tb:updateGrid` cost hardly depends on the box span (gridmap_v2, 2048 squares): 1 square 0.5 ms,
  a 100 x 2 union box 0.6 ms, 100 x 100 1.1 ms (best of 6). `updateGridMaterials` 2 x 2: 0.06 ms.
- `jit.v` (shipped as `lua/common/jit/v.lua`; `require('jit.v').start('/temp/jitv.txt')`) works in
  the GE VM but slows it a lot while on. One bench run: trace aborts in the mod were mostly
  "register coalescing too complex" side traces in `decodeZ` / `writeOne` / `carve`, plus
  `NYI: bytecode UCLO / FNEW` from closures made per call (timer fallback, view-cone `pcall`,
  sort comparators). The closures were moved out (UCLO/FNEW aborts 138 -> 26) and `decodeZ` lost a
  branch.

- `Engine.Render.DecalMgr.addDecal(pos, normal, rot, template, scale, texIndex, flags, alpha)` with
  the level's `tireTrackDecal` / `puddles_decal` templates returned instances but nothing showed,
  neither over a raised ProceduralMesh nor on the terrain beside it (2026-10-31, one try): the
  tread-decal idea (research VIS-2/T14) is open.

- `DynamicShapeBatch` instances shape files (per-instance transforms only).
- `SurfaceMaskClipmap` only feeds the grass (foliage) shader.
- GroundCover with GPU placement (`useNewPlacementGpu 1`) ignores `zOffset` (johnson_valley Grass2:
  only blade tips came through the mud). CPU placement honours it; a CPU cover fills a newly seen
  area within ~25 frames, does not rebuild cells for camera moves of 2–40 m, and costs no
  measurable frame time for one 300 000-element cover (static view).
- `$GroundCover::renderedCells/Billboards` change with every render pass (shadow cascades): useless
  as a per-frame flicker probe.
- With vsync on, frame times below 60 fps quantize; benchmark with `settings.setValue('vsync', false)`
  (and restore it).
- Material changes need `mat:flush()` (~0.4–0.8 ms); `setField` alone does nothing.
- Base-colour alpha is ignored by alpha clip: use `opacityMap`.
- Vehicle tyre material swaps at runtime render chrome.
- `GBitmap():loadFile(path)` reads level terrain PNGs in GE Lua (2048² in tens of ms);
  `bmp:getColor(x, y, colorI)` fills an OUT `ColorI` (call without it errors "expect userdata").
- Object material `baseColorFactor` x2 (0.25 -> 0.5 grey) gave x3.2 in decoded screenshot values:
  consistent with a linear factor through the tonemapper toe, not with an sRGB-decoded one (x4.2+).
- A level's `WaterPlane` (puresands: z 25) puts wheels in water: tyre mud washes off (coat stays 0).
- Engine memory kept per `createMesh` follows buffer size changes per object: with size-affine
  reuse (same padded sizes back to the same object) 1-7 MB per ~850 uploads, without 12-17 MB.
  Finer tile classes (12 instead of 6) cut padding 20 % but only 2 % of createMesh time and
  doubled the memory growth (more sizes, more objects changing size).
- Compiling + running a 1 KB `queueGameEngineLua` chunk: 16 us.
- With vsync on, `createMesh` (and material flushes) block while the driver waits for the frame:
  ~14 ms per tile upload and ~3.7 ms per flush measured at a steady 60 fps, against ~1.2 / 0.8 ms
  with vsync off. Wall-clock timing of uploads is no cost measure with vsync on.
- `jit.profile` in the GE VM attributes engine time to the next Lua that runs (useless shares),
  and after a profiling session the mod's stamping ran 3-4x slower until `reload_lua`.
- `mudLayerAt` falls back to neighbour layers and the zone/default kind: hard ground next to mud
  reads as mud (gridmap_v2 sand lane start line). Test softness with `P.softAtWorld`.
- Vehicles spawned from Lua start in `realistic` gearbox mode (stay in neutral):
  `controller.mainController.setGearboxMode('arcade')`.
