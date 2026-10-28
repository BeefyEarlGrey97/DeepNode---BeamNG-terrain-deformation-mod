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
- ProceduralMesh has object type bits 0 and 8 (`SOTStaticObject`, `SOTStaticShape`), the same as
  TSStatic: a render view's `shadowCasterObjectTypeBlacklistMask` cannot leave only the mud out.

## Terrain

- `tb:setHeightGrid` + `tb:updateGrid` take effect for physics at once; `updateGrid` costs 1–2.5 ms
  whatever the box size: merge all writes of a frame into one call.
- Creating a second `TerrainBlock` at runtime and calling its `update*` methods crashed the game.
- `digSdf`/`placeSdf` is an experimental forward-lit SDF renderer, not usable for mud.

## Decal roads

- `DecalRoad.overObjects` drapes by a physics raycast onto collision meshes, not render meshes.
- `zBias` is a depth bias, not a vertical lift.
- With the terrain left at the mud surface (terrain-first) the engine draws decal roads exactly as vanilla.

## Other

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
- Vehicles spawned from Lua start in `realistic` gearbox mode (stay in neutral):
  `controller.mainController.setGearboxMode('arcade')`.
