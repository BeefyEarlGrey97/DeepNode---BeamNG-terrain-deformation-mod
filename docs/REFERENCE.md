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
  texts in `softMatch` (default `mud`, `sand`, `snow`). The kind (mud, sand, snow) is that text.
* Run tab "Deformable ground": one tick box per ground model of the level
  (`deepnode_materials`, test `tests/materials_test.lua`). Hard ground is not listed: a word
  of the ground model or layer name is asphalt, concrete, rock(s), cliff, ice, cobble(stone),
  slippery, metal, wood, ... (words are letter runs: DIRT_ROCKY is listed). Every session
  starts from the `softMatch` defaults; ticks are not saved and apply on Restart. A ground
  model ticked beyond the defaults gets its kind from its name (SNOW -> snow, SAND -> sand,
  MUD -> mud, else firm: 0.08 m prints, 0.06 m heavy soft layer, no tyre coat), the sink
  depth of that kind; in heavy mode its kind's soft layer values and
  terrain floor, but not the friction keys (the level's grip stays; physics test
  `tests/physics_test.lua`).
* Snow (kind `snow`): sink 0.2 m, small berms and steep walls (`stamp.kinds.snow`), white
  tyre coat that packs into the tread (`clods.kinds.snow`, sand order map), dry print look,
  no stains carried onto hard ground. Heavy physics uses polish_roads_winter's SNOW_DEEP
  values for snow ground models. Vanilla levels with snow: automation_test_track only
  (`snow` layer; its `ice` layer on ground model SNOW stays hard).
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
* You can add your own mud zones (circles) with the GUI button "Add zone here" (Debug tab, Zones section). Zones
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
road"** (`roads.mode`, default `shader` since 2026-11-08, switches live and is saved):

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

Road shader (`roads.mode = "shader"`, GUI "Decal roads on mud: shader", 2026-11-08): the decal
roads over soft ground are hidden as in mode off and drawn again by post effects
(`deepnode_overlay`, `overlay.roads`, shaders `roadStampP` / `roadLitP` / `roadDrawP.hlsl`). At
start they are cut into quads (left / right edge points of neighbouring spline samples, as the
engine's strip) and painted into a world-space road map around the camera (`#deepnode_road`,
`layers` entries per texel; each entry holds the road key, u and v at the texel centre and their
world gradients, so a pixel extrapolates exact u, v with smooth texture derivatives). Every
(renderPriority, material) key gets two passes in the engine's draw order (lower numbers on top):
a colour pass (colour, opacity, AO maps) blended over the scene and a relight pass (normal map)
that multiplies the scene by the light of the normal blended towards the road's, as the
engine's G-buffer blend relights the ground under a decal. Light is the engine's own: the
diffuse light buffer `#lightinfo` and screen AO `#gtaoOutput` (packed once a frame into
`#deepnode_roadLit`) and the sky SH9 (`ambientSH9`, set by the engine for every post effect).
So any number of roads may overlap, and the road lies in the ruts, on the berms and on undug
ground alike; tyre prints draw over it. Only surfaces from `zBelow` under to `zAbove` over the
road's own height take it, not vehicles (footprint boxes). The light is packed at `PFXBeforeBin
ReflectDepthBin` (the light buffer reads 0 by `ObjTranslucentBin`); the map and road passes run
at `PFXBeforeBin ObjTranslucentBin` before the rut overlay, so tyre prints, glass and particles
draw over the roads.

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
* Rut floor (mud, and sand since 2026-10-31): under undisturbed ground the hard floor stays `floorLift` (0.3 m) above the
  full sink. Where ruts are dug, the terrain under them is lowered to the rut surface,
  so rut walls are real terrain. Terrain squares are 0.75-1 m, so the walls are coarse
  and gentle: they hold a light steering input for a while and can be climbed. Terrain
  comes back up only when the ruts reset and no vehicle is within 8 m.
  Cost: one terrain update per frame at most (1-3 ms, measured), inside the upload budget.
  Grass: every terrain update makes the engine rebuild the groundcover cells over its box, so
  that grass is missing for a frame. The writes are grouped in clusters of `floorCluster`
  (16) squares; one update takes every cluster whose joint box stays `grassReach` (24 m,
  rounded up to whole clusters) clear of terrain layers that carry groundcover, and a cluster
  near grass is written on its own (with its neighbours near grass) at most every `grassHold`
  (1 s). Measured on the gridmap_v2 material ramp (HT-55 up its mud strip, grass 12-16 m
  away): terrain updates near the grass 58 -> 18 per run (~4/s -> 1/s), all updates 62 -> 25.
  Since 2026-11-02 (`grassSplit`, default on): `tb:updateGrid` refreshes the physics terrain
  everywhere whatever its box, but redraws terrain and grass only inside it. Clusters near grass
  are therefore written at once with a far 1 x 1 dummy box (vehicles sink without the old
  `grassHold` delay, no grass touched); their real box (terrain drawn lower, the rut showing)
  follows once the groundcover cells over it are out of the camera's view or `grassHold` s
  passed, neighbouring waiting clusters in the same update (one blink). `grassViewRange` (160 m):
  cells farther from the camera count as out of view. gridmap_v2, lc300 circling 9-15 m from the
  grass meadow for 30 s: visible grass blinks 22 -> 11 (camera on the grass) and 27 -> 12 (chase
  camera); physics near grass was held 540-640 frames before, now 0.
  A group forces its redraw (after `grassHold`) only once a vertex sits lower than drawn by more
  than `grassRedrawShare` (0.7) x `floorMargin`: the rut mesh lies `floorMargin` over the floor,
  so a smaller drop or a raise leaves the stale terrain under the mesh; those wait for the camera
  to look away. Without any redraw the stale terrain covers fresh ruts in flat patches (checked).
  Since 2026-11-05 (`grassLowDraw`, default on): at start the sink pass draws the terrain under
  interior soft vertices of every cluster near grass at the full sink level, then writes their
  floor heights back for physics only (dummy box). Those squares are never flush (the mud mesh
  draws them, with decal road copies) and their floor writes are physics only for good: no
  redraw, so the grass beside them never blinks. gridmap_v2, one 2-Percheron run: terrain
  redraws near grass 10 -> 0 (262 physics-only writes), fps in the noise (127.7 / 131.3 off /
  138.9, BENCHMARK 13). Region mode and coarse terrains skip it.
  `lowDrawRuts` (default on, 2026-11-08; `lowDrawAll` off): a vertex is drawn low once the first
  rut reaches it (`lowDrawAll` did that for every soft cluster), so the floor is physics only there and sits `floorSoftShare` (1) x the kind's ground-model `defaultDepth`
  ABOVE the drawn rut (minus `floorMargin`): a tyre sinks the soft layer and rests on the drawn rut
  bottom. `floorGap` (0.6 s): floor writes at least this far apart, because the vehicle physics
  takes a terrain change only ~0.55 s after the last `updateGrid` (ENGINE_FINDINGS).
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
* Big terrains (`slowUpdateMs` 8, `slowUpdateGap` 2): a terrain update costs more the bigger the
  terrain (hw550 8192 x 8192: 15-78 ms per update, gridmap_v2: 1-2.5 ms). When the measured cost
  passes `slowUpdateMs`, the floor is written at most every `slowUpdateGap` s, all pending
  vertices in one update.
* Stopped vehicles keep their floor (`holdSpeed` 0.8 m/s, `holdSpin` 1 m/s, `holdPad` 0.75
  squares): the floor writes trail a driving vehicle, so they used to catch up under its parked
  wheels and sink it (-22 cm in 6 s, measured). The floor under the wheels of a slower vehicle is
  not lowered while they stand there (a wheel spinning faster than `holdSpin` keeps digging);
  held vertices are written once the wheels leave. A ~5 cm settle into the engine's soft layer
  when the wheels stop rolling remains.
* Crossing ruts: the terrain grid (1 m on gridmap_v2) is coarser than the ridge between a
  Percheron's two rut lines (0.8 m, measured): a vertex is lowered by the deepest carved cell
  within `floorReach`, so at 0.3 squares the vertex in the middle of the ridge went down to the
  rut floor (-19 cm, ridge +2 cm) and the two ruts feel like one. 0.15 keeps such a vertex but
  lets the terrain cover part of the rut wall; not changed. Ruts further apart than ~2 m (other
  vehicles, crossing tracks) keep their ridge.
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

Every `createMesh` also builds a physics triangle mesh for the object (engine
`ProceduralMesh::updatePhysicsCollision`, decompiled from 0.40.5). The physics static
collision store keeps every one it was handed, including the old sizes of an object and
objects that were deleted, until the next `be:reloadCollision()`. Hidden objects keep it
too: it is not GPU memory. Measured 2026-11-07 (gridmap_v2, D3D12): one object cycling 40
mesh sizes keeps 10-28 MB, a deleted meshed object 110-330 KB; the same object re-uploaded
at the same size keeps ~0.

**Collision compaction** gives it back: the mod hides its meshes, calls
`be:reloadCollision()` and shows them again in the same frame (so the mud stays out of the
physics world). One compaction freed 97-100 % of the kept memory (52 MB after two 8-truck
bench runs, 3 GB after a long session) and costs one 380-510 ms hitch on gridmap_v2 (it
rebuilds the whole level's collision). It runs where the hitch does not show or is
expected:

* while the game is paused (menus), once the process grew `memory.compactMinMB` (50 MB)
  since the last one;
* after a vehicle reset, same minimum;
* when the player vehicle is below `memory.compactStopSpeed` (1 m/s) and the process grew
  `memory.compactMB` (1000 MB). `memory.compactMB = 0` turns all three off.

Console: `deepnode_main.compactCollision()`, `deepnode_main.lastCompaction()` (reason, ms,
MB freed; the log has the same line).

Uploads still cost frame time, so the mod keeps them to real changes: a tile only rebuilds
when a vertex really changes, tiles rebuild at most `ring.tileRebuildHz` times per second
(`ring.farRebuildHz` far from the camera), and `ring.maxMeshBuildsPerSec` caps all tile and
sector replaces per second (nearest first). The upload governor (`perf.*`) keeps createMesh
inside the frame budget.

The Lua heap is separate: LuaJIT keeps freed heap pages committed, so the process does not
shrink after a Lua GC. "Lua cleanup" in the Debug tab (console `deepnode_main.flushMemory()`)
runs a full Lua GC in the game engine and every vehicle VM and drops the mod's caches
(hidden tyre meshes, landed lumps, debug outlines); it keeps the Lua heap from swelling.
`memory.gcStepKB` adds a small Lua GC step every frame. When measuring engine memory, keep
test tables alive: process commit minus `collectgarbage('count')` rises when Lua frees tables
and fakes an engine leak.
* A submesh never holds more than 60 000 triangle corners: the engine counts corners with a
  16-bit number and hangs forever above 65 535.

### Camera

The mud surface has no collision mesh. While the mod runs, the game's static ray cast is
wrapped so the camera and other ray users also see the mud surface for rays up to
`camera.maxDist` metres. All arguments and results pass through unchanged otherwise.

### Shadows

Screen-space shadows are switched off while the mod runs and restored on Stop (any visible
mesh casts them and rebuilding meshes makes them flash; they also draw dark slivers along
the mud mesh edges). A graphics settings change re-enables them; the mod turns them off again
and Stop restores the option the user picked last. The GUI can keep them on.

## GUI

Three tabs:

* **Run** (everyday): status row (light, Running / Stopped / Loading terrain, fps, mod ms),
  Start/Stop, Restart, Smooth ruts, Wash tyres; Ground look (decal roads, pre-rutted roads,
  tread prints, tyre mud); Physics (ground models, which vehicles dig); Deformable ground (one
  tick per ground model, apply on Restart); Display (status light, screen-space shadows off,
  chunk outline).
* **Status light**: while the window is closed or folded, a small box (top right by default)
  shows a green dot when running, red when stopped, an amber spinner with "Loading terrain"
  while region mode loads the next area. Drag to move, double-click to open the window.
* **Debug** also holds the Zones section (Zone radius, Zone depth, Add zone here, Clear
  zones), moved off the Run tab 2026-11-04.
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
| `deepnode_main.setRutOverlay(true/false)` | Experimental tread prints on/off (GUI checkbox, saved to gui.json) |
| `deepnode_overlay.stats()` | Tread print map: prints queued / painted / dropped, window moves, map window |

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
| `softMatch` | ["mud","sand","snow"] | Texts that make a layer soft by default (layer name or ground model name); the Run tab ticks more per session |

### region

Big maps: the mod works in a square region around the player (layer map, distance field,
sink, tiles, road cover); outside it the terrain is left alone. The region follows the player:
the overlap keeps its ruts, tiles outside it are dropped and their terrain restored.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | 'auto' | true, false, or 'auto' (on for terrains over `autoAboveKm2`) |
| `autoAboveKm2` | 68 | Terrain area above which 'auto' turns region mode on (over 8 x 8 km: gridmap_v2 4, johnson_valley 9.4, hw550 67.1 stay whole) |
| `size` | 2000 | Side of the region in m (4 km2) |
| `shiftAt` | 500 | Distance (either axis) of the player from the region centre that recentres it; also when the player is outside it |
| `checkEvery` | 0.5 | Seconds between checks |
| `loadBudgetMs` | 4 | ms per frame for loading the next region's layer map and distance field (the switch itself runs in one frame) |
| `maxSquare` | 2 | Terrains with squares over this many m get a virtual grid (huge_desert: 64 m) |
| `virtualSquare` | 1 | m per square of that virtual grid; tiles, ruts and mud work on it. The terrain is lowered on its real vertices only where all mud within one square is at full depth; no rut floor writes |

### layers

| Key | Default | Meaning |
|---|---|---|
| `defaultSinkDepth` | 0.3 | Sink depth of a soft layer with no specific entry |
| `sinkDepthByMatch` | mud 0.5, sand 0.3, snow 0.2 | Sink depth by text found in the layer name; first match wins; layers ticked by hand use their kind's value |
| `featherVerts` | 4 | Width of the depth fade in terrain vertices |
| `edgeDip` | 0.04 | How far the patch dips under the terrain where the depth is 0 |

### roads

| Key | Default | Effect |
|---|---|---|
| `enabled` | true | Keep terrain under hard decal roads free of mud |
| `margin` | 0.5 | Extra width (m) kept free of mud on each side of a road |
| `skipMatch` | `["invisible", "dirt"]` | Roads with a material containing one of these texts (or a `softMatch` text) are not carved |
| `preRut` | false | Decal roads on soft ground become ruts at start: a procedural rut field per road (deepnode_preRut; the road material is not used) is carved into the rest surface. GUI "Experimental pre-rutted roads" (applies on Restart) |
| `preDepth` | mud 0.3, sand 0.17, snow 0.1 | Depth (m) of a road's first-pass ruts per ground kind |
| `preDepthScale` | 1 | Factor on `preDepth` |
| `preBasin` | 0.6 | Puddle roads: dish depth (x `preDepth`) |
| `preBasinMatch` | `["water", "puddle"]` | Road materials made a dish instead of ruts |
| `preTyreWidth` | [0.28, 0.48] | Rut width range (m, one tyre); each pass of a road picks one from its seed |
| `preTrackHalf` | [0.75, 1.0] | Half wheel gauge range (m) |
| `prePasses` | [1, 3] | Passes (vehicles) per road; passes after the first are shallower and fade in and out along the road over `preFadeLen` m (7) |
| `preRutFlat` | 0.3 | Share of a rut's half width that is flat bottom |
| `preBerm`, `preBermWidth` | 0.3, 0.18 | Torn berm height (x rut depth) and width (m), both broken up along the rut |
| `preWander`, `preWanderLen` | 0.25, [6, 14] | Lateral wander (m) of a pass and its wavelength range (m) |
| `preDepthVar` | 0.35 | Rut depth varies by +- this share along the road |
| `preLumps`, `preLumpSize` | 0.15, 0.25 | Clumpy mud (x depth, size m) along the ruts, a fifth of it elsewhere |
| `preSingleMax` | 1.4 | Roads narrower than this (m) carry one wheel line |
| `preEndFade`, `preEdgeFade` | 1.5, 0.1 | Fade (m) at the road ends, (share of width) at its sides |
| `preSoftShare` | 0.3 | Share of a road's centre points on soft ground needed to use it |
| `preReach`, `preMargin` | 0.6, 0.03 | Terrain vertices within `preReach` m of a dip go down by the dip + `preMargin` (mesh shows, physics floor follows) |
| `prePin` | true | Keep pre-rutted tiles as frozen tile data from the start (false: tiles only near vehicles, sectors draw 1 m quads) |
| `preCellStride` | 1 | Sector cell stride for undug pinned tiles (4 = 0.8 m lost the 0.3 m grooves) |
| `preTileMax` | 4000 | Pre-rutted tiles kept as frozen tile data (sectors draw them at full resolution) |
| `preSkipMatch` | `["line", "asphalt", "invisible", "skidmark"]` | Road materials never pre-rutted |
| `mode` | `"shader"` | Decal roads on the mud (GUI button "Decal roads on mud"): `vanilla` (the level's own decal roads untouched: not hidden, no copies, do not follow ruts), `copy` (the engine's decals stay; deepnode_roadCopy copies in the mud meshes around ruts on every build), `overlay` (older copies, deepnode_decals), `drape` (engine decals laid once), `off` (no decal road on soft ground), `shader` (hidden and drawn by the road shader on the dug surface, `overlay.roads`) |
| `copyFlat` | 0.01 | Mode `copy`: m; a dug square still this planar gets one quad in the road copies |
| `copyCut` | 0 | Mode `copy`: m; > 0 leaves copy quads with a corner dug deeper than this out (plain holes in the road pattern) |
| `copyFade` | 5 levels, 0.03-0.14 m | Mode `copy`: `{ { m, opacity x }, ... }`; a copy quad whose mean \|surface - rest\| passes a level's m is drawn with a fainter clone of the road material (no vertex alpha in a ProceduralMesh): the road pattern fades into ruts and over berms |
| `copyLift` / `copyLiftStep` | 0.008 / 0 | Mode `copy`: m over the mud; extra m per renderPriority level (not needed: copy submeshes draw bottom layer first, depth writes off) |
| `copyMerge` | true | Mode `copy`: the drawn cells of a dug square go into the copies as greedy planar rectangles instead of one quad per cell |
| `copyMergeFlat` | 0.004 | Mode `copy`: m; largest mud deviation from a merged copy quad (keep it under `copyLift`) |
| `overlayOriginal` | true | Copies use the road's own material (translucent, same look as the engine decal); false = alpha-clipped matte copies (`overlayAlphaRef`, `overlayRoughness`) |
| `overlayOnRuts` | true | Copies also on rut and track cells, clipped to the strip (the pattern drapes over the ruts); false = untouched squares only |
| `overlayQuiet` | 1.0 | s after a tile's last stamp before its decal copies are built (0 = every build) |
| `hideKinds` | ["mud","sand"] | `hideOnMud` hides decal roads over these kinds only: snow maps paint ploughed paths and tyre tracks as decals over the snow (polish_roads_winter 3478 roads) |
| `hideOnMud` | true | Mode `off`: hide every decal road that touches soft ground (false: leave them, heavy mode then shows them on undug mud) |
| `overlayAlphaRef` | 110 | Alpha clip of the overlay materials (0 = translucent: slow) |
| `overlayLift` / `overlayLiftStep` | 0.008 / 0.002 | m over the mud; one step per renderPriority level (lower numbers higher; kept under `sectors.drop` without terrain-first) |
| `overlayRoughness` | 0.85 | Fixed roughness of the overlay materials (-1 = the road's own maps) |
| `overlayRoughnessByMatch` | furrows 1, tiretracks 1 | Per material text |
| `overlaySkipMatch` | `["__none__"]` | Decals left out of the overlay (text match) |
| `overSkipMatch` | `["invisible"]` | Roads never drawn over the mud |

### grass

| Key | Default | Meaning |
|---|---|---|
| `cellSize` | 10 | m: GroundCover cell size while heavy physics writes the rut floor (smaller cells blink less grass per terrain update); 0 = level cells |
| `maxRadius` | 150 | m: only GroundCovers up to this radius get smaller cells (tree / distant covers keep theirs: more cells thin them out and cost shadow time) |
| `maxGrid` | 32 | Most cells per side a GroundCover is given |
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
| `physicalVehicles` | all | Vehicles that dig ruts: 'all', 'player', 'near' (player + vehicles within `physicalRange` m of the camera). The others leave screen-space prints only (GUI "Ruts: ...") |
| `physicalRange` | 40 | 'near' mode: m from the camera |
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
| `bodyMaxWait` / `bodyHideMargin` | 1.5 / 0.5 | New ruts all under a vehicle body (box + margin) wait up to this long (s): one upload per truck pass instead of one per axle (2026-10-31, 8 Percherons: uploads -55 %, +4.5 fps; was 0.1 in config.json) |
| `bigChange` / `smallChangeWait` | 0.02 / 0.4 | Rut changes below 2 cm wait up to 0.4 s |
| `borderRebuildGap` | 5 | A tile whose only change is a neighbour's mesh waits this long |
| `minVisibleChange` | 0.006 | A tile re-upload whose largest height change against the mesh on screen is below this (m) is skipped (data keeps the change) |
| `inViewTarget` / `outViewTarget` | 0.3 / 1.5 | Target latency (s) of a waiting rebuild in / out of the camera view: the queue serves the earliest deadline first after fresh rut fronts |
| `outViewMaxDefer` | 4 | Deepening of a meshed tile out of view waits until it comes into view, at most this long (s; config.json 1) |
| `bodyFreshHz` / `bodyFreshDist` | 20 / 20 | A fresh rut front in view under the vehicle body (front axle inside the footprint box) skips `bodyMaxWait` and rebuilds at this rate within this many m of the camera; 0 Hz = wait |
| `digMaxPerFrame` | 6 | Rut-front (dig) tile uploads per frame at most; the rest go next frame. 16 made 20-50 ms frames between 10 ms ones (low1 27 vs 31, 4 trucks); 4 = +2 fps, front lag +20 ms; 3 (8 trucks): no frames over 45 ms but rut lag +45 ms (rejected: visuals first) |
| `deepenFast` | true | Ruts deepened in view by the axles behind (within `digNearDist`) take the fresh-front fast path instead of the shared budget |
| `ownMeshRadius` | 3 | Untouched tiles this close to a footprint box get their own mesh ahead of the wheels |
| `maxMeshBuildsPerSec` | 40 | Tile + sector mesh replaces per second at most (config.json 400; the kept collision memory is returned by collision compaction) |
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
| `liquid` | see below | Liquid mud: pipe-model flow of the rut surface round the tyres (main P.liquidStep) |
| `liquid.kinds` | `{ "mud": 1.0 }` | Flow factor per ground kind; kinds not listed stay solid |
| `liquid.margin`, `liquid.maxSize` | 1.0, 12 | One window per vehicle: its tyres' box plus margin (m), at most maxSize m a side; it follows the vehicle cell by cell |
| `liquid.hz` | 20 | Simulation steps per second |
| `liquid.gravity`, `liquid.depthRef` | 9.81, 0.12 | Flux acceleration: gravity x the mud depth the flux moves through (wave speed) |
| `liquid.yield` | 0.3 | Slope the mud holds without flowing (Bingham yield): ruts keep a wall up to this |
| `liquid.damping` | 1.4 | 1/s viscous damping of the flux (lower: more slosh) |
| `liquid.life` | 2.0 | s a window keeps flowing after its vehicle left the mud |
| `liquid.minStep` | 0.004 | m of change before a vertex is rewritten (each write can rebuild a tile) |
| `bermFraction` | 0.4 | Share of displaced mud that ends in the berms |
| `bermWidthFactor` | 0.6 | Berm width as a share of the tyre width |
| `liquid.rebuildHz` | 1 | Tiles changed only by the liquid flow since their last build rebuild this often; flow writes do not count as tyre stamps (dig rate, big-change, under-body wait) |
| `bermMax` | 0.25 | Rut code range above the undisturbed surface (m): the highest berm of any kind |
| `bermCap` | 0.1 | Berm cap above the undisturbed surface (m); per kind `kinds.<kind>.bermCap` (mud 0.2, sand 0.16, snow 0.12) |
| `bermPeak` | 0.5 | Where a berm is highest across its band (0 at the tyre wall); mud 0.4. Kinds with `rimDepth` 0 start the berm at the tyre wall |
| `bow`, `bowLen` | 0, 0.5 | Bow wave ahead of a rolling tyre: height = bow x sink depth, over bowLen x R ahead of its front (mud 0.45 / 0.75, sand 0.4, snow 0.25) |
| `kinds.<kind>.bermWidthFactor` | - | Berm band width per kind (mud 1.0), else `bermWidthFactor` |
| `layerGap` | 1.5 | (clods) s between two tyre-layer updates of one tyre material (a reload costs ~8 ms with 4 trucks sharing it) |
| `layerRelief` | 0.8 | (clods) Tyre layer: strength of the dirt normal map over the tyre relief |
| `rimCells` | 1 | Width of the soft rim beside the tyre, in cells |
| `rimDepth` | 0.45 | How far the rim sags towards the tyre edge (0..1); per kind in `kinds` (mud 0: the pushed mud stays against the tyre and the liquid flow takes it round) |
| `maxSlope` | 1.2 | Steepest wall the mud holds (rise over run; 1.2 is about 50°) |
| `slumpRate` | 0.35 | Share of the too-steep part removed per pass |
| `slumpPasses` | 1 | Slope passes over each stamped area |
| `relaxHz` | 5 | Settling updates per second |
| `relaxTime` | 3 | Seconds for fresh ruts to settle most of the way |
| `instantSettle` | true | Ruts written at their settled depth (no settling pass, no extra re-meshes) |
| `relaxWindow` | 0.3 | Seconds after the last stamp; settling then snaps to its end shape (instantSettle off) |
| `spinDigRate` | 0.012 | Visual only: dig per (m/s of wheel spin x s) under a spinning wheel |
| `spinDigMax` | 0.2 | Visual only: deepest spin hole below the tyre at `refWheelLoad` |
| `torqueDigRate` | 0.08 | Dig under a driven wheel per s per unit of traction ratio (drive force / wheel load) above `torqueDigStart`; capped like spin digging. Heavy mode: the floor follows, so a rear-wheel-drive car squats into the mud under hard throttle |
| `torqueDigStart` | 0.25 | Traction ratio below which drive torque does not dig |
| `refWheelLoad` | 3500 | Wheel load (N) the dig numbers are tuned for; heavier digs more |
| `relaxKeep` | 0.75 | Share of the deepest rut that stays after settling |
| `relaxKeepBerm` | 0.8 | Share of the highest berm that stays after settling |
| `shoulderFactor` | 0.25 | Tyre shoulder radius as a share of the tyre width |
| `maxSweep` | 3 | Longer jumps between two reports are treated as a teleport |
| `bodyRadius` | 0.16 | Radius of a chassis dent |
| `bodySkin` | 0.03 | Dent bottom below the chassis node |
| `bodyBermWidth` | 0.12 | Width of the ring around a dent |
| `bodyBermFraction` | 0.3 | Share of dent mud that ends in the ring |
| `hull` | true | Stamp the body's collision triangles under the surface (bumpers, sills, panels plow the mud) |
| `hullEdge` | 0.08 | m: triangle edges rounded off over this width (a vertical panel cuts a groove this wide) |
| `hullSkin` | 0.01 | m: dent bottom below the triangle |
| `hullStep` | 0.15 | m: sweep step between two reports |
| `trackBase` | 0.25 | Roughness of any rut |
| `trackSpinGain` | 0.08 | Extra roughness per m/s of wheel spin |
| `trackDepthGain` | 2.0 | Extra roughness per metre of depth |
| `bermCrumble`, `bermCrumbleMax` | 0.9, 0.16 | Torn berm crests: berm vertices move by berm height x this x a clump noise (render only), capped (m) |
| `rutCrumble`, `rutCrumbleMax` | 0.6, 0.06 | Torn rut walls and floor: dug vertices move by depth x this x a +- clump noise (render only), capped (m) |
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
| `soil.trainGap` / `soil.trainWeight` | 10 / 0.25 | A following wheel of the same vehicle within trainGap s of the last touch adds trainWeight of a pass (tandem axles; quarter steps) |

### report

| Key | Default | Meaning |
|---|---|---|
| `rateHz` | 15 | Wheel and chassis reports per second (vehicles within 40 m of the camera; further: half, beyond meshRange 1/farLod) |
| `maxBodyNodes` | 48 | Chassis nodes reported for dents at most |
| `maxHullTris` | 64 | Body collision triangles reported per vehicle at most (deepest first) |
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
| `buildPerMeter` | 0.02 | Coat picked up per metre the tread rolls through mud (Percheron at 18 km/h: coverage ~0.6 after 7 s) |
| `buildSpinGain` | 0.5 | Extra pick-up per m/s of wheel spin (at most x3) |
| `looseShare` | 0.3 | Share of the coat that is loose while in mud |
| `looseShedPerMeter` | 0.04 | Loose coat lost per metre after leaving the mud |
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
| `kinds.<kind>.treadInset` | mud 0.07, sand 0.010 | Skin this far below the tread surface (x outward share of the normal): the tyre's lugs show through, sand stays in the grooves |
| `kinds.<kind>.coverMax` | sand 0.62 | Covered share at coat 1 (default `clods.coverMax`) |
| `kinds.<kind>.groundGain` | sand 1.3 | Factor on the ground colour (default: the kind's `wet`) |
| `kinds.<kind>.groundDesat` | sand 0.3 | Move the ground colour towards grey (0..1) |
| `groundColor` | true | Tyre coat takes the terrain colour under the wheel (base map + macro/detail mean, / tyre texture mean); `color`, `brightness`, `tyreBrightness` only where it is unknown |
| `groundGrid` | 128 | Cells a side of the base-map colour grid read at start |
| `kinds.mud.texN` / `groundGain` | t_tyremud_nm, 1.4 | Procedural mud normal map; drying mud on a tyre is lighter than the wet ground |
| `filmMud` | 0.5 | Water film colour = ground colour of the wheel's last soft ground x this (`filmColor` grey where unknown) |
| `filmOpacity` | 0.4 | Water film opacity at full wetness (x the streak texture `t_tyrefilm_o`) |
| `wetFilm` | false | Old water film layer on the tyre skin (replaced by `rubberWet`) |
| `tyreLayer` | true | Tyre mud drawn as one more layer of the vehicle's own tyre material (SnowRunner-style layer of dirt: coverage masks tread first, the tyre's normal/AO maps stay); off or no free layer: the skin mesh |
| `sectors` | 8 | Tyre perimeter arcs with their own coat / kind / colour / wetness (skin submesh + material each); arcs in the contact patch pick mud up by rolled distance, arcs under water get wet and washed; 0 = one coat per wheel. Not used while `overlay.tyreCoat` is on (the shader's 32 arcs replace it; the fallback skin then has one material) |
| `sectorRefStep` | 8 | Sector coverage thresholds snap to multiples of this (alphaRef): arcs with the same coat change level together |
| `layerMaxSectors` | 3 | With sectors: highest tyre-layer mask level (the layer is only the dirt on the rubber under the sectored skin) |
| `layerAoTint` | 0.1 | Tyre layer: the tyre's AO map as colour detail on the mud (lug tops lighter, grooves darker) |
| `rubberWet` | true | Wet tyres: the vehicle's own tyre materials (name contains tire/tyre) get lower roughness and a darker colour |
| `rubberGloss` | 0.7 | Roughness x (1 - this x wetness) |
| `rubberDarken` | 0.3 | Base colour x (1 - this x wetness) |
| `rubberStep` | 0.12 | Wetness change that re-applies a material (`Material:reload`, ~2 ms) |
| `rubberGap` | 0.25 | Seconds between rubber passes (one material per pass) |
| `rubberWetRate`, `rubberDryTime` | 1.5, 90 | Wetting rate per s; drying time in s (faster with speed, `drySpeedRef`) |
| `kinds.<kind>.rubberWet` | mud 0.7, sand 0.1 | Wetness a tyre reaches on that ground (water: 1) |

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
| `pool.tileClasses` | 24 | Tile meshes are padded to k/tileClasses of the largest tile (fewer classes: less engine memory per upload, more createMesh time) |
| `pool.decalMinCorners` | 96 | Smallest size class of decal overlay submeshes (doubling classes from here) |
| `pool.mode` | pair | 'pair': each chunk alternates between two objects of its own (no flicker, least engine memory); 'swap': a fresh pooled object per upload |
| `memory.gcStepKB` | 0 | >0: a Lua GC step of this size every frame (GUI: Steady GC) |
| `memory.compactMB` | 1000 | Collision compaction when the player vehicle is nearly stopped and the process grew this many MB since the last one; 0 = compaction off |
| `memory.compactMinMB` | 50 | Growth that triggers a compaction while paused or after a vehicle reset |
| `memory.compactStopSpeed` | 1 | m/s: "nearly stopped" for `compactMB` |
| `gui.openOnStart` | true | Open the window when the mod starts |
| `gui.indicator` | true | Status light while the window is closed or folded (green on, red off, amber spinner while region mode loads) |
| `debug.chunks` | false | Chunk border overlay (GUI checkbox; kept over mod restarts) |
| `debug.drawRadius` | 120 | Tiles within this distance of the camera are outlined (sectors within twice it) |
| `debug.lift` | 0.12 | Overlay lines float this high over the mud |

### overlay (experimental ground and tyre look)

Tyre prints painted on the GPU into a world-space map (`#deepnode_rut`, RGBA16F) around the
camera and drawn over the lit scene (shaders in `shaders/common/postFx/deepnode/`). Every wheel
stamp of the mud pipeline queues a print with its surface kind (mud / sand) and a berm band
beside the tyre; coated wheels off the soft ground leave tread-shaped mud (or sand dust) stains
on hard ground. The overlay pass draws tread relief, granular crumbs, wet churned colour and a
sun highlight; colours change on the lit scene colour (the light pre-pass G-buffer holds no base
colour) and the engine's screen shadow mask (`#sunShadowMask`) keeps shadowed ground unlit. A
second pass makes wet / freshly mud-coated tyres darker and glossy. No mesh uploads.

| Key | Default | Meaning |
|---|---|---|
| `overlay.enabled` | true | On/off (GUI "Experimental tread prints"); on by default since v0.3.0 |
| `overlay.mapSize` | 2048 | Texels per side of the print map |
| `overlay.span` | 128 | Metres covered by the map (6.25 cm texels) |
| `overlay.recentreMargin` | 24 | The map window moves (8 m steps, prints kept) when the camera is this close to its edge |
| `overlay.segmentsPerFrame` | 16 | Prints painted per frame (shader limit 16); the rest wait |
| `overlay.queueMax` | 512 | Waiting prints at most (oldest dropped) |
| `overlay.mergeMax` | 3 | A wheel's waiting print segment is extended by its next report while it goes on straight, up to this length (m): 6 trucks x 8 wheels at 20 Hz otherwise fill the 16 segments a frame |
| `overlay.edge` | 0.03 | Soft print edge (m) |
| `overlay.strength` | 1.0 | Overall strength (0 = no visible effect, passes still run) |
| `overlay.phasePerMetre` | 4 | Along-track coordinate scale (the print pattern repeats every 64 / this m) |
| `overlay.streaks` | 0.65 | Share of smear streaks in the print relief (the rest: stick-slip ripples). No tread pattern: the print suits any wheel |
| `overlay.pressDepth` | 0.025 | Depth of the print relief (m) |
| `overlay.lip` | 0.8 | Height of the mud lip squeezed up at the print edge, x pressDepth |
| `overlay.parallax` | 6 | Ray march steps into the print relief (MudRunner's track parallax: grooves look sunk in at low camera angles), 0 = off, max 12 |
| `overlay.parallaxDepth` | 1.0 | Depth of the marched relief, x pressDepth |
| `overlay.grooveDark` | 0.4 | Darkening of the deepest pressed parts (reads whatever side the sun is on) |
| `overlay.engineLight` | true | Tyre prints lit with the engine's own light: light pre-pass diffuse + sky SH9 x screen AO (packed at ReflectDepthBin, shared with the road shader), sun glint from the shadowed sun light, sky SH9 in wet sheen and puddles; false = the estimates (`ambient`, `groundAlbedo`, sky from the screen top) |
| `overlay.ambient` | 0.45 | Ambient share in the relight ratio |
| `overlay.highlight` | 1.0 | Sun highlight on wet ground |
| `overlay.wetSheen` | 0.3 | Sky reflection on wet ground at grazing angles (flat-water Fresnel x a smooth wetness: kind wetness x print strength; sky sampled from the top of the screen). The per-groove wetness made it streaky |
| `overlay.useShadowMask` | true | Use the engine screen shadow mask (no relief / highlight in shadow) |
| `overlay.groundAlbedo` | 0.3 | Ground albedo guess: light level for the highlight = scene / this |
| `overlay.roads.mapSize` | 512 | Texels per side of the road map (target 2 x `layers` x this by this, RGBA16F, plus a copy: 67 MB at 512 x 8) |
| `overlay.roads.span` | 192 | Metres covered around the camera (37.5 cm texels; u, v are extrapolated, texel size does not blur the road) |
| `overlay.roads.layers` | 8 | Road entries per texel (1..8); more overlapping roads drop the lowest (gridmap_v2's pit stacks up to 7) |
| `overlay.roads.recentreMargin` | 48 | The road map moves (~16 m steps, content shifted, only the newly covered quads painted, nearest first) when the camera is this close to its edge |
| `overlay.roads.quadsPerFrame` | 32 | Road quads painted per frame (shader limit 32) |
| `overlay.roads.margin` | 0 | Metres beyond the road edges a texel still takes a road (at least 0.75 texel) |
| `overlay.roads.edgeFade` | 12 | Roads fade out over this many metres towards the map edge |
| `overlay.roads.ao` | true | Engine screen AO (`#gtaoOutput`) on the road's ambient light |
| `overlay.roads.materialAO` | true | The road material's AO map on its ambient light |
| `overlay.roads.zAbove` / `zBelow` | 0.4 / 1.5 | Height band around the road's own surface that takes the road (berms above, ruts below) |
| `overlay.roads.minNormalZ` | 0.15 | No road on faces steeper than this |
| `overlay.roads.normalStrength` / `relief` | 1 / 0.5 | Road normal map tilt / strength of the relight pass |
| `overlay.roads.alphaGain` | 1 | Opacity multiplier |
| `overlay.roads.lowPriorityOnTop` | true | Engine draw order: lower `renderPriority` numbers on top |
| `overlay.roads.skipMatch` | `invisible` | Road materials left out |
| `overlay.roads.debug` | 0 | 1 u / v, 2 light only, 3 light on `debugAlbedo` (light scale check against the terrain), 4 opacity, 5 slots 4 / 5 / 3 raw; `debugMat` draws one material only |
| `overlay.fadeStart` / `fadeLength` | 35 / 25 | Prints fade out between these distances from the camera (m) |
| `overlay.zTolerance` | 0.35 | Pixels this far above the undisturbed ground are left alone (vehicles over the ruts) |
| `overlay.bermZTolerance` | 0.5 | Same over a berm (berms stand above the ground) |
| `overlay.maxDepth` | 1.2 | Deepest rut floor below the undisturbed ground that is drawn (m) |
| `overlay.puddles` | 0.7 | Water in the mud ruts, 0 = none; 'fill': share of each closed hollow's spill depth that holds water; 'noise': 1 = every rut deeper than `puddleDepth` |
| `overlay.puddleMode` | fill | 'fill': water pools in the closed hollows of the ruts (cell heights flood-filled per quiet tile, the level stored in the rut map); 'noise': the old patchy level below `puddleDepth` |
| `overlay.prePrints` / `prePerFrame` | true / 8 | Pre-rutted roads' wheel lines painted as plain mud prints (map kind 11: wet trench floor where the groove is deep, pools; no tyre print pattern) and their tiles' pools; segments queued per frame |
| `overlay.poolMin` | 0.03 | Hollows shallower than this (m, spill depth) hold no water |
| `overlay.poolQuiet` | 0.8 | Seconds a tile must go unstamped before its pools are worked out |
| `overlay.poolMaxPerSec` | 6 | Tiles per second whose pools are worked out (0.6-0.8 ms each) |
| `overlay.trench` | start 0.08, range 0.12, wet 0.95, darken 0.12 | Wet trench look: mud ruts deeper than `start` m get wetter (up to `wet`), smoother and darker (`darken`) over `range` m |
| `overlay.shade` | rim 0.35, floor 0.3, floorDepth 0.4, bermLift 0.15 | Depth shading of the prints: floors darker the deeper they lie (`floor`, full at `floorDepth` m below the undisturbed ground), berm tops lighter (`bermLift`, full 5 cm above it); `rim`: dark wet band where mud coverage fades out (not on sand) |
| `overlay.puddleDepth` | 0.1 | 'noise' mode: rut depth below the undisturbed ground where water starts (m) |
| `overlay.puddleMurk` | 0.7 | How opaque the muddy water is |
| `overlay.minNormalZ` | 0.45 | Steeper ground fades out (slope from the depth buffer, not the normal-mapped G-buffer normal) |
| `overlay.drySoil` | dust, dry, desert, sand | Soft layers whose name contains one of these get the sand look (no wet darkening, no puddles), e.g. johnson_valley `dirt_loose_dusty` |
| `overlay.bermReach` | mud 2.4, sand 2.6 | Berm band beside the print, x tyre half width |
| `overlay.mud` / `overlay.sand` | see config | `darken`, `saturate` (gain), `wet` (0..1), `bermCrumbs` (crumb density on the berms), `crumbLift` (crumbs lighter than the floor); sand also `relief` and `crumbHeight` (x the mud values: softer prints, fine grains) |
| `overlay.grain` | size 0.05, height 1.2, printDensity 0.15, churnSize 0.35 | Crumb size (m), crumb height (x size), crumb density in the print, size of the wet/dry mottling (m) |
| `overlay.carry` | see config | Mud on hard ground: `enabled`, `color` (hue), `gain` (brightness), `opacity`, `minCoat`, `perCoat` (strength = coat x this), `step` (m between prints), `afterSoft` (s off the soft ground) |
| `overlay.dust` | colour, gain 1.35, opacity 0.45 | Sand carried onto hard ground |
| `overlay.tracks` | see config | Tracks on hard terrain (no deformation): a clean wheel on a terrain material whose name contains a `grass` part leaves a flattened track (darker, paler: `grassDarken`, `grassDesat`), a `dirt` part (dirt, gravel, soil, ...) a compacted one (`dirtDarken`); `relief` x the mud print relief; one print every `step` m; skipped more than `maxGap` m off the terrain and on decal roads (road mask scanned when the overlay starts). Grass blades (groundcover) hide most of a grass track |
| `overlay.wetTracks` | see config | Tyres wet from water (wetness >= `minWet`) leave dark glossy tracks on hard ground (strength wetness x `perWet`, `darken`), drying patchily over `dryTime` s (< 64: the map stores the paint time mod 64 s; a paint pass every 3 s erases dried texels) |
| `overlay.splats` | see config | Mud thrown by wheels spinning in mud (MudRunner's terrain mud decals): `enabled`, `minSpin` (m/s slip), `perSpin` (splats per s per m/s), `maxPerSec`, `reach` (m behind the wheel, full at `fullSpin` m/s), `sizeMin`/`sizeMax` (radius m), `color`, `gain`, `opacity`. Thrown only while the paint queue is below a quarter full |
| `overlay.tyres` | true | Wet tyre pass on/off |
| `overlay.tyreRange` / `tyreMaxWheels` | 40 / 32 | Wheels within this distance, nearest first (shader limit 32); further wheels fall back to the tyre skin mesh |
| `overlay.tyreWetDarken` / `tyreHighlight` | 0.35 / 1.0 | Wet tyre darkening / sun highlight |
| `overlay.tyreAlbedo` | 0.06 | Tyre albedo guess (light level for the wet highlight; the coat uses the engine light pack when `engineLight` is on) |
| `overlay.tyreMudWet` / `tyreMudDry` | 0.7 / 25 | Wetness of fresh mud / seconds since an arc last picked mud up until it reads dry (per perimeter arc with `tyreCoat`) |
| `overlay.tyreCoat` / `tyreCoatLump` | true / 0.03 | Tyre mud drawn by the tyre shader from 32 perimeter arcs per wheel (wheelMud `W.bins`): the coat starts at the contact patch, creeps round as the tyre rolls, thickens per pass; drawn wheels show no skin mesh and need no material flushes, `clods.tyreLayer` is off / lump size of a thin coat (m) |
| `overlay.tyreCoatDryLift` / `tyreCoatCracks` | 1.3 / 0.6 | Albedo factor of dried over fresh mud / crack strength in thick dried cake |
| `overlay.debug` | 0 | 1 sun term, 2 coverage (red print, blue berm, green carried), 3 shadow mask, 5 tyre pixels, 6 print terms (groove, lip, filters), 7 crumbs, 9 depth below the undisturbed ground, 10 tyre coat (r cover, g thickness, b freshness), 11 tyre coat light (r opacity, g engine light x 4, b albedo x 4) |

`deepnode_overlay.reloadShaders()` recompiles the overlay and tyre shaders (new ShaderData
objects, prints stay), for shader work. 2026-11-09: it did NOT swap the tyre pass's shader (a
red-output test kept drawing the old one); reload GE Lua for tyre shader edits. Offline syntax check: copy the game's `shaders/common`
and the mod's `shaders/common/postFx/deepnode` into one tree and run the Windows SDK `dxc.exe
-T ps_6_0 -E main -D SHADER_STAGE_PS=1 -I <tree> <file>` (the game logs nothing when a post
effect shader fails to compile; it keeps drawing the old one).

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

- `sectors.autoSize` (true): choose the sector size at start from the map's meshed soft area (soft kinds whose heavy floor lift is below their sink depth, soft clusters drawn low near grass, plus zones in vanilla mode), so that a camera in the biggest region sees at most `sectors.autoMaxObjects` (50) sectors within `sectors.loadRadius`. Clamped between `sectors.tiles` (minimum, GUI "Sector size") and `sectors.autoMaxTiles` (8). The choice is logged (`sector size: ...`).

## Bearing sinkage (`stamp.bearing`, 2026-11-08)

Rut depth of a rolling tyre comes from the Bekker rigid-wheel sinkage, not from where the tyre
bottom is: z = (3 W / ((3 - n)(kc + b kphi) sqrt(D)))^(2 / (2n + 1)) with W the wheel's load
(vehicle report `downForce`), b tyre width, D diameter, n `kinds.<kind>.soilN`, kc / kphi
`kinds.<kind>.kc` / `kphi` (game-soft values: mud 800 / 90000, sand 20000 / 1600000 since 2026-11-09; Percheron
wheel 18 kN, 0.39 m, R 0.6: ~0.2 m in mud, ~0.1 m in sand), times (1 + slip sinkage). Heavier
vehicles and narrower or smaller tyres dig deeper; spinning and drive torque still dig on top
(`spinDig*`, `torqueDig*`). Off (`bearing = false`) the stamp carves to the tyre bottom, which in
heavy mode compounded with the soft layer (floor follows rut, tyre sinks again).

