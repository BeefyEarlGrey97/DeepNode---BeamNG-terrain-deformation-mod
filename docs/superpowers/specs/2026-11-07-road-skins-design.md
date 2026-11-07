# One decal road system: baked layer + road skins (2026-11-07)

## Intent
Decal roads over soft ground cost frame time twice: the level's own stacked DecalRoads (~1.1 ms in
the gridmap_v2 pit view, ~2.6 ms close up) plus the mod's road copies. With every road baked per
region at map load (Revision B), the vanilla decals on soft-ground roads are no longer needed. The
user wants one decal road option, and only the baked roads drawn on the deformation area.

## Goals
- One GUI switch "Decal roads on the mud" (on = bake, off = roads hidden on soft ground).
  `roads.mode` keeps two values, `'bake'` and `'off'`; old values `copy`, `overlay`, `drape` read as
  `'bake'`.
- Every DecalRoad that touches soft ground is hidden once all regions it crosses are ready; until
  then it stays visible (a road never goes blank).
- Undug ground shows the baked roads through **road skins**: one thin see-through ProceduralMesh per
  region covering the squares a road quad crosses (hard-ground parts of the road included).
- Dug ground shows them through the tile's own mesh material (existing baked layer, `tileMatName`).
- Delete the copy, overlay and drape modes: `roadCopy.lua`, `decals.lua`, `P.drapeRoads` /
  `finishDrape` / `collectMudRoads` / `redrapeRoads`, and their hooks in main, tileMesh, farMesh, gui.

## Non-goals
- `overlay.roads` (screen-space road redraw, config only, default off) stays as it is; it is the
  other session's area. With roads hidden by mode 'bake' it must not start (it only runs when
  `overlay.roads.enabled`).
- Far sectors' plain terrain squares get no roads (as before).
- No change to the bake itself, the cache or the load phase.

## Anti-goals
- A road visible twice (decal + skin) or nowhere (decal hidden, skin missing) in a steady state.
- Skins floating over ruts (a skin square over a dug square).
- Per-frame cost from skins beyond their draw: no rebuilds while a truck digs inside one tile.

## Constraints
- Spike (2026-11-07, pit view, no trucks): vanilla 149 fps, skins 157-162 fps, no roads 178-180.
  115 skins, ~16,800 squares, one createMesh each.
- Skin material that works (spike): the region's baked images as **base** maps, factors 2 (images
  store value/2): `baseColorMap` b + `baseColorFactor 2 2 2 1`, `opacityMap` o + `opacityFactor 2`,
  `normalMap` nm, `roughnessMap` r + `roughnessFactor 2`, `metallicMap` m + `metallicFactor 2`,
  `translucent 1`, `translucentZWrite 0`, `translucentBlendOp LerpAlpha`, `castShadows 0`; mesh UV =
  terrain UV (`main.uvOf`) x the region mapping scale (`sx`, `sy`). The detail-layer form drew dark
  and opaque. A Material once drawn keeps its shader: new fields need a new name.
- Each scene object costs ~1.9 µs in the shadow pass; uploads cost engine time; createMesh of
  malformed faces crashes the game (faces 0-based, `{v, n, u}`).
- Never delete cache images or a Material that a mesh may still reference while the game runs.

## Approaches
- **A. Road skin per region (chosen).** 115-121 objects, built once, re-uploaded only when a tile in
  the region gets or loses its own mesh. Covers hard-ground parts of roads too, so whole roads hide.
- B. Baked layer on sector meshes: no new objects, but sectors cover soft ground only (roads would
  need splitting) and every extra submesh costs shadow + reflection time (fade levels: -10 fps).
- C. A mud mesh on every road tile: up to 1086 objects (~2 ms shadow pass), mud material on hard
  ground looks wrong.

## Design
- New module `deepnode_roadSkin` (GE extension, next to roadBake), or a section of roadBake: builder's
  call. Interface used by others: `onRegionReady(rk)`, `onTileMesh(tileKey)` (tile got / lost its own
  mesh or became rutted), `stop()`, `stats()`.
- Squares: per region, every terrain square (`ter.sq`) a road quad's polygon overlaps (spike used
  the quad bounding box: ~12 % more squares; polygon test preferred). Hard and soft squares alike.
- Height: the rest surface + 4 mm (terrain height in terrain-first heavy mode; the mud rest height
  where the soft ground is meshed and the terrain lowered).
- Cut-outs: squares of tiles that have their own mesh or are rutted (drawn by a tile or sector mesh)
  are left out; that mesh carries the baked layer itself.
- Rebuild rate: `onTileMesh` marks the region dirty; at most `roads.skinRebuildPerSec` (2) regions
  rebuilt a second, never in a frame that uploaded a tile mesh.
- Hiding: `P.coverRoads` keeps its job for mode 'off' (hide every soft-ground road). In mode 'bake'
  a road is hidden when every region it crosses has a skin (ready); roadBake records the regions
  per road.
- GUI: one checkbox; the "Bake roads into the mud (beta)" box goes.
- Config/REFERENCE: drop `copy*`, `overlay*` (roads section), `drape*`, `overObjects*` keys; add
  `skinRebuildPerSec`, `skinLift` (0.004).

## Left to the builder
- Module split, square polygon test, exact hook points in main for tile mesh gain/loss.
- Skin look calibration against vanilla with the rig (5 % gate): spike skins looked paler than the
  decals (forward-lit mesh vs decal blend into the G-buffer); see ENGINE_FINDINGS "How the engine
  renders a decal road" (uncommitted research in the work tree) for the decal passes.
- Default `roads.mode` stays 'off' until the user decides.
