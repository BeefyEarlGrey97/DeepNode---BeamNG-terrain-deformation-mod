# DeepNode for BeamNG.drive

DeepNode turns the soft terrain of any level (layers whose name or ground model contains
"mud" or "sand") into deformable mud. Wheels dig ruts that stay, chassis parts carve dents,
the vehicle is dragged and held by the mud, wet dark mud lines the wheel paths, and lumps of
mud build up on the tyres and fly off when the wheels spin.

Target: BeamNG.drive 0.39.x on Windows.

## Install

Copy `deepnode.zip` into `%LOCALAPPDATA%/BeamNG/BeamNG.drive/current/mods/` and enable it
in the mod manager. The mod starts by itself when a level loads.

The control window opens when the mod starts (`gui.openOnStart`). To show or hide it
from the console (`~` key, GE Lua):

```lua
deepnode_main.gui.toggle()
```

## How it works

### Soft ground

* A terrain layer is soft when its layer name or its ground model name contains one of the
  texts in `softMatch` (default `mud`, `sand`).
* The layer map is read straight from the level's `.ter` file. The mod checks the file's
  row order against the engine on a few hundred random points. It accepts the file as
  "direct" or "flipped" only when 90 % or more of the points agree. Otherwise it asks the
  engine for every vertex once at start (about 0.3 us per vertex: ~5 s on a 4096 x 4096
  terrain).
* Mud depth fades to zero over `layers.featherVerts` terrain vertices towards any other
  layer, with a smooth (S-shaped) curve. The fade distance is measured with rounded
  contours, so the mud border does not follow the square steps of the terrain grid.
  A soft vertex that touches another layer has depth 0, so every mud square is pure soft
  ground.
* You can add your own mud zones (circles) with the GUI button "Add mud zone here". Zones
  are saved per level in `settings/deepnode/levels/<level>.json` in your user folder. A zone
  adds depth (the deeper of zone and layer wins). Adding or removing zones rebuilds the mud
  state (ruts are cleared).

### Decal roads

Hard roads (asphalt and the like) keep their strip free of mud: at level start every
terrain vertex under such a decal road (left to right edge, plus `roads.margin`) is taken
out of the soft mask. Roads whose material contains a `roads.skipMatch` text (`invisible`,
`dirt`) or a `softMatch` text (`mud`, `sand`) are not carved: mud furrows, tyre tracks and
dirt decals belong to the mud.

Those decals on the mud are switched by the GUI Run tab checkbox **"Experimental decal
road"** (`roads.mode`, off by default, switches live and is saved):

* Off (`"off"`): no decal road shows on the mud or sand. Every decal road with any part
  over soft ground is hidden whole (`roads.hideOnMud`), also its stretch over hard ground
  next to the mud. (Heavy physics draws undug mud with the terrain itself, which would draw
  the level's decals on it; covering them with the mud mesh does not work: the decal's depth
  bias beats a mesh up to ~5 cm above the terrain, 2 cm z-fights.)
* On (`"overlay"`): the roads are shown again; on undug mud in heavy mode the terrain draws
  them, and the mod draws them into its meshes (sand, vanilla physics):

* An engine decal road is a flat strip laid once onto what is below it. On the mud it
  either lies on the lowered terrain (hidden) or, laid onto the mud surface, covers every
  rut dug later like a flat sheet. So the mod draws the decal into its own mud meshes:
  every mud mesh carries, for each decal road over it, a copy of its triangles under the
  road strip, textured with the road's material and UVs. The decal follows the mud.
* Where a tyre or the chassis touched the mud (rut, berm, track) there is no decal: the
  pattern is churned away, and a decal never lies over a rut.
* The copies of the road materials are alpha-clipped (drawn with the mud in the opaque
  pass: same shadows and lighting), matte (`overlayRoughness`), cast no shadow.
  Puddle decals (`overlaySkipMatch`, default `water`) are left out: as a mesh they turn
  into a flat light sheet.
* The engine keeps drawing the roads too, on the lowered terrain: hidden under the mud
  meshes, still visible beyond the loaded mud sectors.
* Cost (gridmap_v2, 8 Percherons through both pits, 4 runs): 54.6 fps with decals,
  55.1 without; ~3 MB engine memory per run more once warmed up. Switching it on rebuilds
  every loaded mud mesh (gridmap_v2: 85 sectors in ~3 s).
* The overlay materials are kept for the session and updated in place: deleting them on an
  off/on switch left the meshes still drawn with the deleted copy (garbage strips).
* A Material changed after a mesh was uploaded only reaches that mesh for constants
  (colour factor, alphaRef); feature changes (alphaTest on/off, maps added/removed) need
  a new upload (measured: recolouring the copies showed only on meshes built later).
* Not possible in BeamNG 0.40 (measured): ProceduralMesh has no vertex colours (decal
  ends fade by narrowing the strip instead), ProceduralMesh collision only enters the
  physics world on a full `be:reloadCollision()` (~380 ms), and translucent copies of
  decal materials cost ~2.8 ms of GPU time and sort badly.

`roads.mode = "drape"` is the old method: the engine decals are laid once at start onto
temporary collision meshes at the mud surface (one ~1 s pause with physics stopped);
ruts dug later are covered by them.

### Groundcover

Groundcover (grass, plants, small rocks of a GroundCover object) on soft layers would grow
on the lowered terrain, under the mud surface. At start, before the terrain is lowered:

* a GroundCover whose used types all lie on soft layers of one sink depth gets its
  `zOffset` raised by that depth;
* a GroundCover that mixes soft and hard layers (or soft layers of different depths) gets a
  copy per depth that keeps only those soft types, lifted by the depth; the original keeps
  the rest. A type is switched off with an unreachable `minElevation`, not with
  probability 0, so it still takes its share of the random picks: with the same seed every
  copy places its types exactly where the original did.

The sink pass's terrain update makes the groundcover rebuild its cells, so the lifted
grass shows at once. Stop puts everything back (before the terrain is restored).
`grass.lift = false` turns this off. Known limits: on the depth fade near a layer border
(`layers.featherVerts`) the terrain is lowered less than the full depth, so grass there can
stand up to that depth above the mud; grass does not move into fresh ruts.

### The terrain under the mud

At level start every soft vertex of the whole map is lowered once by its mud depth, in one
terrain update. The lowered terrain is the hard floor; the mud surface is drawn at the
original ground height. The terrain is never edited while you drive. Stop, GE Lua reload
and opening the world editor put the terrain back exactly as it was.

### The mud surface

* The world is split into tiles of whole terrain squares (about 5 m). Each terrain square is
  split into cells of about 20 cm.
* Untouched tiles draw one quad per terrain square; tiles with ruts draw every cell.
* The surface uses the terrain's own textures for each soft layer, so an untouched patch
  looks like the terrain it covers. The base colour map spans the layer's
  `baseColorBaseTexSize` (spinMud mapping; `materials.baseSizeFrom = "terrain"` spans the
  whole terrain instead).
  Its colour copy (see Safeguards) is logged in `beamng.log`; if the copy fails a warning
  is logged and colours can look washed out. `materials.tint` and `materials.roughness`
  fine-tune the match on a level. Where the depth fades out, the patch dips a few
  centimetres under the terrain, so the visible border is a smooth line.
* Mesh rebuilds never flicker: the new mesh goes into a hidden object that is shown at once,
  and the old one stays visible for `pool.hideFrames` more frames (replacing a visible
  object's geometry in place leaves it undrawn for a frame: measured in game as a rut tile
  vanishing in every other frame; hiding the old one after a single frame still left some
  chunks undrawn for a frame, the lowered terrain and the lifted grass showing through). With `pool.mode = 'pair'` each chunk, tyre and lump mesh alternates between
  two objects of its own.

### Ruts

* Every wheel in mud is reported about 30 times per second (hub position, axle, radius,
  width, depth, wheel spin). The mod sweeps the tyre shape from the previous report to the
  current one, so ruts stay continuous at speed.
* A rut follows the tyre profile (rounded shoulders) and never goes below the hard floor.
* The mud behaves half liquid:
  * part of a fresh rut flows straight back (`stamp.flowBack`);
  * the mud beside the tyre sags towards it over a soft rim of `stamp.rimCells` cells;
  * wet mud cannot hold steep walls: right after each stamp, walls steeper than
    `stamp.maxSlope` slump into the rut (only where the tyre passed, so older ruts keep
    their shape);
  * over the next few seconds (`stamp.relaxTime`) fresh ruts and berms settle back towards
    the undisturbed surface and keep `stamp.relaxKeep` of their depth, leaving a soft
    trough. Frozen ruts do not change.
* The displaced mud builds low, rounded berms beside the tyre. They grow over repeated
  passes up to `stamp.bermMax`.
* Chassis parts under the mud surface carve round dents along their path, with a low ring
  of mud around them.
* Spinning, deep wheels leave rougher, clumpier ruts (track intensity drives a fixed
  world-space jitter of the rut vertices).

### Physics

* Physics is BeamNG's own (vanilla mode): the mod applies no forces. Vehicles sink through
  the drawn mud to the lowered terrain and drive on it with the soft layer's ground model.
  (The heavy option below adds the rut guide.)
* The game engine streams the undisturbed mud level and the mud depth of the tiles near
  each vehicle into that vehicle's Lua. The vehicle reports its wheels and chassis nodes
  under that level about 30 times per second; the reports cut the ruts and dents and coat
  the tyres. In vanilla mode the visual ruts do not change the physics.
* Up to `ring.maxVehicles` vehicles near the camera (yours, traffic, other cars) get an
  active ring: they dig ruts and coat their tyres at full rate. The others report at
  1/`ring.farLod` of the rate.
* Spin dig (visual) scales with the real wheel load reported by the vehicle: heavy trucks
  dig deeper holes than light cars (`stamp.refWheelLoad`).

### Heavy physics option

GUI Run tab: "Physics: vanilla / HEAVY" (or `physics.mode` in the config). Switching
restarts the mod, so do it with no vehicle sunk in the mud. Heavy mode still uses only
BeamNG's own physics:

* The soft ground models get thicker values (`physics.heavy.groundModels`), set live
  and put back on stop. Mud: soft layer 0.2 m (vanilla 0.15), viscosity 17000 (2000),
  density 20000 (7000), friction 0.35/0.32 (0.55). Sand: soft layer 0.14 m (0.10),
  viscosity 7500 (5000), density 30000 (25000).
  Measured on gridmap_v2, 85 m from standstill, full throttle:
  Percheron 8x8 mud 56 -> 30 km/h (rear drive only 25, low range 32), sand 55 -> 48 km/h.
* Rut floor: under undisturbed mud the hard floor stays `floorLift` (0.3 m) above the
  full sink. Where ruts are dug, the terrain under them is lowered to the rut surface,
  so rut walls are real terrain. Terrain squares are 0.75-1 m, so the walls are coarse
  and gentle: they hold a light steering input for a while and can be climbed. Terrain
  comes back up only when the ruts reset and no vehicle is within 8 m.
  Cost: one terrain update per frame at most (1-3 ms, measured), inside the upload budget.
  Floor heights are written absolute (full sink level from the sink pass + lift): the height grid
  rounds every write to maxHeight / 65536, and the old relative writes drifted (ENGINE_FINDINGS).
  The heavy ground-model values are checked once a second and applied again when the game reloads
  its ground models (environment reset, mission start, ground-model file change).
* Soil memory and per-kind ruts (`stamp.soil`, `stamp.kinds`): each rut cell counts tyre passes
  and remembers the first pass's depth; pass N may carve at most z1 x N^(2/(2n+1)) (Bekker's
  multi-pass rule: ~4x after 4 axles in clay, ~2.4x in dry sand), times a softening factor for
  mud. The terrain floor follows the rut, so this also bounds how deep the trucks sink over
  repeated passes. Sand has wider berms that grow with depth, gentler walls (35° vs 58°),
  stronger slip sinkage and spin digging. Measured 2026-10-31 (4 Percherons, gridmap_v2): mud
  cells passed twice 0.147 m mean depth, four times 0.180 m; sand reached its 0.15 m floor by the
  second pass.
* Rut guide (`physics.heavy.rutGuide`): the terrain grid cannot hold a 0.3 m wide rut,
  so the rut walls of the mud mesh act on the tyres as the ground would. With every
  wheel report the mod fits the slope of the rut relief across the tyre (5 samples over
  its width plus `edge`) and the vehicle applies the lateral part of the ground force,
  `-gain x wheel load x slope` (|slope| <= `maxSlope`), to the hub nodes. A tyre in the
  middle of a rut feels nothing; one climbing a wall is pushed back.
  Measured (gridmap_v2, Percheron at 21 km/h, steering held at 0.05, 95 m): no ruts
  27 m off the line; in its own ruts with the terrain floor only 10 m; with the rut
  guide 0.0 m.

### Dual wheels

A dual wheel is one physics wheel that carries two tyres side by side. The mod finds
them from the tyre meshes on the wheel's axle (their `pos` in the jbeam); without
them a wheel wider than `dually.autoRatio` x its radius is split into two tyres. Each
tyre cuts its own rounded rut, the mud between them squeezes up into a low ridge
(`dually.ridge`), the rim and berms run along the outer edges of the pair, and both
tyres carry mud (`clods.dualSlotFactor` x the lumps of a single tyre).

### Mud on the tyres

Turn it on/off with the key binding **"DeepNode: tyre mud on / off"** (Options > Controls >
Bindings, category Gameplay; no default key), the "Tyre mud" checkbox in the window, or
`deepnode_main.toggleClods()`. The choice is saved with the other GUI settings.

* One skin mesh per wheel, built once per wheel shape; which part shows is decided per
  pixel by its material's alpha clip (coverage order texture: tread first, then
  shoulders, then the sidewalls). A coat above 1 makes the cake thicker.
* Kinds (`clods.kinds`, by the `softMatch` text of the layer): mud sticks and cakes;
  sand has its own fine-grain textures (`tools/tyre_textures/bake_tyresand.py`, shipped as half-size DDS by `tools/dev/tyre_dds.py`): it packs into
  the tread grooves and dusts the sidewalls, never cakes and falls off fast. The colour
  is the kind's `color` (GUI colour pickers), mixed by mass when the kind changes.
* Build-up: per metre rolled in mud (`buildPerMeter` x `stick`), more when deep or
  spinning, saturating. The outer `looseShare` is loose.
* Fall-off: above `flingSpeed` (6 m/s tyre surface speed) the loose layer is flung off
  with a time constant `1 / (flingRate x (speed - flingSpeed))` (about 1 s at 30 mph),
  so a tyre at speed in deep mud keeps a packed tread and sprays the rest as chunks.
  Out of the mud the loose layer drops over the first metres, the packed layer wears
  off over ~500 m (`cleanPerMeter`) and above `flingPackedSpeed` (18 m/s).
* Water: the vehicle reports each tyre's share under water. Water washes the loose layer
  `washLooseFactor` x faster than the packed one. The tyre gets wet: wetness rises to
  the water share and dries over `dryTime` (45 s, faster with speed). A wet coat is
  darker and glossier (`wetRoughness`, `wetDarken`), and every tyre gets a water film:
  a second layer of its skin over the whole tyre with a translucent dark glossy material
  (opacity `filmOpacity` x wetness, roughness `filmRoughness`). BeamNG PBR: lower
  roughness = glossier, so wet means lower roughness. (Swapping the vehicle's own tyre
  material per vehicle is not possible: `switchMaterial` / `setFlexmeshMaterial`
  render it chrome until the vehicle is reset, measured.)
* Chunks: a fixed pool of lumps moved by transform (no mesh uploads while driving).
* Coat bookkeeping runs at `coatHz` (20) per vehicle; the skin follows its wheel every
  frame only while drawn.
* A vehicle reset means clean, dry tyres. "Wash tyres" in the GUI does the same.

### Performance

* Only tiles within `ring.boxMargin` of a vehicle's footprint get full detail. The
  footprint is an oriented box round the vehicle's main body, measured in the vehicle's
  Lua `report.boxHz` times per second from the nodes of the main node cluster (the
  cluster of the reference node). Parts that broke loose form their own cluster and do
  not count, so a wheel lying 20 m away does not stretch the box. Between updates the
  box moves with the vehicle. Copies of the box placed ahead along the vehicle's path
  (`ring.lookaheadTime`, at least `ring.minLookahead`, up to `ring.maxLookaheadPoints`
  boxes) prepare the tiles before the vehicle arrives. Tiles are prepared nearest first
  within a time budget.
* A rutted tile that leaves this ring is frozen: its ruts are kept; it becomes active again
  with its ruts when you come back. Within `ring.frozenOwnMeshRadius` of the camera (at
  most `ring.frozenOwnMeshMax` tiles) it keeps its own mesh; further away its ruts are drawn
  by its 20 m sector mesh. Up to `ring.frozenLimit` frozen tiles are kept (oldest released
  first).
* Every mesh upload (createMesh) costs about 1.3 ms per 700 vertices in game; that, not
  building the mesh in Lua (~0.1 ms), is what limits rebuilds. So:
  * tiles near the camera rebuild first and at `ring.tileRebuildHz`; the rate falls to
    `ring.farRebuildHz` between `camNearDist` and `camFarDist` (AI digging far away shares
    the rebuild cap without slowing your own ruts);
  * a rutted tile draws untouched terrain squares as one quad (`tiles.mergePlain`):
    about 45 % fewer vertices per upload;
  * frozen tiles keeping their own mesh means no sector re-mesh each time a vehicle
    drives on (these re-meshes measured 10-15 ms each with 30 m sectors);
  * sectors are 20 m (`sectors.tiles` = 4), so a sector re-mesh uploads less than half
    of what a 30 m one did.
* Sectors within `sectors.loadRadius` draw frozen ruts and every other mud square, so the
  lowered terrain never shows a hole. Sectors sit 1.5 cm lower than active
  tiles. Sector builds are spread over frames (about 2 ms per frame). A tile's own mesh is
  removed only after the sector that takes over its area has been rebuilt.
* Sector rebuild order: first sectors within `sectors.nearRadius` that must leave out a tile
  that just got its own mesh (else its fresh ruts stay hidden under the sector surface and
  the mud looks flat), then unbuilt sectors nearby, then sectors with pending handovers,
  and only then far sectors entering the load radius. While a nearby sector waits, sector
  builds get `catchUpBudgetMs` per frame.
* All mesh objects come from one pool created at level start; no scene objects are created
  while driving (except the per-wheel mud meshes, created when a vehicle spawns or resets).
* The rest/depth grid a vehicle receives for a tile is built once per tile and shared by
  every vehicle.

### 7-truck stress test (2026-10-27)

Johnson Valley, 7 Percheron 8x8 flatbeds, each on its own 200 m circle at 40 km/h in mud
zones, orbit camera on one truck, 40 s runs. Vanilla (mod off) 97-102 fps, worst second
75-92. Before: 64 fps, worst second 49, rut lag 1.3 s, process commit +180 MB/min. After:
~80 fps, worst second 60-69 (0-1 s below 60 per 40 s), rut lag 0.12-0.13 s (max ~1-2 s),
commit 7-20 MB/min once the caches are full. What did it (every mesh upload costs ~1 ms of
createMesh plus shadow/reflection time, and engine memory per distinct mesh size):

* Uploads are padded to a few fixed sizes (tiles: thirds of the largest tile; sectors:
  powers of two with a fixed vertex/corner ratio). Measured: one size ~0 KB per upload,
  free sizes 20-30 KB per upload and growing.
* `ring.meshRange` (60 m): vehicles further from the camera dig into the data only (no
  tile meshes, no sectors round them, report rate 1/farLod, no chassis dents, no slump).
* Sectors are 2 x 2 tiles; vehicles load sectors only within `sectors.vehLoadRadius`
  (20 m), the camera within `loadRadius`. Sectors leaving the radius are hidden and kept
  (`sectors.cacheMax`, 600): coming back needs no rebuild. Frozen rut tiles keep their own
  mesh while their sector is loaded (hidden with it); only the drawn ones count against
  `ring.frozenOwnMeshMax`.
* Sectors leave out rutted tiles only; an untouched tile with its own mesh is also in its
  sector (same surface 1.5 cm lower), so look-ahead meshes need no sector rebuild. Urgent
  sector rebuilds wait `sectors.urgentBatch` (0.25 s) to take in more fresh ruts.
* Ruts settle at write time (`stamp.instantSettle`): no settling re-meshes. A frozen tile
  becoming active again is not re-meshed until a tyre writes into it. A neighbour's mesh
  change only re-meshes a tile after `ring.borderRebuildGap` (5 s).
* Tyre stamps are one analytic sweep per report (each cell carved once at the point the
  tyre passes over it) instead of a full footprint every 15 cm; slump walks tiles directly.
* Per-frame passes walk the active / own-mesh tile sets, the ring runs at 20 Hz, mud
  bounds at 2 Hz; tyre mud of trucks beyond `clods.drawDist` updates every 4th frame.
* Tiles rebuild at most 5 times per second (`ring.tileRebuildHz`): A/B against 6, 81 vs 77
  fps and worst second 69 vs 58 at the same rut lag (0.13 s).
* The governor shrinks the upload budget below `perf.targetFps` (70, at most 88 % of the
  best second seen) down to `uploadMsMin` (0.6 ms): fewer dips when two trucks dig near
  the camera.

### Engine memory and mesh rebuilds

Measured in game (0.39.4): every time a ProceduralMesh that has been drawn gets new geometry,
the engine keeps some memory that is only given back when the game closes (not by a mod
restart, a level reload or deleting the objects). Re-measured with four trucks digging
(30 s A/B runs, process commit): ~50-80 KB per upload when each upload goes to a fresh
object from the shared pool (`pool.mode = 'swap'`), ~13 KB or less when each chunk
alternates between its own two objects (`'pair'`, default; same no-flicker swap). So the
mod keeps mesh replaces low:

* a tile is only rebuilt when a vertex really changes; a wheel that stands still and does
  not spin does not stamp;
* untouched mud farther than `ring.ownMeshRadius` (3 m) from a vehicle's footprint or its
  look-ahead boxes has no tile mesh of its own: the sector draws it. Closer tiles get their
  mesh before the wheels arrive, so fresh ruts are never hidden under the sector;
* fresh ruts are written at their settled depth (`stamp.instantSettle`); with it off they
  settle for at most `stamp.relaxWindow` (0.3 s) after the last tyre contact, then snap;
* tiles rebuild at most `ring.tileRebuildHz` (12) times per second, one sector at most once
  per `sectors.minRebuildGap` (1 s), and left-behind ruts are drawn on a 40 cm grid
  (`sectors.frozenCellStride`);
* `ring.maxMeshBuildsPerSec` (40, "Chunk rebuilds per second" in the GUI) caps all tile
  and sector replaces per second; the nearest tiles go first, the rest wait;
* rut tiles nobody dug or drove near for `reset.idleSeconds` (60 s) are released.

Four trucks digging non-stop at 40 replaces per second: well under 1 MB per second of
process memory with 'pair' (2-2.5 MB/s with 'swap'). Idling costs nothing. The Debug tab
shows the growth since the mod started and per upload.

**This memory cannot be freed while the game runs.** Measured in game: a full Lua GC freed
24 MB of Lua heap and deleting 93 hidden pooled mesh objects freed their meshes, and the
process commit did not change at all; the engine and the Lua allocator keep freed memory
for their own reuse until the game closes. BeamNG sandboxes the FFI (`ffi.load` denied, no
new `ffi.cdef`), so a mod cannot call the Windows working-set functions either. The only
lever is to upload less (the limits above, 'pair' mode). "Lua cleanup" in the Debug tab
(console `deepnode_main.flushMemory()`) runs a full Lua GC in the game engine and every
vehicle VM and drops the mod's caches (hidden tyre meshes, landed lumps, debug outlines);
it keeps the Lua heap from swelling but does not shrink the process. `memory.gcStepKB`
adds a small Lua GC step every frame.
* A submesh never holds more than 60 000 triangle corners: the engine counts corners with a
  16-bit number and hangs forever above 65 535.

### Camera

The mud surface has no collision mesh. While the mod runs, the game's static ray cast is
wrapped so the camera and other ray users also see the mud surface for rays up to
`camera.maxDist` metres. All arguments and results pass through unchanged otherwise.

### Shadows

Screen-space shadows are switched off while the mod runs and restored on Stop (any visible
mesh casts them and rebuilding meshes makes them flash). The GUI can keep them on.

## GUI

Three tabs:

* **Mud** (everyday): turn on/off, Smooth all ruts, Wash tyres, Mud sticks to tyres,
  Detail margin round vehicles, Old ruts fade after, and Mud zones (add a round patch
  where you are, remove all).
* **Settings**: vehicles with full mud, chunk rebuilds per second, terrain UV flip,
  screen-space shadows off.
* **Debug**:
  * Performance: mod time per frame (avg, last, max), game fps, the cost of each part
    (last, max over 5 s, peak; colour-coded), chunk mesh rebuilds per second against the cap.
  * Memory: system RAM bar, game process RAM, GPU memory against the driver's budget, GE
    Lua heap, the mod's own share (tile data, terrain maps, mesh geometry, pooled mesh
    objects), process growth since the mod started and per mesh upload, "Lua cleanup"
    with its result, and "Steady GC".
  * Chunks: "Show chunk borders" draws the borders on the mud: blue = active tile with
    its own mesh, pale blue = active tile drawn by its sector, red = inactive (frozen) rut
    tile, cyan = near sector, orange = far sector, yellow = sector building or waiting,
    white box = a vehicle's footprint (grey: look-ahead boxes, dashed: plus the margin).
    Plus tile and sector counts, build times, waits.
  * Vehicles: per vehicle LOD, state (MUD / body / near / off), wheels and chassis nodes
    in mud, mud tiles held, footprint box size, footprint nodes read, vehicle Lua memory.
  * Tyre mud: wheels (dual, active, visible, in water), coat, lumps on tyres / flying /
    landed, and kind + coat per wheel.
  * Level: decal roads drawn over the mud / waiting / left as they are, groundcovers
    lifted, layer map check, level start timings, stamps, camera rays.

## Console (GE Lua)

| Command | Effect |
|---|---|
| `deepnode_main.stats()` | Table with all status values and timings |
| `deepnode_main.setFlipV(true/false)` | Flip the terrain texture V (no argument = toggle) |
| `deepnode_main.cleanWheels()` | Remove all mud from the tyres |
| `deepnode_main.reloadLevelData()` | Restore everything and start again from the level files |
| `deepnode_main.gui.toggle()` | Show/hide the window (also `deepnode_gui.toggle()`) |
| `deepnode_main.start()` / `stop()` / `toggle()` | Start or stop the mod |
| `deepnode_main.setBoxMargin(m)` | Active tiles within this many metres of a footprint box |
| `deepnode_main.clearRuts()` | Flatten all ruts |
| `deepnode_main.setDebugChunks(true/false)` | Chunk border overlay |
| `deepnode_main.setMaxVehicles(n)` | Vehicles with full-rate mud |
| `deepnode_main.setMeshBuildsPerSec(n)` | Cap on chunk mesh rebuilds per second |
| `deepnode_main.setClodsEnabled(true/false)` | Mud on tyres on/off |
| `deepnode_main.toggleClods()` | Mud on tyres on/off, with an on-screen message, saved to gui.json |
| `deepnode_main.rutLag(reset)` | Rut lag readout: time from a visible rut change to its mesh (near / far camera), lost writes |
| `deepnode_main.gui.selectTab('Debug')` | Open the window on a tab |
| `deepnode_main.flushMemory()` | Lua cleanup (see Engine memory) |

## Configuration

Every tunable value lives in `settings/deepnode/config.json`. To change values, copy that
file to `%LOCALAPPDATA%/BeamNG/BeamNG.drive/current/settings/deepnode/config.json` and edit
the copy (it overrides the one in the zip). The file is merged over the built-in defaults:
nested tables merge, lists replace. Changes apply on the next start (Stop/Start in the GUI).
Lengths are metres, speeds m/s, times seconds.

### General

| Key | Default | Meaning |
|---|---|---|
| `autoStart` | true | Start automatically when a level loads |
| `softMatch` | ["mud","sand"] | Texts that make a layer soft (layer name or ground model name) |

### layers

| Key | Default | Meaning |
|---|---|---|
| `defaultSinkDepth` | 0.3 | Sink depth of a soft layer with no specific entry |
| `sinkDepthByMatch` | mud 0.35, sand 0.2 | Sink depth by text found in the layer name; first match wins |
| `featherVerts` | 4 | Width of the depth fade in terrain vertices |
| `edgeDip` | 0.04 | How far the patch dips under the terrain where the depth is 0 |

### roads

| Key | Default | Effect |
|---|---|---|
| `enabled` | true | Keep terrain under hard decal roads free of mud |
| `margin` | 0.5 | Extra width (m) kept free of mud on each side of a road |
| `skipMatch` | `["invisible", "dirt"]` | Roads with a material containing one of these texts (or a `softMatch` text) are not carved |
| `mode` | `"off"` | Decal roads on the mud: `overlay` (shown, drawn into the mud meshes, experimental), `drape` (engine decals laid once), `off` (no decal road on soft ground) |
| `hideOnMud` | true | Mode `off`: hide every decal road that touches soft ground (false: leave them, heavy mode then shows them on undug mud) |
| `overlayAlphaRef` | 110 | Alpha clip of the overlay materials (0 = translucent: slow) |
| `overlayLift` / `overlayLiftStep` | 0.008 / 0.001 | m over the mud; one step per renderPriority level (stack kept under `sectors.drop`) |
| `overlayRoughness` | 0.85 | Fixed roughness of the overlay materials (-1 = the road's own maps) |
| `overlayRoughnessByMatch` | furrows 1, tiretracks 1 | Per material text |
| `overlaySkipMatch` | `["water"]` | Decals left out of the overlay |
| `overSkipMatch` | `["invisible"]` | Roads never drawn over the mud |

### grass

| Key | Default | Meaning |
|---|---|---|
| `lift` | true | Lift groundcover on soft layers onto the mud surface (see Groundcover) |

### tiles

| Key | Default | Meaning |
|---|---|---|
| `targetSize` | 5 | Tile size; rounded to whole terrain squares |
| `cellSize` | 0.2 | Cell size; each terrain square is split into a whole number of cells |
| `mergePlain` | true | Rutted tiles draw untouched terrain squares as one quad |

### ring

| Key | Default | Meaning |
|---|---|---|
| `boxMargin` | 3 | Tiles within this distance of a vehicle's footprint box are active (GUI slider) |
| `releaseMargin` | 4 | Extra distance before a tile leaves the ring (no flip-flopping) |
| `lookaheadTime` | 2.0 | Tiles are prepared where the vehicle will be in this time |
| `minLookahead` | 10 | Look ahead at least this far (m) whenever the vehicle moves faster than 1 m/s |
| `prebuildReserve` | 8 | Mesh tokens kept for tiles being dug; look-ahead meshes only use tokens above this |
| `maxLookaheadPoints` | 6 | Footprint boxes placed along the look-ahead path at most (spaced so they touch) |
| `prepBudgetMs` | 2 | Time per frame for preparing tile data |
| `maxPreparePerUpdate` | 8 | Tiles prepared per frame at most |
| `meshBudgetMs` | 2 | Time per frame for tile mesh rebuilds |
| `tileRebuildHz` | 5 | One tile rebuilds at most this often (6: +27 % uploads, -4 fps, same rut lag in the test) |
| `meshRange` | 60 | Vehicles further from the camera dig without meshes |
| `settleRebuildHz` | 2 | Rebuild rate of a tile no tyre touched for 0.3 s |
| `bodyMaxWait` / `bodyHideMargin` | 0.6 / 0.5 | New ruts all under a vehicle body (box + margin) wait up to this long |
| `bigChange` / `smallChangeWait` | 0.02 / 0.4 | Rut changes below 2 cm wait up to 0.4 s |
| `borderRebuildGap` | 5 | A tile whose only change is a neighbour's mesh waits this long |
| `minVisibleChange` | 0.006 | A tile re-upload whose largest height change against the mesh on screen is below this (m) is skipped (data keeps the change) |
| `inViewTarget` / `outViewTarget` | 0.3 / 1.5 | Target latency (s) of a waiting rebuild in / out of the camera view: the queue serves the earliest deadline first after fresh rut fronts |
| `outViewMaxDefer` | 4 | Deepening of a meshed tile out of view waits until it comes into view, at most this long (s) |
| `ownMeshRadius` | 3 | Untouched tiles this close to a footprint box get their own mesh ahead of the wheels |
| `maxMeshBuildsPerSec` | 40 | Tile + sector mesh replaces per second at most (caps engine memory growth) |
| `farLod` | 3 | Vehicles without an active ring report at 1/farLod rate |
| `meshBuildBurst` | 24 | Replaces that may happen at once after a quiet moment |
| `maxTileBuildsPerFrame` | 2 | Tile mesh rebuilds per frame at most (one costs up to ~3 ms in game) |
| `maxVehicles` | 8 | Vehicles (nearest to the camera) that get an active ring: they dig ruts and feel the mud |
| `vehicleRange` | 400 | Vehicles further from the camera are ignored |
| `frozenLimit` | 1500 | Frozen rutted tiles kept (oldest released first) |
| `frozenOwnMeshRadius` | 100 | Frozen tiles this close to the camera keep their own mesh (while their sector is loaded) |
| `frozenOwnMeshMax` | 150 | At most this many drawn frozen tiles keep their own mesh |
| `camNearDist` / `camFarDist` | 30 / 60 | Tile rebuild rate falls from `tileRebuildHz` to `farRebuildHz` between these camera distances |
| `farRebuildHz` | 3 | Rebuild rate of tiles far from the camera |
| `streamInterval` | 0.2 | Seconds between tile data updates to the vehicles |
| `maxTilesPerStream` | 12 | Tiles sent to one vehicle per update at most |

### sectors

| Key | Default | Meaning |
|---|---|---|
| `tiles` | 2 | Sector size in tiles (2 x 2) |
| `loadRadius` | 50 | Sectors are loaded within this distance of the camera |
| `vehLoadRadius` | 20 | ... and within this distance of the vehicles and their look-ahead boxes |
| `cacheMax` | 600 | Sectors kept hidden after leaving the radius |
| `urgentBatch` | 0.25 | Seconds an urgent sector rebuild waits to take in more fresh ruts |
| `unloadMargin` | 40 | Extra distance before a sector is unloaded |
| `buildBudgetMs` | 2 | Time per frame for sector builds |
| `syncRadius` | 90 | Sectors built at once at level start |
| `catchUpBudgetMs` | 5 | Time per frame while an unbuilt sector near a vehicle waits |
| `nearRadius` | 40 | Sectors this close to a footprint or look-ahead box centre rebuild first |
| `drop` | 0.015 | Sectors sit this much lower than active tiles |
| `refreshInterval` | 0.25 | Seconds between sector load checks |
| `minRebuildGap` | 4 | Seconds between rebuilds of one sector |
| `frozenCellStride` | 2 | Left-behind ruts drawn every 2nd cell (40 cm) |

### stamp

| Key | Default | Meaning |
|---|---|---|
| `flowBack` | 0.22 | Share of a fresh rut that flows straight back |
| `bermFraction` | 0.4 | Share of displaced mud that ends in the berms |
| `bermWidthFactor` | 0.6 | Berm width as a share of the tyre width |
| `bermMax` | 0.1 | Highest berm above the undisturbed surface |
| `rimCells` | 1 | Width of the soft rim beside the tyre, in cells |
| `rimDepth` | 0.45 | How far the rim sags towards the tyre edge (0..1) |
| `maxSlope` | 1.2 | Steepest wall the mud holds (rise over run; 1.2 is about 50°) |
| `slumpRate` | 0.35 | Share of the too-steep part removed per pass |
| `slumpPasses` | 1 | Slope passes over each stamped area |
| `relaxHz` | 5 | Settling updates per second |
| `relaxTime` | 3 | Seconds for fresh ruts to settle most of the way |
| `instantSettle` | true | Ruts written at their settled depth (no settling pass, no extra re-meshes) |
| `relaxWindow` | 0.3 | Seconds after the last stamp; settling then snaps to its end shape (instantSettle off) |
| `spinDigRate` | 0.012 | Visual only: dig per (m/s of wheel spin x s) under a spinning wheel |
| `spinDigMax` | 0.12 | Visual only: deepest spin hole below the tyre at `refWheelLoad` |
| `refWheelLoad` | 3500 | Wheel load (N) the dig numbers are tuned for; heavier digs more |
| `relaxKeep` | 0.75 | Share of the deepest rut that stays after settling |
| `relaxKeepBerm` | 0.8 | Share of the highest berm that stays after settling |
| `shoulderFactor` | 0.25 | Tyre shoulder radius as a share of the tyre width |
| `maxSweep` | 3 | Longer jumps between two reports are treated as a teleport |
| `bodyRadius` | 0.16 | Radius of a chassis dent |
| `bodySkin` | 0.03 | Dent bottom below the chassis node |
| `bodyBermWidth` | 0.12 | Width of the ring around a dent |
| `bodyBermFraction` | 0.3 | Share of dent mud that ends in the ring |
| `trackBase` | 0.25 | Roughness of any rut |
| `trackSpinGain` | 0.08 | Extra roughness per m/s of wheel spin |
| `trackDepthGain` | 2.0 | Extra roughness per metre of depth |
| `jitterZ` | 0.015 | Height jitter of the roughest ruts |
| `jitterXY` | 0.03 | Sideways jitter of the roughest ruts |
| `kinds.<kind>.bermFraction` | mud 0.35, sand 0.5 | Berm share per ground kind (kind of the terrain square under the hub) |
| `kinds.<kind>.bermDepthRef` | sand 0.1 | > 0: berm share x clamp(immersion / bermDepthRef, 0.4, 1.6) (sand berms grow with deep ruts) |
| `kinds.<kind>.maxSlope` | mud 1.6, sand 0.7 | Steepest wall per kind (about 58° / 35°) |
| `kinds.<kind>.soilN` | mud 0.5, sand 1.1 | Bekker sinkage exponent n for the soil memory |
| `kinds.<kind>.soften` | mud 0.1, sand 0 | Allowed depth x (1 + soften x (passes - 1)): mud softens with passes |
| `kinds.<kind>.slipBeta` | mud 0.2, sand 1.0 | Slip sinkage: the stamp's hub is lowered by beta x s / (s + 0.2) x immersion (s = slip ratio) |
| `kinds.<kind>.spinDig` | mud 0.8, sand 1.4 | Factor on `spinDigRate` / `spinDigMax` |
| `soil.enabled` | true | Soil memory: pass N carves at most z1 x N^(2/(2n+1)) deep (z1 = first pass depth) |
| `soil.passGap` | 0.6 | The same wheel over a cell again after this many seconds is a new pass |

### report

| Key | Default | Meaning |
|---|---|---|
| `rateHz` | 15 | Wheel and chassis reports per second (vehicles within 40 m of the camera; further: half, beyond meshRange 1/farLod) |
| `maxBodyNodes` | 48 | Chassis nodes reported for dents at most |
| `waterHz` | 5 | Tyre-in-water checks per second |
| `boxHz` | 10 | Footprint box updates per second (sent only when the box moved) |
| `candidateHz` | 10 | How often chassis nodes near the mud are looked up |
| `candidateMargin` | 0.15 | Chassis nodes this far above the mud surface are watched |
| `maxCandidates` | 48 | Chassis nodes watched at most (the deepest win) |

### dually

| Key | Default | Meaning |
|---|---|---|
| `enabled` | true | Detect dual wheels |
| `autoRatio` | 1.05 | Without tyre meshes: a wheel wider than this x its radius is a dual |
| `gap` | 0.04 | Gap between the two tyres of such a wheel |
| `ridge` | 0.6 | Mud ridge between the tyres, as a share of the tyre shoulder radius |

### clods

| Key | Default | Meaning |
|---|---|---|
| `enabled` | true | Mud on tyres |
| `texDir`, `texBase` | decal-road mud set | Mud texture where a layer has no texture of its own |
| `coatMax` | 3.0 | Highest coat; 0..1 sets how much of the tyre is covered, 1..coatMax how thick |
| `buildPerMeter` | 0.01 | Coat picked up per metre the tread rolls through mud (Percheron at 18 km/h: coverage ~0.6 after 7 s) |
| `buildSpinGain` | 0.5 | Extra pick-up per m/s of wheel spin (at most x3) |
| `looseShare` | 0.55 | Share of the coat that is loose while in mud |
| `looseShedPerMeter` | 0.1 | Loose coat lost per metre after leaving the mud |
| `packTime` | 6 | Seconds for the loose layer to pack down after leaving the mud |
| `cleanDelay` | 1.0 | Time out of the mud before the tyre starts to clean |
| `cleanPerMeter` | 0.02 | Packed coat lost per metre (times the coat below 1) |
| `lookDelay` / `lookFade` | 1.0 / 1.0 | Drawn colour and kind hold this long after the wheel's state (mud / sand / off the soft ground) changed, then blend over `lookFade` s; the texture set changes half way |
| `coverUpRate` / `coverDownRate` | 0.5 / 1.0 | Drawn coverage follows the coat's at most this much per s (no jump when mud and sand cover differently) |
| `colorFlushGap` | 0.1 | At most one colour step per wheel in this time during a blend |
| `flushGap` | 0.25 | Per wheel at most one coverage update in this time (near the camera; 3x further away) |
| `flingSpeed` | 9.0 | Tyre surface speed above which mud flies off |
| `flingRate` | 0.08 | Coat lost per second per m/s above that speed |
| `washRate` | 0.6 | Coat washed off per second with the tyre fully in water |
| `washSpeedGain` | 0.25 | Extra wash per m/s of tyre surface speed |
| `surfaceOffset` | 0.04 | Visual tyre surface outside the tread nodes, share of the radius |
| `shell.segments` | 36 | Steps round the tyre |
| `shell.noiseScale` | 0.14 | Size of the mud blotches (m) |
| `shell.contrast` | 1.6 | Blotch sharpness |
| `shell.thickness` / `thicknessMax` | 0.012 / 0.035 | Cake thickness at coat 1 / at `coatMax` (m) |
| `shell.taper` | 0.08 | Mask range over which a patch edge thins into the tyre |
| `shell.treadBias` / `shoulderBias` / `sideBias` / `rimBias` | -0.18 / -0.06 / 0.12 / 0.3 | Order in which the parts of the tyre get mud (lower first) |
| `shell.rimClear` | 0.02 | Clean sidewall next to the rim (m) |
| `shell.widthScale` | 1.12 | Visible / jbeam tyre width when the tyre mesh name gives none |
| `shell.coverStart` / `coverGain` / `coverExp` | -0.15 / 0.9 / 0.75 | Mask threshold = start + gain x coat^exp |
| `shell.stepNear` / `stepFar` | 0.04 / 0.12 | Mask threshold step per rebuild near / far from the camera |
| `roughShape` | 0.6 | Flying / landed lump shape irregularity |
| `lodNearDist` / `lodFarDist` | 20 / 50 | Tyres further from the camera rebuild at 0.4 x `rebuildHz` and in coarser steps |
| `rebuildHz` | 3 | Skin mesh updates per second per tyre at most |
| `rebuildsPerFrame` | 1 | Tyre skins rebuilt per frame over all vehicles |
| `maxSharedUploads` | 2 | A skin waits for a frame in which the chunks uploaded fewer meshes than this |
| `drawDist` | 150 | Tyres further from the camera hide their mud and skip updates |
| `maxFlying` | 32 | Flying lumps at most |
| `maxFlyPerWheel` | 6 | Lumps one wheel throws per update at most |
| `maxLanded` | 120 | Lumps on the ground at most |
| `landedLife` | 15 | Seconds a lump stays on the ground |
| `landedSinkTime` | 0 | Landed lumps sink into the ground over their last seconds (each step is a mesh redraw; 0 = off) |
| `stayChance` | 0.6 | Chance that a landing lump stays |
| `kick` | 1.2 | Outward speed of a lump leaving the tyre |
| `flyingHz` | 10 | Flying lump mesh updates per second |
| `removeDist` | 120 | Lumps further than this from every vehicle are removed |
| `darken`, `roughness` | 0.5, 0.35 | Generic mud colour and roughness (when `kinds.mud` gives none) |
| `kinds.<kind>` | mud, sand | Per ground kind: `stick` (pick-up factor), `coatMax` (1 = no thick cake), `shed` (loose/clean/fling factor), `wet` (colour factor on the layer texture), `roughness`, `size` (cake thickness factor), `color` (generic texture colour) |
| `kinds.<kind>.thickness` | sand 0.003 | Skin thickness of that kind (default `clods.thickness`); a kind with its own `texO` gets an even skin |
| `kinds.<kind>.treadInset` | sand 0.010 | Skin this far below the tread surface (x outward share of the normal): the tyre's lugs show through, sand stays in the grooves |
| `kinds.<kind>.coverMax` | sand 0.62 | Covered share at coat 1 (default `clods.coverMax`) |
| `kinds.<kind>.groundGain` | sand 1.3 | Factor on the ground colour (default: the kind's `wet`) |
| `kinds.<kind>.groundDesat` | sand 0.3 | Move the ground colour towards grey (0..1) |
| `groundColor` | true | Tyre coat takes the terrain colour under the wheel (base map + macro/detail mean, / tyre texture mean); `color`, `brightness`, `tyreBrightness` only where it is unknown |
| `groundGrid` | 128 | Cells a side of the base-map colour grid read at start |
| `kinds.mud.texN` / `groundGain` | t_tyremud_nm, 2.0 | Procedural mud normal map; drying mud on a tyre is lighter than the wet ground |
| `filmMud` | 0.5 | Water film colour = ground colour of the wheel's last soft ground x this (`filmColor` grey where unknown) |
| `filmOpacity` | 0.4 | Water film opacity at full wetness (x the streak texture `t_tyrefilm_o`) |

### camera, materials, render, pool, gui

| Key | Default | Meaning |
|---|---|---|
| `camera.enabled` | true | Rays see the mud surface |
| `camera.maxDist` | 60 | Only rays up to this length are checked |
| `camera.step` | 0.25 | Step of the ray march |
| `camera.maxIter` | 300 | Steps per ray at most |
| `materials.flipV` | true | Flip the terrain texture V (GUI toggle; check on each level) |
| `materials.useDetail` | true | Use the layer's detail texture |
| `materials.detailStrength` | 1.0 | Scale of the detail texture strength |
| `materials.defaultDetailSize` | 2 | Detail texture size (m) when the terrain material gives none |
| `materials.srgbMethod` | "copy" | "off" (use the map as the terrain does), "copy" (falls back to a link file), or "link" |
| `materials.tint` | [1, 1, 1] | Colour factor on the patch, to match the terrain's brightness |
| `materials.roughness` | -1 | 0..1 fixed patch roughness; -1 uses the terrain's roughness map (spinMud) |
| `materials.baseSizeFrom` | "layer" | "layer": base UVs span the layer's baseColorBaseTexSize, detail-only layers tile their detail texture (spinMud); "terrain": base UVs span the whole terrain |
| `materials.defaultDetailStrength` | 0.5 | Detail strength when the layer gives none |
| `materials.defaultNormalDetailStrength` | 0.8 | Detail normal strength when the layer gives none |
| `materials.fallbackTexSize` | 4 | Metres per repeat of the fallback material |
| `reset.idleSeconds` | 60 | Release a rut chunk (tile outside every vehicle's active ring) nobody has dug or driven near for this many seconds (game time); its ruts go back to the untouched surface. 0 = off. GUI slider too |
| `render.disableSSS` | true | Screen-space shadows off while running |
| `pool.initial` | 200 | Smallest number of pooled mesh objects (more are made when the map needs them) |
| `pool.growStep` | 16 | Objects added if the pool ever runs out (logged) |
| `pool.hideFrames` | 3 | Frames a replaced mesh stays visible next to its replacement (1 flickered) |
| `pool.tileClasses` | 6 | Tile meshes are padded to k/tileClasses of the largest tile (fewer classes: less engine memory per upload, more createMesh time) |
| `pool.decalMinCorners` | 96 | Smallest size class of decal overlay submeshes (doubling classes from here) |
| `pool.mode` | pair | 'pair': each chunk alternates between two objects of its own (no flicker, least engine memory); 'swap': a fresh pooled object per upload |
| `memory.gcStepKB` | 0 | >0: a Lua GC step of this size every frame (GUI: Steady GC) |
| `gui.openOnStart` | true | Open the window when the mod starts |
| `debug.chunks` | false | Chunk border overlay (GUI checkbox; kept over mod restarts) |
| `debug.drawRadius` | 120 | Tiles within this distance of the camera are outlined (sectors within twice it) |
| `debug.lift` | 0.12 | Overlay lines float this high over the mud |

## Safeguards

* **Terrain heights.** Terrain heights cannot go below the terrain origin; lowering below it
  would wrap round to the top and build walls. Every lowered vertex is clamped at the
  origin and the missing depth is remembered; the mud is still drawn at the original
  height and the terrain is restored exactly. The mod checks whether the engine reports
  heights relative to the terrain or in world space.
* **Broken vehicles.** A vehicle that breaks apart can report invalid node positions; using
  them for meshes or transforms can crash the game. Every value is checked before it is
  used for a mesh, a transform, a wheel report, a footprint box, the
  view centre or a ray. A broken wheel's lumps are hidden and its coat is reset. A
  footprint longer or wider than 120 m is never used.
* **Endless loops.** Distances, origins and directions are checked first, and every loop is
  limited by a step count as well as by distance.
* **Messages between game engine and vehicle.** Wheels are identified by their order in a
  list, never by table iteration order. Wheel definitions are sent again after every
  reset.
* **Flashing.** Mod materials do not cast shadows, screen-space shadows are off while
  running, and meshes are swapped without a gap.
* **First-visit stalls.** Every material is created and used once at level start.
* **Patch colour.** BeamNG's terrain shader reads the base colour map as linear data, so
  the patch uses the original file too (`materials.srgbMethod = "off"`). In-game
  measurement on hw550: an sRGB copy came out much darker and yellower than the terrain.
  For levels that need it, `"copy"` writes a `.color.` copy to `/temp/deepnode/<level>/`
  (file copy, then byte copy, then a small BeamNG link file); the log says which worked.
  The terrain's roughness map looks glossy on an object material, so the patch uses a
  fixed matte roughness (`materials.roughness`), and `materials.tint` matches brightness.
* **Seams.** Tile edges lift only when the neighbouring area is drawn; next to a sector
  they drop by the sector offset so both surfaces meet.
* **Hitches.** Small active ring, time budgets everywhere, sector builds spread over
  frames, submeshes split below 60k vertices, pre-created mesh pool.
* **Z-fighting.** Sectors sit lower than active tiles.
* **Recycled objects.** Pooled meshes are reset to an identity transform when recycled;
  the rotating tyre meshes use their own objects.
* **Ray users.** The ray wrapper returns at once for bad input or rays far from mud, passes
  every argument and extra result through, never changes rays longer than
  `camera.maxDist`, and is removed on Stop only if nothing wrapped it afterwards.
* **Frame rate.** Every build-up and decay is scaled by the frame time.
* **Lua reload and editor.** A GE Lua reload or opening the world editor restores the
  terrain, the decal roads and the groundcover first, so none of the changes can be
  saved; the mud comes back afterwards.

## Notes for testing in game

* Check once on a mud level that the patch is visible from above (face winding) and that
  the terrain texture lines up; if it is mirrored, use "Terrain UV flip".
* `beamng.log` lines tagged `deepnode` report the layer map check, the height frame, the
  sink pass and any slow call (over 20 ms).


## Sector auto size (2026-10-27)

- `sectors.autoSize` (true): choose the sector size at start from the map's meshed soft area (soft kinds whose heavy floor lift is below their sink depth, plus zones in vanilla mode), so that a camera in the biggest region sees at most `sectors.autoMaxObjects` (200) sectors within `sectors.loadRadius`. Clamped between `sectors.tiles` (minimum, GUI "Sector size") and `sectors.autoMaxTiles` (8). The choice is logged (`sector size: ...`).
