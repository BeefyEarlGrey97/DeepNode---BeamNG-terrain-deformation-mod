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
- That memory is the physics collision (2026-11-07, 0.40.5, D3D12, decompiled + measured with
  `user/lua/ge/extensions/dntestPM.lua`). The Lua `createMesh` (exe 0x1401a60b0) makes a new static
  vertex buffer per submesh (44 B: position, normal, tangent, uv) and a 16-bit index buffer, keeps
  a CPU copy, then calls the virtual `updatePhysicsCollision` (vtable +0x1b8): old PhysicsRep
  deleted, a triangle mesh per submesh (ground model from the material, "asphalt" if none), a new
  PhysicsRep, plus a 12 B position / 32-bit index copy for ray casts. Lua has only `createMesh`,
  `updateMaterial`, `setMaterial`; no way to skip the collision. The static collision store keeps
  every mesh it was handed (old sizes of an object, deleted objects; hidden objects too) until
  `be:reloadCollision()`, which freed 97-100 % of it (380-510 ms). Same object, same size: ~0 kept;
  one object x 40 sizes: 10-28 MB; deleted meshed object: 110-330 KB; created and deleted without
  createMesh: 0. Engine flags seen in the exe (not tested): `-nogfxgpudriven`, `-nogfxgpuupload`,
  `-nogfxbindless`, `-nogfxbindlesscbv`, `-nogfxindirectconstants`.
- `updatePhysicsCollision` (0x1401abf80, decompiled 2026-11-09) returns early only when the CPU
  index copy or the CPU vertex copy is empty; there is no flag or field check, so no live mesh can
  skip its collision build.
- Malformed face tables (corners without `n`/`u`) crash the game in C++. Never test that live.
- A submesh with more than 65535 face corners hangs the game (16-bit counter).
- Collision of a ProceduralMesh only enters physics on `be:reloadCollision()` (~370 ms on gridmap_v2).
  Hidden objects stay out of it.
- A mesh uploaded into a hidden object and shown at once is not always drawn in the next frame:
  hiding the replaced object one frame later left some chunks undrawn for a frame (johnson_valley,
  forced sector rebuilds, 11 of ~200 rebuilds); two frames or more: none seen.
- createMesh time is mostly per face corner (~0.2 µs) and per call (a 590-vertex / 3120-corner
  tile: 1.08 ms exact, 1.41 ms padded to 4518 corners).
- `createMesh({ {lod0 submesh}, {lod1 submesh} })` (two outer entries, as Track Builder passes):
  only the first entry drew, close up, at 120 m and from a low side view (lod1 placed 2 m higher
  to tell them apart). No coarse far level through the outer table (research T18).
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
- The first-draw cost is per `createMesh` CALL, not per submesh (2026-11-10, gridmap_v2, 0.40.5,
  256-vertex grids, 24 samples per case, `dntestEng` cases `k<N>` = N objects / N calls and
  `m<N>` = the same N grids as N submeshes of one object in one call). Upload-frame
  `RenderShadows` over idle: k1 +0.74, k2 +1.23, k3 +1.70, k4 +2.29 ms, but m2 / m3 / m4
  +0.75 ms each. `createMesh` time: k = 0.77 ms per mesh (0.83 / 1.54 / 2.32 / 3.06 ms), m =
  0.36 ms per call + 0.46 ms per submesh (1.28 / 1.72 / 2.20 ms). `RenderReflections`: k4 +0.34,
  m4 +0.07 ms. So tiles uploaded together as submeshes of one object save ~0.3 ms of createMesh
  and ~0.5 ms of shadow pass per avoided call. In the mod this did not pay with 2 trucks
  (BENCHMARK 24): a shared object must resend every tile it shows, so more submeshes go up.
- WHY the first-draw cost is per call (decompiled 2026-11-10, 0.40.5 exe, static only, not
  measured): `createMesh` deletes every material instance of the object (the MatInstance list at
  obj+0x240, emptied once at the start and once at the end, unconditionally). The next
  prepRenderImage (vtable +0x240, 0x1401aa2b0) sees the empty list and calls `updateMaterial`
  (0x1401abc20), which makes one new MatInstance per distinct material name. Each pass then builds
  its hook for that new instance on first use: `ShadowMaterialHook::init` (0x1404cb370) collects
  the shadow features, allocates a new `ShadowMatInstance` (0x788 B) and runs its init (process
  material, state blocks); prepass and reflection-depth hooks work the same way. No cache is keyed by
  material, and no field or console variable skips it: same object, same size and same material
  still pays, as measured above. The sun cascades have no static-caster cache. The "still caster
  keeps its cached depth" settings in the exe are for local-light (cluster) shadows only. Lua cannot
  keep the instances across a `createMesh`. The only way around this cost is to not call it.
- Other per-call work in `createMesh`: `resetWorldBox` (0x140934aa0) then SceneContainer
  `checkBins` (octree move) and zone-dirty queueing (0x14095ebd0); then `updatePhysicsCollision`.
- Vertex buffers (decompiled 2026-11-10): `createMesh` allocates each submesh VB through the device
  (vtable +0xe0) with buffer type 0 (static), stride 44, then lock (VB vtable +0x68) / memcpy /
  unlock (+0x78) on the frame command list. On D3D12 (`GFXd3d12VertexBuffer`, vtable 0x1421abb48)
  a static VB is NOT immutable: lock (0x140e09e40) hands out an upload-heap staging block of
  stride x count bytes; unlock (0x140e09f60) records barriers + `CopyBufferRegion` into the GPU
  buffer. The index buffer (`GFXd3d12PrimitiveBuffer`, vtable 0x1421a9758) has the same lock/unlock
  slots. So a same-size rewrite of an existing tile's buffers is possible in the engine. It would
  skip the MatInstance rebuild, the collision and the world-box update. The CPU copies (ray casts at
  obj+0x388 / +0x3a0) and the bounds would go stale. Lua has no API for this: it would need native
  calls into engine objects. Not built.
- `PSSMLightShadowMap.lastSplitCastersEnabled = false`: no change (1.68 vs 1.69 ms per upload frame).
- ProceduralMesh has object type bits 0 and 8 (`SOTStaticObject`, `SOTStaticShape`), the same as
  TSStatic: a render view's `shadowCasterObjectTypeBlacklistMask` cannot leave only the mud out.

## Terrain

- `tb:setHeightGrid` + `tb:updateGrid` reach the VEHICLE physics only ~0.55 s after the LAST
  `updateGrid` (debounced; measured 2026-11-08, gridmap_v2, parked Percheron: one update 0.55 s; an
  update every 70 ms for 2 s: no movement until 0.55 s after the last one; real or far 1x1 box
  alike). `castRayStatic` sees the new height at once, which is why the old note said "at once".
  Writing the terrain every frame or at 20 Hz means the physics never gets it while writes go
  on. `updateGrid` costs 1–2.5 ms whatever the box size: merge all writes into one call, and keep
  writes >= 0.6 s apart (deepnode `physics.heavy.floorGap`).
- Mud ProceduralMeshes are not vehicle collision (2026-11-08, 0.40.5): a truck dropped from 0.6 m
  above a mesh lying 0.24 m over the terrain fell through it to the terrain. `castRayStatic` DOES hit
  them (per-object ray structure built in createMesh), so it is no proof of physics contact.
- Heights are stored rounded to `maxHeight / 65536` (gridmap_v2: maxHeight 100, step 1.5 mm).
  Read-modify-write drifts downwards: 20 cycles of `h - 0.13` then `h + 0.13` ended 3.4 cm low;
  10 x `-0.004` gave -4.6 cm. Write absolute heights from a saved reference.
- `core_environment.reset()` / `reloadGroundModels()` (also mission start, ground-model file
  change, the ground-model debug panel's "Default") rebuild `core_environment.groundModels` from
  the files: live `be:setGroundModel` retunes are lost (measured: MUD defaultDepth 0.25 -> 0.15).
- `tb:updateGrid` cost grows with the terrain, not the box: hw550 (8192 x 8192, 1 m) 15-78 ms for a
  3 x 3 square box, depending on where (measured 2026-11-01, three calls each, also with every
  GroundCover hidden: 16 -> 20 ms); gridmap_v2 (2048 x 2048) 1-2.5 ms.
- GroundCover `gridSize`: the same `maxElements` over more cells thins the cover out (hw550 tree
  covers at 300 / 760 cells per side lost most trees on the slopes) and the cells the camera has
  passed stay cached: RenderShadows 20 ms after a drive (0.8 ms at the level's grid sizes).
- `tb:updateGrid` drops and rebuilds every GroundCover cell over its box: that grass is gone for
  the next frame (measured 2026-10-31, gridmap_v2: updateGrid every frame over a 6 x 100 m strip
  12 m from a grass strip hid 75 % of the grass in view; a 2 x 2 m box beside it 5-14 %, at 24 m
  none). GPU and CPU placement alike (CPU copies took several frames to come back); calling it
  from onUpdate, onPreRender, onDrawDebug or onGuiUpdate makes no difference. Cells are
  2 x radius / gridSize (gridmap_v2: 15 m and 25 m). `$GroundCover::renderedCells` /
  `renderedBillboards` show the last pass drawn (they cycle with reflection faces).
- GroundCover `gridSize` can be changed live (`setField` + `postApply`): cells = 2 x radius /
  gridSize. updateGrid drops only the cells its box overlaps, so smaller cells limit the blink:
  gridmap_v2 (radius 100 / 45, gridSize 8 / 6 = 25 / 15 m cells) lost most long grass in view to
  a 4 x 3 m box 13 m away; with 10 m cells (20 / 9) none; 5-7 m cells changed the look (long
  grass evenly spread instead of patches). `tb:setHeightWs` leaves physics stale like
  `setHeightGrid`; no other update call exists (`updateGridMaterials`, `updateAllTextures`).
- How long the grass is gone (2026-11-07, gridmap_v2, physics paused, static camera,
  `$GroundCover::renderedCells` / `renderedBillboards` logged every frame in onPreRender): one
  `updateGrid` over a 2 x 2 m box dropped 2 cells (784 blades) for 3 frames; a 30 x 30 m box dropped
  28 cells, the cells came back over ~6 frames and their blades only at frame 7. Any `updateGrid`
  drops the cells, heights changed or not. The blades lag the cells: GPU placement
  (`shaders/common/groundCoverPlacement.hlsl`) bakes blade heights from the terrain height texture
  and counts them with `InterlockedAdd`, so the CPU reads the count back about 3 frames later.
  `screenshot_image` renders a fresh frame and never shows the gap (use the counters or desktop
  grabs of the game window).
- No way around the drop from Lua: `lockFrustum` (debug field) changes nothing with `setField`
  alone, and covers locked with `postApply` still lose their grass under updates. `postApply()` on
  a GroundCover and the global `flushGroundCoverGrids()` drop all its cells.
- The drawn terrain and the physics terrain can stay different for good (2026-11-05): heights
  written and drawn with a real-box `updateGrid`, then written again and refreshed with a far
  1 x 1 dummy box, keep drawing at the first heights while vehicles sink to the second ones,
  until a later real box covers those vertices. GroundCover there is never dropped. Used by
  `physics.heavy.grassLowDraw` (no grass blink next to digging).
- `tb:updateGrid` refreshes physics for the whole terrain whatever its box, but redraws the
  terrain and drops GroundCover cells only inside the box (2026-11-02, gridmap_v2): a vertex
  lowered 0.5 m then `updateGrid` on a 1 x 1 box at the far terrain corner -> `castRayStatic` hit
  the new height the next frame, the terrain looked unchanged until an update over the vertex,
  and grass beside a per-frame far-box update stayed (per-frame `updateGrid` or
  `updateGridMaterials` over a box in the meadow removed its long grass). Its cost growing with
  the terrain, not the box, fits a whole-terrain physics refresh.
- `setHeightGrid` without `updateGrid` changes nothing for physics (a parked truck stayed up and
  `castRayStatic` hit the old surface); `updateGrid` is the only update (no physics-only call in
  the TerrainBlock API).
- Creating a second `TerrainBlock` at runtime and calling its `update*` methods crashed the game.
- `digSdf`/`placeSdf` is an experimental forward-lit SDF renderer, not usable for mud.

## Decal roads

- `DecalRoad.overObjects` drapes by a physics raycast onto collision meshes, not render meshes.
- `zBias` is a depth bias, not a vertical lift.
- `decalBias` is the hover height over the terrain (exe field description).
- Translucent ProceduralMesh layers (probe 2026-11-06, two overlapping quads, gridmap_v2): with
  `translucentZWrite` on, the depth test decides which layer shows, and at a few mm apart it
  z-fights (at ~14 m slant: 2 mm -> the lower layer won, 0.5 mm -> the upper one; 2 cm ->
  always the upper one). With it off, submeshes of one object draw in submesh order (later =
  on top) and of two objects the nearer object draws last. Decal road materials have
  `translucentZWrite` on.
- Material field changes on an existing Material reach meshes only after `Material:reload()`;
  `flush()` left `opacityFactor` / `baseColorFactor` edits invisible on ProceduralMesh copies.
- A full decal copy draped over ruts hides them (the road pattern wins over the mud's rut
  look); a copy cut out of dug cells leaves plain stair-stepped holes. Fainter clones per
  disturbance level are the soft fade a ProceduralMesh can do (no vertex alpha).
- How the engine builds them (exe strings + shipped HLSL, 2026-11-05): a DecalRoad clips its
  strip against the TerrainBlock only ("A strip shaped decal ... which clips against Terrain
  objects"); `overObjects` adds a downward raycast onto static meshes. `SceneStaticDecalRoadManager`
  builds the geometry on the thread pool (`_captureTerrainVerticesThread`,
  `_rebuildNodeBatchesThread`) into static batches per spatial leaf. Vertex format
  `GFXVERTEXFORMAT_DECALROAD` (`shaders/common/material/shadergen/vertexIA.h.hlsl`): position
  packed 21/21/21 bits relative to the leaf origin (2048 m range), UV as half2, normal RGBA8 whose
  alpha is the vertex visibility (`startEndFade` / `distanceFade`), tangent RGBA8. Shading is the
  ordinary object shader (`defaultMat.hlsl`) with that vertex format.
- Why a decal road looks like part of the ground: its translucent material also runs the
  prepass permutation (`MFT_PrePassConditioner` with `MFT_IsTranslucent`,
  `permutations.h.hlsl`), which blends the road's normal and roughness into the G-buffer with the
  opacity as source alpha (RT0.a and RT1.a = opacity); the colour pass then draws the lit road
  over it. A ProceduralMesh with the same material goes to the translucent bin and gets only the
  colour pass (hence the copy's ~3 % difference and missing normals in `AL_NormalsVisualize`).
  Render bins named in the exe: MeshFast, MeshDecalFast, TranslucentFast, Terrain,
  ObjectTranslucent, DecalFast; no Lua route found that puts a ProceduralMesh in a decal bin.
- `DeferredDecal` is a box-projected colour-only decal (`deferred_decalP.hlsl`, test texture
  name in the exe), projecting onto whatever is in the depth buffer: not a road route.
- hw550 (8192 x 8192): `tb:updateGrid` of a 3 x 3 box costs 16-23 ms (best of 5) on a decal
  road, far from roads and at the terrain corner alike: the cost is the terrain size, not decal
  road rebuilds.
- With the terrain left at the mud surface (terrain-first) the engine draws decal roads exactly as vanilla.
- UV mapping (measured 2026-10-31 with a UV test texture on a DecalRoad and on a ProceduralMesh
  copy): u = 0 at the left edge, 1 at the right; v = -distance / textureLength, the distance
  measured along the middle line from the road's start. The copy then matched the decal within
  ~3 % brightness on matte ground (the rest was `startEndFade`, a vertex alpha a ProceduralMesh
  cannot carry).
- The exe documents "DecalRoads are rendered in descending renderPriority order": higher numbers
  first, lower numbers on top.
- A ProceduralMesh with a road's own (translucent) material is drawn forward-lit after the
  opaque scene; the engine's decal blends into the G-buffer (normals, roughness) before
  lighting (`AL_NormalsVisualize` shows the decal's normals, not the mesh copy's). On glossy wet
  ground the forward copy keeps more of the ground's sheen. On the mod's rut mesh next to the
  engine's decal no edge was visible on gridmap_v2.
- Copies laid on the terrain must follow its triangles: gridmap_v2's mud pit has furrows in the
  1 m heightmap, and a copy sampled every 0.5 m along the road sank under them in stripes.
- `be:reloadStaticCollision()` takes as long as `be:reloadCollision()` (~370 ms on gridmap_v2,
  2026-11-01); ProceduralMesh exposes no per-object collision update to Lua
  (`ProceduralMesh::updatePhysicsCollision` exists in the exe only): a DecalRoad cannot be
  re-draped over live ruts. The BeamNG docs confirm DecalRoads clip terrain and static (collision)
  mesh triangles and regenerate when terrain under them changes.
- The mesh vertex format used by ProceduralMesh carries one UV set (`VertexIaMesh.texCoord0`,
  expanded to `.xyxy`): material layers with `...MapUV1` flags cannot give a road layer its own
  UVs inside the mud material. Named render targets (`#name`) are bound only as CustomMaterial
  samplers in the shipped Lua (water), and CustomMaterial crashes on a ProceduralMesh.
- `fizzle()` (opaque visibility dither) is a static screen-space pattern, not usable as soft
  alpha for opaque decal copies.
- A screen-space redraw of decal roads cannot match them: no albedo buffer, own lighting
  (2026-10-31 A/B on gridmap_v2: the overlay road was far paler and flatter than the decal).
- A decal road's depth bias does not reliably draw it over a mesh a few mm above the terrain at
  close range (2026-11-02, camera ~8 m away: a mesh 6-12 mm over the terrain hid the decal over a
  half terrain square). The earlier "beats a mesh up to ~5 cm" was seen from further away: the bias
  is in depth units, so its world size shrinks near the camera. Copies cannot be left out where
  the mud lies just over the terrain.
- Cost (gridmap_v2, 2026-11-02): the level's decal roads over the pits cost ~2.6 ms of frame time
  in a close view of the mud pit (124 -> 186 fps when hidden), vanilla included. Translucent copy
  materials on a ProceduralMesh: about half of their draw cost is pixel shading (normal,
  roughness and AO maps), the rest per draw. Road opacity maps are dense (BC4, 10-25 % of texels
  transparent), so skipping copies by texture alpha would save little.
- Terrain squares are two triangles split along the (0,0)-(1,1) diagonal (gridmap_v2, both
  square parities); `core_terrain.getTerrainHeight` costs ~0.36 us a call.

### How the engine renders a decal road (reverse engineered 2026-11-06, game 0.40.5)

Sources: the game's shader cache `temp/shaders/shaders.d3d12.db` (msgpack records:
`[key, key, DXIL]`, key = HLSL path + stage + every define), the shipped HLSL preprocessed with
exactly those defines (`dxc -P`), exe strings, live probes on gridmap_v2.

- 62 cached permutations carry `GFXVERTEXFORMAT_DECALROAD`, all `defaultMat.hlsl` /
  `defaultMatV0.hlsl` (old materials, `MFT_MaterialDeprecated`). No special decal shader.
- Material fields pick the permutation: `translucent` + `translucentZWrite` ->
  `MFT_IsTranslucentZWrite`; `alphaTest` -> `MFT_AlphaTest0` (clip in every pass, also the
  G-buffer pass); `translucentRecvShadows` -> PSSM in the forward pass; `dynamicCubemap` ->
  `MFT_CubeMap` + `MFT_SceneCubeMap`.
- Pass 1, G-buffer (`MFT_PrePassConditioner`, `permutations.h.hlsl`): RT0 = oct-encoded normal
  xy, roughness, alpha = opacity; RT1 = specular colour, alpha = opacity; both blended by source
  alpha, so the road's normal and roughness mix into the terrain's. For one dielectric layer the
  base colour texture is not even sampled there.
- The deferred light passes then light those blended normals.
- Pass 2, colour (`MFT_OutputFinalColor` + `MFT_RTLighting1_5`, not forward): reads the light
  buffers at its own pixel (`lightInfoBuffer` rgb = diffuse, `lightInfoBuffer1` rgb = specular),
  adds SH ambient x the AO buffer x material AO, the cube reflection (+ SSR with `MFT_Sssr`), and
  blends over the scene by opacity. Hence a decal road looks "in" the ground: its lighting is the
  ground lighting of the blended normals.
- Other passes: `MFT_ClipPlane0` variants (water reflection, forward lit, PSSM, fog),
  depth-only variants, an SSR surface-capture path that special-cases decal roads
  (`materialReflection.hlsl`: decals overlapping within the depth bias are not matched by
  roughness).
- Vertex format: 21/21/21-bit position relative to a leaf origin (2048 m range, origin in
  `cspPrimitive.localTrans`), UV half2, normal RGBA8 with alpha = vertex visibility
  (`startEndFade`), tangent RGBA8 (w = -1). The instance's `distanceFadeParams` scales
  visibility by distance (`MaterialFlagInstanceDistFade`). Visibility multiplies opacity.
- Spline (`getEdgeCount` / `getLeft|Middle|RightEdgePosition`, `Sim.getDecalRoadData()`,
  `Sim.getVerticesOfDecalRoad(id)`): 11 samples per node segment at `detail` 0.1, position =
  lerp(linear, smoothstep Hermite, `smoothness`) (measured spacing 0.68...1.36 m on a 12 m
  segment matches it exactly); edge z = terrain height, no bias. These calls return the spline
  edges, not the clipped render triangles.
- Field docs (exe): `decalBias` "the hovering height of the decal over the terrain";
  `renderPriority` "-1 to top most, 1 for bottom most"; LevelInfo `decalBias` "NearPlane bias
  used when rendering Decal and DecalRoad" (gridmap_v2: 0.0005, nearClip 0.1). Changing either
  live (0.5 / 0.3 + `regenerate()`) showed no visible change: read at load or rebuilt elsewhere,
  not settled.
- The render pipeline is the C++ `RenderPassPipeline` (no Lua-visible bins). Render instance
  types named in the exe: MeshFast, MeshDecalFast, TranslucentFast, Terrain, ObjectTranslucent,
  DecalFast, Water, Foliage, SdfTerrain.
- `ProceduralMesh:createMesh` reads only `verts`, `uvs`, `normals`, `faces`, `material` (exe
  strings): no vertex colour, no second UV set, no vertex alpha. A ProceduralMesh has no
  object-level shadow switch (fields: material, render/selection flags only).
- `$DecalRoad::wireframe / showBatches / showSpline` draw only in the editor's road mode.
- `temp/shaders/pipelinecache.d3d12.db` is an opaque driver pipeline library (no states).

## Custom shaders (2026-10-31, D3D12 backend, gridmap_v2)

Method learned from the Dynamic Dirt mod (technique only, none of its code). Test shaders were
loaded from the user folder (`/shaders/...` is visible to the VFS).

- A `PostEffect` with its own `ShaderData` (one HLSL file as VS + PS, `pixVersion 5.0`) and
  `GFXStateBlockData` runs fine and draws into `$backBuffer`. Constants: `fx:setShaderConst`.
- Render slots that fire: `PFXAfterDiffuse`, `PFXBeforeBin ObjTranslucentBin` (after opaque
  lighting; fog and translucent objects like glass draw over it, the better slot for a screen-space
  overlay), `PFXBeforeBin ReflectDepthBin` (before the opaque scene is composited: geometry covers
  it), `CloudComposeBin`, `RenderBinWater`. `PFXBeforeBin SssrTrace` never fired. The exe names no
  bin between the G-buffer pass and lighting.
- `#prepass` / `#prepass[RT0]` as a PostEffect `target` writes nothing (checked with
  `AL_NormalsVisualize`): no G-buffer injection, so a post effect cannot get engine lighting for
  rut normals. A screen-space overlay must shade itself (read `#prepass[RT0]` + `#prepass[Depth]`).
- `CustomMaterial` as the material of a `ProceduralMesh` submesh: the custom VS + PS compile and
  draw (unlit colour), but the draw gets NO constant buffers and NO textures:
  - any `cbuffer` in the shader (own `perDraw` at b0, or the engine scene cbuffer
    `RenderPassConstBuffer` at b0/space1) -> fatal assert "root cbv has null gpu va", game crash;
  - a texture read in the VS returns 0 ("sampler root descriptor table had null gpu handle;
    binding null-descriptor fallback").
  - the shadow pass ignores the custom VS (shadow cast from the uploaded vertices).
  So GPU displacement of static mud meshes (no uploads) is not possible this way.
- Why it crashed (2026-11-07, stock shaders + exe strings, then live on game 0.40.5, D3D12):
  - Meshes draw on the **bindless** path (`MFT_Bindless`): no vertex buffer, no per-draw cbuffer.
    The vertex, the primitive transform and the material live in one byte arena
    (`materialsBytes`, t10 space0), found through push constants `pushC` at b3
    (`shaders/common/material/shadergen/bindlessArena.h.hlsl`). A `cbuffer perDraw : register(b0)`
    has no counterpart there, so its root CBV stays null.
  - Our test used `pixVersion 5.0`. The engine derives the `BNG_HLSL_MODEL` define from it
    (exe string `@BNG_HLSL_MODEL=%g`), and `hlsl.h` drops register spaces below model 6:
    `REGISTER(b0, sceneSpace)` became `register(b0)` in space0. That is why even the scene
    cbuffer crashed. Texture reads hit the same space0 mismatch.
  - Stock working examples: `shaders/common/vehicle/ghost.hlsl` and `highlight.hlsl`, set up in
    `lua/ge/client/core.lua` `createVehicleData()`: `pixVersion` 6 on D3D12/Vulkan (4 on D3D11),
    define `BNG_HLSL_MODEL=6`, `#define SHADERGEN_CUSTOM_MATERIAL_CBUFFER`, include
    `shadergen.h.hlsl` (+ `bindlessArena.h.hlsl` if `MFT_Bindless`), stub `getMaterialData()`,
    include `materialDrawId.h.hlsl`, VS signature `(vertexIARAW, svInstanceData, SV_VertexID)`,
    vertex from `getVertexIA()`, transform from `getInstanceTransform()` + `getPrimData()`,
    camera from the scene cbuffer (`worldToCameraPos0`, `cameraToScreen`, `eyePosWorld`).
  - Custom constants: `highlight.hlsl` reads `cbuffer cspMaterial : REGISTER(b4, materialSpace)
    { float highlightAlpha; }`, but `$highlightAlpha` is a name hard-coded in the exe, so the
    engine probably fills only known names. Generic per-material constants: unknown.
  - Textures on a bindless CustomMaterial: unknown (no stock custom mesh shader samples one).
  - `-nogfxbindless` launch flag exists (legacy binding path); not usable for players.
- Live test 2026-11-07 (gridmap_v2, 4 m ProceduralMesh grid, probe shader
  `tools/dev/bindlessWave.hlsl`: opaque magenta, VS sine wave from `accumTime`):
  - A CustomMaterial made in Lua (pixVersion 6 or 5, opaque or translucent, `reload()` or not)
    never runs its own shader, on a ProceduralMesh or in a vehicle `setRenderPass`. No crash: the
    ProceduralMesh draws flat dark grey (the default shader with empty material data), a
    translucent one draws nothing. The shader cache (`temp/shaders/shaders.d3d12.db`) holds only
    one bare compile of the file (no `MFT_*` features), while `vehicle/ghost.hlsl` has full
    `MFT_Bindless` permutations. The same file compiles offline against all 996 cached
    `defaultMat` feature sets and the ghost's 12.
  - Cause: the exe registers custom-material permutations only for the hard-coded names
    `vehicleGhost` and `VehicleHighlightMat` (`engine::registerCustomMaterialPermutation`, with
    a capacity limit; also `vehicleOverrideMat` in `VehicleResourceContainer`).
  - Proof: pointing the stock `VehicleGhostShader` at our file (`DXVertexShaderFile` /
    `DXPixelShaderFile` + `ShaderData:reload()` + `vehicleGhost:reload()`) made it run: on the
    player vehicle via `setRenderPass(0, 'vehicleGhost', meshes, false, true)`, AND as the
    `material` of a ProceduralMesh submesh: the flat grid was drawn as a moving 1 m sine wave.
    So **GPU vertex displacement of a ProceduralMesh works**, through a hijacked engine slot.
  - Sharing the slot without breaking the x-ray (live, same day): `tools/dev/ghostShared.hlsl`
    `#include`s the stock `ghost.hlsl` unchanged with its entry renamed (`#define main
    dn_ghost_main` before the include) and branches per vertex: first UV u < -500 (only DeepNode
    meshes write that; mesh UVs are full float2) takes the DeepNode path, every other vertex
    returns the stock ghost's VS / PS result. Vehicle and ProceduralMesh draws compile with the
    same `MFT_*` set, so the switch has to be at runtime. Seen in one frame: the marked grid waved,
    the SUV kept its grey x-ray ghost. Compiles against all 12 cached ghost permutations.
  - **Own slot (live, same day): name the ShaderData `ParallaxInteriorShaderData`.** Ghidra on
    the 0.40.5 exe: a CustomMaterial draws its own shader on the bindless path only when a flag
    byte on its processed data is set (`[mat+0xb28]+0xf1`, read by a virtual `Material` method).
    Three writers: the vehicle container (for `VehicleHighlightMat` / `vehicleGhost` only), an
    unrelated object, and `ParallaxInteriorManager`, which listens to the material manager's
    `Signal<void(CustomMaterial*)>` and flags every CustomMaterial whose shader name is
    `ParallaxInteriorShaderData`, also ones registered after the level loaded. No stock Lua or
    shipped level creates that ShaderData. Test: `createObject('ShaderData')` with our file,
    pixVersion 6, define `BNG_HLSL_MODEL=6`, registered as `ParallaxInteriorShaderData`; a new
    CustomMaterial `dnPIMatA` (opaque, `shader` = that name) on the test ProceduralMesh drew our
    animated wave; the ghost untouched. Cached permutations for it: the bindless translucent set
    plus an opaque `MFT_OutputFinalColor` + `MFT_RTLighting1_5` colour pass (reads the engine
    light buffers; no G-buffer variant).
    Limits: one ShaderData name, so one shader file and define set for all our materials (branch
    inside it); a future game version or level that ships parallax interiors would own the name
    (check `scenetree.findObject('ParallaxInteriorShaderData')` first and fall back).
    `Engine.ParallaxInterior` (`setSet`, `getSets`, `apply`, `getTuning`, sets of 7 texture paths
    + params, per level `art/parallaxMappingTextureSets.json`) applies texture sets to the
    materials in this slot: a possible texture input, binding layout not yet reversed.
    Texture test (live, same day, `shaders/dntest/dnTex.hlsl`): `uniform_sampler2D(dnTex, 0)` (t0/s0
    space0, as the water shader) + `material:setField('sampler', 'dnTex', '/art/dntest/dnTex1.png')`
    + a state block with `samplerStates[0] = SamplerWrapLinear`: our shader ran, but every read
    returned 0, the PNG was never even loaded (no cooked copy in `temp/`), and the log said
    "sampler root descriptor table had null gpu handle; binding null-descriptor fallback". This
    path ignores CustomMaterial `sampler` fields. Every CustomMaterial owns a texture-array holder
    (`+0xbc8`, built in its constructor with a change callback) that `ParallaxInteriorManager`
    fills from the set PNGs (`customTextureArray`: Texture2DArray, up to 2048 slices of one size,
    8-bit PNG, RGBA8 then background BC7); the parallax shader picks its set from the instance's
    `customData`. Which register it is bound to is not found yet (the parallax shader is not
    shipped). Even then it is a file-based channel (PNG + `apply()`, BC7 recompress), not a
    per-frame GPU height map.
    Ghidra project of this exe: `~/beamng-decomp/gproj` (analysed, saved), scripts in
    `~/beamng-decomp/gscripts` (DecompByStrings, DecompCallers, FindDisp), run with
    `run_script.bat`. Registration table `engine::registerCustomMaterialPermutation` (44 slots) is
    for internal render passes (sensor glass depth, radar), not material names.
  - Limits of the ghost route: only two slots, both translucent forward passes (no G-buffer, no engine lighting, no shadow:
    the shader must light itself), per-draw data only from the scene cbuffer (time, camera) and
    the vertices; custom constants (`highlightAlpha` only, slot 2) and textures not tested.
- GPU height map for the own slot: research 2026-11-10 (static only: stock shaders, 0.40.5 exe,
  the 11-07 shader cache). Goal: upload each tile once and displace it in the VS from a PostEffect
  target, so deepening needs no `createMesh`.
  - Texture access: a bindless shader can index ONE global 2D texture table,
    `materialTextures2D[65536]` at t26 space0 (`materialInputBindless.h.hlsl`, cube table at
    t65562), plus its own material block (`getMaterialData()`, `customDataOffets[]`; the engine puts
    the custom cubemap's index in `[1]`). A shader in the `ParallaxInteriorShaderData` slot includes
    the same headers, so it can sample any texture whose table index it knows. That index is the
    missing link: nothing found yet hands it to a custom material.
  - Named targets in materials: the bindless material init (0x1407fb4a0, gated by a global flag)
    takes a texture reference whose name starts with `#`, resolves it with `NamedTexTarget::find`
    (0x1407ed3d0) and stores the target's texture. The legacy binding path (0x1407ef370) handles
    `#` and `$` names too. Which Material / CustomMaterial field feeds the bindless one is not
    resolved.
  - Shadow pass: `ShadowMaterialHook::init` (0x1404cb370) swaps in `AL_DefaultShadowMaterial`
    unless the material's virtual +0x1b8 is true. For a CustomMaterial that is the bindless flag the
    ParallaxInterior slot sets (0x1407be400 reads `[mat+0xb28]+0xf1`). So in our slot the shadow
    instance should be built from our own material and run our VS. Not proven: the 11-07 cache
    holds colour, prepass (`MFT_PrePassConditioner`) and reflection (`MFT_ClipPlane0`) permutations
    of `dnBindless.hlsl` / `dnTex.hlsl`, but nothing shadow-like. Stock shadow casters compile
    with almost no features (`MFT_MATERIAL_LAYER_COUNT` [+ `MFT_MaterialDeprecated`,
    `MFT_ParaboloidVertTransform`]). The prepass permutation shows that the G-buffer pass DID run
    our shader, which corrects "no G-buffer variant" above.
  - Risk for an in-place vertex buffer write: `bindlessArena.h.hlsl` says a bindless mesh draws its
    vertex stream from the arena (t10), not from a vertex buffer. A lock/unlock of the static VB may
    therefore not change what is drawn, unless the VB lives inside the arena. Not checked.
  - LIVE probe 2026-11-11 (gridmap_v2, D3D12, RTX 5070; `tools/dev/slotTableScan.hlsl`): the
    route is blocked at the texture input.
    - Correction: the slot does NOT draw on the bindless path. Every cached permutation of our slot
      shader (`dnTex.hlsl`, 11-07) lacks `MFT_Bindless` (stock defaultMat permutations carry it),
      so `materialTextures2D` at t26 is not ours to read. The slot compiles the legacy layout:
      `Texture2D materialTexture[32]` at t14 `materialSpace` (space2), as `defaultMat.hlsl`.
    - Reading t14 space2 from the slot is safe: the 8 x 8 cell scan of all 32 slots (GetDimensions
      + texel 0) drew, no crash. All 32 slots were null (0 x 0) in every variant: no sampler,
      `sampler dnTex = '#dnH'`, and `sampler dnTex = 'core/art/white.color.png'` (a texture the
      level already has loaded). CustomMaterial `sampler` fields never reach this slot's table,
      for named targets or for files. No log line about it.
    - The named target itself was fine: `#dnH` (64 x 32 RGBA16F, written by a PostEffect at
      `PFXBeforeBin ObjTranslucentBin`) saved by `createScreenshotTracked({bufferType = 'dnH'})`
      held the magic texel exactly (223, 16, 143, 64).
    - Stock Material with `#name` maps was already dead (11-07 spike: "Failed to load 'diffuse'
      map"), so no Material route either.
    - **`castShadows = 1` on a slot CustomMaterial crashed the game** (C++ access violation on
      the main thread, ~150 ms after the first `createMesh` with it). By elimination: the same
      setup with `castShadows = 0` ran in three variants. The crash did not repeat with shadows
      alone (not retried, to spare a restart). The only minidump written
      (`%LOCALAPPDATA%/CrashDumps`) is from a process with 9 threads and no GPU driver loaded
      (start-up / shutdown), so it does not show this crash. Keep `castShadows = 0` in this slot.
    - Left untested: the CustomMaterial `cubemap` field (t10 space2, our permutations have
      `MFT_CubeMap`) and the ParallaxInterior texture array. Both take files, not per-frame GPU
      data, so neither gives a dynamic height map.
- GPU work available to Lua: compute PostEffects (`ShaderData.DXComputShaderName`, e.g.
  `postFx/passthru.cs.hlsl`, writes the `pfxOut` UAV of the target texture). Compute that writes
  mesh vertices exists only engine-internal (`skinning.cs.hlsl`, `dynamicDecals/processMesh.cs.hlsl`),
  with no Lua hook. No mesh/amplification/geometry/tessellation stages.

PostEffect details learned building the rut overlay (deepnode_overlay, same day):
- Shader constants: set `fx:setShaderConst('$name', 'x y z w')` inside the global
  `<effectName>Callbacks.setShaderConsts` function (the engine calls it before the effect renders).
  A constant shown as colour by a probe shader arrived this way; with the plain name it stayed 0.
  Engine-set uniforms (`accumTime`, `eyePosWorld`, `projParams`, `rtParams0`) arrive by themselves.
- A pass that draws into a named target does not keep the target's old content, even with
  `targetClear PFXTargetClear_None`: only the last draw's texels survived. Persistent GPU state
  needs a ping-pong (read the map, write all texels to a temp target, copy back), as Dynamic Dirt
  does. While both passes are skipped (`setField('skip', 0, '1')`), the map keeps its content.
- Draws in the first frames after creating the effects were lost: warm up with a few frames.
- `$backBuffer` as texture slot 0 and target `$backBuffer` works at `PFXBeforeBin
  ObjTranslucentBin` and at `PFXAfterDiffuse` (read the scene, write the changed colour, no blend).
- A deleted `GFXStateBlockData` / `ShaderData` can survive (still referenced) and `findObject`
  returns the old one: update fields in place instead of "create if missing".
- Compiled shaders are cached per file + `defines`: put a source revision into `defines` so an
  edited file compiles again (Dynamic Dirt does the same).
- `getConsoleNumber('fps::gpuTime')` (`VariableRegistry '$fps::gpuTime'`) stayed at one value with
  the GPU timing overlay on; fps stayed at 150 with `fpsLimitEnabled` and
  `fpsLimitBackgroundEnabled` off: GPU cost of a pass is not measurable that way. 8 extra copies of
  the 2048² stamp pass or of the full-screen overlay did not lower the 150 fps.
- Depth to world position in a post effect: `decodeGBuffer(depthTex, rt0Tex, uv, projParams).w`
  is linear depth, `worldPos = eyePosWorld + IN.wsEyeRay * depth` (as the engine's fog pass).
- Sun direction for a self-lit pass: ScatterSky `azimuth` / `elevation` (degrees);
  `(sin(az) cos(el), cos(az) cos(el), sin(el))` matched the engine's shading (debug view).
- `#sunShadowMask` (the screen-space sun shadow mask the vector light reads, r = unshadowed)
  can be bound as a PostEffect texture at `PFXBeforeBin ObjTranslucentBin`: the truck's shadow
  showed correctly (2026-10-31). Read it with `Load` at uv x its own size.
- `#prepass[RT1]` is NOT a base colour in this renderer (light pre-pass: lighting goes into
  `#lightinfo`, materials draw forward); shown as colour it was noise-like false colour. A post
  effect has no albedo: colour changes must work on the lit scene colour (scalar darkening,
  chroma gain, multiplicative tint).
- `ShaderData:reload()` with new `defines` does not change what an existing PostEffect draws,
  and `PostEffect:reload()` did not either (2026-10-31, second check): only a new ShaderData
  object (new name) set as the effect's `shader` field, then `reload()`, took the new code. A post
  effect shader that fails to compile logs nothing; the old one keeps drawing. Check offline with
  the Windows SDK dxc (see REFERENCE.md, overlay).
- A post effect can declare `uniform float lastFrameExposure;` in its perDraw block and gets a
  non-zero value (as the light passes); not decoded (tonemapping hides the number).
- Reflections without matrices: the sky colour can be read from the top rows of `$backBuffer`
  where `#prepass[Depth]` is far (rut puddles use the mean of 4 such points).
- Screen derivatives (`ddx`/`ddy`) of the world position and of map values work in a post
  effect; take them before any `discard` / branch. World gradient of a map value = 2x2 solve
  with `ddx(wp.xy)`, `ddy(wp.xy)`.
- After `reload_lua` with the MCP free camera active, `core_camera.getPosition*` returned
  (0, 0, 0) until the camera mode was set again (`set_camera orbit`).

### Road look (2026-10-31)

- A PostEffect has 6 texture slots (`texture` 0-5; slot 6+ reads back empty).
- Scene depth decodes without the normal buffer: `realToEyeLinearDepth(ndcToRealDepth(depth,
  projParams.zw), projParams)` with `#prepass[Depth]` alone (frees `#prepass[RT0]`'s slot).
- Decal road materials name `.png` files; the game ships `.dds` (colour BC7_UNORM_SRGB, opacity /
  roughness / AO BC4, normal BC5, 13 mips). Bound to a PostEffect slot the colour map arrives
  linear (the GPU decodes sRGB): a second `pow(2.2)` darkened it.
- Decal road draw order: on gridmap_v2 the engine draws mud_large (renderPriority 18) and
  mud_water (19) over the dirt roads (14): higher numbers on top.
- `mud_water` is a metallic (0.49) light-grey decal at 0.5 x 0.93 opacity: a wet, darker,
  reflective film, not a light colour.

### Engine lighting in a post effect (2026-11-08, game 0.40.5, D3D12, gridmap_v2)

- `PostEffect::_setupConstants` (FUN_14087e2f0, Ghidra) looks up a fixed list of names in
  every post effect shader and the engine fills them: `$ambientSH9` (sky SH9, float4[9]),
  `$sunDirection` (towards the sun), `$sunRadiance`, `$sunIrradiance`, `$exposure`,
  `$fogScatterParams`, `$ambientColor`, `$sunColor`, `$matWorldToScreen`, `$matScreenToWorld`,
  `$camForward`, `$texSize0-5`, `$rtParams0-5`, ... Probe (values written to a 16 x 8 target,
  read back with a named-buffer screenshot): SH9, sun direction (-0.54, 0.40, 0.75), sun
  radiance (~15, 14, 12) and irradiance (>100) arrive; `$exposure` ~1.6e-4; `lastFrameExposure`
  reads 0 in a post effect.
- The light pre-pass buffer is the named target `lightinfo` (`#lightinfo` = `[RT0]` diffuse
  light, `#lightinfo[RT1]` specular light). It reads 0 at `PFXBeforeBin ObjTranslucentBin` and at
  `PFXAfterDiffuse`, valid at `PFXBeforeBin ReflectDepthBin` and `PFXBeforeBin RenderBinWater`.
  Also valid at `PFXBeforeBin CloudComposeBin`. Order: `ObjTranslucentBin` passes run BEFORE
  `CloudComposeBin` and `RenderBinWater` ones (a road pass at either covered the rut overlay's
  prints); so pack the light into an own target at `ReflectDepthBin` and use it later.
- Screen AO: `#gtaoOutput` (r).
- `BNG_COCONUT` is defined globally: a lit material's colour is
  `diffColor / PI x (lightinfo + SH9(normal) x screenAO x materialAO) + specular (+ cube / SSR)`
  with `diffColor = baseColor x (1 - metallic)` (`permutations.h.hlsl`
  `calculateDeferredRTLighting`). A post effect computing `albedo / PI x (#lightinfo + SH9 x AO)`
  with the terrain's albedo rendered seamlessly into the real terrain (debug view 3).
- `baseColorFactor` alpha is not the opacity (layer opacity = `opacityFactor` x opacity map);
  `alphaTest` clips at `opacity - alphaRef` (mud_large: ref 0, no cut-out).
- Decal road material AO maps are strong (mud_water mean 0.21, mud_furrows 0.69, mud_large
  0.64) and every one has a normal map; the engine blends decal normals into the G-buffer before
  lighting, so the relief shows on the ground under a decal too.
- In a post effect, `SampleGrad` on texture slots 4 and 5 returned the texture's smallest mip
  (its average) while `SampleLevel` on the same slot read right (slot 3 `SampleGrad` worked);
  post effect samplers (`SamplerWrapLinear`) are not anisotropic. The road shader samples with
  explicit mip levels and 4 taps along the footprint (roadDrawP.hlsl `sampleAniso`).
- gridmap_v2 mud pit: up to 7 decal roads overlap at one point (>= 5 on 2 % of road cells),
  12 visible (renderPriority, material) keys, 7 materials.
- `distanceFade` of the pit roads is "150 50", `startEndFade` "5 5".
- With pre-rutted roads on, the engine's decals in the pit lie under the pre-rut meshes: mode
  'vanilla' then looks like plain terrain (no reference for road look tests).

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
- GE VM: `ffi.cast('const uint8_t*', luaString)` returns the string itself (no pointer); read
  bytes with `string.byte`. `GBitmap:loadFile` does not read DDS (returns false, 1 x 1).
  `readFile(path)` reads DDS from the mounted zips (5.6 MB in one call).
- Stock decal road textures (content/assets/materials/decalroad.zip): normal maps BC5U (or DX10
  dxgi 83), opacity / AO / roughness BC4U (or dxgi 80), colour BC7 (dxgi 99), full mip chains,
  materials name .png paths and the engine loads the .dds next to them. Normal maps are
  DirectX style (green flipped): least-squares integration has the lower residual that way on
  every stock decal; with dh/du = -nx / nz the dips fall on the dark track strips of the base
  colour (correlation 0.79-0.98).
- Editing a vehicle's own Material in place works: `setField` + `mat:reload()` (~2 ms per material)
  reaches the vehicle meshes; `flush()` alone changes nothing on them (2026-11-04, lc300 /
  Percheron, colour test). Vehicle materials are shared by name (`veh:getMaterialNames()`), so
  an edit shows on every vehicle that uses the material. Object shader: roughness =
  `roughnessFactor` x roughness map; per-instance roughness exists only through the colour
  palette path (`paletteRoughness`, tied to the paint).
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
- Terrain files inside a level zip: `io` seek works but decompresses up to the offset
  (huge_desert, 8192^2 v8: 534 ms per 100 MB forward). A seek beyond the end of an unpacked file
  returns nil (gridmap_v2).
- huge_desert: 8192 x 8192 squares of 64 m; `setHeightGrid` rounds heights to steps of up to
  ~9 cm there (maxHeight / 65536), read back after writing. `tb:updateGrid` costs 15-60 ms per
  call on it (any box), like hw550.
- A game frozen by Lua for seconds ends as launcher error `0xCFFFFFFF STATUS_APPLICATION_HANG`
  (Windows kills it); beamng.log may miss the mod's lines when the 15000-line cap cuts the middle.
- Terrain layer strengths (`baseColor/normal/roughness/ao` `Macro`/`DetailStrength`) reach the
  shader packed as 0..1 unorm (terrain.h.hlsl `unpackFloat4N`): a strength of 8 draws as 1.
- The terrain leaves out a layer texture whose pixel size differs from its slot's size in the
  level's `TerrainMaterialTextureSet` (`baseTexSize` / `detailTexSize` / `macroTexSize`); the
  log says "dont have required size of ... declared in TerrainMaterialTextureSet".
- Terrain normals: `lerp(lerp(base, macro, mF), detail, dF)`; object materials (defaultMat.hlsl):
  `normal.xy += detail.xy * detailNormalMapStrength`.
- Any graphics settings apply (preset or `PostFXScreenSpaceShadowsEnabled`) calls
  `setScreenSpaceShadowsEnabled` (core/settings/graphic.lua) and re-enables
  `ScreenSpaceShadowsPostFx` + `$AL::UseSSSmask`; `extensions.hook('onSettingsChanged')` fires
  after it. `settings.getValue('PostFXScreenSpaceShadowsEnabled')` returns the stored option, not
  the PostFx state. Its contact shadows draw dark slivers 15-40 m away at mesh edges a few mm
  above the terrain. `$pref::Terrain::lodScale` (set it with `VariableRegistry.set`) did not
  open visible seams between mud meshes and terrain (1.5 vs 0.001, same shot).
- BeamNG's ImGui build fills a ticked `Checkbox` blue whatever the style colours (probed every
  `Col_*` slot the Lua binding exposes). Draw over it (`GetItemRectMin`, `GetFrameHeight`) for
  another look. ImGui windows hide with `toggle_ui {"show":false}` too. A new ImGui window can get
  its own OS window (viewport) unless `SetNextWindowViewport(GetMainViewport().ID)` is set.
- hw550 region recentre cost vs region size: 1000 m 85-88 ms, 2000 m 188-208 ms, mostly
  `tb:updateGrid` (76-79 ms vs 174-192 ms).

## Baked road layer (roads.mode 'bake', 2026-11-07, gridmap_v2, D3D12)

- A stock Material cannot sample a `#named` render target (`baseColorMap` / `diffuseMap` = '#name':
  "Failed to load 'diffuse' map"), own PostEffect targets and engine ones alike.
- A PostEffect target can be saved to PNG: `require('screenshot').createScreenshotTracked{ filename =
  'path/without/ext', bufferType = '<target name without #>', superSampling = 1 }` (exact pixels at the
  target size; alpha is written as 255). The screenshot module keeps every job and re-sends the whole
  list to the UI on each callback: call `clearScreenshotJobs()` after a batch (hundreds of jobs made
  every frame ~16 ms slower).
- The screenshot writer creates the file before it finishes it: wait until the size is non-zero and
  stable, else a cook reads a partial PNG ("TextureCooker: Could not open ..." and a NO TEXTURE layer).
- The engine cooks a PNG to `/temp/<path>.dds` (`.color` -> BC7 sRGB, `.data` -> BC7, `.normal` -> BC5)
  only when its texture manager loads it; creating or `reload()`ing a Material does not.
  `ui_imgui.ImTextureHandler(path)` cooks at once (~10 ms per 512² image).
- Files created by an outside process are not seen by the game's file system (NO TEXTURE); files the
  game writes (screenshots, GBitmap:saveFile) are.
- Deleting a texture file that a live Material uses crashes the game (the file watcher re-cooks it,
  "Texture[] started importing", C++ crash). Never delete cache images while the level runs.
- `defaultMat.hlsl` layer maths: a layer with no base maps and detail maps at strength 1 gives
  colour = saturate(2 detail), opacity = saturate(2 opacityDetail.r), roughness / metallic =
  factor * saturate(2 x), normal = normalize(flat + detailNormal.xy); layers lerp by opacity. Every
  channel has a detail slot (`detailMap`, `opacityDetailMap`, `detailNormalMap`, `roughnessDetailMap`,
  `metallicDetailMap`, `ambientOcclusionDetailMap`) scaled by the layer's `detailScale`; `*MapUseUV`
  only switches the UV channel.
- `PostEffect:setTexture(slot, path)` switches a slot live. Several PostEffects must not declare the
  same `#target` (one effect pair with switched maps instead).
- Five named-buffer readbacks per tile cost ~+5 ms a frame while baking (GPU sync; the same at 256² and
  512², invisible in the CPU metrics).
- Draw order checked against the engine's own decals on an undug pit tile (patch 4 mm over the terrain
  with the mud material + baked layer): lower renderPriority on top (`bakeHighOnTop = false`) matched
  within 1.2 % mean / 2.6 % luminance std at 6 m and 0.6 % / 2.5 % at 3 m; higher on top buried the
  furrows under the water sheet (soft, pale).
- Revision B (regions of 4 x 4 tiles, 2048² images): gridmap_v2 has 230 roads over soft ground in
  121 regions; baking all of them at load took 100.9 s (~0.83 s per region, 0 failures), a second
  load from the cache 0.55 s. A cooked 2048² image is 5.6 MB of DDS (all three kinds), 28 MB per
  region; only regions whose clone material is drawn load into VRAM. Rig check of one region against
  the vanilla decals: 0.1-1.9 % mean / 2.5 % std at 6 m, 0.7 % / 1.8 % at 3 m.
- The mod's sim clock (`deepnode_main.simTime`) advances with `dtSim` only: it stands still while
  `be:setPhysicsRunning(false)`; timeouts during a physics pause must use real time (`os.clock`).

## Material updates (2026-11-09, 0.40.5)

- Per Material, after `setField('alphaRef', ...)`: `flush()` 0.52-0.61 ms, `reload()` 0.58 ms,
  `postApply()` 1.1 ms; `inspectUpdate()` costs nothing and applies nothing. A flush every frame
  also adds ~1.5 ms of engine `Ticking` (8 trucks, sector tyre materials).
- `ProceduralMesh:setMaterial(submesh, name)` on a live tyre skin CRASHED the game (fatal). Never
  call it on DeepNode meshes.

## Where the 8-truck dig frames go (2026-11-09, per-frame `Engine.Debug.getLastPerformanceMetrics`)

gridmap_v2, 8 Percherons digging vs idle frames: GE Lua 16.1 vs 0.8 ms (mod 9.3, of it uploads
6.4; vehicle reports ~4), RenderShadows 9.1 vs 4.1, Render 5.3 vs 2.6, RenderReflections 2.75
vs 0.6, Ticking 1.8 vs 0.1 (material flushes). The digging phase is uniformly slow (every frame
uploads), the >45 ms frames are dig batches plus a reload / floor write in the same frame.
- LuaJIT (jit.v, 5 s while digging): hundreds of "NYI: register coalescing too complex" side-
  trace aborts in carve / writeOne (inlined under onMudReport's big wheel loop: snapshots carry
  the caller frames' live slots). Branch-free decodeZ / encodeZ / settle (exact) and a two-pass
  stampFootprint did not remove them or change stamp cost (~74 us per stampWheel call);
  `jit.opt -sink` made stamping 40-75 % slower.
- Mud ProceduralMesh uploads already skip invisible changes (ring.minVisibleChange 6 mm on
  screen) and padding is ~8 % of corners (6 tile classes): no visual-neutral upload cut left
  there.
- Wheel-report loop restructure tested (2026-11-09, 8 trucks): stamps deferred until after
  onMudReport and run from a small loop (kind state captured) -> 124.5 vs 69.7 us per
  stampWheel call, same aborts. The caller frame is not the cause.
- Branch-free tyre write path (per cell only codes + per-tile running min/max, bookkeeping once
  per tile at the end of onMudReport): bit-identical to the old path (6 trials, 48672 values
  each, 0 differences) and fewer trace aborts, but not faster (interleaved 74.9 / 81.2 vs
  71.9 / 74.3 us per call). Reverted. The stamp cost is not the trace aborts.
