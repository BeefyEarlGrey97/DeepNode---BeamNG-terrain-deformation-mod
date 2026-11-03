# Changelog

## [Unreleased]

### Added
- Region mode for big maps (BeamNG.earth, hw550): on terrains over 16 km2 (`region.enabled`
  'auto') the mod works in a 1 km x 1 km region around the player only. The layer map, distance
  field, sink pass, tiles and road cover cover the region; outside it the terrain stays as it is.
  Once the player is 250 m off the region centre (`region.shiftAt`) or outside it, the region is
  recentred: the next region's layer map and distance field load over a few frames
  (`region.loadBudgetMs` 4 ms), then one frame keeps the overlap (sunk vertices, rut floor,
  tiles), gives the vertices that left their original height back, sinks the ones that entered
  and drops the tiles outside the stable overlap. Measured on gridmap_v2 forced to region mode
  (1001 x 1001 squares): load 8-14 ms over 3-4 frames, switch frame 4-13 ms; after a far jump the
  terrain matches its original heights exactly (54 rutted floor vertices restored); ruts in the
  overlap survive a shift. Memory per array: ~1 MB per km2 instead of S x S bytes (268 MB each
  on a 16384 x 16384 terrain); start no longer reads or scans the whole map. hw550 (8192 x
  8192, 67 km2, region on by 'auto'): start 1.35 s (42586 vertices sunk in 90 ms), shifts of
  300-1000 m: load 9-15 ms over 3-4 frames, switch frame 4-12 ms.
- Terrain files up to 32768 x 32768 vertices (was 16384).

### Changed
- Decal road edges are read once per start (`P.roadEdges`) and reused by the road carve, the
  road cover and the overlay's road mask. The road mask is built per 64-square chunk at the
  first lookup (gridmap_v2: whole-map mask 14 ms / 162k squares per km2 -> 4 ms index at start).
- Decal road copies (`roads.mode` 'copy'): the drawn cells of a dug square are merged into planar
  rectangles for the copies (`roads.copyMerge`, `copyMergeFlat` 4 mm, tested against the two
  triangles the copy draws). gridmap_v2, one lc300 in a 60 m circle: copy corners per upload
  2750 -> 2110 (-23 %), same look; the fps change was inside the noise.

### Fixed
- Grass blinking next to digging (heavy physics), and the rut floor waiting near grass:
  `tb:updateGrid` turned out to refresh physics for the whole terrain whatever its box, while it
  redraws terrain and grass only inside the box. Near grass the floor now goes to physics at once
  through a far dummy box and the terrain is redrawn once the grass cells are out of view or after
  `grassHold` (`physics.heavy.grassSplit`, `grassViewRange`). gridmap_v2, lc300 circling next to
  the grass meadow, 30 s: visible blinks 22 -> 11 (camera on the grass), 27 -> 12 (chase camera);
  vehicles near grass no longer ride on the old terrain for up to 1 s (540-640 held frames -> 0).
  A waiting group is redrawn while in view only once its terrain would hide the rut (lowered by
  more than 0.7 x `floorMargin` since drawn, `grassRedrawShare`); smaller changes wait until the
  grass is out of view (90 s next to the meadow: 12 / 13 / 7 visible redraws per 30 s).

### Found
- Why decal roads on cost so much frame rate (BENCHMARK 8): mostly the level's own decal roads.
  gridmap_v2's pits carry 238 stacked decal roads (~2.6 ms in a close view, vanilla included);
  mode `off` hides them and runs faster than vanilla. The copies add ~0.55 ms with one truck
  (uploads ~0.22, drawing ~0.25, emission ~0.08).
- Tried and dropped: no copies where the mud lies within ~1 cm of the terrain (the engine's decal
  does not reliably draw over the mesh up close: plain half-squares), skipping by road opacity
  (opacity maps are dense).

## [0.3.1] — 2026-11-01 — big maps: trees, grass and frame rate fixed

### Fixed
- Big maps (hw550): trees and grass thinned out and the frame rate fell under 25 fps. The
  groundcover cell shrink (`grass.cellSize` 10 m, heavy physics) applied to every GroundCover:
  hw550's tree covers (radius 1500 / 3800 m) went from 10 / 20 to 300 / 760 cells per side, the
  same `maxElements` spread over many more cells and the cell cache grew as the camera moved
  (RenderShadows 20 ms after a drive, 0.8 ms with the mod off). Now only covers up to
  `grass.maxRadius` (150 m) shrink, to at most `grass.maxGrid` (32) cells per side. hw550, same
  view: Render 10.2 ms / shadows 0.79 ms against 10.0 / 0.79 with the mod off (was 23.2 / 20.0);
  forests and grass as without the mod. gridmap_v2's covers (radius 45-100 m) keep 10 m cells.
- Terrain updates on big terrains: `tb:updateGrid` costs 15-78 ms on hw550 (8192 x 8192) for any
  box (1-2.5 ms on gridmap_v2). Above `physics.heavy.slowUpdateMs` (8 ms, measured) the rut floor
  is written at most every `slowUpdateGap` (2 s), everything pending in one update: 90 s of
  digging in hw550 mud 70 -> ~30 updates (one ~15 ms hitch every 2 s). The rut shows up to 2 s
  later there.

## [0.3.0] — 2026-11-01 — water in the ruts, trucks that stay put, tread prints on by default

### Changed defaults
- Tread prints on (`overlay.enabled` true, GUI "Experimental tread prints").
- Decal roads on the mud off (`roads.mode` 'off' in config.json, was 'copy'; GUI "Experimental
  decal road") and the screen-space road look off (`overlay.roads.enabled` false).

### Results (gridmap_v2, 6 Percherons, runs 2-5, one session)
- Mod off 88.7 fps (low1 84.2); vanilla physics 63.7 (51.0); heavy 59.5 (47.5); heavy with only
  the player's truck digging 69.5 (58.1). Release notes: docs/RELEASE_NOTES_v0.3.0.md.

### Added
- Pooled water in the ruts (`overlay.puddleMode` 'fill', default): once a rut tile has been quiet
  for `poolQuiet` (0.8 s), its cell heights are flood-filled (priority flood over the tile and one
  tile around it); every closed hollow holds water up to `puddles` (0.7) of its spill depth. The
  pools go into the rut map as water rects in the paint slots the prints leave free; the overlay
  draws water wherever the surface lies below the stored level, so the shoreline follows the rut.
  Replaces the patchy noise level (still there as `puddleMode` 'noise'). gridmap_v2, one
  Percheron through fresh mud: 23 tiles, 27 pools, 48 rects, 0.58 ms per tile (max 0.76 ms),
  `poolMaxPerSec` 6.
- Wet trenches (`overlay.trench`): mud ruts deeper than `start` (8 cm) get wetter, smoother
  (fewer crumbs) and darker over `range` (12 cm), with a slow smeared pattern.
- Only the player's vehicle digs ruts, optional (`ring.physicalVehicles` 'all' / 'player' /
  'near' + `ring.physicalRange`, GUI Run tab "Ruts: ..."): the other vehicles leave screen-space
  prints only (no stamps, rut meshes, uploads or floor writes). gridmap_v2, 6 Percherons, runs
  2-5: 69.5 fps (low1 58.1), Lua 1.26 ms against 58.8 (45.5), Lua 2.77 ms with every truck digging.
- Driven wheels dig under drive torque (`stamp.torqueDigRate` 0.08, `torqueDigStart` 0.25): above
  a traction ratio (drive force / wheel load) of 0.25 the driven wheel churns the mud under it
  before it spins. Wheel reports carry each wheel's own load (smoothed down force: weight transfer
  under throttle) and drive torque (report stride 16). Moonhawk (RWD) launch in gridmap_v2 mud,
  2 s: rear wheels 0.35-0.43 m below the undisturbed surface with the floor dug to 0.22 m, the
  front wheels 0.19-0.20 m on a 0.10-0.12 m floor.

### Changed
- Decal roads over the mud rebuilt (`roads.mode` 'copy', new module `deepnode_roadCopy`): copies
  of every road over a mud mesh are built on every mesh build, so a truck digging a road no
  longer leaves a plain-mud rectangle around it (the previous build waited 1 s for a tile to
  settle). Copies come from the quads the mesh builder records; a square still planar within
  `roads.copyFlat` (1 cm) is one quad in the copies even where the mud is drawn in cells, so
  mainly dug cells cost copy vertices. Copy materials are exact clones of the road materials
  (`assignFieldsFromObject`) without shadow casting; tile border drops are undone for copies.
  gridmap_v2, 8 Percherons: tile uploads 4617 -> 1066 vertices and 5.9 -> 2.8 ms each against
  the old copies on every build; 51.9 fps (low1 35) against 45.4 (24) for the old copies on
  every build and 56.9 (44.4) with no roads on the mud.

### Performance
- Decal copies only once a tile is quiet (`roads.overlayQuiet` 1 s after its last stamp): while
  a truck digs, a tile rebuilds at the rut rate and the copies (several road layers over every
  rut cell) cost ~0.6 ms of Lua per build and larger uploads. A quiet tile is rebuilt with them
  (not skipped as a too-small change), a tile that freezes first gets them on freezing.
  gridmap_v2, 8 Percherons, same session, runs 2-5: copies on every build 45.4 fps (low1 24),
  Lua 8.6 ms, trucks bogged to 1.2 m/s; quiet copies 53.3 (36.0), Lua 5.2 ms, 3.0-3.5 m/s; copies
  off 56.9 (44.4), Lua 2.6 ms. Hull triangles skip reports that cut nothing new (~1 ms Lua).
- Decal copies undo the tile border drop (`sectors.drop` next to a sector mesh): the copy
  followed the dip under the sector's mud, a light line along tile edges.

### Fixed
- Vehicles sank after stopping in heavy mud: the rut floor writes trail a driving vehicle and
  caught up under its parked wheels (Percheron braking in fresh gridmap_v2 mud: -22 cm over 6 s
  after standing still, 1800 more floor writes). The floor under the wheels of a vehicle slower
  than `physics.heavy.holdSpeed` (0.8 m/s) is no longer lowered while they stand there, unless
  the wheel spins faster than `holdSpin` (1 m/s): it digs itself in. Same test: no floor write
  after the stop; a one-off settle of ~5 cm into the engine's soft layer as the wheels stop
  rolling remains, then the truck holds still (+0.1 mm in 4 s).
- Grass blinking next to digging trucks (heavy physics). The v0.1.1 fix (`pool.hideFrames`)
  covers a different cause, mesh swaps; this blink comes from the rut-floor terrain writes:
  every `tb:updateGrid` drops the GroundCover cells over its box for a frame, and the level's
  cells are 15-25 m. GroundCover cells are now 10 m while the floor is written
  (`grass.cellSize`, gridSize raised to 2 x radius / cellSize, restored on stop; same density,
  the patchy look stays). Probe on gridmap_v2 (updateGrid every frame over a 4 x 3 m box 13 m
  from the meadow south of the mud pit): the long grass in view vanished with the level's
  cells, stayed with 10 m cells. `physics.heavy.grassReach` 24 -> 12 m (writes beyond it run at
  the full floor rate again).

### Added
- Every part of the vehicle plows the mud, not only the tyres and the chassis nodes: the body's
  collision triangles (not tyres, rims or pressure triangles) with a corner under the
  undisturbed surface are stamped as their lower envelope, edges rounded off over
  `stamp.hullEdge`, swept between reports in `stamp.hullStep` steps, displaced volume into a
  berm (`stamp.hull`, `report.maxHullTris` 64, deepest first). gridmap_v2: a Land Cruiser
  flipped onto its roof left a roof-shaped dent.

### Changed
- Decal roads on the mud are real geometry again, drawn by the engine with the road's own
  material (`roads.mode` 'overlay', new `roads.overlayOriginal` / `roads.overlayOnRuts`, now the
  default). Terrain-first: the level's decal roads stay visible on undug ground (exactly
  vanilla); the mud mesh around ruts carries a copy of every road over it, clipped to the strip
  and stacked in the engine's draw order, so the road pattern drapes over the rut walls and
  berms. Replaces the screen-space road look (roads hidden + redrawn from a road map), which
  looked nothing like the engine's decals (own lighting) and showed the vehicle mask boxes
  around every truck. gridmap_v2: no visible edge between the engine's decal and the copies.
- Decal copies use the engine's UV mapping: v runs negative along the road
  (v = -distance / textureLength, measured with a UV test texture), distance along the middle
  line in 3D. The old copies had the pattern mirrored along the road, so it broke at every rut
  band edge.

## [0.2.0] — 2026-10-31 — ground look, decal roads in the ruts, faster with 8 trucks

Research follow-up (terrain deformation techniques review, 2026-10-31): what BeamNG 0.40's Lua
allows now, measured on gridmap_v2 with 4 Percherons (2 mud, 2 sand), interleaved A/B, runs 2-5
of each set: 76.1 -> 78.3 fps, low1 59.7 -> 62.3, worst near rut lag 1.5-3.9 s -> 0.8-1.0 s.

### Added
- Decal roads on the mud follow the ruts (overlay `roads`, with the experimental ground look on
  and `roads.mode` off): the roads DeepNode hides over soft ground are drawn again in screen
  space from a world-space road map (two layers per texel, one pass per road material), on the
  rut floors and berms as dug; tyre prints draw over them. Not on kerbs, walkways or vehicles
  (height band around the road's own surface). gridmap_v2: 230 roads, 6017 quads, 7 materials;
  render thread +0.1-0.17 ms, 34 MB video memory.
- Wet sky sheen (overlay `wetSheen` 0.3): wet mud ruts mirror the sky at grazing angles
  (flat-water Fresnel x a smooth wetness; the per-groove wetness first gave blue streaks).
- No puddles under vehicles: the footprints of up to 8 vehicles near the camera mask the water
  (a sunk truck showed water around and between its tyres).
- Dry soil look (overlay `drySoil`): soft layers named dusty / dry / desert / sand (e.g.
  johnson_valley `dirt_loose_dusty`) get the sand print look and throw no mud splats; wet mud
  darkening and puddles stay for real mud.
- Wet tracks (overlay `wetTracks`, after MudRunner's wet decals): tyres wet from water leave
  dark glossy prints on hard ground that dry out patchily within ~55 s (the map stores the paint
  time; a paint pass every few seconds erases dried texels).
- Tracks on hard terrain (overlay `tracks`): clean wheels on grass terrain leave flattened, paler
  tracks, on dirt / gravel compacted ones, picked by the terrain material name; none on decal
  roads (a road mask is scanned when the overlay starts) or off the terrain.
- Mud splats (overlay, after MudRunner's terrain mud decals): wheels spinning in mud throw
  lumpy wet blobs behind them (further and more with more slip, either side when spinning on the
  spot) onto berms, rut floors or hard ground. The blob shape is cut in the stamp pass, so the
  ground under its ragged edge keeps its own look, and a splat over a print keeps the print's
  relief running.
- Puddles in mud ruts (overlay, after MudRunner's water pooling): the print map now stores the
  undisturbed ground height, so the shader knows how deep each pixel lies; below a patchy water
  level (`puddles`, `puddleDepth`) the rut floor turns into murky water with a sky reflection
  (sampled from the sky at the top of the screen), sun glint and slow ripples.
- Per-kind print look: sand prints have softer relief and finer, lighter crumbs than mud.

### Fixed
- Road look cost ~0.5 ms of GE Lua a frame with 8 trucks (vehicle boxes measured and constants
  formatted per pass every frame): boxes cached (0.5 s) and moved with the vehicle, constants
  shared; sky sampled only for glossy roads. 8 Percherons: Lua 4.08 -> 3.6 ms, 47.2 -> 48.1 fps
  (main without the road look 48.6).
- Grass flickered next to dug mud in heavy mode (clear on the gridmap_v2 material ramp, whose mud
  strip lies 12-16 m from a grass strip): every rut-floor terrain update makes the engine rebuild
  the groundcover over its box for a frame, and the one merged box per frame spanned all trucks.
  Floor writes now go out in clusters: grass-free clusters together in one update as before,
  clusters near grass layers on their own at most once a second (`physics.heavy.floorCluster`,
  `grassReach`, `grassHold`). Ramp run: updates near the grass 58 -> 18, all updates 62 -> 25.
  Grass beside a digging truck still blinks about once a second (engine: no terrain update
  without the groundcover rebuild).
- Tyre mud on the HT-55 dump truck's rear wheels: its four rear physics wheels share their hub
  nodes in pairs (one 1.27 m axle span per side), so each picked up its neighbour's tyre mesh and
  was built as a dual (two narrow skins per wheel, one on the wrong tyre). A wheel now only takes
  tyre meshes over its own tread nodes.
- Prints were dropped with 6 trucks (16 segments a frame, queue overflow): a wheel's waiting
  segment is now extended by its next report while it goes on straight (`mergeMax`); 0 dropped of
  ~20 600 in a 6-truck run (5 000 merged).
- Thin pale outlines where print, berm and splat texels meet (the interpolated lateral channel
  is no position across kinds: the point value is used there).
- Shader edits reach the game after an overlay restart: ShaderData objects are named after the
  source revision.
- `deepnode_overlay.reloadShaders()` did not change what was drawn (the PostEffects kept their
  compiled shader): it now makes new ShaderData objects and points the effects at them.

### Changed
- `ring.bodyMaxWait` 0.1 -> 1.5 s (config.json): a tile whose new ruts are all under a truck body
  waits until the whole truck has passed, so an 8x8 makes one upload per tile instead of one per
  axle. 8 Percherons on gridmap_v2: uploads 8500 -> 3900 per 5 runs, 47.5 -> 52.3 fps, low1
  35.5 -> 39.9, Lua 3.7 -> 2.6 ms, RenderShadows 6.3 -> 5.5 ms.
- `overlay.zTolerance` now counts from the undisturbed ground (not the tyre bottom); new
  `maxDepth`. Overlay constants are formatted only when they change.
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
