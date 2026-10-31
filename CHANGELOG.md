# Changelog

## [Unreleased]

Research follow-up (terrain deformation techniques review, 2026-10-31): what BeamNG 0.40's Lua
allows now, measured on gridmap_v2 with 4 Percherons (2 mud, 2 sand), interleaved A/B, runs 2-5
of each set: 76.1 -> 78.3 fps, low1 59.7 -> 62.3, worst near rut lag 1.5-3.9 s -> 0.8-1.0 s.

### Changed
- Tyre prints have no tread pattern any more, so they suit every wheel, small or big: a
  compacted, wetter band with smear streaks along the track, irregular stick-slip ripples across
  it and a lip of mud squeezed up at the edges (noise relief, filtered by the pixel footprint).
  Carried mud on hard ground is a streaky stain. Config: `phasePerMetre`, `streaks`, `lip`
  replace `lugsPerMetre`, `chevron`, `lugWidth`.

### Added
- Screen-space ground and tyre look on top of the tread prints (`overlay`, still experimental,
  off by default), after a Spintires reference: the print map now stores the surface kind and a
  berm band; the overlay draws filtered chevron relief with darkened grooves (no thin aliased
  lines, readable whatever side the sun is on), granular crumbs with tiny cast shadows on the
  berms, wet churned mud (darker, more saturated, patchy) and damp sand, and a sun highlight.
  Coated tyres leaving the soft ground print their mud (or sand dust) on hard ground, fading as
  the coat runs out. A new tyre pass makes wet and freshly mud-coated tyres darker and glossy
  (sun highlight, Fresnel sky sheen) for the 16 nearest wheels, without material flushes; it can
  also draw the coat itself (`overlay.tyreCoat`, off: the tyre mud meshes stay for now).
  Measured on gridmap_v2 (Percheron 8x8): Lua 0.06-0.09 ms/frame, CPU render +~0.15 ms; fps sat
  at the 120 cap with and without the passes (GPU cost not readable).
- Experimental tread prints (`overlay`, GUI "Experimental tread prints", off by default): tyre
  prints are painted on the GPU into a 2048² world-space map around the camera (128 m) and drawn
  over the lit scene as chevron tread relief and wet darkening in the ruts. Own HLSL post effects
  (`shaders/common/postFx/deepnode/`), no mesh uploads; the rut shape still comes from the meshes.
  The map scrolls with the camera, lugs stay in phase from one wheel report to the next, and
  tiles DeepNode resets (idle reset, Smooth ruts) erase their prints. Lua cost 0.003 ms per idle
  frame, ~0.04 ms with 16 prints; 8 extra copies of each pass did not lower fps (150 fps cap, GPU
  timer not readable: GPU cost not measured exactly).
- Soil memory (`stamp.soil`): every rut cell counts tyre passes and keeps the first pass's depth;
  pass N carves at most z1 x N^(2/(2n+1)) (Bekker's multi-pass rule) instead of straight to the
  tyre bottom. The heavy terrain floor follows the rut, so repeated passes deepen by a bounded,
  kind-dependent amount: sand packs, mud keeps giving (`soften`).
- Per-kind rut rules (`stamp.kinds`): berm share (sand 0.5 growing with depth, mud 0.35), wall
  slope (sand ~35°, mud ~58°), slip sinkage (`slipBeta`: a slipping tyre carves deeper, most in
  sand) and spin-dig factor.
- Deadline-first rebuild queue: after fresh rut fronts, waiting rebuilds are served by deadline
  (change became visible + `ring.inViewTarget` / `outViewTarget`); deepening of meshed tiles out
  of the camera's view waits until it comes into view (at most `ring.outViewMaxDefer` s).
- `ring.minVisibleChange` (6 mm): a tile re-upload whose largest change against the mesh on screen
  is smaller is skipped (~47 uploads per run, ~4 %).

- Heavy physics: sand is drawn terrain-first too (`physics.heavy.floorLift.sand` 1 in
  config.json): undug sand is the engine terrain with its decals and view distance. Same truck
  times through the sand pit and same fps; engine memory per 4 runs 15.9 -> 4.9 MB.
- LuaJIT: no closures created per call in the hot paths (timers, view cone, sort orders) and a
  branch less in `decodeZ` (`jit.v` trace aborts, see ENGINE_FINDINGS).

### Fixed
- Tread prints: relief and highlight no longer appear inside shadows (engine screen shadow mask
  `#sunShadowMask`); no grey holes in the prints (slope from the depth buffer instead of the
  normal-mapped G-buffer normal); no artefact line along the tyre centre; no green/red speckles.
- Heavy physics floor heights are written absolute from the sink pass's reference. The height
  grid rounds every write (1.5 mm steps on gridmap_v2) and the relative writes drifted down
  (-3.4 cm after 20 lower/raise cycles, measured).
- Heavy ground models are applied again after the game reloads its ground models
  (`core_environment.reset()` / mission start / ground-model file change / debug panel
  "Default"); before, heavy mode silently fell back to the vanilla values.
- Benchmark harness (`tools/benchmark/ge_extensions/dntestRun.lua`): reset with `map.safeTeleport`
  facing the captured heading and the arcade gearbox set again (trucks drove backwards in
  reverse gear after a reset).

## [0.1.4] — 2026-10-29 — 4.3 MB download (DDS tyre textures)

### Changed
- Tyre textures ship as DDS at half size (512x1024, film 256x512) in BeamNG's formats, made with
  NVIDIA Texture Tools (`tools/dev/tyre_dds.py`): colour BC7 sRGB, normal BC5, coverage order BC7
  linear (BC4, the game's data format, was clipped everywhere by the object shader's alpha test).
  Release zip 18.3 MB -> ~4.3 MB. Same look in game (wheel close-ups, mud and sand, steady state;
  coverage-by-alphaRef identical within 0.3 %). New folder `art/deepnode/tyre/`: the engine's
  texture cache keeps cooked `art/deepnode/t_tyre*.dds` from the old PNGs and loads those instead
  of same-named files.
- Tyre texture means are stored per kind (`clods.kinds.*.texMean`, measured from the source
  PNGs) instead of read from the texture at start.
- PNG sources and bake scripts moved to `tools/tyre_textures/` (not shipped).

## [0.1.3] — 2026-10-29 — gradual tyre mud, heavy physics default, decal roads switch

### Changed
- Heavy physics is the default (`physics.mode = "heavy"`).
- Decal roads on the mud are off by default; the GUI checkbox is now called "Experimental decal
  road". Off: no decal road shows on mud or sand: every decal road touching soft ground is hidden
  whole (`roads.hideOnMud`; heavy physics draws undug mud with the terrain, which drew them;
  a mud mesh up to ~5 cm above the terrain loses to the decal's depth bias). gridmap_v2: 238 roads
  hidden in 62 ms at start. On: shown again, plus the overlay in the mud meshes.
- Tyre coat look changes gradually: after a change of state (mud / sand / off the soft ground)
  the drawn colour and kind hold for `clods.lookDelay` (1 s), then blend over `clods.lookFade`
  (1 s), textures switching half way; drawn coverage moves at most `coverUpRate` 0.5 /
  `coverDownRate` 1.0 per s. gridmap_v2, Percheron on a 60 m circle (mud -> sand): colour held
  ~1.2 s, blended in ~1 s, coverage 0.48 -> 0.30 over ~0.6 s (before: colour and texture
  switched within 0.3 s, coverage jumped).
- Slower build-up, faster fall-off: `buildPerMeter` 0.03 -> 0.01 (coverage 0 -> 0.58 over 6.5 s
  in mud at 18 km/h, before full in ~3 s), coverage updates every 0.25 s per wheel (was 0.5 s:
  visible jumps); `cleanDelay` 2 -> 1 s, `looseShedPerMeter` 0.03 -> 0.1 (loose layer gone ~0.7 s
  after the delay), `cleanPerMeter` 0.002 -> 0.02 (packed layer). Tyre flushes ~4.5/s with one
  truck, 59.7 fps mean.

### Fixed
- Decal overlay switch: turning it off and on deleted the overlay materials while meshes still
  drew with them (garbage strips until each mesh was rebuilt); the copies are now updated in
  place. Overlay lift 4 -> 8 mm (z-fighting speckles beyond ~10 m).
- Tyre coat switched kind the moment a wheel crossed from mud to sand (or back): a mud-caked
  tyre turned into a thin sand film at once. The ground's kind is now kept apart from the coat's;
  the coat changes kind when the new material makes up half of it (same mass share the colour
  mixes with: ~4-6 m of driving), at once only on a nearly clean tyre.
- Coated tyres blinked or stayed bare for seconds: a wheel waiting for a skin rebuild (other kind)
  was hidden, and the rebuild itself hid it for the upload. The current skin now stays drawn and is
  replaced in place.
- Upload starvation with vsync on: createMesh blocks while the driver waits for the frame (~14 ms
  measured per tile upload at a steady 60 fps, ~1.2 ms with vsync off); the budget charged that
  wait, allowed about one upload per frame and learned absurd costs. Uploads are now charged at most
  twice their estimate (min 1.5 ms) and waits do not train the cost model. Reservations (tyre
  skins, sectors) queue up and are served in turn on upload frames, also after the rut fronts' dig
  uploads; before, a waiting sector won every frame and a reservation on a frame without uploads
  was lost.
- gridmap_v2, one Percheron on a 40 m circle across the sand/mud seam, vsync on: coated wheels
  hidden in 8 of 1920 samples (first 5 s after a reload) against 199 of 1920; 25 tile uploads/s
  against 13/s; 59-61 fps.

## [0.1.2] — 2026-10-28 — tyre mud, sand and wet looks; ~60 % less memory growth

### Fixed
- Tyre coat changed colour (and kind) out of the mud: the vehicle reports every wheel on a
  mud tile, and tiles also cover hard squares at the mud's edge, where `mudLayerAt` falls back
  to a neighbour layer or the zone/default kind (gridmap_v2: the hard start line of the sand
  lane read as mud). Tyre mud is now only fed on soft ground (`P.softAtWorld`), and a wheel
  keeps the last soft-ground colour where the ground colour is unknown.
- Mud on the tyres looked like moss camouflage (blotchy decal texture, lumpy normal map, olive
  tint). New procedural mud set (`bake_tyremud.py`, no game texture any more): a smooth clay coat,
  tread first, then shoulders and sidewalls down to the rim with ragged edges, soft lumps and the
  lug relief under the mud; own normal map `t_tyremud_nm`. `kinds.mud.groundGain` 2: drying mud
  on a tyre is lighter than the wet ground (gridmap_v2: the coat read near black in the truck's
  shadow, rubber 17 vs coat 25 grey levels; now a clay brown).
- Wet tyres looked wrapped in black plastic (uniform film colour 0.03). The water film is now
  muddy water: ground colour of the wheel's last soft ground x `filmMud` (0.5), streaked where
  water runs off (`bake_tyrefilm.py`, `t_tyrefilm_b/o`), opacity `filmOpacity` 0.4 (was 0.25).
- Sand on the tyres looked like a cake: a solid, uniform, greyish band over the whole tyre.
  - The user gui.json saved the whole `clods.kinds` table, so the sand texture paths from before
    the rename (`/art/deepmud/...`, gone) stayed pinned over config.json: no coverage map, the
    alpha clip showed the full skin. The GUI now saves only the kind colours, and loading drops
    everything but `color` from older gui.json kinds.
  - The skin sat 1.2 cm over the tread lugs (a smooth band). Sand skin: 3 mm (`kinds.sand.thickness`)
    and 10 mm below the tread surface (`kinds.sand.treadInset`), so the tyre's own lugs show
    through and the sand sits in the grooves.
  - New sand coverage order (`bake_tyresand.py`): tread, shoulders, then down the sidewall with a
    ragged, radially streaked edge (the old order was mostly speckle over the whole tyre); thin
    sidewall dust baked darker (rubber showing through). `kinds.sand.coverMax` 0.62 (was 0.92).

### Changed
- Tyre coat colour = terrain colour under the wheel (`clods.groundColor`): the layer's base map
  (sampled once at start into a `groundGrid`² grid, GBitmap, ~50 ms) plus its macro/detail mean,
  divided by the alpha-weighted mean of the kind's tyre texture, times `groundGain` (default: the
  kind's `wet`), `groundDesat` towards grey. puresands: tyre sand (190,166,142) vs lit ground
  (215,187,160), same hue (B/R 0.74; was 0.62, a fixed orange-grey colour). The fixed kind colours
  only apply where the ground colour is unknown (zones, layers without texture).
- A wheel entering a kind with other skin values (thickness, inset) rebuilds its skin once after
  1 s in it.
- Mesh pool: size-affine reuse. A released object waits in a free list keyed by the padded
  buffer sizes of its last mesh and is handed out again for a mesh of the same sizes (engine
  memory grows when an object's buffers change size). gridmap_v2, 8 Percherons, vanilla, after
  warm-up: +1.2 to +6.8 MB per run (~850 uploads) against +12 to +17 MB before; 87 % same-size
  hits. `deepnode_tileMesh.reuseStats()` (hits, fresh, steals, keyed free).
- Decal overlay size classes pair verts = corners / 2 (measured 1.95 corners per vertex) instead
  of the grid ratio 4: overlay padding 307 -> 103 corners per submesh (no new classes).
- A rebuild identical to the shown mesh (positions, normals, uvs, faces, materials) is not
  uploaded: 4.4 % of builds on gridmap_v2 (a neighbour or timer asked, nothing visible changed).
- Tyre coat colour from the ground computed without a table per wheel and coat tick (tyre mud
  update 0.41 -> 0.30 ms per frame, 8 trucks).
- `deepnode_tileMesh.uploadCensus(reset)`: uploads, submeshes, corners (layer / overlay),
  padding, distinct padded sizes.

### Results (gridmap_v2, 8 Percherons, vanilla, orbit camera on truck 1, vsync off)
- Same session, original v0.1.1 Lua swapped in and out: fps mean 45.9 (v0.1.1, 14 runs) vs
  45.3 (now, 14 runs; ±3 fps between single runs of one setup), low 1 % 24–35 vs 28–34.
  Without tyre mud 45.1 vs 48.0 (the new mud/sand/wet looks cost ~1 ms more to draw).
- Engine memory, fresh mud, 5 runs after a reload: +244–268 MB vs +96–113 MB; runs 4–5
  +12 to +26 MB each vs +0.6 to +5 MB. Repeat runs (existing ruts, 10 runs): +5.9 MB/min.
- Physics unaffected in every setup: sim/wall time 0.998–1.000, `PhysicsNodes` 1.5–1.7 ms
  with or without the mod, vehicle Lua (`PhysicsAndVLUA`) 0.35–0.45 ms.

## [0.1.1] — 2026-10-28 — grass flicker fix, faster tile rebuilds

### Fixed
- Grass (and the ground under it) flickered while mud chunks rebuilt: the replaced mesh was
  hidden one frame after its replacement was uploaded, and the new mesh was not always drawn by
  then, so for one frame the lowered terrain showed with the lifted grass standing above it.
  Measured on johnson_valley with forced sector rebuilds: 11 undrawn frames in 6 passes with a
  one-frame hold, 0 in 12 passes with 2 or 3. New `pool.hideFrames` (default 3).

### Changed
- Mesh builder: submesh arrays keep their last length and take spare element tables back only
  when a build grows; a submesh returns to its last material. Before, every tile build moved
  thousands of tables to and from the stash when submeshes changed size (tile build
  0.98 → 0.10 ms in a micro-benchmark of a 590-vertex rut tile).
- Mesh size classes: tile meshes padded to sixths instead of thirds of the largest tile, decal
  overlay submeshes from 96 instead of 384 corners (`pool.tileClasses`, `pool.decalMinCorners`).
  createMesh of a rut tile: padded to thirds 1.41 ms, exact 1.08 ms.

### Results (gridmap_v2, 8 Percherons, vanilla physics, user GUI settings, vsync off)
- Fresh mud: 38.4 fps (low1 27.6), GE Lua 7.6 ms → 40.7–41.9 fps (low1 30.9–31.5), GE Lua 4.6–5.2 ms;
  mod frame time 5.2 → 2.8–3.6 ms. Memory growth not higher (36–122 vs 113 MB/min, noisy).

## [0.1.0] — 2026-10-28 — first release

### Renamed
- Mod renamed from "Deep Mud" to **DeepNode**: extensions `deepnode_*`, folders `lua/*/extensions/deepnode`,
  `art/deepnode`, `settings/deepnode`, `scripts/deepnode`, user settings `<user folder>/settings/deepnode/`,
  benchmark helpers `dntest*`. Distributed as `DeepNode-v0.1.0.zip`.

### Added
- Terrain-first drawing for heavy physics: undug mud is the level terrain (vanilla decal roads,
  grass, colours, unlimited view distance); mud meshes only where wheels dug.
- Predictive stamping (adaptive lead from the measured rut-front latency).
- Fresh-rut-front scheduler: tiles with a fresh front in the camera view rebuild at up to 40 Hz
  outside the frame-rate governor; uploads coalesced every 2nd frame.
- `deepnode_main.rutLag().fresh` (rut front latency), `deepnode_main.pointInView`.
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
