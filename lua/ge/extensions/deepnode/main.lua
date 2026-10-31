-- deepnode_main
-- Lifecycle, terrain (layer map, sink pass), tiles, stamping, materials, config,
-- vehicle data streaming and the castRayStatic wrapper.
--
-- Engine API this file relies on (confirmed in the shipped 0.39 Lua):
--  * core_terrain.getTerrain() -> TerrainBlock            ge/extensions/core/terrain.lua:9-19
--  * tb:getPosition() is the terrain corner, tb:getSquareSize(), tb:getWorldBlockSize()
--      ge/extensions/editor/terraform/terraform.lua:538-539, ge/extensions/ui/uiNavi.lua:359-368
--  * tb:getHeightGrid(gx,gy) / tb:setHeightGrid(gx,gy,z) work in grid coordinates and the
--    terrain-local height frame (they clamp with max(0, z)); tb:updateGrid(vec3 min, vec3 max)
--    rebuilds the given grid range                       terraform.lua:197-208
--  * tb:getHeight(vec3(x,y,0)) returns world z           editor/roadRiver.lua (getHeight(vec3(x,y,0)) + 0.1)
--  * tb:getMaterialIdxWs(vec3) -> layer index            editor/rallyEditor/drivelineTab.lua:649
--  * tb:getMaterials() (0-based order = ipairs index-1)  editor/biomeTool.lua:613-618
--    material:getInternalName(), :getGroundmodelName(), :getField(name, 0)
--      editor/terrainEditor.lua:709, :809-821 (field names baseColorBaseTex, ...Size, ...)
--  * tb:getTerrFileName()                                editor/terrainEditor.lua:1068
--  * core_environment.groundModels[UPPERNAME].cdata.defaultDepth
--      ge/extensions/core/environment.lua:1456,1474-1477
--  * castRayStatic(origin, dir, maxDist[, flag]) -> distance (>= maxDist when nothing hit)
--      ge/extensions/core/cameraModes/external.lua:145-150, ge/spawn.lua:192
--  * veh:queueLuaCommand(str) / obj:queueGameEngineLua(str)  core/vehicles.lua, vehicle/*.lua
--  * ScreenSpaceShadowsPostFx :isEnabled/:enable/:disable and $AL::UseSSSmask
--      ge/extensions/core/settings/graphic.lua:110-119,1461-1470
--  * createObject('Material') + setField + registerObject   ge/client/core.lua:17-60
--  * hooks onClientPostStartMission / onClientEndMission      ge/main.lua:774,794
--    onVehicleSpawned / onVehicleResetted / onVehicleDestroyed ge/main.lua:1083,1109,1125

local M = {}
local P = {} -- private functions and state (keeps the main chunk under LuaJIT's 200-local limit)

local ffi = require('ffi')

local floor, ceil, min, max, abs, sqrt, huge = math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt, math.huge
local byte = string.byte
local sfmt = string.format
local logTag = 'deepnode'

local tclear = table.clear
if not tclear then
  local ok, f = pcall(require, 'table.clear')
  tclear = ok and f or function(t) for k in pairs(t) do t[k] = nil end end
end

local KEY = 65536 -- tile/sector key = y * KEY + x

local function isFinite(v)
  return type(v) == 'number' and v == v and v > -1e7 and v < 1e7
end
M.isFinite = isFinite

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end

-- (the os.clock fallback lives in its own function: closures in newTimer made LuaJIT
-- abort every trace through its return, `jit.v`: "NYI: bytecode UCLO")
local function clockTimer()
  local t = { t0 = os.clock() }
  function t:stop() return (os.clock() - self.t0) * 1000 end
  function t:stopAndReset() local e = (os.clock() - self.t0) * 1000; self.t0 = os.clock(); return e end
  return t
end

local function newTimer()
  if hptimer then return hptimer() end
  return clockTimer()
end

-------------------------------------------------------------------------------
-- configuration
-------------------------------------------------------------------------------
-- Code defaults. settings/deepnode/config.json is merged over these: nested tables
-- merge, arrays replace. Every value is explained in docs/REFERENCE.md.
local defaults = {
  autoStart = true,
  softMatch = { 'mud', 'sand' },
  layers = {
    -- 0.3 m: a car sinks to the rims and can belly out on deep tracks; in-game test
    -- showed 0.45 m trenched a stock SUV, which read as too thick
    defaultSinkDepth = 0.3,
    -- first matching text wins: mud is wetter and deeper than sand
    sinkDepthByMatch = { mud = 0.35, sand = 0.2 },
    depthScale = 1,         -- multiplies every sink depth (GUI "Depth x")
    -- 4 vertices of smoothstep feather (4 m on a 1 m grid): the border has no step
    -- and the round chamfer contours hide the square grid
    featherVerts = 4,
    -- 4 cm dip at depth 0 hides terrain LOD wobble along the border line
    edgeDip = 0.04,
  },
  roads = {
    -- Decal roads lie on the terrain at the height the mud surface is drawn, so the mud
    -- mesh would hide them. Terrain vertices under a decal road are not soft ground:
    -- no mud, no sink, no mesh there, and the mud border fades out beside the road.
    enabled = true,
    margin = 0.5,           -- m: extra width kept free of mud on each side of the road
    -- roads whose material contains one of these (or a softMatch text) are ignored: dirt
    -- variation decals are scattered over sand and mud and must not clear the soft ground
    skipMatch = { 'invisible', 'dirt' },
    -- Decal roads lying entirely on the mud are drawn over objects (DecalRoad.overObjects):
    -- projected onto the mud surface instead of lying on the lowered terrain under it.
    -- Switched once the mud mesh under a road is built, put back on stop.
    overObjects = true,
    overSkipMatch = { 'invisible' }, -- roads with a material containing one of these are left alone
    perFrame = 4,           -- roads switched per frame at most (regenerate costs ~0.3 ms each)
    -- lay all those roads at start onto a temporary collision proxy at the mud height
    -- (P.drapeRoads); false: switch them as their sectors load (they then stay on the
    -- lowered terrain, hidden: overObjects only sees collision meshes)
    drape = true,
    drapeWait = 0.5,        -- s between creating the proxies and the reload (collision build)
    drapeTries = 3,         -- reloads at most while the proxies' collision is not ready
    drapeFrames = 30,       -- frames between laying the roads and removing the proxies (3 was too few)
    -- mode: 'overlay' = decal roads drawn into the mud meshes (deepnode_decals, follows the
    -- mud, left out on rut cells), 'drape' = the engine's decals laid once onto the
    -- undisturbed mud (above), 'off' = no decal roads on the mud. Default off: the overlay is
    -- experimental (GUI "Experimental decal road"); off hides the decal roads on soft ground
    -- (P.coverRoads)
    mode = 'off',
    hideOnMud = true,       -- mode off: no decal road shows on soft ground (P.coverRoads)
    overlayAlphaRef = 110,  -- overlays are alpha-clipped (opaque pass); 0 = translucent (slow, sorts badly)
    overlayLift = 0.008,    -- m over the mud (4 mm z-fought beyond ~10 m); one overlayLiftStep per renderPriority level
    overlayLiftStep = 0.001,
    overlayRoughness = 0.85, -- fixed roughness (the decal roughness maps sparkle on a mesh); -1 = keep
    overlayRoughnessByMatch = { furrows = 1, tiretracks = 1 },
    overlaySkipMatch = { 'water' }, -- puddle decals are left out (a flat sheet as a mesh)
    overlayCellMargin = 0.12,
    insideShare = 0.9,
  },
  -- Groundcover (grass, plants) on soft layers would grow on the lowered terrain, under the
  -- mud surface. Its GroundCover is lifted by the layer's sink depth (zOffset); where one
  -- GroundCover also covers hard layers, the soft types move to a lifted copy.
  grass = {
    lift = true,
  },
  tiles = {
    -- 5 m tiles: about one car length, so a 10 m ring is a handful of tiles
    targetSize = 5.0,
    -- 20 cm cells: about the width of a tread block, fine enough for a tyre profile
    cellSize = 0.2,
    -- rutted tiles draw untouched terrain squares as one quad (fewer vertices per upload)
    mergePlain = true,
  },
  ring = {
    -- Tiles are active (full detail, can be dug) where they come within boxMargin of a
    -- vehicle's footprint: an oriented box round its main body (parts that broke loose
    -- do not count), or of that box moved ahead along the vehicle's path.
    boxMargin = 3,          -- m around the footprint box
    -- an active tile freezes once it has been outside every box margin for this long
    -- (s, simulation time): its ruts stay, it stops rebuilding and settling
    freezeDelay = 1,
    lookaheadTime = 2.0,    -- prepare tiles where the vehicle will be in this many seconds
    minLookahead = 10,      -- m: look ahead at least this far whenever the vehicle moves
    prebuildReserve = 8,    -- mesh tokens kept for tiles being dug; look-ahead meshes only use tokens above this
    maxLookaheadPoints = 6, -- footprint boxes placed along the look-ahead path at most
    prepBudgetMs = 2.0,     -- per frame, tile data preparation
    maxPreparePerUpdate = 8,
    meshBudgetMs = 2.0,     -- per frame, tile mesh rebuilds
    tileRebuildHz = 5,      -- one tile rebuilds at most this often (7-truck test: 6 Hz cost 4 fps, same rut lag)
    maxTileBuildsPerFrame = 2, -- in game one rebuild costs up to ~3 ms (mesh upload); 3 per frame peaked at 9.7 ms
    -- Hard cap on mesh replaces per second (tiles + sectors). The engine keeps ~25-150 KB
    -- per replace of a drawn ProceduralMesh until the game closes (measured; not freed by
    -- mod restart or level reload), so this caps the leak rate. Nearest tiles go first;
    -- the rest wait. Measured need while digging hard: about 14 per second; 35 leaves
    -- room for several vehicles digging at once.
    maxMeshBuildsPerSec = 33,
    -- m from a vehicle's footprint box or its first look-ahead box: untouched tiles this
    -- close get their own mesh ahead of the wheels. Further look-ahead boxes only prepare
    -- tile data: their prebuilt meshes were uploads (and urgent sector re-meshes) for
    -- tiles a turning vehicle never reached.
    ownMeshRadius = -1,
    camNearDist = 30,       -- m from the camera: tiles closer rebuild at tileRebuildHz
    camFarDist = 60,        -- m: tiles this far and further rebuild at farRebuildHz
    farRebuildHz = 3,
    -- frozen rut tiles this close to the camera keep their own mesh (no sector re-mesh
    -- when a vehicle drives on); at most frozenOwnMeshMax of them
    -- In the 6-truck stress test (Johnson Valley) 300+ tiles froze and most were handed to
    -- their sectors: every handover is a sector re-mesh (2-9 ms upload). Keeping the own
    -- mesh is free (no upload; a few hundred extra objects measured at < 0.5 ms render).
    frozenOwnMeshRadius = 100,
    frozenOwnMeshMax = 150,
    meshBuildBurst = 24,
    maxVehicles = 8,        -- vehicles that get an active ring (nearest to the camera)
    vehicleRange = 400,     -- vehicles further than this from the camera are ignored
    meshRange = 70,         -- m: vehicles further from the camera dig without meshes (beyond
                            -- sectors.loadRadius the mud is drawn as lowered terrain anyway)
    settleRebuildHz = 2,    -- rebuild rate of a tile that only settles (no tyre on it)
    bodyMaxWait = 0.6,      -- s a tile may wait while all its new ruts are under a vehicle
    bodyHideMargin = 0.5,   -- m added round the vehicle box for that test
    bigChange = 0.02,       -- m: a rut change this big rebuilds at tileRebuildHz ...
    smallChangeWait = 0.4,  -- s: ... smaller ones (axles behind deepening it) wait this long
    -- Depth ladder, first rung: a re-upload whose largest change against the mesh on
    -- screen is below minVisibleChange (m) is skipped; the data keeps the change and the
    -- next real change (or the sector at freeze) shows it. Measured 2026-10-31 (4
    -- Percherons, gridmap_v2): 7.6 % of tile uploads changed < 1 cm, 14 % < 3 cm. The
    -- terrain floor sits floorMargin (3 cm) under the rut, so a few mm do not show.
    minVisibleChange = 0.006,
    -- Deadline-first queue (Recoil / UE significance style): every waiting rebuild has a
    -- deadline = when its change became visible + a target latency (fresh rut front in
    -- view: the fast path; deepening in view: inViewTarget; out of view: outViewTarget);
    -- earliest deadline first. Deepening out of the camera's view waits up to
    -- outViewMaxDefer s (or until it comes into view): same budget, spent on what is seen.
    inViewTarget = 0.3,
    outViewTarget = 1.5,
    outViewMaxDefer = 4,
    borderRebuildGap = 5,   -- s a tile waits when only its border rule changed (neighbour mesh);
                            -- most freeze first and keep a 1.5 cm step at that edge (not seen)
    farLod = 3,             -- vehicles without an active ring run reports at 1/farLod rate
    -- ring vehicles further than this from the camera report at half rate (their ruts
    -- stay continuous: each report sweeps the tyre from the last one)
    lodNearDist = 40,
    frozenLimit = 1500,     -- LRU limit of frozen rutted tiles
    streamInterval = 0.2,   -- seconds between tile streaming passes to the vehicles
    maxTilesPerStream = 12,
  },
  sectors = {
    -- 4x4 tiles = 20 m sectors: a sector re-mesh is one createMesh of the whole sector
    -- (~1.3 ms per 700 vertices in game), so smaller sectors keep the spikes small
    tiles = 4,
    -- 300 m loaded ~1000 sector objects: the shadow pass culls every one of them in each
    -- cascade (about 1.9 us per object per frame measured: +1.7 ms with 900 objects,
    -- though they cast no shadow). The lowered terrain (0.2-0.35 m) beyond 100 m does
    -- not show.
    loadRadius = 70,
    vehLoadRadius = 20,     -- m round vehicles (look-ahead points); the camera keeps loadRadius
    cacheMax = 600,         -- sectors kept hidden after leaving the radius (no rebuild on return)
    urgentBatch = 0.25,     -- s an urgent sector rebuild waits to take in more fresh ruts
    unloadMargin = 40,
    buildBudgetMs = 2.0,
    catchUpBudgetMs = 3.0,  -- budget per frame while a sector near a vehicle is unbuilt (hole) or urgent (hidden ruts)
    nearRadius = 40,        -- m: sectors this close to a vehicle or look-ahead point rebuild first
    syncRadius = 90,        -- built synchronously at level start
    drop = 0.015,           -- sectors sit 1.5 cm lower than active tiles (no z-fighting)
    refreshInterval = 0.25,
    minRebuildGap = 1.0,    -- s between rebuilds of one sector (batches changes)
    frozenCellStride = 2,   -- left-behind ruts drawn on a 2-cell (40 cm) grid
  },
  stamp = {
    -- second in-game pass: 0.35 flow-back, a 2-cell rim and wide berms made the ruts
    -- too soft and wide; these values sit between that and the first, too-stiff set
    flowBack = 0.22,        -- share of a carved rut that flows straight back
    bermFraction = 0.4,     -- share of displaced mud that ends in the berms (rest compacts)
    bermWidthFactor = 0.6,  -- berm band width as a fraction of tyre width
    bermMax = 0.1,          -- berm cap above the rest surface (m)
    rimCells = 1,           -- soft rim width in cells beside the tyre (cosine falloff)
    rimDepth = 0.45,        -- how far the rim sags towards the tyre edge (0..1)
    maxSlope = 1.2,         -- steepest wall wet mud holds (rise/run, about 50 degrees)
    slumpRate = 0.35,       -- share of the excess slope removed per pass
    slumpPasses = 1,        -- slope-limit passes over each stamped area
    relaxHz = 5,            -- settling updates per second
    relaxTime = 3,          -- seconds for a fresh rut to settle most of the way
    instantSettle = true,   -- ruts written at their settled depth (no settling pass, no extra uploads)
    relaxWindow = 1.0,      -- s after the last stamp: settling then snaps to its end shape
    relaxKeep = 0.75,       -- share of the deepest rut that stays after settling
    relaxKeepBerm = 0.8,    -- share of the highest berm that stays after settling
    shoulderFactor = 0.25,  -- tyre shoulder radius as a fraction of tyre width
    maxSweep = 3.0,         -- longer jumps between reports are treated as teleports (m)
    bodyRadius = 0.16,      -- dent radius under a chassis node (m)
    bodySkin = 0.03,        -- dent bottom below the node centre (m)
    bodyBermWidth = 0.12,
    bodyBermFraction = 0.3,
    trackBase = 0.25,       -- base track intensity of any carve
    trackSpinGain = 0.08,   -- per m/s of wheel spin
    trackDepthGain = 2.0,   -- per m of immersion
    -- Spinning tyres dig: each report lowers the mud under the tread by
    -- spinDigRate * wheel spin (m/s) * report time, scaled by the wheel load against
    -- refWheelLoad (a heavier vehicle digs faster), down to at most spinDigMax below the
    -- tyre bottom (also load scaled) and never below the floor.
    spinDigRate = 0.012,    -- m of dig per (m/s of spin * s)
    spinDigMax = 0.12,      -- m below the tyre bottom at refWheelLoad
    refWheelLoad = 3500,    -- N per wheel (about a 1400 kg car on 4 wheels)
    jitterZ = 0.015,        -- clumpy vertical jitter at full track intensity (m)
    jitterXY = 0.03,        -- horizontal jitter at full track intensity (m)
    -- Per soft-ground kind (the kind of the terrain square under the hub; values missing
    -- here fall back to the ones above). Sources: research notes in docs/REFERENCE.md.
    --  bermFraction: share of the displaced mud pushed into berms (Poisson-like ratio,
    --    Alvarado et al. 2022: sand ~0.5, wet clay ~0.35); bermDepthRef > 0: the share
    --    grows with rut depth (x depth / bermDepthRef, clamped 0.4..1.6): bulldozing in
    --    frictional soil grows with depth squared, so sand berms grow with deep ruts
    --  maxSlope: steepest wall (rise/run) before it slumps: dry sand ~35 deg (0.7,
    --    Sumner 1999 25 deg, SCM default 40 deg), wet mud ~58 deg (1.6, Sumner 63 deg)
    --  soilN: Bekker sinkage exponent n (clay 0.5, sandy loam 0.7, dry sand 1.1), see soil
    --  soften: mud softens with passes (MudRunner): allowed depth x (1 + soften x (passes-1))
    --  slipBeta: slip sinkage, the tyre carves beta x s / (s + 0.2) x its immersion deeper
    --    (s = slip ratio; Reece 1965: strong in sand, weak in clay; values to tune)
    --  spinDig: factor on spinDigRate / spinDigMax
    kinds = {
      mud = { bermFraction = 0.35, maxSlope = 1.6, soilN = 0.5, soften = 0.1, slipBeta = 0.2, spinDig = 0.8 },
      sand = { bermFraction = 0.5, maxSlope = 0.7, bermDepthRef = 0.1, soilN = 1.1, soften = 0, slipBeta = 1.0, spinDig = 1.4 },
    },
    -- Soil memory (Bekker multi-pass rule, Chrono SCM yield memory): a cell remembers how
    -- many tyre passes it took and how deep the first one went (z1). Pass N may carve down
    -- to z1 x N^(2 / (2n + 1)) (x the soften factor), not straight to the tyre bottom:
    -- after 4 identical axles ~4x z1 in clay, ~2.4x in dry sand, so sand packs and stops
    -- deepening while mud keeps giving. A tyre sinking further than that rides a little
    -- into the drawn surface (as vanilla BeamNG mud looks). The hard floor caps it all.
    -- A pass = one wheel crossing the cell; the same wheel again after passGap s counts as
    -- a new pass. Spin digging is not limited (it is the same pass).
    soil = { enabled = true, passGap = 0.6 },
  },
  report = {
    -- wheel/body reports per second; swept stamps keep ruts continuous. 30 Hz cost 38 ms
    -- per second of GE Lua with 6 trucks digging (stress test); 15 Hz (one analytic sweep
    -- per report, 0.74 m at 40 km/h) kept the same rut lag as 20 Hz with 7 trucks
    rateHz = 15,
    maxBodyNodes = 48,
    waterHz = 5,            -- tyre-in-water checks per second
    boxHz = 10,             -- footprint box updates per second
    candidateHz = 10,       -- how often chassis nodes near the mud are looked up
    candidateMargin = 0.15, -- chassis nodes this far above the mud surface are watched
    maxCandidates = 48,     -- chassis nodes watched at most (the deepest win)
  },
  -- Dual wheels: one physics wheel carrying two tyres side by side. The tyre layout comes
  -- from the tyre meshes on the wheel's axle; without them a wheel wider than
  -- autoRatio x its radius is split into two tyres gap apart. Each tyre cuts its own rut,
  -- with a low ridge of squeezed mud between them, and carries its own mud.
  dually = {
    enabled = true,
    autoRatio = 1.05,
    gap = 0.04,
    ridge = 0.6,            -- ridge between the tyres as a share of the tyre shoulder radius
  },
  clods = {
    enabled = true,
    -- clod texture: BeamNG's decal-road mud set
    texDir = '/assets/materials/decalroad/mud/mud_large/',
    texBase = 't_mud_large',
    coatMax = 3.0,          -- 0..1: how much of the tyre is covered; 1..coatMax: how thick it cakes
    -- Build-up: mud is picked up per metre the tread rolls through it (spin counts: a
    -- spinning tyre churns more mud onto itself), more in deeper mud, and the coat
    -- saturates (each layer sticks less well than the one under it).
    buildPerMeter = 0.03,
    buildSpinGain = 0.5,    -- extra pick-up share per m/s of wheel spin (capped at x3)
    -- The outer layer of the coat is loose (looseShare of it, while in mud): after
    -- leaving the mud it falls off over the first metres (looseShedPerMeter), and a fast
    -- tyre flings it off (flingSpeed); the rest packs down within packTime and only
    -- wears off slowly (cleanPerMeter: ~500 m for a packed tread).
    looseShare = 0.55,
    packTime = 6,
    looseShedPerMeter = 0.03,
    cleanDelay = 2.0,       -- s out of the mud before anything falls off
    cleanPerMeter = 0.002,  -- per metre, times the coat below 1 (a thin residue lasts)
    -- Colour: mud of another kind mixes in by the share it adds to the coat (a thick
    -- cake changes colour slowly); colorMix x picked-up coat / clamp(coat, 0.1, 1.5)
    -- per frame, the material is updated once the colour moved colorStep.
    colorMix = 3,
    colorStep = 0.03,
    -- Fling: above flingSpeed (tyre surface m/s) the loose layer leaves with a time
    -- constant 1 / (flingRate x (speed - flingSpeed)) s: ~1 s at 30 mph, so a tyre in
    -- deep mud at speed keeps a packed tread and sprays the rest as chunks. The packed
    -- layer only goes above flingPackedSpeed (flingPackedRate per s and m/s).
    flingSpeed = 6.0,
    flingRate = 0.12,
    flingPackedSpeed = 18.0,
    flingPackedRate = 0.01,
    washRate = 0.2,         -- packed coat washed off per second with the tyre fully in water
    washSpeedGain = 0.05,   -- extra wash per m/s of tyre surface speed in water
    washLooseFactor = 3,    -- the loose layer washes this much faster
    -- Wet tyres (water from the vehicle: share of tread nodes under water): wetness goes
    -- up to that share at wetRate per s and dries over dryTime s (x (1 + speed /
    -- drySpeedRef): airflow). The coat material then gets roughness wetRoughness and
    -- wetDarken darker colour, and the tyre a water film (wheelMud: a translucent dark
    -- glossy layer filmLift over the whole tyre, opacity filmOpacity x wetness,
    -- roughness filmRoughness). BeamNG PBR: roughness 0 = mirror, 1 = matte, so wet =
    -- lower roughness.
    coatHz = 20,            -- coat bookkeeping rate per vehicle
    wetRate = 3,
    dryTime = 45,
    drySpeedRef = 8,
    wetRoughness = 0.22,
    wetDarken = 0.25,
    wetStep = 0.1,          -- wetness change that triggers a material update
    wetFilm = true,
    -- the film is muddy water: colour = ground colour of the wheel's last soft ground x
    -- filmMud (filmColor grey where unknown), streaked by art/deepnode/t_tyrefilm_*
    filmOpacity = 0.4,
    filmRoughness = 0.05,
    filmColor = 0.03,
    filmMud = 0.5,
    filmLift = 0.0015,
    -- x factors on the whole build-up and on every loss (GUI "Mud build-up" / "Mud wear-off")
    buildRate = 1,
    wearRate = 1,
    -- the visual tyre is surfaceOffset x radius outside the tread nodes (tyre meshes are
    -- a little bigger than the physics tyre)
    surfaceOffset = 0.04,
    -- Tyre skin (wheelMud): one mesh per wheel, built once; the material's alpha clip
    -- shows coverage = coverMax x min(1, coat)^coverExp of it (per pixel, t_tyremud_*).
    coverMax = 0.92,        -- covered share at coat 1 (the rest up to coatMax)
    coverExp = 1.1,
    flushWait = 0.25,       -- s: a waiting material update goes ahead even over budget
    flushGap = 0.4,         -- s between two material updates of one wheel (x3 far away)
    segLen = 0.06,          -- m between skin steps round the tyre
    maxSegments = 112,
    thickness = 0.012,      -- m: cake where the mud sticks first (thinner at blotch edges)
    thicknessMax = 0.035,   -- m added at coatMax (skin scaled outwards)
    lift = 0.003,           -- m: skin base over the tyre surface
    widthScale = 1.12,      -- visual / jbeam tyre width when the tyre mesh gives none
    tyreBrightness = 1,     -- factor on the kind colour (tyre skin and chunks)
    flushPerFrame = 2,      -- material updates (alphaRef + flush, ~0.5 ms) per frame at most
    refStepNear = 8,        -- alphaRef change that triggers an update near the camera (of 254)
    refStepFar = 24,        -- beyond lodNearDist
    lodNearDist = 20,
    drawDist = 150,         -- tyres further from the camera hide their mud and chunks
    -- Chunks: pooled lump meshes that drop off when loose mud sheds or is flung.
    chunkRate = 10,         -- chunks per unit of coat dropped (per wheel)
    chunkMax = 24,          -- chunks alive at once (pool size per kind)
    chunkLife = 3,          -- s on the ground before they are gone (last 40 %: sink and shrink)
    chunkSize = 0.035,      -- m base size (+ cake thickness)
    chunkFling = 0.5,       -- share of the tyre surface speed they leave with
    roughness = 0.35,
    -- Colour of the coat: the terrain colour under the wheel (base map + macro/detail
    -- mean, see P.initGroundColors) divided by the mean of the kind's tyre texture, times
    -- the kind's groundGain (default: its `wet`), moved groundDesat towards grey;
    -- `color`/`brightness`/tyreBrightness then only apply where the ground colour is
    -- unknown (no layer texture, zones). groundGrid: base map cells a side.
    groundColor = true,
    groundGrid = 128,
    -- Per soft-ground kind (the softMatch text found in the layer; zones are mud).
    -- Lumps use the textures of the layer they were picked up from, times `wet`.
    -- stick: pick-up factor; coatMax: highest coat (1 = no clumps); shed: loose/clean
    -- factor; wet: colour factor on the layer texture (wet mud is darker); roughness:
    -- lump roughness; size: lump size factor; color: colour factor of the generic lump
    -- texture, used where a layer has no texture.
    kinds = {
      -- color: factor on the monochrome tyre mud texture (mean grey 0.72)
      -- mud: own procedural textures (tools/tyre_textures/bake_tyremud.py, shipped as DDS
      -- by tools/dev/tyre_dds.py): a smooth clay coat,
      -- tread first, then the shoulders and the sidewalls down to the rim; groundGain 2:
      -- mud drying on a tyre is lighter than the wet ground (gridmap_v2: the ground colour
      -- alone read near black next to the rubber in the truck's shadow)
      mud = { stick = 1.0, coatMax = 3.0, shed = 1.0, wet = 0.85, roughness = 0.6, size = 1.0,
              color = { 0.55, 0.45, 0.35 }, texN = '/art/deepnode/tyre/t_tyremud_nm.normal.dds',
              groundGain = 2.0, texMean = 0.4767 },
      -- sand: own fine-grain tyre textures (tools/tyre_textures/bake_tyresand.py): packs into
      -- the tread, dusts the sidewalls; no caking (coatMax 1), falls off fast (shed)
      -- thickness / coverMax: per kind over the clods values (sand: a thin film in the
      -- tread grooves and a dusting down the sidewalls, not a cake); treadInset: skin
      -- below the lug tops (wheelMud buildMesh); groundGain / groundDesat: see groundColor
      sand = { stick = 0.9, coatMax = 1.0, shed = 2.0, wet = 0.88, roughness = 0.9, size = 0.6, looseShare = 0.4, brightness = 1.45,
               color = { 1.0, 0.88, 0.68 }, thickness = 0.003, coverMax = 0.62, treadInset = 0.010,
               groundGain = 1.3, groundDesat = 0.3,
               texB = '/art/deepnode/tyre/t_tyresand_b.color.dds', texO = '/art/deepnode/tyre/t_tyresand_o.data.dds',
               texN = '/art/deepnode/tyre/t_tyresand_nm.normal.dds', texMean = 0.4489 },
    },
  },
  memory = {
    gcStepKB = 0,           -- >0: one incremental Lua GC step of this size per frame (steadier heap)
  },
  debug = {
    chunks = false,         -- draw chunk borders (GUI checkbox)
    tiles = true,           -- outline layers drawn while chunks is on
    sectors = true,
    boxes = true,
    drawRadius = 80,        -- m around the camera
    lift = 0.12,            -- lines float this high over the mud surface
  },
  camera = {
    enabled = true,
    maxDist = 60,
    step = 0.25,
    maxIter = 300,
  },
  materials = {
    flipV = true,
    useDetail = true,
    -- second layer for the terrain's macro texture (see createLayerMaterials)
    macro = true,
    detailStrength = 1.0,
    defaultDetailSize = 2,     -- detail texture size (m) when the terrain material gives none
    -- Measured in game on hw550 (same view, mod off vs on, average ground colour): the
    -- terrain shader reads the base map as linear data, like an object material reading
    -- the original file. An sRGB copy came out darker and yellower (85,81,58 against
    -- vanilla 108,106,99), the original file only a little brighter (122,121,118).
    -- So no copy by default; 'copy' / 'link' stay available for levels that need them.
    -- Chunk materials now follow spinMud: sRGB copy of the base map, no tint, the layer's
    -- own roughness map and detail strengths, base UVs per layer (see baseSizeFrom).
    -- The old measured look: srgbMethod 'off', tint 0.77/0.76/0.73, roughness 0.92.
    srgbMethod = 'copy',       -- 'off', 'copy' (then link if the copy fails), or 'link'
    -- the terrain adds macro/detail overlays and its own lighting; 0.77/0.76/0.73 brought
    -- the patch to within ~2 % of vanilla ground colour in the same measurement
    tint = { 1, 1, 1 },
    -- the terrain roughness map reads as glossy on an object material (the patch looked
    -- like wet water); a fixed matte value matches the terrain's look
    roughness = -1,            -- >= 0 overrides the patch roughness (no roughness map then)
    -- 'layer' (spinMud): base UVs span the layer's baseColorBaseTexSize; a layer with only a
    -- detail texture tiles that texture every baseColorDetailTexSize metres.
    -- 'terrain': base UVs span the terrain world size (old deepnode mapping).
    baseSizeFrom = 'layer',
    defaultDetailStrength = 0.5,       -- when the layer gives no baseColorDetailStrength
    defaultNormalDetailStrength = 0.8, -- when the layer gives no normalDetailStrength
    fallbackTexSize = 4,               -- metres per repeat of the fallback material
  },
  -- Idle reset per chunk: a frozen rut tile (outside every vehicle's active ring) that
  -- nobody has dug or driven near for idleSeconds (simulation time, a paused game does
  -- not count) is released, so its ruts go back to the untouched surface. Ruts near a
  -- vehicle are never touched. Keeps rut meshes and memory small. 0 = off.
  reset = {
    idleSeconds = 120,
  },
  -- Physics (deepnode_physics). 'vanilla': BeamNG's own ground models, the terrain under
  -- the mud is lowered by the full sink depth. 'heavy': still the engine's own physics,
  -- but the soft ground models are made thicker (deeper soft layer, more viscous: mud
  -- slows a truck to ~30 km/h, sand ~13 % slower than vanilla), and the hard floor under
  -- undisturbed mud is floorLift higher; where ruts are dug the terrain is lowered under
  -- them, so rut walls are real terrain the tyres have to climb (4WD, diff locks and low
  -- range work as in vanilla). Changing the mode restarts the mod (new sink pass).
  physics = {
    mode = 'heavy',
    heavy = {
      -- ground model values per soft kind (absolute, see art/groundmodels.json fields)
      groundModels = {
        mud = { defaultDepth = 0.2, flowConsistencyIndex = 17000, fluidDensity = 20000,
          staticFrictionCoefficient = 0.35, slidingFrictionCoefficient = 0.32 },
        sand = { defaultDepth = 0.14, flowConsistencyIndex = 7500, fluidDensity = 30000 },
      },
      -- m the hard floor starts above the vanilla sink (>= the sink depth: terrain-first, the
      -- terrain draws undug ground). Sand too since 2026-10-31: same truck times through the
      -- gridmap_v2 sand pit (5.9 / 9.1 / 11.8 s to 30 / 60 / 90 m), same fps, engine memory
      -- per 4 runs 15.9 -> 4.9 MB (the floor follows the dug ruts, as for mud)
      floorLift = { mud = 0.3, sand = 0.3 },
      floorReach = 0.3,    -- squares round a terrain vertex whose ruts lower it
      floorMargin = 0.03,  -- m the terrain stays under the rut surface (hidden by the mesh)
      floorHz = 5,         -- rut floor recomputes per second
      floorMaxVerts = 600, -- terrain vertices written per frame at most
      raiseClear = 8,      -- m: terrain is raised back (rut reset) only this far from vehicles
      -- rut walls of the mud mesh push the tyres (P.rutGuide): lateral force = -gain x
      -- wheel load x relief slope across the tyre (|slope| <= maxSlope), sampled over the
      -- tyre width + edge on each side
      rutGuide = { enabled = true, gain = 1.0, maxSlope = 1.0, edge = 0.05 },
    },
  },
  -- Frame-rate governor. All mesh uploads of a frame (tiles, sectors, tyre mud) share an
  -- upload budget in ms (tileMesh.canUpload). Once a second the budget shrinks when the
  -- game ran below targetFps and grows back slowly when it ran at the cap.
  perf = {
    targetFps = 70,         -- capped at 88 % of the best second seen (slower PCs)
    uploadMsStart = 3,
    -- mesh uploads only every uploadEvery-th frame (with that many frames' budget): each
    -- frame with uploads also costs engine time outside createMesh. 8 trucks, gridmap_v2:
    -- 1: 55.0 fps low1 43 rut lag 0.55 s; 3: 56.7 / 47.4 / 0.63 s; 6: 57.3 / 49.8 / 0.98 s
    uploadEvery = 3,
    uploadMsMin = 1.2,      -- floor: below it ruts lag (0.6: 0.7 s near, 1.9 s far with 8 trucks)
    uploadMsMax = 4,
  },
  render = {
    disableSSS = true,
  },
  pool = {
    initial = 200,
    growStep = 16,
    -- How a chunk gets new geometry. The new mesh always goes to a hidden object that is
    -- shown at once, and the old one is hidden on the next frame (replacing the visible
    -- object's geometry in place made the chunk vanish for a frame: flicker).
    -- 'pair': each chunk alternates between two objects of its own (the old one becomes
    --   its spare); 'swap': a fresh object from the shared pool each time.
    mode = 'pair',
    -- frames the replaced object stays visible after its replacement was uploaded
    -- (1 left the chunk undrawn in some frames: the lowered terrain and the lifted grass
    -- showed through for a frame while chunks rebuilt)
    hideFrames = 3,
    -- mesh size classes (tileMesh padMeshes): engine memory grows per distinct mesh
    -- size, createMesh time per padded corner
    tileClasses = 6,
    decalMinCorners = 96,
  },
  gui = {
    openOnStart = true,
  },
  -- Screen-space ground and tyre look (deepnode_overlay, experimental): tyre prints are
  -- painted on the GPU into a world-space map around the camera and drawn over the lit scene
  -- (tread relief, granular crumbs on the berms, wet churned colour, sun highlight; mud carried
  -- onto hard ground by coated tyres); wet tyres drawn darker and glossy. No mesh uploads; the
  -- rut shape still comes from the mud meshes.
  overlay = {
    enabled = false,
    mapSize = 2048,         -- texels per side of the rut map
    span = 128,             -- m covered by the map (6.25 cm texels at 2048)
    recentreMargin = 24,    -- m: the map follows the camera when it gets this close to an edge (prints are lost)
    segmentsPerFrame = 16,  -- prints painted per frame (shader limit 16)
    queueMax = 512,
    mergeMax = 3,           -- m: a wheel's waiting print segment is extended up to this length
    edge = 0.03,            -- m soft print edge
    strength = 1.0,
    -- the print has no tread pattern (any wheel, small or big): smear streaks along the
    -- track, irregular stick-slip ripples across it, a lip squeezed up at the edges
    phasePerMetre = 4,      -- along-track coordinate scale (pattern repeats every 64 / this m)
    streaks = 0.65,         -- streak share of the relief (the rest: ripples)
    pressDepth = 0.025,     -- m: depth of the print relief
    lip = 0.8,              -- edge lip height, x pressDepth
    grooveDark = 0.4,       -- darkening of the deepest pressed parts
    ambient = 0.45,         -- ambient share in the relight ratio
    highlight = 1.0,        -- sun highlight on wet ground
    useShadowMask = true,   -- engine screen shadow mask (#sunShadowMask): no relief / highlight in shadow
    groundAlbedo = 0.3,     -- ground albedo guess: light level for the sun highlight = scene / this
    fadeStart = 35,         -- m from the camera
    fadeLength = 25,
    zTolerance = 0.35,      -- m: pixels this far above the undisturbed ground are left alone (vehicles)
    bermZTolerance = 0.5,   -- m: the same over a berm (berms stand above the ground)
    maxDepth = 1.2,         -- m: deepest rut floor below the undisturbed ground that is drawn
    -- puddles in mud ruts: water fills ruts deeper than puddleDepth below the undisturbed ground
    -- (patchy level, lower when puddles < 1), murk = how opaque the muddy water is
    puddles = 0.7,
    puddleDepth = 0.1,
    puddleMurk = 0.7,
    minNormalZ = 0.45,      -- ground steeper than this fades out (geometric slope from depth)
    bermReach = { mud = 2.4, sand = 2.6 }, -- berm band beside the print, x tyre half width
    -- per soft kind: wet darkening, saturation gain, wetness (0..1), crumb density on the berms
    mud = { darken = 0.5, saturate = 0.35, wet = 0.9, bermCrumbs = 0.75, crumbLift = 0.12 },
    sand = { darken = 0.15, saturate = 0.05, wet = 0.35, bermCrumbs = 0.35, relief = 0.45, crumbHeight = 0.3,
             crumbLift = 0.25 },
    grain = { size = 0.05, height = 1.2, printDensity = 0.15, churnSize = 0.35 }, -- crumb size m, height x size
    -- mud a coated tyre leaves on hard ground: tread-shaped stains while coat >= minCoat,
    -- strength coat x perCoat, one print every step m, starting afterSoft s off the soft ground;
    -- the stain tints the lit ground by color (hue) x gain (brightness)
    carry = { enabled = true, color = { 0.16, 0.12, 0.085 }, gain = 0.5, opacity = 0.85, minCoat = 0.08,
              perCoat = 1.2, step = 0.12, afterSoft = 0.3 },
    dust = { color = { 0.5, 0.45, 0.36 }, gain = 1.35, opacity = 0.45 }, -- sand carried onto hard ground
    -- tracks on hard terrain (no deformation): a clean wheel on a terrain material whose name
    -- contains one of the grass / dirt parts leaves a flattened grass or compacted dirt track
    -- (one print every step m, only within maxGap m of the terrain: not on road meshes)
    tracks = { enabled = true, step = 0.15, maxGap = 0.25, relief = 0.4,
               grass = { 'grass', 'meadow', 'field', 'lawn', 'moss', 'weed' },
               dirt = { 'dirt', 'gravel', 'soil', 'ground', 'forest', 'trail', 'track', 'mud', 'sand' },
               grassDarken = 0.22, grassDesat = 0.25, dirtDarken = 0.12 },
    -- wet tracks: a tyre wet from water (wetness >= minWet) leaves dark glossy prints on hard
    -- ground (strength wetness x perWet) that dry out over dryTime s (< 60, the map keeps the
    -- paint time mod 64 s)
    wetTracks = { enabled = true, minWet = 0.15, perWet = 1.3, dryTime = 55, darken = 0.35 },
    -- mud splats thrown by wheels spinning in mud (slip above minSpin m/s): perSpin splats per s
    -- per m/s of slip (at most maxPerSec), landing up to reach m behind the wheel (full reach at
    -- fullSpin m/s), radius sizeMin..sizeMax m; tinted like the carried mud
    splats = { enabled = true, minSpin = 0.8, perSpin = 1.2, maxPerSec = 6, reach = 3, fullSpin = 6,
               sizeMin = 0.08, sizeMax = 0.3, color = { 0.12, 0.105, 0.09 }, gain = 0.45, opacity = 0.85 },
    -- wet tyres (screen-space): wheels within tyreRange m, nearest tyreMaxWheels (shader limit 16)
    tyres = true,
    tyreRange = 40,
    tyreMaxWheels = 16,
    tyreWetDarken = 0.35,
    tyreAlbedo = 0.06,      -- tyre albedo guess: light level for highlight / coat = scene / this
    tyreHighlight = 1.0,
    tyreMudWet = 0.7,       -- wetness of a fresh mud coat
    tyreMudDry = 25,        -- s: a mud coat's sheen fades after leaving the mud
    tyreCoat = false,       -- draw the tyre mud coat in the shader too (tyre mud meshes stay)
    tyreCoatLump = 0.03,    -- m lump size of that coat
    debug = 0,              -- 1 sun term, 2 coverage (red print, blue berm, green carried), 3 shadow mask,
                            -- 5 tyre pixels
  },
}

function P.isArray(t)
  return type(t) == 'table' and (t[1] ~= nil or next(t) == nil)
end

function P.copy(v)
  if type(v) ~= 'table' then return v end
  local r = {}
  for k, x in pairs(v) do r[k] = P.copy(x) end
  return r
end

function P.mergeConfig(dst, src)
  for k, v in pairs(src) do
    if type(v) == 'table' and next(v) == nil and type(dst[k]) == 'table' and not P.isArray(dst[k]) then
      -- an empty section ({} reads as an empty array) must not wipe the defaults
    elseif type(v) == 'table' and not P.isArray(v) and type(dst[k]) == 'table' and not P.isArray(dst[k]) then
      P.mergeConfig(dst[k], v)
    else
      dst[k] = P.copy(v)
    end
  end
  return dst
end
M.mergeConfig = P.mergeConfig

local cfg = P.copy(defaults)
M.cfg = cfg

-- GUI changes live in their own file (user folder), merged over config.json, so the
-- mod's config.json stays the reference and "Defaults" only has to delete this file.
P.GUI_CFG = '/settings/deepnode/gui.json'

function P.loadConfig()
  local c = P.copy(defaults)
  local file = jsonReadFile and jsonReadFile('/settings/deepnode/config.json')
  if type(file) == 'table' then P.mergeConfig(c, file) end
  local g = jsonReadFile and FS and FS:fileExists(P.GUI_CFG) and jsonReadFile(P.GUI_CFG)
  if type(g) == 'table' then
    -- the GUI owns only the kind colours: older gui.json files saved whole kinds (with
    -- texture paths from before the rename), which pinned them over config.json
    local ks = type(g.clods) == 'table' and g.clods.kinds
    if type(ks) == 'table' then
      for k, K in pairs(ks) do
        ks[k] = type(K) == 'table' and type(K.color) == 'table' and { color = K.color } or nil
      end
    end
    P.mergeConfig(c, g)
  end
  cfg = c
  M.cfg = c
  return c
end
M.loadConfig = P.loadConfig

-- tbl: nested table of the values the GUI owns ({ring = {boxMargin = 4}, ...})
function M.saveGuiConfig(tbl)
  if jsonWriteFile then jsonWriteFile(P.GUI_CFG, tbl, true) end
end

-- drop the GUI file and go back to config.json (restarts when running)
function M.resetGuiConfig()
  if FS and FS:fileExists(P.GUI_CFG) then FS:removeFile(P.GUI_CFG) end
  P.debugChunksOverride = nil
  -- M.isRunning: the `running` local is declared further down this file
  if M.isRunning() then P.stop(true); P.start() else P.loadConfig() end
end

-------------------------------------------------------------------------------
-- state
-------------------------------------------------------------------------------
local running = false
P.startRequested = false
P.session = 0
local simTime = 0
P.levelName = nil

local ter = nil            -- terrain info, see initTerrain
M.ter = nil
local rows = nil           -- layer map rows (Lua strings, file order)
local flipRows = false
local engineFallback = false
P.orientation = 'none'
local f2e = ffi.new('uint8_t[256]')
local layerSoft = ffi.new('uint8_t[256]')
local layerDepth = ffi.new('float[256]')
local layers = {}
local dist = nil           -- uint8 [S*S]: Chebyshev distance to a non-soft vertex, capped
local distCap = 4
local featherVerts = 3
local edgeDip = 0.04
local engineCache = nil    -- fallback: uint8 [S*S] layer map read from the engine
local zones = {}
local zoneBox = nil
P.zoneMat = 255
P.memberPad = 1.5

P.sinkIdx = nil
P.sinkRaw = nil
P.sinkCount = 0
P.sinkCapacity = 0
P.shortfall = {}
P.sinkBox = nil
local sinkApplied = false
P.loweredSectors = {}

local TS, CPS, N, CELL, TILE = 5, 5, 25, 0.2, 5
local SEC = 6
local bermMax = 0.12
P.baseSize = 1024

local tiles = {}
M.tiles = tiles
P.emptyTiles = {}
P.frozenCount = 0
P.activeCount = 0
P.frozenPerSector = {}
P.changedTiles = {}
P.floorTiles = {} -- tile key -> 'lower' (ruts dug) or 'reset' (ruts gone): heavy rut floor to redo
P.liftOn = false

P.vehs = {}
P.matNames = {}
P.ownedMaterials = {}
P.FALLBACK_MAT = 'deepnode_fallback'
P.preloadObj = nil
P.preloadTimer = 0

P.origCast = nil
P.castWrapper = nil
P.castActive = false
P.sssSaved = nil

P.stats = {
  layerMapMs = 0, distMs = 0, sinkMs = 0, materialsMs = 0, syncSectorsMs = 0, startMs = 0,
  sunkVertices = 0, orientation = 'none', lastFrameMs = 0, maxFrameMs = 0, maxFrameAge = 0,
  slowCalls = 0, prepared = 0, stamps = 0, skippedSmall = 0, rays = 0, rayHits = 0, lastError = '',
}
M.statsTable = P.stats

P.mods = {}  -- other deepnode extensions

function P.mod(name)
  return extensions and extensions['deepnode_' .. name] or P.mods[name]
end
M.setModuleForTests = function(name, m) P.mods[name] = m end

-------------------------------------------------------------------------------
-- small helpers shared with other modules
-------------------------------------------------------------------------------
function M.tileKey(tx, ty) return ty * KEY + tx end
function M.sectorKeyOfTile(tx, ty) return floor(ty / SEC) * KEY + floor(tx / SEC) end
function M.isRunning() return running end
-- the terrain is always lowered under the mud (sink): kept for the other modules
function M.isSink() return true end
function M.getMode() return 'sink' end
function M.simTime() return simTime end
M.KEY = KEY

function P.sectorKeyOfTile(tx, ty) return floor(ty / SEC) * KEY + floor(tx / SEC) end

-- terrain-vertex world z (pitfall 1: getHeightGrid may be local or world)
local function gridZ(gx, gy)
  local h = ter.tb:getHeightGrid(gx, gy)
  if ter.localZ then return h + ter.oz end
  return h
end

-- UVs of layer m (spinMud mapping): terrain-space base UVs for a layer with a base map
-- (same as the terrain shader), world-tiled every uvSize metres otherwise (detail-only
-- layer, fallback material). m nil: the old single terrain-wide mapping.
P.matUV = {}  -- [layer idx] = { size, base }
function M.uvOf(x, y, m)
  local e = m and P.matUV[m]
  if not e then
    if m and not P.matNames[m] then
      local s = cfg.materials.fallbackTexSize or 4
      return x / s, y / s
    end
    e = { size = P.baseSize, base = true }
  end
  if not e.base then return x / e.size, y / e.size end
  local u = (x - ter.ox) / e.size
  local v = (y - ter.oy) / e.size
  if cfg.materials.flipV then v = 1 - v end
  return u, v
end

function M.matName(m)
  return P.matNames[m] or P.FALLBACK_MAT
end

-- rut code: 0 = floor, 128 = rest surface, 255 = rest + bermMax
-- One branch (min compiles branch-free): side traces off the old three-way branch failed
-- in LuaJIT ("register coalescing too complex", jit.v, thousands per bench run).
local function decodeZ(t, idx)
  local c = t.rut[idx]
  local r = t.rest[idx]
  if c <= 128 then
    local f = min(t.floor[idx], r)
    return f + (r - f) * c * 0.0078125
  end
  return r + (c - 128) / 127 * bermMax
end
M.decodeZ = decodeZ

local function encodeZ(t, idx, z)
  local r = t.rest[idx]
  if z >= r then
    local c = 128 + floor((z - r) / bermMax * 127 + 0.5)
    return c > 255 and 255 or c
  end
  local f = t.floor[idx]
  if f > r then f = r end
  local span = r - f
  if span < 1e-4 then return 128 end
  local c = floor((z - f) / span * 128 + 0.5)
  if c < 0 then c = 0 elseif c > 128 then c = 128 end
  return c
end
M.encodeZ = encodeZ

-------------------------------------------------------------------------------
-- terrain: layer map, layers, distance field, zones
-------------------------------------------------------------------------------
function P.lcg(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return s % n
  end
end

function P.engineMaterials(tb)
  local list = {}
  local ok, mats = pcall(function() return tb:getMaterials() end)
  if ok and type(mats) == 'table' and #mats > 0 then
    for i, m in ipairs(mats) do list[i - 1] = m end
    return list, #mats
  end
  local cnt = (tb.getMaterialCount and tb:getMaterialCount()) or 0
  for i = 0, cnt - 1 do list[i] = tb:getMaterial(i) end
  return list, cnt
end

function P.mtlName(m)
  local n = m.getInternalName and m:getInternalName() or m.internalName
  return tostring(n or '')
end

function P.mtlGm(m)
  local n = m.getGroundmodelName and m:getGroundmodelName() or m.groundmodelName
  return tostring(n or '')
end

function P.mtlField(m, name)
  local ok, v = pcall(function() return m:getField(name, 0) end)
  if not ok or v == nil then return '' end
  return tostring(v)
end

function P.firstNumber(s)
  return tonumber((tostring(s or ''):match('^%s*([%-%d%.eE]+)')))
end

function P.matchSoft(name, gm)
  local a, b = name:lower(), gm:lower()
  for _, s in ipairs(cfg.softMatch) do
    local p = tostring(s):lower()
    if p ~= '' and (a:find(p, 1, true) or b:find(p, 1, true)) then return p end
  end
  return nil
end

function P.refreshLayerDepths()
  for e = 0, 255 do layerSoft[e] = 0; layerDepth[e] = 0 end
  P.zoneMat = 255
  for e, L in pairs(layers) do
    if L.soft then
      layerSoft[e] = 1
      layerDepth[e] = L.sinkDepth
      if P.zoneMat == 255 or e < P.zoneMat then P.zoneMat = e end
    end
  end
end

-- Read the .ter file: u8 version, u32 size, u16 heights[size^2], u8 layers[size^2],
-- then (version 7+) u32 count + count * (u8 len, name). One Lua string per row: the
-- game's LuaJIT does not allow pointer arithmetic on file buffers.
function P.readLayerMap(fn)
  local f = io.open(fn, 'rb')
  if not f then return nil, 'cannot open ' .. tostring(fn) end
  local head = f:read(5)
  if not head or #head < 5 then f:close(); return nil, 'short header' end
  local version = byte(head, 1)
  local S = byte(head, 2) + byte(head, 3) * 256 + byte(head, 4) * 65536 + byte(head, 5) * 16777216
  if S < 2 or S > 16384 then f:close(); return nil, 'bad terrain size ' .. S end
  local skip = 2 * S * S
  local okSeek, pos = pcall(f.seek, f, 'set', 5 + skip)
  if not okSeek or pos ~= 5 + skip then
    f:close()
    f = io.open(fn, 'rb')
    if not f then return nil, 'reopen failed' end
    f:read(5)
    local left = skip
    while left > 0 do
      local n = min(left, 4194304)
      local s = f:read(n)
      if not s or #s < n then f:close(); return nil, 'short height block' end
      left = left - n
    end
  end
  local out = {}
  for r = 1, S do
    local s = f:read(S)
    if not s or #s < S then f:close(); return nil, 'short layer map' end
    out[r] = s
  end
  local names = nil
  local cs = f:read(4)
  if cs and #cs == 4 then
    local cnt = byte(cs, 1) + byte(cs, 2) * 256 + byte(cs, 3) * 65536 + byte(cs, 4) * 16777216
    if cnt > 0 and cnt < 256 then
      names = {}
      for i = 0, cnt - 1 do
        local l = f:read(1)
        if not l then break end
        local len = byte(l)
        names[i] = len > 0 and (f:read(len) or '') or ''
      end
    end
  end
  f:close()
  return { version = version, size = S, rows = out, names = names }
end
M.readLayerMap = P.readLayerMap

function P.layerAtEngine(gx, gy)
  return engineCache[gy * ter.size + gx]
end

-- Fallback when the .ter file cannot be read or its row order not verified: ask the
-- engine for every vertex once (about 0.3 us per vertex in game: ~5 s for 4096 x 4096).
-- The terrain is lowered over the whole map, so the whole map is needed.
function P.readEngineLayerMap()
  local S = ter.size
  local map = ffi.new('uint8_t[?]', S * S)
  local tb = ter.tb
  local v = vec3()
  local ox, oy, sq = ter.ox + 0.01, ter.oy + 0.01, ter.sq
  for gy = 0, S - 1 do
    local base = gy * S
    local y = oy + gy * sq
    for gx = 0, S - 1 do
      v:set(ox + gx * sq, y, 0)
      local e = tonumber(tb:getMaterialIdxWs(v)) or -1
      map[base + gx] = (e >= 0 and e < 255) and e or 255
    end
  end
  return map
end

local function layerAt(gx, gy)
  local S = ter.size
  if gx < 0 or gy < 0 or gx >= S or gy >= S then return 255 end
  if engineFallback then return P.layerAtEngine(gx, gy) end
  local row = flipRows and rows[S - gy] or rows[gy + 1]
  return f2e[byte(row, gx + 1)]
end
M.layerAt = layerAt

-- terrain material name at world (x, y) (nil off the terrain): the screen-space overlay picks
-- the track look on hard ground by it (grass, dirt / gravel)
function P.layerNameAt(x, y)
  if not ter then return nil end
  local L = layers[layerAt(floor((x - ter.ox) / ter.sq + 0.5), floor((y - ter.oy) / ter.sq + 0.5))]
  return L and L.name or nil
end

-- Compare the file rows with the engine on random vertices where the two row
-- orders disagree. Accept an order only with >= 90 % agreement.
function P.verifyOrientation()
  local S = ter.size
  local rnd = P.lcg(90210)
  local v = vec3()
  local disc, agreeD, agreeF, tries = 0, 0, 0, 0
  while disc < 300 and tries < 8000 do
    tries = tries + 1
    local gx = 1 + rnd(S - 2)
    local gy = 1 + rnd(S - 2)
    local d = f2e[byte(rows[gy + 1], gx + 1)]
    local fl = f2e[byte(rows[S - gy], gx + 1)]
    if d ~= fl then
      disc = disc + 1
      v:set(ter.ox + gx * ter.sq + 0.01, ter.oy + gy * ter.sq + 0.01, 0)
      local e = tonumber(ter.tb:getMaterialIdxWs(v)) or -1
      if e == d then agreeD = agreeD + 1 elseif e == fl then agreeF = agreeF + 1 end
    end
  end
  if disc < 20 then return 'direct', disc, agreeD, agreeF end
  if agreeD / disc >= 0.9 then return 'direct', disc, agreeD, agreeF end
  if agreeF / disc >= 0.9 then return 'flipped', disc, agreeD, agreeF end
  return 'engine', disc, agreeD, agreeF
end

-- Clear the soft mask under decal roads: rasterise every road's edge strip (left/right
-- edge positions, widened by roads.margin) into `d`, the initial soft mask of the
-- distance field. Returns road count and cleared soft vertices.
function P.carveRoads(d)
  local rc = cfg.roads
  if not rc or not rc.enabled then return 0, 0 end
  local names = scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad')
  if type(names) ~= 'table' then return 0, 0 end
  local S, sq, invSq, ox, oy = ter.size, ter.sq, ter.invSq, ter.ox, ter.oy
  local margin = max(0, tonumber(rc.margin) or 0)
  -- roads that are mud or sand themselves (mud furrows, tyre tracks, puddles) are part of
  -- the soft ground: skip them as well, else they would clear the mud they decorate
  local skip = {}
  for _, t in ipairs(rc.skipMatch or {}) do skip[#skip + 1] = t end
  for _, t in ipairs(cfg.softMatch or {}) do skip[#skip + 1] = t end
  local nRoads, nCleared = 0, 0
  local function inTri(px, py, x1, y1, x2, y2, x3, y3)
    local d1 = (px - x2) * (y1 - y2) - (x1 - x2) * (py - y2)
    local d2 = (px - x3) * (y2 - y3) - (x2 - x3) * (py - y3)
    local d3 = (px - x1) * (y3 - y1) - (x3 - x1) * (py - y1)
    local neg = d1 < 0 or d2 < 0 or d3 < 0
    local pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)
  end
  local function fillQuad(lx0, ly0, rx0, ry0, lx1, ly1, rx1, ry1)
    local minx = min(lx0, rx0, lx1, rx1)
    local maxx = max(lx0, rx0, lx1, rx1)
    local miny = min(ly0, ry0, ly1, ry1)
    local maxy = max(ly0, ry0, ly1, ry1)
    local gx0 = max(0, floor((minx - ox) * invSq))
    local gx1 = min(S - 1, ceil((maxx - ox) * invSq))
    local gy0 = max(0, floor((miny - oy) * invSq))
    local gy1 = min(S - 1, ceil((maxy - oy) * invSq))
    for gy = gy0, gy1 do
      local py = oy + gy * sq
      local base = gy * S
      for gx = gx0, gx1 do
        local i = base + gx
        if d[i] ~= 0 then
          local px = ox + gx * sq
          if inTri(px, py, lx0, ly0, rx0, ry0, lx1, ly1) or inTri(px, py, rx0, ry0, rx1, ry1, lx1, ly1) then
            d[i] = 0
            nCleared = nCleared + 1
          end
        end
      end
    end
  end
  for _, name in ipairs(names) do
    local road = scenetree.findObject(name)
    local use = road ~= nil
    if use then
      local okH, hid = pcall(function() return road:isHidden() end)
      if okH and hid then use = false end
    end
    if use and #skip > 0 then
      local okM, mat = pcall(function() return tostring(road:getField('material', 0) or ''):lower() end)
      if okM then
        for _, t in ipairs(skip) do
          if t ~= '' and mat:find(tostring(t):lower(), 1, true) then use = false; break end
        end
      end
    end
    if use then
      local okC, n = pcall(function() return road:getEdgeCount() end)
      n = okC and tonumber(n) or 0
      if n >= 2 then
        nRoads = nRoads + 1
        local pl, pr = nil, nil
        for i = 0, n - 1 do
          local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
          local cur = nil
          if okE and l and r and isFinite(l.x) and isFinite(l.y) and isFinite(r.x) and isFinite(r.y) then
            local dx, dy = l.x - r.x, l.y - r.y
            local len = sqrt(dx * dx + dy * dy)
            local k = len > 1e-6 and margin / len or 0
            cur = { l.x + dx * k, l.y + dy * k, r.x - dx * k, r.y - dy * k }
          end
          if cur and pl then
            fillQuad(pl[1], pl[2], pl[3], pl[4], cur[1], cur[2], cur[3], cur[4])
          end
          pl = cur
        end
      end
    end
  end
  return nRoads, nCleared
end

-- Two-pass 3-4 chamfer distance transform over the soft mask (3 = one vertex
-- straight, 4 = one vertex diagonal), capped at distCap. The chamfer contours are
-- nearly round, so the mud border does not follow the square steps of the grid.
-- A vertex with any non-soft 8-neighbour has a distance <= 4 (TOUCH). Map-edge
-- vertices count as touching.
local TOUCH = 4
function P.buildDistanceField()
  local S = ter.size
  local cap = distCap
  local d = ffi.new('uint8_t[?]', S * S)
  for gy = 0, S - 1 do
    local base = gy * S
    if engineFallback then
      for gx = 0, S - 1 do
        d[base + gx] = (layerSoft[engineCache[base + gx]] ~= 0) and cap or 0
      end
    else
      local row = flipRows and rows[S - gy] or rows[gy + 1]
      for gx = 0, S - 1 do
        d[base + gx] = (layerSoft[f2e[byte(row, gx + 1)]] ~= 0) and cap or 0
      end
    end
  end
  P.stats.roads, P.stats.roadVerts = P.carveRoads(d)
  if P.stats.roads > 0 then
    log('I', logTag, sfmt('decal roads: %d roads, %d soft vertices kept free of mud', P.stats.roads, P.stats.roadVerts))
  end
  for gy = 0, S - 1 do
    local base = gy * S
    for gx = 0, S - 1 do
      local i = base + gx
      local m = d[i]
      if m ~= 0 then
        if gx == 0 or gy == 0 or gx == S - 1 or gy == S - 1 then
          m = 3
        else
          local a = d[i - 1] + 3; if a < m then m = a end
          a = d[i - S - 1] + 4; if a < m then m = a end
          a = d[i - S] + 3; if a < m then m = a end
          a = d[i - S + 1] + 4; if a < m then m = a end
        end
        d[i] = m
      end
    end
  end
  for gy = S - 2, 1, -1 do
    local base = gy * S
    for gx = S - 2, 1, -1 do
      local i = base + gx
      local m = d[i]
      if m > 3 then
        local a = d[i + 1] + 3; if a < m then m = a end
        a = d[i + S + 1] + 4; if a < m then m = a end
        a = d[i + S] + 3; if a < m then m = a end
        a = d[i + S - 1] + 4; if a < m then m = a end
        d[i] = m
      end
    end
  end
  return d
end

local function distAt(gx, gy)
  local S = ter.size
  if gx < 0 or gy < 0 or gx >= S or gy >= S then return 0 end
  if dist then return dist[gy * S + gx] end
  -- fallback (engine queries): Chebyshev ring search, scaled to chamfer units
  if layerSoft[layerAt(gx, gy)] == 0 then return 0 end
  local rings = floor(distCap / 3)
  for r = 1, rings do
    for k = -r, r do
      local xs = { gx + k, gx + k, gx - r, gx + r }
      local ys = { gy - r, gy + r, gy + k, gy + k }
      for q = 1, 4 do
        local x, y = xs[q], ys[q]
        if x < 0 or y < 0 or x >= S or y >= S or layerSoft[layerAt(x, y)] == 0 then return 3 * r end
      end
    end
  end
  return distCap
end
M.distAt = distAt

function P.rebuildZoneBox()
  if #zones == 0 then zoneBox = nil; return end
  local b = { huge, huge, -huge, -huge }
  for _, z in ipairs(zones) do
    local r = (z.kind == 'rect') and sqrt(z.hx * z.hx + z.hy * z.hy) or z.r
    r = r + P.memberPad
    b[1] = min(b[1], z.x - r); b[2] = min(b[2], z.y - r)
    b[3] = max(b[3], z.x + r); b[4] = max(b[4], z.y + r)
    if z.kind == 'rect' then
      local a = math.rad(z.rot or 0)
      z.cos, z.sin = math.cos(a), math.sin(a)
    end
  end
  zoneBox = b
end

-- Zone depth at a world point and whether the point is inside the zone (plus a
-- pad of 1.5 squares so the zone border gets depth-0 vertices for the edge blend).
local function zoneSample(x, y)
  local best, member = 0, false
  for i = 1, #zones do
    local z = zones[i]
    local e
    local dx, dy = x - z.x, y - z.y
    if z.kind == 'rect' then
      local lx = abs(dx * z.cos + dy * z.sin) - z.hx
      local ly = abs(-dx * z.sin + dy * z.cos) - z.hy
      local ox, oy = max(lx, 0), max(ly, 0)
      e = sqrt(ox * ox + oy * oy) + min(max(lx, ly), 0)
    else
      e = sqrt(dx * dx + dy * dy) - z.r
    end
    if e <= P.memberPad then member = true end
    if e < 0 then
      local f = min(1, -e / max(z.feather or 1, 1e-3))
      f = f * f * (3 - 2 * f)
      local d = (z.depth or 0.3) * f
      if d > best then best = d end
    end
  end
  return best, member
end

-- mud depth and membership of a terrain vertex
local function depthAt(gx, gy)
  local dd = distAt(gx, gy)
  local d, member = 0, dd >= 1
  if dd > TOUCH then
    local f = (dd - TOUCH) / (3 * featherVerts)
    if f > 1 then f = 1 end
    d = layerDepth[layerAt(gx, gy)] * f * f * (3 - 2 * f) -- smoothstep: no crease at either end
  end
  if zoneBox then
    local x, y = ter.ox + gx * ter.sq, ter.oy + gy * ter.sq
    if x >= zoneBox[1] and x <= zoneBox[3] and y >= zoneBox[2] and y <= zoneBox[4] then
      local zd, zm = zoneSample(x, y)
      if zm then member = true end
      if zd > d then d = zd end
    end
  end
  return d, member
end
M.depthAt = depthAt

-- rest (undeformed mud surface), floor (hard ground), depth, member  -- world z
local function vertexInfo(gx, gy)
  local S = ter.size
  if gx < 0 then gx = 0 elseif gx > S - 1 then gx = S - 1 end
  if gy < 0 then gy = 0 elseif gy > S - 1 then gy = S - 1 end
  local d, member = depthAt(gx, gy)
  local cur = gridZ(gx, gy)
  -- heavy rut floor: the terrain is above the full sink by the vertex's lift
  if P.liftOn and d > 0 then cur = cur - P.liftOf(gx, gy) end
  if not member then return cur, cur, 0, false end
  if d <= 0 then return cur - edgeDip, cur, 0, true end
  if sinkApplied then
    local sf = P.shortfall[gy * S + gx]
    if sf then return cur + d - sf, cur, d, true end
  end
  return cur + d, cur, d, true
end
M.vertexInfo = vertexInfo

local function squareMaterial(gx, gy)
  local e = layerAt(gx, gy)
  if layerSoft[e] ~= 0 then return e end
  e = layerAt(gx + 1, gy); if layerSoft[e] ~= 0 then return e end
  e = layerAt(gx, gy + 1); if layerSoft[e] ~= 0 then return e end
  e = layerAt(gx + 1, gy + 1); if layerSoft[e] ~= 0 then return e end
  return P.zoneMat
end

-------------------------------------------------------------------------------
-- decal roads and groundcover over the mud
-------------------------------------------------------------------------------
-- Decal roads lie on the terrain, which is lowered under the mud: drawn normally they
-- vanish under the mud surface. With overObjects a decal road is projected down onto
-- static meshes instead, so it shows on the mud mesh (checked in game: a dirt track
-- hidden under the mud shows on it; its edge points stay on the terrain).
-- Every visible road with a point on soft ground (left, centre or right of any edge) is
-- switched once the mud sectors under it are built (a frame earlier, so the mesh is in
-- the scene), a few per frame; far roads wait until the camera or a vehicle comes near.
-- Some roads cannot take overObjects: the engine then throws vertices to +-16000 m and
-- logs "packed position exceeded ... (id=N)" for the road's material batch. Measured on
-- Johnson Valley: it happens with the mod stopped too and a mesh under the whole road
-- does not help, so it cannot be predicted. The log is read once a second; a road
-- named there is put back and remembered per level (settings/deepnode/levels/
-- <level>.roads.json, by persistentId), so the next start skips it.
-- The old values are restored on stop.
P.roadsChanged = {}
P.roadsPending = {}
P.roadsById = {}
P.roadsBad = {}
P.roadLog = { pos = nil, acc = 0 }

-- Soft ground at a world point: a soft layer at the nearest vertex (before the road
-- carve: roads that keep their strip free of mud still cross the mud area) or a zone.
function P.softAtWorld(x, y)
  local gx, gy = floor((x - ter.ox) * ter.invSq + 0.5), floor((y - ter.oy) * ter.invSq + 0.5)
  if layerSoft[layerAt(gx, gy)] ~= 0 then return true end
  if zoneBox and x >= zoneBox[1] and x <= zoneBox[3] and y >= zoneBox[2] and y <= zoneBox[4] then
    local zd = zoneSample(x, y)
    if zd > 0 then return true end
  end
  return false
end

-- terrain square (gx,gy) carries mud: all four corners belong to the mud and one is deep
function P.squarePatched(gx, gy)
  local S = ter.size
  if gx < 0 or gy < 0 or gx >= S - 1 or gy >= S - 1 then return false end
  local deep = false
  for k = 0, 3 do
    local d, member = depthAt(gx + k % 2, gy + floor(k / 2))
    if not member then return false end
    if d > 0 then deep = true end
  end
  return deep
end

-- note the sector of (x,y) in keys when mud is drawn there
function P.noteMudSector(x, y, keys)
  local gx, gy = floor((x - ter.ox) * ter.invSq), floor((y - ter.oy) * ter.invSq)
  if P.squarePatched(gx, gy) then keys[P.sectorKeyOfTile(floor(gx / TS), floor(gy / TS))] = true end
end

-- 'overlay' (decals drawn into the mud meshes, deepnode_decals), 'drape' (engine decals
-- switched to overObjects and draped by a collision reload) or 'off'
function P.roadMode()
  local r = cfg.roads
  if not r or r.enabled == false then return 'off' end
  if r.mode == 'drape' then return r.overObjects ~= false and 'drape' or 'off' end
  if r.mode == 'off' then return 'off' end
  return 'overlay'
end

function P.roadsCachePath() return '/settings/deepnode/levels/' .. tostring(P.levelName) .. '.roads.json' end

function P.loadBadRoads()
  P.roadsBad = {}
  local data = jsonReadFile and jsonReadFile(P.roadsCachePath())
  if type(data) == 'table' and type(data.bad) == 'table' then
    for _, pid in ipairs(data.bad) do P.roadsBad[tostring(pid)] = true end
  end
end

function P.saveBadRoads()
  local list = {}
  for pid in pairs(P.roadsBad) do list[#list + 1] = pid end
  table.sort(list)
  if jsonWriteFile then jsonWriteFile(P.roadsCachePath(), { bad = list }, true) end
end

-- terrain squares under any decal road (all of them, not only those on soft ground): the
-- screen-space overlay leaves no grass / dirt tracks there (a road over grass terrain).
-- Each road quad marks its bounding box of squares (a little wide on diagonal roads).
P.roadMask = {}
function P.markRoadMask(ed)
  local inv, ox, oy, S = ter.invSq, ter.ox, ter.oy, ter.size
  local mask = P.roadMask
  for i = 1, #ed - 7, 4 do
    local x0 = min(ed[i], ed[i + 2], ed[i + 4], ed[i + 6])
    local x1 = max(ed[i], ed[i + 2], ed[i + 4], ed[i + 6])
    local y0 = min(ed[i + 1], ed[i + 3], ed[i + 5], ed[i + 7])
    local y1 = max(ed[i + 1], ed[i + 3], ed[i + 5], ed[i + 7])
    local gx0, gx1 = max(0, floor((x0 - ox) * inv)), min(S - 1, floor((x1 - ox) * inv))
    local gy0, gy1 = max(0, floor((y0 - oy) * inv)), min(S - 1, floor((y1 - oy) * inv))
    if (gx1 - gx0) * (gy1 - gy0) < 4096 then
      for gy = gy0, gy1 do
        for gx = gx0, gx1 do mask[gy * S + gx] = true end
      end
    end
  end
end

-- scan every visible decal road into P.roadMask (deepnode_overlay at start); returns roads, ms
function P.buildRoadMask()
  P.roadMask = {}
  if not ter then return 0, 0 end
  local names = scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad')
  if type(names) ~= 'table' then return 0, 0 end
  local t0 = newTimer()
  local n = 0
  local edges = {}
  for _, name in ipairs(names) do
    local road = scenetree.findObject(name)
    local okH, hid = pcall(function() return road and road:isHidden() end)
    if road and okH and not hid then
      local okC, ec = pcall(function() return road:getEdgeCount() end)
      ec = okC and tonumber(ec) or 0
      local ne = 0
      for i = 0, ec - 1 do
        local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
        if okE and l and r and isFinite(l.x) and isFinite(r.x) then
          edges[ne + 1], edges[ne + 2], edges[ne + 3], edges[ne + 4] = l.x, l.y, r.x, r.y
          ne = ne + 4
        end
      end
      for k = ne + 1, #edges do edges[k] = nil end
      P.markRoadMask(edges)
      n = n + 1
    end
  end
  return n, t0:stop()
end

function P.onRoadAt(x, y)
  if not ter then return false end
  local S = ter.size
  local gx, gy = floor((x - ter.ox) * ter.invSq), floor((y - ter.oy) * ter.invSq)
  return P.roadMask[gy * S + gx] == true
end

function P.collectMudRoads()
  P.roadsChanged, P.roadsPending, P.roadsById = {}, {}, {}
  P.stats.roadsOver, P.stats.roadsPending, P.stats.roadsBad = 0, 0, 0
  P.loadBadRoads()
  local names = scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad')
  if type(names) ~= 'table' then return end
  local t0 = newTimer()
  local skip = cfg.roads.overSkipMatch or { 'invisible' }
  local seen, known = 0, 0
  for _, name in ipairs(names) do
    local road = scenetree.findObject(name)
    if road then
      local okH, hid = pcall(function() return road:isHidden() end)
      local okO, over = pcall(function() return tostring(road:getField('overObjects', 0)) end)
      local okM, mat = pcall(function() return tostring(road:getField('material', 0) or ''):lower() end)
      local okP, pid = pcall(function() return tostring(road:getField('persistentId', 0) or '') end)
      local use = not (okH and hid) and okO and over ~= '1' and okM
      if use then
        for _, t in ipairs(skip) do
          if t ~= '' and mat:find(tostring(t):lower(), 1, true) then use = false; break end
        end
      end
      if use and okP and pid ~= '' and P.roadsBad[pid] then use = false; known = known + 1 end
      if use then
        seen = seen + 1
        local okC, ec = pcall(function() return road:getEdgeCount() end)
        ec = okC and tonumber(ec) or 0
        local keys = {}
        local soft = false
        local edges = {}
        for i = 0, ec - 1 do
          local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
          if okE and l and r and isFinite(l.x) and isFinite(l.y) and isFinite(r.x) and isFinite(r.y) then
            local mx, my = (l.x + r.x) * 0.5, (l.y + r.y) * 0.5
            local ne = #edges
            edges[ne + 1], edges[ne + 2], edges[ne + 3], edges[ne + 4] = l.x, l.y, r.x, r.y
            if not soft and (P.softAtWorld(l.x, l.y) or P.softAtWorld(r.x, r.y) or P.softAtWorld(mx, my)) then
              soft = true
            end
            P.noteMudSector(l.x, l.y, keys)
            P.noteMudSector(r.x, r.y, keys)
            P.noteMudSector(mx, my, keys)
          end
        end
        if soft then
          local list = {}
          for k in pairs(keys) do list[#list + 1] = k end
          P.roadsPending[#P.roadsPending + 1] = { id = road:getId(), old = over, keys = list, pid = okP and pid or '',
            edges = edges }
        end
      end
    end
  end
  P.stats.roadsPending = #P.roadsPending
  P.stats.roadsBad = known
  log('I', logTag, sfmt('decal roads on soft ground: %d of %d to draw over the mud (%d skipped as known bad, %.0f ms)',
    #P.roadsPending, seen + known, known, t0:stop()))
end

-- Before the sector update of the frame: a sector reported built was built in an
-- earlier frame, so its mesh is in the scene. Up to roads.perFrame roads, 1 ms at most.
function P.updateRoads()
  local list = P.roadsPending
  if #list == 0 then return end
  local fm = P.mod('farMesh')
  if not fm or not fm.isLoaded then return end
  local t0 = newTimer()
  local per = cfg.roads.perFrame or 4
  local done = 0
  local k = 1
  while k <= #list do
    local e = list[k]
    local ready = true
    for _, sk in ipairs(e.keys) do
      if not fm.isLoaded(sk) then ready = false; break end
    end
    if ready then
      local road = scenetree.findObjectById and scenetree.findObjectById(e.id)
      if road then
        local ok = pcall(function()
          road:setField('overObjects', 0, '1')
          road:postApply()
          if road.regenerate then road:regenerate() end
        end)
        if ok then
          P.roadsChanged[#P.roadsChanged + 1] = e
          P.roadsById[e.id] = e
          P.stats.roadsOver = (P.stats.roadsOver or 0) + 1
          P.roadLog.watch = 5 -- s of log watching after the last switch
        end
      end
      list[k] = list[#list]
      list[#list] = nil
      done = done + 1
      if done >= per or t0:stop() > 1 then break end
    else
      k = k + 1
    end
  end
  P.stats.roadsPending = #list
end

function P.revertRoad(e)
  local road = scenetree.findObjectById and scenetree.findObjectById(e.id)
  if road then
    pcall(function()
      road:setField('overObjects', 0, e.old ~= '' and e.old or '0')
      road:postApply()
      if road.regenerate then road:regenerate() end
    end)
  end
end

-- new lines of beamng.log since the last call (nil when the log cannot be read)
function P.readNewLog()
  local f = io.open('beamng.log', 'r')
  if not f then return nil end
  local size = f:seek('end')
  local pos = P.roadLog.pos
  if not pos or size < pos then pos = size end -- first call, or the log was rotated
  local text = ''
  if size > pos then
    f:seek('set', pos)
    text = f:read(min(size - pos, 4194304)) or ''
  end
  f:close()
  P.roadLog.pos = size
  return text
end

-- Once a second while roads were switched in the last seconds: put back every switched
-- road the engine reports with thrown vertices. Putting one back rebuilds its batch,
-- which then reports the next one, so this settles over a few seconds.
function P.watchRoadErrors(dt)
  local L = P.roadLog
  if not L.pos then P.readNewLog() end -- start at the end of the log
  if (L.watch or 0) <= 0 then return end
  L.acc = L.acc + dt
  if L.acc < 1 then return end
  L.watch = L.watch - L.acc
  L.acc = 0
  local text = P.readNewLog()
  if not text or text == '' then return end
  local reverted = 0
  for id in text:gmatch('packed position exceeded[^\n]-%(id=(%d+)%)') do
    local e = P.roadsById[tonumber(id)]
    if e and not e.reverted then
      e.reverted = true
      P.revertRoad(e)
      if e.pid ~= '' then P.roadsBad[e.pid] = true end
      P.stats.roadsOver = max(0, (P.stats.roadsOver or 0) - 1)
      P.stats.roadsBad = (P.stats.roadsBad or 0) + 1
      reverted = reverted + 1
    end
  end
  if reverted > 0 then
    L.watch = 5
    P.saveBadRoads()
    log('I', logTag, sfmt('decal roads: %d road(s) cannot be drawn over objects (engine error), put back', reverted))
  end
end

function P.restoreRoads()
  for _, e in ipairs(P.roadsChanged or {}) do
    if not e.reverted then P.revertRoad(e) end
  end
  P.roadsChanged, P.roadsPending, P.roadsById = {}, {}, {}
  P.roadLog.watch = 0
end

-- Draping (roads.drape). overObjects lays a decal road by a physics ray cast onto
-- collision meshes (shipped editor/heroRoadEditor/groupMgr.lua:474-476: build the mesh,
-- reload collision, then lay the decals). ProceduralMesh builds its collision in
-- createMesh, but the physics world only takes it on be:reloadCollision(), and the mud
-- meshes must never be in it (vehicles sink through them). Measured on gridmap_v2: with
-- the mud meshes out of the physics world the roads fall through to the lowered terrain
-- and are hidden under the mud; after a reload they drape onto the mud and stay there
-- when the mud is taken out of the physics world again (hidden objects are left out of
-- a reload). So, once at start, with physics paused:
--   1. proxy meshes at the undisturbed mud height under every road square (one object
--      per sector), mud meshes hidden;  2. reload collision;  3. switch + regenerate the
--   roads;  4. delete the proxies, reload again (mud still hidden);  5. show the mud.
-- One reload costs ~370 ms on gridmap_v2 (it rebuilds the whole level), so this is not
-- done while driving. A decal stays where it was laid: ruts dug later under a road are
-- covered by it until the next drape. live = true (GUI "Redrape roads") keeps the visible
-- mud meshes in the first reload and builds proxies only for sectors that are not
-- loaded, so the roads follow the ruts near the camera.
-- Caution: any other be:reloadCollision() while the mod runs (some flowgraph missions,
-- dynamic props) puts the visible mud meshes into the physics world.
function P.roadSquares(e, set)
  local ed = e.edges
  if not ed then return end
  local inv, ox, oy, S = ter.invSq, ter.ox, ter.oy, ter.size
  for i = 1, #ed - 7, 4 do
    local x0 = min(ed[i], ed[i + 2], ed[i + 4], ed[i + 6])
    local x1 = max(ed[i], ed[i + 2], ed[i + 4], ed[i + 6])
    local y0 = min(ed[i + 1], ed[i + 3], ed[i + 5], ed[i + 7])
    local y1 = max(ed[i + 1], ed[i + 3], ed[i + 5], ed[i + 7])
    local gx0, gx1 = max(0, floor((x0 - ox) * inv) - 1), min(S - 2, floor((x1 - ox) * inv) + 1)
    local gy0, gy1 = max(0, floor((y0 - oy) * inv) - 1), min(S - 2, floor((y1 - oy) * inv) + 1)
    for gy = gy0, gy1 do
      for gx = gx0, gx1 do
        local k = gy * S + gx
        if set[k] == nil then set[k] = P.squarePatched(gx, gy) end
      end
    end
  end
end

-- one ProceduralMesh per sector over the given squares (flat grid at the rest height)
function P.buildDrapeProxies(bySector, objs)
  local S = ter.size
  local up, uv0 = { { x = 0, y = 0, z = 1 } }, { { u = 0, v = 0 } }
  for _, list in pairs(bySector) do
    local verts, faces, idx = {}, {}, {}
    local function vert(gx, gy)
      local k = gy * S + gx
      local i = idx[k]
      if not i then
        local rest = vertexInfo(gx, gy)
        verts[#verts + 1] = { x = ter.ox + gx * ter.sq, y = ter.oy + gy * ter.sq, z = rest }
        i = #verts - 1
        idx[k] = i
      end
      return i
    end
    local function face(i) faces[#faces + 1] = { v = i, n = 0, u = 0 } end
    for _, k in ipairs(list) do
      local gx, gy = k % S, floor(k / S)
      local a, b, c, d = vert(gx, gy), vert(gx + 1, gy), vert(gx, gy + 1), vert(gx + 1, gy + 1)
      -- clockwise seen from above (see tileMesh)
      face(a); face(c); face(d)
      face(a); face(d); face(b)
    end
    local o = createObject('ProceduralMesh')
    if o then
      o.canSave = false
      o:registerObject('')
      objs[#objs + 1] = o
      o:createMesh({ { { verts = verts, normals = up, uvs = uv0, faces = faces, material = P.FALLBACK_MAT } } })
    end
  end
  return objs
end

function P.mudObjects()
  local out = {}
  for _, n in ipairs(scenetree.findClassObjects('SimGroup') or {}) do
    if n:find('^deepnode_objects_') then
      local g = scenetree.findObject(n)
      for i = 0, (g and g:getCount() or 0) - 1 do
        local o = g:getObject(i)
        if o and not o:isHidden() then out[#out + 1] = o end
      end
    end
  end
  return out
end

-- Steps, physics paused from the first to the last:
--   build   proxies created (P.drapeRoads, this frame);
--   lay     roads.drapeWait s later: reload collision and check that sample ray casts
--           hit the proxies. Measured on gridmap_v2: a ProceduralMesh's collision is not
--           ready in the frame of createMesh (a reload then misses it), it is 1 s later.
--           Not ready yet: wait again (at most roads.drapeTries reloads). Ready: switch +
--           regenerate the roads;
--   settle  roads.drapeFrames frames later (the decal geometry is built over frames
--           after regenerate() returns: on gridmap_v2, removing the proxies after 0 or
--           3 frames left most roads on the terrain, 30 frames laid them all): proxies
--           deleted, mud meshes out of the physics world,
--           physics back on (P.finishDrape).
-- The mud meshes stay visible all along (in the physics world only while physics is
-- paused): at start they lie at the proxies' height; on a redrape they carry the ruts.
P.drape = nil
function P.drapeRoads(live)
  if P.drape or not running or not be or not be.reloadCollision then return 0 end
  local list = {}
  for _, e in ipairs(P.roadsPending) do list[#list + 1] = e end
  if live then for _, e in ipairs(P.roadsChanged) do if not e.reverted then list[#list + 1] = e end end end
  if #list == 0 then return 0 end
  local t0 = newTimer()
  local set = {}
  for _, e in ipairs(list) do P.roadSquares(e, set) end
  local fm = P.mod('farMesh')
  local S = ter.size
  local bySector, nsq, samples = {}, 0, {}
  for k, on in pairs(set) do
    if on then
      local gx, gy = k % S, floor(k / S)
      local sk = P.sectorKeyOfTile(floor(gx / TS), floor(gy / TS))
      if not (live and fm and fm.isLoaded(sk)) then
        local l = bySector[sk]
        if not l then l = {}; bySector[sk] = l end
        l[#l + 1] = k
        nsq = nsq + 1
        -- readiness sample: the deepest square of each proxy
        local _, _, dep = vertexInfo(gx, gy)
        local sm = samples[sk]
        if not sm or dep > sm[2] then samples[sk] = { k, dep } end
      end
    end
  end
  local okR, wasRunning = pcall(function() return be:getPhysicsRunning() end)
  if not okR then wasRunning = true end
  be:setPhysicsRunning(false)
  local sl = {}
  for _, sm in pairs(samples) do if sm[2] > 0.05 then sl[#sl + 1] = sm[1] end end
  local d = { live = live, list = list, proxies = {}, samples = sl, wasRunning = wasRunning,
    step = 'build', wait = cfg.roads.drapeWait or 0.5, tries = 0, n = 0, nsq = nsq, tm = { reload = 0 } }
  P.drape = d
  local ok, err = pcall(P.buildDrapeProxies, bySector, d.proxies)
  d.tm.build = t0:stop()
  if not ok then
    P.finishDrape(true)
    error(err, 0)
  end
  return #list
end

-- share of the sample squares (the deepest of each proxy object, 32 at most) where a ray
-- cast down stops above the lowered terrain, i.e. on the proxy (or on a static object)
function P.drapeReady(d)
  local cast = P.origCast or castRayStatic
  if not cast or #d.samples == 0 then return 1 end
  local S = ter.size
  local step = max(1, floor(#d.samples / 32))
  local hit, n = 0, 0
  for i = 1, #d.samples, step do
    local k = d.samples[i]
    local gx, gy = k % S, floor(k / S)
    -- just inside the square from its corner vertex: heights there are the vertex's
    -- (at the square centre a slope made false misses)
    local x, y = ter.ox + (gx + 0.02) * ter.sq, ter.oy + (gy + 0.02) * ter.sq
    local rest, fl, dep = vertexInfo(gx, gy)
    local dist = cast(vec3(x, y, rest + 2), vec3(0, 0, -1), 4)
    n = n + 1
    if dist and rest + 2 - dist > fl + 0.5 * dep then hit = hit + 1 end
  end
  return n > 0 and hit / n or 1
end

function P.layDrapedRoads(d)
  local t0 = newTimer()
  for _, e in ipairs(d.list) do
    local road = scenetree.findObjectById and scenetree.findObjectById(e.id)
    if road and pcall(function()
      road:setField('overObjects', 0, '1')
      road:postApply()
      if road.regenerate then road:regenerate() end
    end) then
      d.n = d.n + 1
      if not P.roadsById[e.id] then
        P.roadsChanged[#P.roadsChanged + 1] = e
        P.roadsById[e.id] = e
        P.stats.roadsOver = (P.stats.roadsOver or 0) + 1
      end
    end
  end
  P.roadsPending = {}
  P.stats.roadsPending = 0
  d.tm.roads = t0:stop()
end

function P.updateDrape(dtReal)
  local d = P.drape
  if not d then return end
  if d.step == 'build' then
    d.wait = d.wait - (dtReal or 0)
    if d.wait > 0 then return end
    local t0 = newTimer()
    be:reloadCollision()
    d.tm.reload = d.tm.reload + t0:stop()
    d.tries = d.tries + 1
    d.ready = P.drapeReady(d)
    if d.ready < 0.95 and d.tries < (cfg.roads.drapeTries or 3) then
      d.wait = cfg.roads.drapeWait or 0.5
      return
    end
    P.layDrapedRoads(d)
    d.step, d.frames = 'settle', cfg.roads.drapeFrames or 3
  elseif d.step == 'settle' then
    d.frames = d.frames - 1
    if d.frames <= 0 then P.finishDrape(true) end
  end
end

-- objectsAlive = false: the level is gone, only physics is switched back on
function P.finishDrape(objectsAlive)
  local d = P.drape
  if not d then return end
  P.drape = nil
  local t0 = newTimer()
  if objectsAlive ~= false then
    for _, o in ipairs(d.proxies) do pcall(function() o:delete() end) end
    local mud = P.mudObjects()
    for _, o in ipairs(mud) do o:setHidden(true) end
    pcall(function() be:reloadCollision() end)
    for _, o in ipairs(mud) do o:setHidden(false) end
  end
  pcall(function() be:setPhysicsRunning(d.wasRunning and true or false) end)
  local tm = d.tm
  tm.cleanup = t0:stop()
  P.roadLog.watch = 5
  P.stats.drapeMs = (tm.build or 0) + tm.reload + (tm.roads or 0) + tm.cleanup
  P.stats.drape = { roads = d.n, ready = d.ready or 0, tries = d.tries, ms = P.stats.drapeMs, samples = #d.samples,
    live = d.live or false }
  log('I', logTag, sfmt('decal roads draped: %d of %d roads over %d proxy squares (%d objects)%s, proxies hit %.0f%% after %d reload(s); build %.0f ms, reloads %.0f + %.0f ms, roads %.0f ms',
    d.n, #d.list, d.nsq, #d.proxies, d.live and ', live meshes near the camera' or '', (d.ready or 0) * 100, d.tries,
    tm.build or 0, tm.reload, tm.cleanup, tm.roads or 0))
end

-- Decal roads off (roads.mode 'off', GUI "Experimental decal road" unticked): no decal road
-- shows on the mud or sand, as before terrain-first drawing. Heavy physics leaves undug
-- mud to the terrain, which draws the level's decal roads on it; covering them with the
-- mesh does not work (the decal's depth bias wins over a mesh up to ~5 cm above the
-- terrain, measured; 2 cm z-fights). So every decal road with any part over soft ground is
-- hidden whole, also its part over hard ground beside the mud. Shown again when the
-- overlay is switched on or the mod stops.
P.roadsHidden = {}
function P.coverRoads(off)
  for _, o in ipairs(P.roadsHidden) do pcall(function() o:setHidden(false) end) end
  P.roadsHidden = {}
  if not off or not ter or cfg.roads.hideOnMud == false then return 0 end
  local t0 = newTimer()
  for _, name in ipairs(scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad') or {}) do
    local road = scenetree.findObject(name)
    local okH, hid = pcall(function() return road and road:isHidden() end)
    local okE, ec = pcall(function() return road:getEdgeCount() end)
    if road and okH and not hid and okE then
      for i = 0, (tonumber(ec) or 0) - 1 do
        local l, r = road:getLeftEdgePosition(i), road:getRightEdgePosition(i)
        if l and r and isFinite(l.x) and isFinite(r.x)
            and (P.softAtWorld((l.x + r.x) * 0.5, (l.y + r.y) * 0.5) or P.softAtWorld(l.x, l.y) or P.softAtWorld(r.x, r.y)) then
          road:setHidden(true)
          P.roadsHidden[#P.roadsHidden + 1] = road
          break
        end
      end
    end
  end
  log('I', logTag, sfmt('decal roads off: %d roads over soft ground hidden, %.0f ms', #P.roadsHidden, t0:stop()))
  return #P.roadsHidden
end

-- Decal roads on the mud on/off (GUI "Experimental decal road"), live: the overlay module
-- starts or stops, the road cover above is set or removed and every loaded mesh is rebuilt
-- (tiles at their rebuild rate, sectors in turn).
function M.decalRoadsOn() return P.roadMode() == 'overlay' end
function M.setDecalRoads(on)
  cfg.roads.mode = on and 'overlay' or 'off'
  if not running then return end
  P.coverRoads(not on)
  local dec = P.mod('decals')
  if dec then
    if on then
      local ok, err = pcall(dec.start, M)
      if not ok then log('E', logTag, 'decal overlay failed: ' .. tostring(err)) end
    else
      dec.stop(true)
    end
  end
  for _, t in pairs(tiles) do
    if t.obj then t.dirty = true end
  end
  local fm = P.mod('farMesh')
  if fm and fm.markAllDirty then fm.markAllDirty() end
end

-- screen-space rut overlay (deepnode_overlay, experimental): tread prints and wet
-- darkening drawn over the lit scene; on/off live
function M.setRutOverlay(on)
  cfg.overlay.enabled = on and true or false
  if not running then return cfg.overlay.enabled end
  local ov = P.mod('overlay')
  if not ov then return false end
  ov.stop()
  if on then
    local ok, err = pcall(ov.start, M)
    if not ok then log('E', logTag, 'rut overlay failed: ' .. tostring(err)) end
  end
  return ov.isActive()
end

function M.rutOverlayOn()
  local ov = P.mod('overlay')
  return ov and ov.isActive() or false
end

function M.redrapeRoads()
  if P.roadMode() ~= 'drape' then return 0 end
  local ok, res = pcall(P.drapeRoads, true)
  if not ok then
    log('E', logTag, 'road drape failed: ' .. tostring(res))
    return 0
  end
  return res
end
function M.draping() return P.drape ~= nil end

-- Groundcover on soft layers grows on the lowered terrain, under the mud surface. The
-- GroundCover zOffset lifts it, but only in cells the cover builds after the change:
-- measured in game, the terrain update of the sink pass moves existing cells down to
-- the new terrain without applying zOffset, and changing zOffset, moving the camera away
-- and back or a terrain update of the area do not rebuild them (there is no script call
-- that does). A new GroundCover object builds all its cells fresh. So, after the sink
-- pass, every GroundCover with types on soft layers is hidden and replaced by copies:
--  * one copy per sink depth that keeps only the soft types of that depth, with
--    zOffset raised by the depth;
--  * one copy with the other types, unchanged, when there are any.
-- A type is switched off in a copy by an unreachable minElevation, not by probability 0:
-- it still takes its share of the random picks, so every copy places its types exactly
-- where the original did (same seed, same picks). Stop deletes the copies and shows the
-- original again.
-- Grass on the depth fade near a layer border is lifted by the full depth over a
-- terrain that is lowered less (layers.featherVerts): it can stand up to that depth
-- above the mud there.
P.coverChanged = {}
P.coverCopies = {}
P.OFF_ELEV = '1000000'
P.COVER_TYPES = 8
P.COVER_SKIP = { name = true, internalName = true, persistentId = true, parentGroup = true, class = true,
  className = true, superClass = true, canSave = true, canSaveDynamicFields = true, locked = true, hidden = true }

function P.softLayerByName()
  local byName = {}
  for _, L in pairs(layers) do
    if L.soft then byName[L.name:lower()] = L end
  end
  return byName
end

function P.coverField(o, name, i)
  local ok, v = pcall(function() return o:getField(name, i) end)
  if not ok or v == nil then return '' end
  return tostring(v)
end

-- set: list of {field, index, value} applied before registerObject (a GroundCover
-- builds its first cells at registration; fields set after it did not apply)
function P.copyCover(src, name, set)
  local c = createObject('GroundCover')
  if not c then return nil end
  local ok, fields = pcall(function() return src:getFields() end)
  if ok and type(fields) == 'table' then
    for fname in pairs(fields) do
      fname = tostring(fname)
      if not P.COVER_SKIP[fname] then
        for i = 0, P.COVER_TYPES - 1 do
          local v = P.coverField(src, fname, i)
          if v ~= '' then pcall(function() c:setField(fname, i, v) end) end
        end
      end
    end
  end
  for _, f in ipairs(set or {}) do pcall(function() c:setField(f[1], f[2], f[3]) end) end
  c.canSave = false
  c:registerObject(name)
  local grp = src.getGroup and src:getGroup() or scenetree.MissionGroup
  if grp then
    if grp.addObject then grp:addObject(c.obj or c) elseif grp.add then grp:add(c.obj or c) end
  end
  return c
end

-- after the sink pass (the copies build their cells on the lowered terrain)
function P.liftGroundCover()
  P.coverChanged, P.coverCopies = {}, {}
  local names = scenetree.findClassObjects and scenetree.findClassObjects('GroundCover')
  if type(names) ~= 'table' or #names == 0 then return end
  local t0 = newTimer()
  local soft = P.softLayerByName()
  local lifted, copies = 0, 0
  for _, name in ipairs(names) do
    local gc = scenetree.findObject(name)
    if gc and not gc:isHidden() then
      local types = {}
      local depths, nHard = {}, 0
      for i = 0, P.COVER_TYPES - 1 do
        local layer = P.coverField(gc, 'layer', i)
        local prob = tonumber(P.coverField(gc, 'probability', i)) or 0
        local inv = P.coverField(gc, 'invertLayer', i)
        if layer ~= '' and layer ~= '0' and prob > 0 then
          local L = (inv ~= '1' and inv ~= 'true') and soft[layer:lower()] or nil
          -- lift by the visual sink only: with the heavy floor the terrain under the mud
          -- is lowered by depth - lift (none at full lift: the grass stays where it is)
          local dv = L and P.layerVisualDepth(L) or 0
          if dv <= 0.001 then L = nil end
          types[i] = { L = L, dv = dv }
          if L then depths[dv] = true else nHard = nHard + 1 end
        end
      end
      local depthList = {}
      for d in pairs(depths) do depthList[#depthList + 1] = d end
      table.sort(depthList)
      if #depthList > 0 then
        local z0 = tonumber(P.coverField(gc, 'zOffset', 0)) or 0
        local made = {}
        -- the copies: one per soft depth (lifted), one for the hard types
        local groups = {}
        for _, d in ipairs(depthList) do groups[#groups + 1] = { depth = d } end
        if nHard > 0 then groups[#groups + 1] = { depth = nil } end
        for k, gdef in ipairs(groups) do
          -- GPU placement samples the terrain heightmap and ignores zOffset (measured:
          -- billboard grass stayed on the lowered terrain); CPU placement applies it
          local set = { { 'zOffset', 0, sfmt('%g', z0 + (gdef.depth or 0)) }, { 'useNewPlacementGpu', 0, '0' } }
          for i, ty in pairs(types) do
            local keep
            if gdef.depth then keep = ty.L and ty.dv == gdef.depth else keep = not ty.L end
            if not keep then set[#set + 1] = { 'minElevation', i, P.OFF_ELEV } end
          end
          local c = P.copyCover(gc, sfmt('deepnode_cover_%s_%d_%d', tostring(name), k, P.session), set)
          if c then
            made[#made + 1] = c
            P.coverCopies[#P.coverCopies + 1] = c
            copies = copies + 1
          end
        end
        if #made > 0 then
          gc:setHidden(true)
          P.coverChanged[#P.coverChanged + 1] = { id = gc:getId() }
          lifted = lifted + 1
        end
      end
    end
  end
  P.stats.grassLifted = lifted
  if lifted > 0 then
    log('I', logTag, sfmt('groundcover on soft layers lifted onto the mud: %d GroundCover(s) replaced by %d copies (%.0f ms)',
      lifted, copies, t0:stop()))
  end
end

-- before the terrain is restored
function P.restoreGroundCover(objectsAlive)
  if objectsAlive then
    for _, c in ipairs(P.coverCopies or {}) do pcall(function() c:delete() end) end
    for _, e in ipairs(P.coverChanged or {}) do
      local gc = scenetree.findObjectById and scenetree.findObjectById(e.id)
      if gc then pcall(function() gc:setHidden(false) end) end
    end
  end
  P.coverChanged, P.coverCopies = {}, {}
end

-------------------------------------------------------------------------------
-- zones (per level file)
-------------------------------------------------------------------------------
function P.zonesPath() return '/settings/deepnode/levels/' .. tostring(P.levelName) .. '.json' end

function P.loadZones()
  zones = {}
  local data = jsonReadFile and jsonReadFile(P.zonesPath())
  if type(data) == 'table' and type(data.zones) == 'table' then
    for _, z in ipairs(data.zones) do
      if type(z) == 'table' and isFinite(z.x) and isFinite(z.y) then
        z.kind = (z.kind == 'rect') and 'rect' or 'circle'
        z.r = tonumber(z.r) or 6
        z.hx = tonumber(z.hx) or 4
        z.hy = tonumber(z.hy) or 4
        z.feather = tonumber(z.feather) or 2
        z.depth = tonumber(z.depth) or 0.35
        zones[#zones + 1] = z
      end
    end
  end
  P.rebuildZoneBox()
end

function P.saveZones()
  local out = {}
  for _, z in ipairs(zones) do
    out[#out + 1] = { kind = z.kind, x = z.x, y = z.y, r = z.r, hx = z.hx, hy = z.hy, rot = z.rot, feather = z.feather, depth = z.depth }
  end
  if jsonWriteFile then jsonWriteFile(P.zonesPath(), { zones = out }, true) end
end

-------------------------------------------------------------------------------
-- terrain init, sink pass, restore
-------------------------------------------------------------------------------
-- Meshed soft area of the map (m2): soft ground the mod draws a surface over. With the heavy
-- rut floor at full lift (terrain-first) undisturbed ground is the terrain itself and needs no
-- sector mesh, so only kinds whose floor lift is below their sink depth count (sand by default;
-- every kind with vanilla physics). Sampled on a grid of at most 1024 x 1024 vertices.
function P.meshedSoftArea()
  local S, sq = ter.size, ter.sq
  local h = cfg.physics and cfg.physics.mode == 'heavy' and cfg.physics.heavy
  local function meshed(kind, depth)
    if not h then return true end
    local l = tonumber(h.floorLift and h.floorLift[kind]) or 0
    return l < depth - 1e-3
  end
  local meshedIdx = {}
  for e, L in pairs(layers) do
    if L.soft and meshed(L.kind, L.sinkDepth or 0) then meshedIdx[e] = true end
  end
  local step = max(1, floor(S / 1024))
  local n = 0
  if next(meshedIdx) then
    for gy = 0, S - 1, step do
      local base = gy * S
      for gx = 0, S - 1, step do
        if (not dist or dist[base + gx] > TOUCH) and meshedIdx[layerAt(gx, gy)] then n = n + 1 end
      end
    end
  end
  local area = n * (step * sq) ^ 2
  -- zones are mud
  for _, z in ipairs(zones) do
    if meshed('mud', z.depth or 0.3) then
      area = area + ((z.kind == 'rect') and 4 * z.hx * z.hy or math.pi * z.r * z.r)
    end
  end
  return area
end

-- Sector size from the map: the worst case is a camera parked in the biggest meshed soft
-- region, which shows min(meshed area, pi R^2) of it within sectors.loadRadius R. Sectors grow
-- until that is at most sectors.autoMaxObjects sector objects (every object costs time in the
-- shadow pass even when it casts no shadow). minTiles = sectors.tiles (GUI "Sector size").
function P.autoSectorTiles(minTiles)
  local sc = cfg.sectors
  local area = P.meshedSoftArea()
  local R = sc.loadRadius or 100
  local inView = min(area, math.pi * R * R)
  local side = sqrt(inView / max(10, sc.autoMaxObjects or 200))
  local sec = clamp(math.ceil(side / TILE), minTiles, max(minTiles, sc.autoMaxTiles or 8))
  P.stats.meshedSoftArea, P.stats.sectorTiles = area, sec
  log('I', logTag, sfmt('sector size: %d tiles (%.0f m) for %.0f m2 meshed soft ground, %.0f m2 in view at %.0f m',
    sec, sec * TILE, area, inView, R))
  return sec
end

function P.initTerrain()
  local tb = core_terrain and core_terrain.getTerrain and core_terrain.getTerrain()
  if not tb then return false, 'no TerrainBlock in level' end
  local pos = tb:getPosition()
  local sq = tonumber(tb:getSquareSize()) or 1
  local wsize = tonumber(tb:getWorldBlockSize()) or 1024
  ter = { tb = tb, ox = pos.x, oy = pos.y, oz = pos.z, sq = sq, invSq = 1 / sq, size = floor(wsize / sq + 0.5), worldSize = wsize, localZ = true }
  M.ter = ter

  local t0 = newTimer()
  local fn = tb.getTerrFileName and tostring(tb:getTerrFileName() or '') or ''
  local lm, err = nil, 'no terrain file'
  if fn ~= '' then lm, err = P.readLayerMap(fn) end
  P.stats.layerMapMs = t0:stopAndReset()

  local mats, count = P.engineMaterials(tb)
  layers = {}
  for e = 0, count - 1 do
    local m = mats[e]
    if m then
      local name, gm = P.mtlName(m), P.mtlGm(m)
      local hit = P.matchSoft(name, gm)
      -- kind: the softMatch text that made the layer soft ('mud', 'sand'): tyre mud uses it
      local L = { idx = e, name = name, gm = gm, soft = hit ~= nil, kind = hit, mtl = m }
      if L.soft then
        L.sinkDepth = cfg.layers.defaultSinkDepth
        for k, v in pairs(cfg.layers.sinkDepthByMatch or {}) do
          local p = tostring(k):lower()
          if name:lower():find(p, 1, true) or gm:lower():find(p, 1, true) then L.sinkDepth = tonumber(v) or L.sinkDepth; break end
        end
        L.sinkDepth = L.sinkDepth * (tonumber(cfg.layers.depthScale) or 1)
      end
      layers[e] = L
    end
  end

  -- file layer index -> engine layer index (by name when the file lists names)
  for i = 0, 255 do f2e[i] = 255 end
  if lm then
    ter.size = lm.size
    rows = lm.rows
    if lm.names then
      for fi, nm in pairs(lm.names) do
        local want = nm:lower()
        for e, L in pairs(layers) do
          if L.name:lower() == want then f2e[fi] = e; break end
        end
      end
    else
      for e = 0, min(count, 254) - 1 do f2e[e] = e end
    end
  end

  -- pitfall 1: does getHeightGrid return local or world z?
  local S = ter.size
  local nLocal, nWorld = 0, 0
  local resL, resW = 0, 0
  for k = 1, 16 do
    local gx = floor(S * (0.1 + 0.05 * k)) % (S - 1)
    local gy = floor(S * (0.85 - 0.045 * k)) % (S - 1)
    local hg = tb:getHeightGrid(gx, gy)
    local hw = tb:getHeight(vec3(ter.ox + gx * sq, ter.oy + gy * sq, 0))
    if isFinite(hg) and isFinite(hw) then
      local eL, eW = abs(hg + ter.oz - hw), abs(hg - hw)
      if eL <= eW then nLocal = nLocal + 1 else nWorld = nWorld + 1 end
      resL, resW = max(resL, eL), max(resW, eW)
    end
  end
  ter.localZ = nLocal >= nWorld
  local res = ter.localZ and resL or resW
  log('I', logTag, sfmt('height grid frame: %s z (max residual %.3f m)', ter.localZ and 'local' or 'world', res))
  if res > 0.05 then
    log('W', logTag, 'terrain vertex positions do not match getHeight within 5 cm: grid alignment differs from position + gx * squareSize')
  end
  ter.clampRaw = 0 -- heights are unsigned above the terrain origin (pitfall 1)
  if not ter.localZ then ter.clampRaw = ter.oz end

  P.refreshLayerDepths()

  engineFallback = false
  dist = nil
  engineCache = nil
  if lm then
    P.orientation = 'direct'
    flipRows = false
    local o, disc, aD, aF = P.verifyOrientation()
    P.orientation = o
    log('I', logTag, sfmt('layer map %dx%d v%d, row order check: %s (%d samples, direct %d, flipped %d)', S, S, lm.version, o, disc, aD, aF))
    if o == 'flipped' then flipRows = true end
    if o == 'engine' then engineFallback = true end
  else
    log('W', logTag, 'layer map not readable (' .. tostring(err) .. '), using per-point engine queries')
    engineFallback = true
    P.orientation = 'engine'
  end
  P.stats.orientation = P.orientation
  if engineFallback then
    rows = nil
    local t1 = newTimer()
    engineCache = P.readEngineLayerMap()
    local ms = t1:stopAndReset()
    P.stats.layerMapMs = P.stats.layerMapMs + ms
    log('W', logTag, sfmt('layer map read from the engine vertex by vertex (%.0f ms)', ms))
  end
  local t1 = newTimer()
  dist = P.buildDistanceField()
  P.stats.distMs = t1:stopAndReset()
  return true
end

-- lift: m the terrain was left above the full sink (physics 'heavy' rut floor); the
-- current lift (sinkLift) goes down where ruts are dug, sinkLift0 is the start value
-- base: the full sink level (raw - sink depth, before the clamp). Floor writes use it as
-- an absolute reference (physics.lua): the height grid rounds every write to
-- maxHeight / 65536 (1.5 mm on gridmap_v2), and relative writes (current - old lift + new
-- lift) drifted measured -3.4 cm over 20 lower/raise cycles.
function P.recordSink(idx, raw, lift, base)
  if P.sinkCount >= P.sinkCapacity then
    local nc = max(65536, P.sinkCapacity * 2)
    local ni, nr = ffi.new('int32_t[?]', nc), ffi.new('float[?]', nc)
    local nl, nl0 = ffi.new('float[?]', nc), ffi.new('float[?]', nc)
    local nb = ffi.new('float[?]', nc)
    if P.sinkCount > 0 then
      ffi.copy(ni, P.sinkIdx, P.sinkCount * 4)
      ffi.copy(nr, P.sinkRaw, P.sinkCount * 4)
      ffi.copy(nl, P.sinkLift, P.sinkCount * 4)
      ffi.copy(nl0, P.sinkLift0, P.sinkCount * 4)
      ffi.copy(nb, P.sinkBase, P.sinkCount * 4)
    end
    P.sinkIdx, P.sinkRaw, P.sinkLift, P.sinkLift0, P.sinkCapacity = ni, nr, nl, nl0, nc
    P.sinkBase = nb
  end
  P.sinkIdx[P.sinkCount] = idx
  P.sinkRaw[P.sinkCount] = raw
  P.sinkLift[P.sinkCount] = lift or 0
  P.sinkLift0[P.sinkCount] = lift or 0
  P.sinkBase[P.sinkCount] = base or raw
  P.sinkCount = P.sinkCount + 1
end

-- record number of a sunk vertex (sinkIdx is ascending: the sink pass runs row by row),
-- nil when the vertex was not lowered
function P.sinkFind(idx)
  local lo, hi = 0, P.sinkCount - 1
  local si = P.sinkIdx
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    local v = si[mid]
    if v == idx then return mid end
    if v < idx then lo = mid + 1 else hi = mid - 1 end
  end
  return nil
end

-- current lift of a vertex (0 outside the heavy rut floor)
function P.liftOf(gx, gy)
  local k = P.sinkFind(gy * ter.size + gx)
  return k and P.sinkLift[k] or 0
end

-- Terrain-first drawing. With the heavy rut floor at full lift (physics.heavy.floorLift
-- >= the sink depth, the default for mud) the sink pass leaves the terrain under
-- undisturbed mud where it was: the terrain IS the mud surface there and draws it with the
-- level's own decal roads, colours, grass and to any distance. The mod then draws only
-- the squares that ruts touched; an untouched square whose four corners are flush is left
-- to the terrain. A vertex is flush while its lift still equals its sink depth (no rut
-- floor lowered it yet) and nothing clamped it. Off without the heavy floor (vanilla
-- physics: the terrain is lowered by the full depth everywhere).
P.FLUSH_TOL = 0.002
function P.vertexFlush(gx, gy)
  if not P.liftOn or not ter then return false end
  local S = ter.size
  if gx < 0 or gy < 0 or gx >= S or gy >= S then return true end
  local d = depthAt(gx, gy)
  if d <= 0 then return true end
  local idx = gy * S + gx
  if P.shortfall[idx] then return false end
  local k = P.sinkFind(idx)
  if not k then return true end
  return P.sinkLift[k] >= d - P.FLUSH_TOL
end
function P.squareFlush(gx, gy)
  return P.vertexFlush(gx, gy) and P.vertexFlush(gx + 1, gy) and P.vertexFlush(gx, gy + 1)
    and P.vertexFlush(gx + 1, gy + 1)
end
M.squareFlush = function(gx, gy) return P.squareFlush(gx, gy) end
M.terrainFirst = function() return P.liftOn == true end

-- per-square flush flags of a tile (uint8 TS*TS); nil when no square is flush
function P.tileFlush(t)
  if not P.liftOn then return nil end
  local f, any = t.sqFlush, false
  if not f then f = ffi.new('uint8_t[?]', TS * TS); t.sqFlush = f end
  for sj = 0, TS - 1 do
    for si = 0, TS - 1 do
      local q = sj * TS + si
      local v = (t.sqPatched[q] ~= 0 and P.squareFlush(t.gx0 + si, t.gy0 + sj)) and 1 or 0
      f[q] = v
      if v == 1 then any = true end
    end
  end
  t.anyFlush = any
  return f
end

-- visual sink of a soft layer: depth minus the heavy floor lift (0 = terrain at the surface)
function P.layerVisualDepth(L)
  local d = L.sinkDepth or 0
  if not P.liftOn then return d end
  local h = cfg.physics and cfg.physics.heavy
  local l = tonumber(h and h.floorLift and h.floorLift[L.kind]) or 0
  return max(0, d - min(max(0, l), d))
end

-- The heavy rut floor lowered (or raised) terrain vertices in the grid box: squares next
-- to them stop (or start) being flush. Their tiles rebuild; sectors redraw.
function M.onFloorChanged(gx0, gy0, gx1, gy1)
  if not running or not P.liftOn then return end
  local fm = P.mod('farMesh')
  local tx0, tx1 = floor((gx0 - 1) / TS), floor(gx1 / TS)
  local ty0, ty1 = floor((gy0 - 1) / TS), floor(gy1 / TS)
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local t = tiles[ty * KEY + tx]
      if t then
        local old = t.sqFlush and ffi.string(t.sqFlush, TS * TS)
        P.tileFlush(t)
        if not old or old ~= ffi.string(t.sqFlush, TS * TS) then
          if t.state == 'active' or t.obj then t.dirty = true end
          if fm and (t.state ~= 'active' or not t.obj) then fm.markDirty(P.sectorKeyOfTile(tx, ty), true) end
        end
      elseif fm then
        fm.markDirty(P.sectorKeyOfTile(tx, ty), false)
      end
    end
  end
end

-- a tile whose ruts changed: the heavy rut floor under it is redone (deepnode_physics);
-- 'reset' (ruts gone) may raise the terrain again, 'lower' only lowers it
function P.markFloor(t, mode)
  local e = P.floorTiles[t.key]
  if e then
    if mode == 'reset' then e.mode = 'reset' end
  else
    P.floorTiles[t.key] = { mode = mode, tx = t.tx, ty = t.ty }
  end
end

-- soft kind of the layer at a vertex ('mud', 'sand'), nil for hard ground
function M.layerKindAt(gx, gy)
  local L = layers[layerAt(gx, gy)]
  if L and L.soft then return L.kind end
  L = layers[P.zoneMat]
  return L and L.soft and L.kind or 'mud'
end

function P.markLowered(gx, gy)
  local span = TS * SEC
  local sx1, sx2 = floor((gx - 1) / span), floor(gx / span)
  local sy1, sy2 = floor((gy - 1) / span), floor(gy / span)
  P.loweredSectors[sy1 * KEY + sx1] = true
  P.loweredSectors[sy1 * KEY + sx2] = true
  P.loweredSectors[sy2 * KEY + sx1] = true
  P.loweredSectors[sy2 * KEY + sx2] = true
end

-- Lower every soft vertex of the map once, in one setHeightGrid + updateGrid pass.
-- Heights are unsigned above the terrain origin: clamp at 0 and record the
-- shortfall (pitfall 1). Only at mod start, never while driving.
function P.sinkPass()
  local t0 = newTimer()
  local tb = ter.tb
  local S = ter.size
  P.sinkCount = 0
  P.shortfall = {}
  P.loweredSectors = {}
  local bx0, by0, bx1, by1 = huge, huge, -huge, -huge
  local clampRaw = ter.clampRaw
  local ph = P.mod('physics')
  if ph and not ph.floorOn() then ph = nil end
  P.liftOn = ph ~= nil
  local zx0, zx1, zy0, zy1 = -1, -2, -1, -2
  if zoneBox then
    zx0 = floor((zoneBox[1] - ter.ox) / ter.sq) - 1; zx1 = ceil((zoneBox[3] - ter.ox) / ter.sq) + 1
    zy0 = floor((zoneBox[2] - ter.oy) / ter.sq) - 1; zy1 = ceil((zoneBox[4] - ter.oy) / ter.sq) + 1
  end
  for gy = 0, S - 1 do
    local zoneRow = gy >= zy0 and gy <= zy1
    local base = gy * S
    for gx = 0, S - 1 do
      local need
      if dist then
        need = dist[base + gx] > TOUCH or (zoneRow and gx >= zx0 and gx <= zx1)
      else
        need = true
      end
      if need then
        local d = depthAt(gx, gy)
        if d > 0 then
          local raw = tb:getHeightGrid(gx, gy)
          local lift = ph and ph.initialLift(gx, gy, d) or 0
          local nr = raw - d + lift
          if nr < clampRaw then
            P.shortfall[base + gx] = clampRaw - nr
            nr = clampRaw
          end
          tb:setHeightGrid(gx, gy, nr)
          P.recordSink(base + gx, raw, lift, raw - d)
          if gx < bx0 then bx0 = gx end
          if gx > bx1 then bx1 = gx end
          if gy < by0 then by0 = gy end
          if gy > by1 then by1 = gy end
          P.markLowered(gx, gy)
        end
      end
    end
  end
  if P.sinkCount > 0 then
    P.sinkBox = { bx0, by0, bx1, by1 }
    tb:updateGrid(vec3(bx0, by0, 0), vec3(bx1, by1, 0))
  else
    P.sinkBox = nil
  end
  sinkApplied = true
  P.stats.sinkMs = t0:stopAndReset()
  P.stats.sunkVertices = P.sinkCount
  log('I', logTag, sfmt('sink pass: %d vertices lowered in %.1f ms', P.sinkCount, P.stats.sinkMs))
end

function P.restoreTerrain()
  if not sinkApplied or not ter then sinkApplied = false; return end
  local tb = ter.tb
  local S = ter.size
  for k = 0, P.sinkCount - 1 do
    local i = P.sinkIdx[k]
    tb:setHeightGrid(i % S, floor(i / S), P.sinkRaw[k])
  end
  if P.sinkBox then tb:updateGrid(vec3(P.sinkBox[1], P.sinkBox[2], 0), vec3(P.sinkBox[3], P.sinkBox[4], 0)) end
  log('I', logTag, sfmt('terrain restored (%d vertices)', P.sinkCount))
  P.sinkCount = 0
  sinkApplied = false
  P.shortfall = {}
  P.sinkBox = nil
end

-------------------------------------------------------------------------------
-- materials
-------------------------------------------------------------------------------
-- Create a Material unless one with this name exists. fields: list of {name, value,
-- stage} (stage = material layer index, default 0).
function M.createMaterial(name, fields)
  local m = scenetree.findObject(name)
  if m then
    if P.ownedMaterials[name] == nil then P.ownedMaterials[name] = false end
    return m
  end
  m = createObject('Material')
  if not m then return nil end
  m:setField('mapTo', 0, name)
  for _, f in ipairs(fields) do
    if f[2] ~= nil and f[2] ~= '' then m:setField(f[1], f[3] or 0, tostring(f[2])) end
  end
  m.canSave = false
  m:registerObject(name)
  P.ownedMaterials[name] = true
  return m
end

-- BeamNG picks the texture colour space from the file name (*.color.* = sRGB).
-- Copy uncoloured base maps once per level so object materials read them as sRGB.
-- A *.color.<ext>.link file in the user folder that points at the original map.
-- Same format the engine's asset deduplicator writes (editor/assetDeduplicator.lua:90,
-- FS:isLinkFile). No 100 MB copy; whether the texture loader takes the colour space from
-- the link name is checked in game (the log says which method is used).
function P.srgbLink(path, dst)
  local ok = pcall(function()
    jsonWriteFile(dst .. '.link', { path = path, type = 'normal' }, true)
  end)
  return ok and FS.isLinkFile ~= nil and FS:isLinkFile(dst)
end

function P.srgbCopy(path)
  if not path or path == '' then return path end
  local method = cfg.materials.srgbMethod or 'copy'
  if method == 'off' or path:lower():find('.color.', 1, true) then return path end
  local base, ext = path:match('([^/\\]+)%.([^%./\\]+)$')
  if not base then return path end
  local dir = '/temp/deepnode/' .. tostring(P.levelName)
  local dst = dir .. '/' .. base .. '.color.' .. ext
  local srcSize = FS.fileSize and FS:fileSize(path) or nil
  local function good()
    if not FS:fileExists(dst) then return false end
    if FS.isLinkFile and FS:isLinkFile(dst) then return true end
    return not srcSize or not FS.fileSize or FS:fileSize(dst) == srcSize
  end
  if good() then return dst end
  pcall(function() FS:directoryCreate(dir, true) end)
  local how = nil
  if method == 'link' then
    if P.srgbLink(path, dst) then how = 'link' end
  else
    pcall(function() FS:copyFile(path, dst) end)
    if good() then
      how = 'FS:copyFile'
    else
      -- byte copy through the game's file system (io.open reads mods and zips and
      -- writes into the user folder), 4 MB at a time
      pcall(function()
        local fi = io.open(path, 'rb')
        if not fi then return end
        local fo = io.open(dst, 'wb')
        if not fo then fi:close(); return end
        local guard = 0
        while guard < 10000 do
          guard = guard + 1
          local chunk = fi:read(4194304)
          if not chunk or #chunk == 0 then break end
          fo:write(chunk)
        end
        fi:close()
        fo:close()
      end)
      if good() then
        how = 'io copy'
      elseif P.srgbLink(path, dst) then
        how = 'link (copies failed)'
      end
    end
  end
  if how then
    log('I', logTag, sfmt('sRGB copy of %s -> %s (%s, %.1f MB)', path, dst, how, (srcSize or 0) / 1048576))
    return dst
  end
  log('W', logTag, 'could not make an sRGB copy of ' .. path .. '; colours may look washed out')
  return path
end

function P.createFallbackMaterial()
  M.createMaterial(P.FALLBACK_MAT, {
    { 'version', '1.5' },
    { 'baseColorFactor', '0.23 0.17 0.11 1' },
    { 'roughnessFactor', '0.85' },
    { 'metallicFactor', '0' },
    { 'castShadows', '0' },
  })
end

-- terrain material field, '' when empty or "0" (unset texture slots read "0")
function P.texField(m, name)
  local v = P.mtlField(m, name)
  if v == '0' then return '' end
  return v
end

-- Tyre lump material of a soft layer: the layer's own patch textures (so mud on the
-- tyres is the mud the tyre drove through), darker by the kind's `wet` factor, with a
-- fixed roughness (wet mud is glossy, sand matte) and no roughness/AO maps.
P.clodMatNames = {}
function P.createClodMaterial(e, L, fields, tint)
  local ks = cfg.clods.kinds or {}
  local K = ks[L.kind or 'mud'] or ks.mud or {}
  local wet = tonumber(K.wet) or 0.7
  local cf = {}
  local hasBase = false
  for _, f in ipairs(fields) do
    local n = f[1]
    if n == 'baseColorMap' then hasBase = true end
    if n ~= 'baseColorFactor' and n ~= 'roughnessMap' and n ~= 'roughnessFactor' and n ~= 'ambientOcclusionMap' then
      cf[#cf + 1] = f
    end
  end
  if not hasBase then return end -- no texture: the lumps keep the generic clod material
  cf[#cf + 1] = { 'baseColorFactor', sfmt('%g %g %g 1', (tint[1] or 1) * wet, (tint[2] or 1) * wet, (tint[3] or 1) * wet) }
  cf[#cf + 1] = { 'roughnessFactor', sfmt('%g', tonumber(K.roughness) or 0.4) }
  local name = sfmt('deepnode_clod_%s_L%d', tostring(P.levelName), e)
  if M.createMaterial(name, cf) then P.clodMatNames[e] = name end
end

-- lump material and UV mapping of soft layer e (nil when the layer has none)
function M.clodMaterial(e)
  local n = e and P.clodMatNames[e]
  if not n then return nil end
  local uv = P.matUV[e]
  return n, uv and uv.size or 4
end

-- soft layer index and kind under a world point (zones: the zone layer, mud)
function M.mudLayerAt(x, y)
  if not ter then return nil, 'mud' end
  local gx, gy = floor((x - ter.ox) / ter.sq + 0.5), floor((y - ter.oy) / ter.sq + 0.5)
  local e = layerAt(gx, gy)
  if layerSoft[e] == 0 then
    e = layerAt(gx - 1, gy)
    if layerSoft[e] == 0 then e = layerAt(gx, gy - 1) end
    if layerSoft[e] == 0 then e = P.zoneMat end
  end
  local L = layers[e]
  return e, (L and L.soft and L.kind) or 'mud'
end

-- Patch material of each soft layer, built to read like the terrain shader
-- (shaders/common/terrain/terrain.h.hlsl, calculateValue):
--   colour    = base + (macro * 2 - 1) * macroStrength + (detail * 2 - 1) * detailStrength
--   roughness, AO: the same with their own maps and strengths
--   normal    = base normal, blended towards the macro and then the detail normal
-- The base map spans baseColorBaseTexSize metres with V flipped (fixBaseCoords); macro
-- and detail tile every *TexSize metres, not flipped. An object material layer reads
--   colour = factor * saturate(map + (detailMap * 2 - 1) * detailStrength)
-- (shaders/common/material/shadergen/defaultMat.hlsl, blendDetail) and later layers
-- blend in by their opacity. Two layers at opacity 0.5, one with the macro as its detail
-- map and one with the detail map, both at twice the terrain strength, average to the
-- terrain's sum. The detail UVs are the base UVs times detailScale; a negative V scale
-- undoes the base flip (else the detail, e.g. sand ripples, is mirrored).
-- Strengths are the terrain's near values (the patches are seen from close by).
function P.terrainLayerMaps(m)
  local function tex(name) return P.texField(m, name) end
  local function num(name) return tonumber(P.mtlField(m, name)) or 0 end
  local function near(name, def) return P.firstNumber(P.mtlField(m, name)) or def end
  local r = {
    base = tex('baseColorBaseTex'), baseSize = num('baseColorBaseTexSize'),
    detail = tex('baseColorDetailTex'), detailSize = num('baseColorDetailTexSize'), detailStr = near('baseColorDetailStrength', nil),
    macro = tex('baseColorMacroTex'), macroSize = num('baseColorMacroTexSize'), macroStr = near('baseColorMacroStrength', 0),
    nrm = tex('normalBaseTex'), nrmDetail = tex('normalDetailTex'), nrmDetailSize = num('normalDetailTexSize'),
    nrmDetailStr = near('normalDetailStrength', nil), nrmMacro = tex('normalMacroTex'), nrmMacroSize = num('normalMacroTexSize'),
    nrmMacroStr = near('normalMacroStrength', 0),
    rough = tex('roughnessBaseTex'), roughDetail = tex('roughnessDetailTex'), roughDetailStr = near('roughnessDetailStrength', 0),
    roughMacro = tex('roughnessMacroTex'), roughMacroStr = near('roughnessMacroStrength', 0),
    ao = tex('aoBaseTex'), aoDetail = tex('aoDetailTex'), aoDetailStr = near('aoDetailStrength', 0),
    aoMacro = tex('aoMacroTex'), aoMacroStr = near('aoMacroStrength', 0),
  }
  return r
end

function P.createLayerMaterials()
  P.matNames = {}
  P.matUV = {}
  P.clodMatNames = {}
  local maxBase = 0
  local mc = cfg.materials
  for e, L in pairs(layers) do
    if L.soft then
      local m = L.mtl
      local name = sfmt('deepnode_%s_L%d', tostring(P.levelName), e)
      local t = P.terrainLayerMaps(m)
      -- The terrain shader's *TexSize values count heightmap squares, not metres
      -- (terrainImpl.hlsl: uv = terrainUv * layerSize, then uv / size): on Johnson Valley
      -- (0.75 m squares) the 4096 base map spans the 3072 m terrain. Spanning it over
      -- 4096 m put the base map's dark patches in the wrong places.
      local sq = ter.sq
      t.macroSize = (t.macroSize or 0) * sq
      local base, bsize = t.base, t.baseSize * sq
      local detail, dsize = t.detail, t.detailSize * sq
      local dstr = t.detailStr or mc.defaultDetailStrength or 0.5
      local nrmDStr = t.nrmDetailStr or mc.defaultNormalDetailStrength or 0.8
      if base == '' then
        -- legacy (v1) terrain material
        base = m.getDiffuseMap and tostring(m:getDiffuseMap() or '') or ''
        bsize = m.getDiffuseSize and tonumber(m:getDiffuseSize()) or bsize
        detail = m.getDetailMap and tostring(m:getDetailMap() or '') or ''
        dsize = m.getDetailSize and tonumber(m:getDetailSize()) or dsize
        dstr = m.getDetailStrength and tonumber(m:getDetailStrength()) or dstr
        t.nrm = m.getNormalMap and tostring(m:getNormalMap() or '') or ''
        t.nrmDetail, t.rough, t.ao, t.macro, t.nrmMacro, t.roughMacro, t.aoMacro, t.roughDetail, t.aoDetail = '', '', '', '', '', '', '', '', ''
      end
      if dsize <= 0 then dsize = mc.defaultDetailSize or 2 end
      local uvBase = true
      if mc.baseSizeFrom ~= 'layer' or bsize <= 0 then bsize = ter.worldSize end
      if base == '' and detail ~= '' then
        -- detail-only layer (spinMud): tile the detail texture as the colour map
        base, bsize, detail, uvBase = detail, dsize, '', false
      end
      if uvBase and bsize > maxBase then maxBase = bsize end
      P.matUV[e] = { size = bsize, base = uvBase }
      local tint = mc.tint or { 1, 1, 1 }
      -- detail UV scale for a texture tiling every `size` m; V negated against the flipped
      -- base V (only when the base is in terrain UV)
      local function scale(size)
        local s = bsize / max(size, 0.01)
        return sfmt('%g %g', s, (uvBase and mc.flipV) and -s or s)
      end
      local useMacro = mc.macro ~= false and t.macro ~= '' and (t.macroSize or 0) > 0 and uvBase
      local useDetail = mc.useDetail and detail ~= '' and dsize > 0
      local twoStages = useMacro and useDetail
      local k = twoStages and 2 or 1 -- strength factor: each stage carries half
      local F = {}
      local function add(field, value, stage) F[#F + 1] = { field, value, stage or 0 } end
      local baseMap = base ~= '' and (uvBase and P.srgbCopy(base) or base) or nil
      local nst = twoStages and 2 or 1
      for st = 0, nst - 1 do
        if baseMap then
          add('baseColorMap', baseMap, st)
          add('baseColorFactor', sfmt('%g %g %g 1', tint[1] or 1, tint[2] or 1, tint[3] or 1), st)
        else
          add('baseColorFactor', '0.23 0.17 0.11 1', st)
        end
        if t.nrm ~= '' and mc.normalMaps ~= false then add('normalMap', t.nrm, st) end
        local rOver = tonumber(mc.roughness) or -1
        if rOver >= 0 then
          add('roughnessFactor', sfmt('%g', rOver), st)
        elseif t.rough ~= '' then
          add('roughnessMap', t.rough, st)
        else
          add('roughnessFactor', '0.8', st)
        end
        if t.ao ~= '' and mc.aoMaps ~= false then add('ambientOcclusionMap', t.ao, st) end
        -- stage 0: macro (or the detail when there is no macro); stage 1: detail
        local isMacro = useMacro and st == 0
        local dm = isMacro and t.macro or (useDetail and detail or '')
        if dm ~= '' then
          local str = isMacro and t.macroStr or dstr * (mc.detailStrength or 1)
          add('detailMap', dm, st)
          add('detailScale', scale(isMacro and t.macroSize or dsize), st)
          add('detailBaseColorMapStrength', sfmt('%g', str * k), st)
          local nd = isMacro and t.nrmMacro or t.nrmDetail
          if nd ~= '' and mc.normalMaps ~= false then
            add('detailNormalMap', nd, st)
            add('detailNormalMapStrength', sfmt('%g', (isMacro and t.nrmMacroStr or nrmDStr) * k), st)
          end
          local rd = isMacro and t.roughMacro or t.roughDetail
          if rd ~= '' and rOver < 0 and t.rough ~= '' then
            add('roughnessDetailMap', rd, st)
            add('detailRoughnessMapStrength', sfmt('%g', (isMacro and t.roughMacroStr or t.roughDetailStr) * k), st)
          end
          local ad = isMacro and t.aoMacro or t.aoDetail
          if ad ~= '' and t.ao ~= '' and mc.aoMaps ~= false then
            add('ambientOcclusionDetailMap', ad, st)
            add('detailAoMapStrength', sfmt('%g', (isMacro and t.aoMacroStr or t.aoDetailStr) * k), st)
          end
        end
        if st > 0 then add('opacityFactor', '0.5', st) end
      end
      add('version', '1.5')
      add('castShadows', '0')
      add('translucent', '0')
      if twoStages then add('activeLayers', '2') end
      log('I', logTag, sfmt('patch material %s: base %s (%g m, %s), macro %s (%g m, %g), detail %s (%g m, %g)', name, base,
        P.matUV[e].size, P.matUV[e].base and 'terrain UV' or 'tiled', useMacro and t.macro or '-', t.macroSize or 0,
        t.macroStr or 0, useDetail and detail or '-', dsize, dstr))
      if M.createMaterial(name, F) then P.matNames[e] = name end
      -- tyre lumps: one plain layer (base + detail), see createClodMaterial
      local cf = {}
      for _, f in ipairs(F) do
        if (f[3] or 0) == 0 and f[1] ~= 'activeLayers' and f[1] ~= 'opacityFactor' then cf[#cf + 1] = { f[1], f[2] } end
      end
      P.createClodMaterial(e, L, cf, tint)
      -- source maps of the terrain colour (tyre coat colour, see P.initGroundColors)
      P.matUV[e].src = base
      P.matUV[e].macro, P.matUV[e].macroStr = useMacro and t.macro or '', t.macroStr or 0
      P.matUV[e].detail, P.matUV[e].detailStr = useDetail and detail or '', dstr * (mc.detailStrength or 1)
    end
  end
  P.baseSize = maxBase > 0 and maxBase or ter.worldSize
end

-- Terrain colour under a point, for the tyre coat (wheelMud takes the colour of the ground
-- it drove through). The terrain shader's colour is
--   base + (macro * 2 - 1) * macroStrength + (detail * 2 - 1) * detailStrength
-- with the base sRGB-decoded and macro/detail added as data. Macro and detail tile every
-- few metres, so a tyre sees their mean: one offset per layer. The base map is kept as a
-- coarse grid (linear RGB, groundGrid cells a side); a tiled base (detail-only layer) is
-- one mean colour. Read once at start with GBitmap (PNG/JPG/DDS as the engine loads them).
P.groundCols = {}
local function srgbLin(c)
  c = c / 255
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

-- mean of a bitmap over n x n samples: linear RGB (sRGB-decoded) and raw 0..1;
-- byAlpha: weighted by the alpha (tyre textures: coverage order, so the mean of what
-- shows first, the packed part)
function P.bitmapMean(bmp, n, byAlpha)
  local w, h = bmp:getWidth(), bmp:getHeight()
  if not w or w <= 0 or not h or h <= 0 then return nil end
  local c = ColorI(0, 0, 0, 0)
  local lr, lg, lb, rr, rg, rb, k = 0, 0, 0, 0, 0, 0, 0
  for i = 0, n - 1 do
    for j = 0, n - 1 do
      if bmp:getColor(floor((i + 0.5) / n * w), floor((j + 0.5) / n * h), c) then
        local wt = byAlpha and c.a / 255 or 1
        lr, lg, lb = lr + srgbLin(c.r) * wt, lg + srgbLin(c.g) * wt, lb + srgbLin(c.b) * wt
        rr, rg, rb = rr + c.r / 255 * wt, rg + c.g / 255 * wt, rb + c.b / 255 * wt
        k = k + wt
      end
    end
  end
  if k <= 0 then return nil end
  return { lr / k, lg / k, lb / k }, { rr / k, rg / k, rb / k }
end

local bitmapCache = {}
function M.loadBitmap(path)
  if not path or path == '' or not GBitmap then return nil end
  if bitmapCache[path] == nil then
    local b = GBitmap()
    local ok = pcall(function() return b:loadFile(path) end) and b:getWidth() and b:getWidth() > 0
    bitmapCache[path] = ok and b or false
  end
  return bitmapCache[path] or nil
end
function M.releaseBitmaps() bitmapCache = {} end

-- mean linear colour { r, g, b } of a texture file (nil when it cannot be read)
function M.textureMean(path, byAlpha)
  local b = M.loadBitmap(path)
  local lin = b and P.bitmapMean(b, 32, byAlpha)
  bitmapCache[path] = nil
  return lin
end

function P.initGroundColors()
  P.groundCols = {}
  if cfg.clods.groundColor == false or not GBitmap then return end
  local t0 = newTimer()
  local N = cfg.clods.groundGrid or 128
  for e, L in pairs(layers) do
    local uv = P.matUV[e]
    if L.soft and uv and uv.src and uv.src ~= '' then
      local off = { 0, 0, 0 }
      for _, m in ipairs({ { uv.macro, uv.macroStr }, { uv.detail, uv.detailStr } }) do
        local b = (m[1] or '') ~= '' and (m[2] or 0) ~= 0 and M.loadBitmap(m[1])
        local _, raw = b and P.bitmapMean(b, 32)
        if raw then for i = 1, 3 do off[i] = off[i] + (raw[i] * 2 - 1) * m[2] end end
      end
      local bmp = M.loadBitmap(uv.src)
      if bmp then
        local G = { off = off }
        if uv.base then
          local w, h = bmp:getWidth(), bmp:getHeight()
          local c = ColorI(0, 0, 0, 0)
          local grid = {}
          for j = 0, N - 1 do
            for i = 0, N - 1 do
              local q = (j * N + i) * 3
              if bmp:getColor(floor((i + 0.5) / N * w), floor((j + 0.5) / N * h), c) then
                grid[q + 1], grid[q + 2], grid[q + 3] = srgbLin(c.r), srgbLin(c.g), srgbLin(c.b)
              else
                grid[q + 1], grid[q + 2], grid[q + 3] = 0.2, 0.17, 0.13
              end
            end
          end
          G.grid, G.n = grid, N
        else
          G.mean = P.bitmapMean(bmp, 32)
        end
        if G.grid or G.mean then P.groundCols[e] = G end
      end
    end
  end
  M.releaseBitmaps()
  P.stats.groundColorMs = t0:stopAndReset()
end

-- linear terrain colour at a world point on soft layer e; nil when unknown
function M.groundColorAt(x, y, e)
  local G = e and P.groundCols[e]
  if not G then return nil end
  local r, g, b
  if G.grid then
    local u, v = M.uvOf(x, y, e)
    local n = G.n
    local i = floor((u - floor(u)) * n) % n
    local j = floor((v - floor(v)) * n) % n
    local q = (j * n + i) * 3
    r, g, b = G.grid[q + 1], G.grid[q + 2], G.grid[q + 3]
  else
    r, g, b = G.mean[1], G.mean[2], G.mean[3]
  end
  local o = G.off
  return max(0.005, r + o[1]), max(0.005, g + o[2]), max(0.005, b + o[3])
end

function P.allMaterialNames()
  local list = { P.FALLBACK_MAT }
  for _, n in pairs(P.matNames) do list[#list + 1] = n end
  for _, n in pairs(P.clodMatNames) do list[#list + 1] = n end
  local w = P.mod('wheelMud')
  if w and w.materialNames then for _, n in ipairs(w.materialNames()) do list[#list + 1] = n end end
  local dec = P.mod('decals')
  if dec and dec.materialNames then for _, n in ipairs(dec.materialNames()) do list[#list + 1] = n end end
  return list
end

-- One small mesh 20 m under the terrain referencing every mod material, kept until
-- Stop, so entering a new mud area never stalls on texture or shader work (pitfall 7).
function P.createPreload()
  local names = P.allMaterialNames()
  local subs = {}
  local h = 40
  for i, n in ipairs(names) do
    local o = (i - 1) * 0.5
    subs[#subs + 1] = {
      verts = { { x = -h + o, y = -h, z = 0 }, { x = -h + o, y = h, z = 0 }, { x = h + o, y = h, z = 0 } },
      normals = { { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = 1 } },
      uvs = { { u = 0, v = 0 }, { u = 0, v = 1 }, { u = 1, v = 1 } },
      faces = { { v = 0, n = 0, u = 0 }, { v = 1, n = 1, u = 1 }, { v = 2, n = 2, u = 2 } },
      material = n,
    }
  end
  local o = createObject('ProceduralMesh')
  if not o then return end
  o.canSave = false
  o:registerObject(sfmt('deepnode_preload_%d', P.session))
  local tm = P.mod('tileMesh')
  local grp = tm and tm.getGroup and tm.getGroup() or scenetree.MissionGroup
  if grp then
    if grp.addObject then grp:addObject(o.obj) elseif grp.add then grp:add(o.obj) end
  end
  o:createMesh({ subs })
  P.preloadObj = o
  P.preloadTimer = 0
end

function P.updatePreload(dt)
  if not P.preloadObj then return end
  P.preloadTimer = P.preloadTimer - dt
  if P.preloadTimer > 0 then return end
  P.preloadTimer = 2
  local x, y = core_camera.getPositionXYZ()
  if not (isFinite(x) and isFinite(y)) then return end
  local z = ter.tb:getHeight(vec3(x, y, 0))
  if not isFinite(z) then return end
  P.preloadObj:setPosition(vec3(x, y, z - 20))
end

function P.deleteOwnedMaterials(objectsAlive)
  if objectsAlive then
    for name, owned in pairs(P.ownedMaterials) do
      if owned then
        local m = scenetree.findObject(name)
        if m then m:delete() end
      end
    end
  end
  P.ownedMaterials = {}
end

-------------------------------------------------------------------------------
-- tiles
-------------------------------------------------------------------------------
P.vbufN = 0
P.vbRest = nil
P.vbFloor = nil
P.vbMem = nil
P.vbDep = nil
function P.ensureVBuf(n)
  if n > P.vbufN then
    P.vbufN = n
    P.vbRest = ffi.new('float[?]', n); P.vbFloor = ffi.new('float[?]', n)
    P.vbMem = ffi.new('uint8_t[?]', n); P.vbDep = ffi.new('uint8_t[?]', n)
  end
end

function P.inTerrain(tx, ty)
  local S = ter.size
  return tx >= 0 and ty >= 0 and tx * TS < S - 1 and ty * TS < S - 1
end

-- terrain vertex data of tile (tx,ty) into the given arrays; returns patched count
function P.computeTileTerrain(tx, ty, vRest, vFloor, vMem, patched, mats)
  local S = ter.size
  local W = TS + 1
  local gx0, gy0 = tx * TS, ty * TS
  P.ensureVBuf(W * W)
  for j = 0, TS do
    for i = 0, TS do
      local idx = j * W + i
      local rest, flo, d, mem = vertexInfo(gx0 + i, gy0 + j)
      vRest[idx] = rest
      if vFloor then vFloor[idx] = flo end
      P.vbMem[idx] = mem and 1 or 0
      if vMem then vMem[idx] = P.vbMem[idx] end
      P.vbDep[idx] = d > 0 and 1 or 0
    end
  end
  local count = 0
  for sj = 0, TS - 1 do
    for si = 0, TS - 1 do
      local q = sj * TS + si
      local gx, gy = gx0 + si, gy0 + sj
      local p = 0
      if gx < S - 1 and gy < S - 1 then
        local a = sj * W + si
        local b, c = a + 1, a + W
        local d = c + 1
        if P.vbMem[a] ~= 0 and P.vbMem[b] ~= 0 and P.vbMem[c] ~= 0 and P.vbMem[d] ~= 0
          and (P.vbDep[a] + P.vbDep[b] + P.vbDep[c] + P.vbDep[d]) > 0 then
          p = 1
        end
      end
      patched[q] = p
      if p == 1 then
        count = count + 1
        mats[q] = squareMaterial(gx, gy)
      else
        mats[q] = 255
      end
    end
  end
  return count
end

function M.fillTerrainTile(tx, ty, zRest, patched, mats)
  if not P.inTerrain(tx, ty) then return 0 end
  local key = ty * KEY + tx
  if P.emptyTiles[key] then return 0 end
  local count = P.computeTileTerrain(tx, ty, zRest, nil, nil, patched, mats)
  if count == 0 then P.emptyTiles[key] = true end
  return count
end

P.scratchRest = nil
P.scratchPatched = nil
P.scratchMats = nil
function P.isTileEmpty(tx, ty)
  if not P.inTerrain(tx, ty) then return true end
  local key = ty * KEY + tx
  if P.emptyTiles[key] then return true end
  if tiles[key] then return false end
  local W = TS + 1
  -- sized by the tile size, which changes with the level's square size: a buffer kept
  -- from the previous level (5 squares on gridmap, 7 on Johnson Valley) overflowed, and
  -- the error repeated every frame
  if (P.scratchN or 0) < W * W then
    P.scratchN = W * W
    P.scratchRest = ffi.new('float[?]', W * W)
    P.scratchPatched = ffi.new('uint8_t[?]', W * W)
    P.scratchMats = ffi.new('uint8_t[?]', W * W)
  end
  local c = P.computeTileTerrain(tx, ty, P.scratchRest, nil, nil, P.scratchPatched, P.scratchMats)
  if c == 0 then P.emptyTiles[key] = true; return true end
  return false
end

function P.prepareTile(tx, ty)
  if not P.inTerrain(tx, ty) then return nil end
  local key = ty * KEY + tx
  local W = TS + 1
  local vRest, vFloor = ffi.new('float[?]', W * W), ffi.new('float[?]', W * W)
  local vMem = ffi.new('uint8_t[?]', W * W)
  local sqPatched, sqMat = ffi.new('uint8_t[?]', TS * TS), ffi.new('uint8_t[?]', TS * TS)
  local count = P.computeTileTerrain(tx, ty, vRest, vFloor, vMem, sqPatched, sqMat)
  P.stats.prepared = P.stats.prepared + 1
  if count == 0 then P.emptyTiles[key] = true; return nil end

  local NW = N + 1
  local rest, flo = ffi.new('float[?]', NW * NW), ffi.new('float[?]', NW * NW)
  local rut, track = ffi.new('uint8_t[?]', NW * NW), ffi.new('uint8_t[?]', NW * NW)
  local soft = ffi.new('uint8_t[?]', N * N)
  ffi.fill(rut, NW * NW, 128)
  local peakLo, peakHi = ffi.new('uint8_t[?]', NW * NW), ffi.new('uint8_t[?]', NW * NW)
  ffi.fill(peakLo, NW * NW, 128)
  ffi.fill(peakHi, NW * NW, 128)
  -- soil memory (stamp.soil): passes, last wheel and time, first-pass depth (2.5 mm steps)
  local passN, passKey, passT, z1 = nil, nil, nil, nil
  if cfg.stamp.soil and cfg.stamp.soil.enabled then
    passN, z1 = ffi.new('uint8_t[?]', NW * NW), ffi.new('uint8_t[?]', NW * NW)
    passKey, passT = ffi.new('uint16_t[?]', NW * NW), ffi.new('float[?]', NW * NW)
  end
  for j = 0, N do
    local s = j / CPS
    local sj = floor(s); if sj > TS - 1 then sj = TS - 1 end
    local fj = s - sj
    for i = 0, N do
      local r = i / CPS
      local si = floor(r); if si > TS - 1 then si = TS - 1 end
      local fi = r - si
      local a = sj * W + si
      local w00, w10, w01, w11 = (1 - fi) * (1 - fj), fi * (1 - fj), (1 - fi) * fj, fi * fj
      local idx = j * NW + i
      rest[idx] = vRest[a] * w00 + vRest[a + 1] * w10 + vRest[a + W] * w01 + vRest[a + W + 1] * w11
      flo[idx] = vFloor[a] * w00 + vFloor[a + 1] * w10 + vFloor[a + W] * w01 + vFloor[a + W + 1] * w11
    end
  end
  local matSet, matList = {}, {}
  for cj = 0, N - 1 do
    local sqRow = floor(cj / CPS) * TS
    for ci = 0, N - 1 do
      local q = sqRow + floor(ci / CPS)
      if sqPatched[q] ~= 0 then
        soft[cj * N + ci] = 1
        local m = sqMat[q]
        if not matSet[m] then matSet[m] = true; matList[#matList + 1] = m end
      end
    end
  end
  local t = {
    key = key, tx = tx, ty = ty, gx0 = tx * TS, gy0 = ty * TS,
    x0 = ter.ox + tx * TILE, y0 = ter.oy + ty * TILE,
    ts = TS, cps = CPS, N = N, cell = CELL,
    vRest = vRest, vFloor = vFloor, vMem = vMem, sqPatched = sqPatched, sqMat = sqMat,
    rest = rest, floor = flo, rut = rut, track = track, soft = soft,
    peakLo = peakLo, peakHi = peakHi, relaxing = false,
    passN = passN, passKey = passKey, passT = passT, z1 = z1,
    matList = matList, rutted = false, dirty = true, state = 'active',
    lastUse = simTime, lastBuild = -huge, obj = nil, built = false,
  }
  P.tileFlush(t)
  return t
end
M.prepareTileForTests = P.prepareTile

P.NB = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }

-- Only the neighbours' border rows change (1.5 cm, sectors.drop): borderDirty waits
-- ring.borderRebuildGap s or rides along with the next real rebuild. Rebuilding them at
-- once was ~7 full tile uploads per second for one truck.
function P.markNeighboursDirty(t)
  for k = 1, 8 do
    local n = tiles[(t.ty + P.NB[k][2]) * KEY + t.tx + P.NB[k][1]]
    if n and n.state == 'active' and not n.dirty then n.borderDirty = true end
  end
end

-- Border rule codes (see tileMesh.borderCode) for an active tile, or for a frozen
-- tile drawn inside a sector (forSector). Seam rule (pitfall 9): without cover a
-- shared vertex lifts only when every tile sharing it exists; with cover it stays
-- lifted (lowered by the sector drop so both surfaces meet).
function P.borderRule(t, forSector)
  local rule = {}
  for k = 1, 8 do
    local tx, ty = t.tx + P.NB[k][1], t.ty + P.NB[k][2]
    local code = 0
    if P.inTerrain(tx, ty) then
      local n = tiles[ty * KEY + tx]
      if n then
        if not forSector then
          if not n.obj then code = 1 end -- active or frozen, a tile with its own mesh meets this one
        end
      elseif not P.isTileEmpty(tx, ty) then
        -- the sector draws the neighbour's mud at the same height
        code = forSector and 0 or 1
      end
    end
    rule[k] = code
  end
  return rule
end
M.borderRule = P.borderRule

function P.notifyVehiclesDrop(key)
  for vid, vs in pairs(P.vehs) do
    if vs.sent[key] then
      vs.sent[key] = nil
      local veh = getObjectByID(vid)
      if veh then veh:queueLuaCommand(sfmt('if deepnode_vehicle then deepnode_vehicle.dropTile(%d) end', key)) end
    end
  end
end

-- A new tile without a mesh of its own changes no neighbour's border rule (an empty
-- neighbour drawn by its sector and a tile drawn by its sector read the same), so the
-- neighbours are not rebuilt here; they are when this tile gets its own mesh.
-- P.act: active tiles, P.own: frozen tiles that kept their own mesh. The per-frame
-- passes walk these instead of every tile (up to ring.frozenLimit frozen ones).
P.act, P.own = {}, {}
function P.addActive(t)
  tiles[t.key] = t
  P.act[t.key] = t
  t.state = 'active'
  P.activeCount = P.activeCount + 1
end

function P.reactivate(t)
  local sk = P.sectorKeyOfTile(t.tx, t.ty)
  t.state = 'active'
  P.act[t.key] = t
  P.own[t.key] = nil
  P.frozenCount = P.frozenCount - 1
  P.activeCount = P.activeCount + 1
  P.frozenPerSector[sk] = (P.frozenPerSector[sk] or 1) - 1
  if P.frozenPerSector[sk] <= 0 then P.frozenPerSector[sk] = nil end
  local fm = P.mod('farMesh')
  if t.obj then
    -- kept its own mesh while frozen: the sector already leaves it out
    P.frozenOwnCount = P.frozenOwnCount - 1
  elseif fm then
    -- Without its old mesh back the sector keeps drawing this tile (rutted cells) until
    -- the tile gets its own mesh, which marks the sector then: no rebuild needed now.
    -- With it back, a sector build that started before took the tile in: redo it.
    local o = fm.reclaim(sk, t.key)
    if o then
      t.obj = o
      t.geoN = nil -- not the mesh tileMesh.present last saw for this tile: upload again
      fm.markDirty(sk, true)
      -- neighbours' border rules follow whether this tile has its own mesh
      P.markNeighboursDirty(t)
    end
  end
  -- Nothing to rebuild otherwise: the data did not change, and without its own mesh
  -- the sector keeps drawing it until a tyre writes into it (writeOne marks it) or it
  -- comes within ownMeshRadius of a vehicle. Before, every old rut tile entering a
  -- look-ahead box got a mesh upload plus a sector rebuild (~11 uploads/s, 1 truck).
  t.lastUse = simTime
  P.changedTiles[t.key] = true
end

-- An active tile leaves the ring: frozen when rutted, released otherwise. Its mesh
-- is handed to the sector and destroyed only after the sector was rebuilt.
-- A rutted tile near the camera keeps its own mesh while frozen (ring.frozenOwnMesh*):
-- re-meshing a whole sector to take over its ruts cost 10-15 ms per rebuild in game
-- (one createMesh of thousands of vertices), every time a vehicle drove on.
P.frozenOwnCount = 0
function P.camDist2(t)
  if not P.camx then return 0 end
  local cx, cy = t.x0 + TILE * 0.5, t.y0 + TILE * 0.5
  return (cx - P.camx) ^ 2 + (cy - P.camy) ^ 2
end

function P.demote(t)
  local sk = P.sectorKeyOfTile(t.tx, t.ty)
  local o = t.obj
  P.act[t.key] = nil
  t.pendSince, t.visSince = nil, nil -- rut lag readout: the sector takes it over
  P.activeCount = P.activeCount - 1
  P.finishRelax(t)
  t.outSince = nil
  local fm = P.mod('farMesh')
  local r = cfg.ring.frozenOwnMeshRadius or 0
  if t.rutted and o and r > 0 and P.frozenOwnCount < 4 * (cfg.ring.frozenOwnMeshMax or 150) and P.camDist2(t) < r * r then
    -- keeps its mesh: the neighbours' border rules do not change (no rebuilds), and the
    -- spare object goes back to the pool (a frozen tile rebuilds at most once more)
    t.state = 'frozen'
    t.lastUse = simTime
    P.frozenCount = P.frozenCount + 1
    P.frozenPerSector[sk] = (P.frozenPerSector[sk] or 0) + 1
    P.frozenOwnCount = P.frozenOwnCount + 1
    P.own[t.key] = t
    if fm and fm.sectorState and fm.sectorState(sk) == 'hidden' then o:setHidden(true) end
    if not t.dirty then P.mod('tileMesh').dropSpare(t) end
    P.changedTiles[t.key] = true
    return
  end
  t.obj = nil
  P.mod('tileMesh').dropSpare(t)
  if t.rutted and not o and fm then
    -- dug but never meshed (rebuild budget used up): only the sector can draw these
    -- ruts now, and until it does there is a hole down to the hard floor
    fm.markDirty(sk, true)
  end
  if t.rutted then
    t.state = 'frozen'
    t.lastUse = simTime
    P.frozenCount = P.frozenCount + 1
    P.frozenPerSector[sk] = (P.frozenPerSector[sk] or 0) + 1
  else
    tiles[t.key] = nil
    P.notifyVehiclesDrop(t.key)
  end
  -- An untouched tile that the sector still draws (secOut false: sectors leave out
  -- rutted tiles only) just drops its mesh: same surface, no sector rebuild.
  local sectorHasIt = not t.rutted and not t.secOut
  if o then
    if fm and not sectorHasIt then
      fm.handover(sk, o, t.key)
    else
      P.mod('tileMesh').deferRelease(o)
    end
  end
  -- an untouched tile without its own mesh was drawn by the sector all along
  if fm and (o or t.rutted) and not sectorHasIt then fm.markDirty(sk) end
  P.markNeighboursDirty(t)
  P.changedTiles[t.key] = true
end

-- A frozen tile with its own mesh hands it to its sector (far from the camera now).
function P.handoverFrozen(t)
  local o = t.obj
  if not o then return end
  t.obj = nil
  P.own[t.key] = nil
  P.mod('tileMesh').dropSpare(t)
  P.frozenOwnCount = P.frozenOwnCount - 1
  local sk = P.sectorKeyOfTile(t.tx, t.ty)
  local fm = P.mod('farMesh')
  if fm then
    fm.handover(sk, o, t.key)
    fm.markDirty(sk)
  else
    P.mod('tileMesh').deferRelease(o)
  end
  P.markNeighboursDirty(t)
end

-- A frozen tile drops its own mesh without a sector taking it over (its sector is not
-- loaded: it draws the tile from the data when it loads again).
function P.dropFrozenMesh(t)
  local o = t.obj
  if not o then return end
  t.obj = nil
  P.own[t.key] = nil
  P.frozenOwnCount = P.frozenOwnCount - 1
  local tm = P.mod('tileMesh')
  tm.dropSpare(t)
  tm.deferRelease(o)
  P.markNeighboursDirty(t)
end

-- Frozen tiles keep their own mesh as long as their sector is loaded (shown or kept
-- hidden in the sector cache: the tile meshes hide and show with it, see
-- M.onSectorShown). Handing a mesh over costs a sector rebuild, and before, tiles were
-- handed over one by one as the camera moved off (25 m): ~4 sector rebuilds per second
-- with one truck. Once a second: the oldest over frozenOwnMeshMax go to their sectors
-- (in batches, a sector's tiles froze together), tiles of unloaded sectors drop theirs.
P.ownCheck = 0
-- sort orders made once (a closure per call stops LuaJIT traces: FNEW / UCLO)
function P.byLastUse(a, b) return a.lastUse < b.lastUse end
function P.byD(a, b) return a.d < b.d end
function P.byDesiredDist(a, b) return P.desiredDist[a] < P.desiredDist[b] end
function P.byPrio(a, b) return a.prio < b.prio end
function P.updateFrozenOwn(dt)
  if P.frozenOwnCount <= 0 then return end
  P.ownCheck = P.ownCheck + dt
  if P.ownCheck < 1 then return end
  P.ownCheck = 0
  local fm = P.mod('farMesh')
  -- the cap counts the meshes drawn now: those of hidden (cached) sectors cost nothing
  -- per frame and go with their sector when the cache drops it
  local list, drop = nil, nil
  for _, t in pairs(P.own) do
    if t.state == 'frozen' and t.obj then
      local st = fm and fm.sectorState and fm.sectorState(P.sectorKeyOfTile(t.tx, t.ty))
      if fm and not st then
        drop = drop or {}
        drop[#drop + 1] = t
      elseif st ~= 'hidden' then
        list = list or {}
        list[#list + 1] = t
      end
    end
  end
  if drop then for _, t in ipairs(drop) do P.dropFrozenMesh(t) end end
  if not list then return end
  local over = #list - (cfg.ring.frozenOwnMeshMax or 150)
  if over <= 0 then return end
  table.sort(list, P.byLastUse)
  for i = 1, over do P.handoverFrozen(list[i]) end
end

-- farMesh: a sector was hidden (left the load radius, kept in the cache) or shown again
function M.onSectorShown(sk, shown)
  local sx, sy = sk % KEY, floor(sk / KEY)
  for ty = sy * SEC, sy * SEC + SEC - 1 do
    for tx = sx * SEC, sx * SEC + SEC - 1 do
      local t = tiles[ty * KEY + tx]
      if t and t.obj then t.obj:setHidden(not shown) end
    end
  end
end

function P.releaseFrozen(t)
  local sk = P.sectorKeyOfTile(t.tx, t.ty)
  local ovc = P.overlayClear
  if ovc then ovc(t.x0, t.y0, t.x0 + TILE, t.y0 + TILE) end
  if t.obj then
    P.mod('tileMesh').deferRelease(t.obj)
    t.obj = nil
    P.own[t.key] = nil
    P.frozenOwnCount = P.frozenOwnCount - 1
  end
  P.mod('tileMesh').dropSpare(t)
  tiles[t.key] = nil
  P.frozenCount = P.frozenCount - 1
  P.frozenPerSector[sk] = (P.frozenPerSector[sk] or 1) - 1
  if P.frozenPerSector[sk] <= 0 then P.frozenPerSector[sk] = nil end
  local fm = P.mod('farMesh')
  if fm then fm.markDirty(sk) end
  P.notifyVehiclesDrop(t.key)
  P.changedTiles[t.key] = true
  if P.liftOn then P.markFloor(t, 'reset') end
  P.markNeighboursDirty(t)
end

function P.enforceFrozenLimit()
  local limit = cfg.ring.frozenLimit
  local guard = 0
  while P.frozenCount > limit and guard < 64 do
    guard = guard + 1
    local oldest, ot = nil, huge
    for _, t in pairs(tiles) do
      if t.state == 'frozen' and t.lastUse < ot then oldest, ot = t, t.lastUse end
    end
    if not oldest then break end
    P.releaseFrozen(oldest)
  end
end

function M.frozenInSector(sk) return (P.frozenPerSector[sk] or 0) > 0 end
function M.loweredSector(sk) return P.loweredSectors[sk] == true end
function M.frozenSectors() return P.frozenPerSector end
function M.getLoweredSectors() return P.loweredSectors end

-------------------------------------------------------------------------------
-- surface sampling (clods, camera rays)
-------------------------------------------------------------------------------
P.frameVertexCache = {}

function P.cachedRest(gx, gy)
  local k = gy * 131072 + gx
  local v = P.frameVertexCache[k]
  if v then return v[1], v[2] end
  local _, member = depthAt(gx, gy)
  if member then
    local rest, _, d = vertexInfo(gx, gy)
    v = { rest, d > 0 and 2 or 1 }
  else
    v = { 0, 0 } -- not mud: skip the terrain height read
  end
  P.frameVertexCache[k] = v
  return v[1], v[2]
end

-- surface height of a cell vertex as drawn (rut code plus the track jitter)
function P.meshZ(t, idx, gcx, gcy)
  local z = decodeZ(t, idx)
  local tr = t.track[idx]
  if tr > 0 then
    z = z + (P.hash01(gcx, gcy, 7) * 2 - 1) * cfg.stamp.jitterZ * tr / 255
  end
  return z
end

-- Mud surface z at a world point, or nil where there is no drawn mud.
-- Active and frozen tiles return the rutted surface; the remaining patched squares
-- return the sector cover height.
local function surfaceAt(x, y)
  if not running then return nil end
  local fx, fy = (x - ter.ox) / CELL, (y - ter.oy) / CELL
  local cx, cy = floor(fx), floor(fy)
  local tx, ty = floor(cx / N), floor(cy / N)
  local t = tiles[ty * KEY + tx]
  if t then
    local i, j = cx - tx * N, cy - ty * N
    if t.soft[j * N + i] == 0 then return nil end
    local u, v = fx - cx, fy - cy
    local W = N + 1
    local a = j * W + i
    local gc0, gr0 = t.gx0 * CPS + i, t.gy0 * CPS + j
    local z = P.meshZ(t, a, gc0, gr0) * (1 - u) * (1 - v) + P.meshZ(t, a + 1, gc0 + 1, gr0) * u * (1 - v)
      + P.meshZ(t, a + W, gc0, gr0 + 1) * (1 - u) * v + P.meshZ(t, a + W + 1, gc0 + 1, gr0 + 1) * u * v
    if t.state == 'frozen' and not t.obj then z = z - cfg.sectors.drop end
    return z
  end
  local gfx, gfy = (x - ter.ox) / ter.sq, (y - ter.oy) / ter.sq
  local gx, gy = floor(gfx), floor(gfy)
  local S = ter.size
  if gx < 0 or gy < 0 or gx >= S - 1 or gy >= S - 1 then return nil end
  local r00, m00 = P.cachedRest(gx, gy)
  if m00 == 0 then return nil end
  local r10, m10 = P.cachedRest(gx + 1, gy)
  local r01, m01 = P.cachedRest(gx, gy + 1)
  local r11, m11 = P.cachedRest(gx + 1, gy + 1)
  if m10 == 0 or m01 == 0 or m11 == 0 then return nil end
  if m00 + m10 + m01 + m11 <= 4 then return nil end -- no corner with depth: not patched
  local u, v = gfx - gx, gfy - gy
  return r00 * (1 - u) * (1 - v) + r10 * u * (1 - v) + r01 * (1 - u) * v + r11 * u * v - cfg.sectors.drop
end
M.surfaceAt = surfaceAt

-- Rut relief at a point: drawn surface minus the undisturbed rest surface (0 where no
-- tile was dug). Used by the heavy physics rut guide.
function P.reliefAt(x, y)
  local fx, fy = (x - ter.ox) / CELL, (y - ter.oy) / CELL
  local cx, cy = floor(fx), floor(fy)
  local tx, ty = floor(cx / N), floor(cy / N)
  local t = tiles[ty * KEY + tx]
  if not t or not t.rutted then return 0 end
  local i, j = cx - tx * N, cy - ty * N
  local u, v = fx - cx, fy - cy
  local W = N + 1
  local a = j * W + i
  local rest = t.rest
  return (decodeZ(t, a) - rest[a]) * (1 - u) * (1 - v) + (decodeZ(t, a + 1) - rest[a + 1]) * u * (1 - v)
    + (decodeZ(t, a + W) - rest[a + W]) * (1 - u) * v + (decodeZ(t, a + W + 1) - rest[a + W + 1]) * u * v
end

-- Heavy physics rut guide (physics.heavy.rutGuide): the terrain under the mud is a 0.75-1 m
-- grid and cannot hold a 0.3 m wide rut, so the rut walls of the mud mesh act on the
-- tyres as the ground would: a tyre resting across a slope s of the rut relief gets the
-- lateral part of its ground force, -load x s along its axle (gain x, |s| <= maxSlope).
-- Sampled across the tyre at the contact point before the wheel's own stamp; sent to the
-- vehicle, which applies it to the hub nodes (deepnode_vehicle.setGuide).
P.guideS = { -1, -0.5, 0, 0.5, 1 }
function P.rutGuide(px, py, axx, axy, Wt, load)
  local g = cfg.physics.heavy and cfg.physics.heavy.rutGuide
  if not g or g.enabled == false then return 0 end
  local half = Wt * 0.5 + (g.edge or 0.05)
  local sxz, sxx = 0, 0
  for _, f in ipairs(P.guideS) do
    local o = f * half
    local z = P.reliefAt(px + axx * o, py + axy * o)
    sxz = sxz + o * z
    sxx = sxx + o * o
  end
  local slope = sxz / sxx
  local m = g.maxSlope or 1
  if slope > m then slope = m elseif slope < -m then slope = -m end
  return -(g.gain or 1) * load * slope
end

-- Mud surface or terrain height.
function M.groundAt(x, y)
  local z = surfaceAt(x, y)
  if z then return z end
  if ter then return ter.tb:getHeight(vec3(x, y, 0)) end
  return nil
end

-------------------------------------------------------------------------------
-- stamping
-------------------------------------------------------------------------------
-- active tile + vertex index of a global cell vertex
local function vertexRef(gcx, gcy)
  local tx, ty = floor(gcx / N), floor(gcy / N)
  local t = tiles[ty * KEY + tx]
  if not t or t.state ~= 'active' then return nil end
  return t, (gcy - ty * N) * (N + 1) + (gcx - tx * N)
end

-- undisturbed mud surface height at world (x, y) (nil off active tiles): the screen-space
-- overlay measures rut depth (puddles) from it
function P.restAt(x, y)
  local t, idx = vertexRef(floor((x - ter.ox) / CELL + 0.5), floor((y - ter.oy) / CELL + 0.5))
  return t and t.rest and t.rest[idx] or nil
end

-- Rut lag: time from the first vertex write into a tile until the tile's new mesh is
-- shown, split by camera distance (near = within 50 m). At 40 km/h a
-- wheel covers 1.1 m per 0.1 s. Read and reset with deepnode_main.rutLag(true).
P.LAG_EDGES = { 0.05, 0.1, 0.2, 0.35, 0.5, 1, huge }
function P.newLag()
  local function part() return { n = 0, sum = 0, max = 0, hist = { 0, 0, 0, 0, 0, 0, 0 } } end
  return { near = part(), far = part(), fresh = part(), writes = 0, missFrozen = 0, missAbsent = 0, t0 = os.clock() }
end
P.lag = P.newLag()
function P.noteLag(dt, camD2)
  local L = camD2 <= 2500 and P.lag.near or P.lag.far
  L.n = L.n + 1
  L.sum = L.sum + dt
  if dt > L.max then L.max = dt end
  local e = P.LAG_EDGES
  for k = 1, #e do
    if dt < e[k] then L.hist[k] = L.hist[k] + 1; break end
  end
end
function M.rutLag(reset)
  local L = P.lag
  local function out(p)
    return { n = p.n, avg = p.n > 0 and p.sum / p.n or 0, max = p.max, hist = p.hist }
  end
  local r = { near = out(L.near), far = out(L.far), fresh = out(L.fresh), lead = P.stampLead, writes = L.writes, missFrozen = L.missFrozen,
    missAbsent = L.missAbsent, secs = os.clock() - L.t0, edges = P.LAG_EDGES }
  if reset then P.lag = P.newLag() end
  return r
end

local function writeOne(tx, ty, i, j, z, tr)
  local t = tiles[ty * KEY + tx]
  if not t or t.state ~= 'active' then
    -- rut lost: the wheel reached mud whose tile was not active yet (counted for the
    -- rut lag readout; absent tiles only count on soft ground)
    local L = P.lag
    if t then
      L.missFrozen = L.missFrozen + 1
    elseif not P.emptyTiles[ty * KEY + tx] and P.softAtWorld(ter.ox + (tx * N + i) * CELL, ter.oy + (ty * N + j) * CELL) then
      L.missAbsent = L.missAbsent + 1
    end
    return
  end
  local idx = j * (N + 1) + i
  local c = encodeZ(t, idx, z)
  -- nothing changed: no rebuild. Every mesh replace costs engine memory that is never
  -- given back (measured ~25 KB per replace of a drawn ProceduralMesh), so rebuilds are
  -- kept to real changes only.
  local old = t.rut[idx]
  local settle = cfg.stamp.instantSettle
  if settle then
    -- settled at once: the share of the deepest rut / highest berm that relaxation
    -- keeps (stamp.relaxKeep*). The separate settling pass re-meshed every tile once
    -- or twice more after the tyres left it (~7 uploads/s with one truck).
    local st = cfg.stamp
    if c < 128 then
      local lo = t.peakLo[idx]
      if c < lo then t.peakLo[idx] = c; lo = c end
      local target = floor(128 - st.relaxKeep * (128 - lo) + 0.5)
      if c < target then c = target end
    elseif c > 128 then
      local hi = t.peakHi[idx]
      if c > hi then t.peakHi[idx] = c; hi = c end
      local target = floor(128 + st.relaxKeepBerm * (hi - 128) + 0.5)
      if c > target then c = target end
    end
  end
  if c == old and tr <= t.track[idx] then return end
  -- a visible step (first tyre through, new berm) or only a few mm (the axles behind
  -- deepen the same rut by a few cm): see ring.smallChangeWait
  if not t.bigChange and (c - old >= P.bigCode or old - c >= P.bigCode) then t.bigChange, t.bigSince = true, simTime end
  -- the front of a rut: untouched mud carved now (the axles behind only deepen it).
  -- Tiles with a fresh front in view get the fast rebuild path (P.rebuildTiles).
  if old == 128 and t.track[idx] == 0 and 128 - c >= P.bigCode then
    t.lastFresh = simTime
    t.freshPend = t.freshPend or simTime
  end
  t.rut[idx] = c
  -- remember the deepest rut / highest berm reached: relaxation keeps a share of it
  if c < t.peakLo[idx] then t.peakLo[idx] = c end
  if c > t.peakHi[idx] then t.peakHi[idx] = c end
  if tr > t.track[idx] then t.track[idx] = tr end
  t.rutted = true
  t.lastStamp = simTime
  t.pendSince = t.pendSince or simTime
  P.lag.writes = P.lag.writes + 1
  -- terrain squares written since the last build, see P.dirtyHidden
  local sq = floor(j / CPS) * (TS + 1) + floor(i / CPS)
  local ds = t.dsq
  if not ds then ds = {}; t.dsq = ds end
  if not ds[sq] then ds[sq] = true; t.ndsq = (t.ndsq or 0) + 1 end
  t.relaxing = not settle
  t.dirty = true
  P.changedTiles[t.key] = true
  if P.liftOn then P.markFloor(t, 'lower') end
end

-- write a vertex into every active tile sharing it (tile borders are duplicated)
local function writeVertex(gcx, gcy, z, tr)
  local tx, ty = floor(gcx / N), floor(gcy / N)
  local i, j = gcx - tx * N, gcy - ty * N
  writeOne(tx, ty, i, j, z, tr)
  if i == 0 then writeOne(tx - 1, ty, N, j, z, tr) end
  if j == 0 then writeOne(tx, ty - 1, i, N, z, tr) end
  if i == 0 and j == 0 then writeOne(tx - 1, ty - 1, N, N, z, tr) end
end

local bermGX, bermGY, bermW = {}, {}, {}

function P.distributeBerm(nB, wsum, amount)
  if nB == 0 or wsum <= 0 or amount <= 0 then return end
  local k = amount / wsum
  for b = 1, nB do
    local t, idx = vertexRef(bermGX[b], bermGY[b])
    if t then
      local cur = decodeZ(t, idx)
      local cap = t.rest[idx] + bermMax
      if cur < cap then
        local nz = min(cap, cur + k * bermW[b])
        writeVertex(bermGX[b], bermGY[b], nz, 0)
      end
    end
  end
end

-- carve one vertex towards `bottom`; returns the removed height
local function carve(gcx, gcy, t, idx, bottom, tr, dig, digFloor, fb)
  local rest, fl = t.rest[idx], t.floor[idx]
  if fl > rest then fl = rest end
  -- soil memory (stamp.soil): this pass may carve down to z1 x N^e at most
  local soil = P.soil
  if soil and t.passN then
    local want = rest - bottom
    if want > 0 then
      local n = t.passN[idx]
      if n == 0 or t.passKey[idx] ~= soil.key or simTime - t.passT[idx] > soil.gap then
        if n < 255 then n = n + 1; t.passN[idx] = n end
        t.passKey[idx] = soil.key
      end
      t.passT[idx] = simTime
      -- first pass: z1 follows the deepest point of the tyre's own passage
      if n == 1 then
        local q = ceil(want / 0.0025)
        if q > 255 then q = 255 end
        if q > t.z1[idx] then t.z1[idx] = q end
      else
        local allowed = t.z1[idx] * 0.0025 * n ^ soil.e * (1 + soil.soften * (n - 1))
        if want > allowed then bottom = rest - allowed end
      end
    end
  end
  local cur = decodeZ(t, idx)
  -- spinning tyre: dig below the current surface, at most down to digFloor
  if dig and dig > 0 then
    local d = max(cur - dig, digFloor or bottom)
    if d < bottom then bottom = d end
  end
  local target = bottom > fl and bottom or fl -- never below the floor
  if target >= cur then return 0 end
  local nz = target + (fb or cfg.stamp.flowBack) * (cur - target)
  writeVertex(gcx, gcy, nz, tr)
  -- what was really removed (instantSettle stores less than nz, or nothing)
  return cur - decodeZ(t, idx)
end

-- smooth bump 0..1..0 over u in 0..1 (berm cross-section without a ridge)
local function bump(u)
  if u <= 0 or u >= 1 then return 0 end
  local s = math.sin(math.pi * u)
  return s * s
end

-- Wet mud cannot hold steep walls: limit the slope between neighbouring vertices
-- inside the stamped box. Material moves from the high to the low vertex, so a rut
-- partly fills back and its rim rounds off. Local and only where stamped (not a blur
-- of the whole tile), so older ruts elsewhere keep their shape.
function P.slump(gx0, gy0, gx1, gy1)
  local st = cfg.stamp
  local maxStep = (P.kSlope or st.maxSlope) * CELL
  local rate = st.slumpRate
  if rate <= 0 or gx1 < gx0 or gy1 < gy0 or gx1 - gx0 > 300 or gy1 - gy0 > 300 then return end
  local W = N + 1
  -- One pass per tile row segment: a vertex and its +x / +y neighbours lie in the same
  -- tile (tiles hold their border column/row), so no lookup per neighbour except on the
  -- tile's far border, where the neighbour tile must be active too (else its copy of
  -- the shared vertex would not follow: crack).
  for _ = 1, st.slumpPasses do
    for gcy = gy0, gy1 do
      local ty = floor(gcy / N)
      local j = gcy - ty * N
      local gcx = gx0
      while gcx <= gx1 do
        local tx = floor(gcx / N)
        local segEnd = min(gx1, tx * N + N - 1)
        local t = tiles[ty * KEY + tx]
        if t and t.state == 'active' then
          local rest, flo, rut = t.rest, t.floor, t.rut
          for i = gcx - tx * N, segEnd - tx * N do
            local idx = j * W + i
            local r1 = rest[idx]
            local f1 = flo[idx]
            if r1 - f1 > 0.002 then
              local z = nil
              for q = 1, 2 do
                local idx2 = q == 1 and idx + 1 or idx + W
                local border = (q == 1 and i + 1 == N) or (q == 2 and j + 1 == N)
                local ok = true
                if border then
                  local t2 = vertexRef(tx * N + i + (q == 1 and 1 or 0), gcy + (q == 2 and 1 or 0))
                  ok = t2 ~= nil
                end
                local r2, f2 = rest[idx2], flo[idx2]
                if ok and r2 - f2 > 0.002 then
                  z = z or decodeZ(t, idx)
                  local z2 = decodeZ(t, idx2)
                  local d = z - z2
                  local ad = abs(d)
                  if ad > maxStep then
                    local m = (ad - maxStep) * 0.5 * rate
                    if d < 0 then m = -m end
                    local nz, nz2 = z - m, z2 + m
                    local fa, fb = min(f1, r1), min(f2, r2)
                    if nz >= fa and nz <= r1 + bermMax and nz2 >= fb and nz2 <= r2 + bermMax then
                      local gx, gy = tx * N + i, gcy
                      writeVertex(gx, gy, nz, 0)
                      writeVertex(gx + (q == 1 and 1 or 0), gy + (q == 2 and 1 or 0), nz2, 0)
                      z = decodeZ(t, idx)
                    end
                  end
                end
              end
            end
          end
        end
        gcx = segEnd + 1
      end
    end
  end
end

-- static tyre footprint at hub (cx,cy,cz); axle/forward are horizontal unit vectors.
-- tyres: { {o = offset along the axle from the hub, w = width} } -- one entry for a
-- single tyre, two for a dual wheel. Each tyre cuts its own rounded rut; between the
-- tyres of a dual the mud squeezes up into a low ridge; rim and berms run along the
-- outer edges of the whole tyre group. Returns the cell box it covered.
local function stampFootprint(cx, cy, cz, axx, axy, fwx, fwy, R, tyres, tr, dig, digMax)
  local st = cfg.stamp
  local nt = #tyres
  local lo, hi, minW = huge, -huge, huge
  for k = 1, nt do
    local ty = tyres[k]
    lo, hi = min(lo, ty.o - ty.w * 0.5), max(hi, ty.o + ty.w * 0.5)
    minW = min(minW, ty.w)
  end
  local rs = max(CELL * 0.5, minW * st.shoulderFactor)
  local ridge = rs * ((cfg.dually and cfg.dually.ridge) or 0.6)
  local rimW = max(CELL, st.rimCells * CELL)
  local bw = max(CELL, (hi - lo) / nt * st.bermWidthFactor)
  local latExt = max(abs(lo), abs(hi)) + rimW + bw
  local ex = abs(axx) * latExt + abs(fwx) * R
  local ey = abs(axy) * latExt + abs(fwy) * R
  local gx0, gx1 = ceil((cx - ex - ter.ox) / CELL), floor((cx + ex - ter.ox) / CELL)
  local gy0, gy1 = ceil((cy - ey - ter.oy) / CELL), floor((cy + ey - ter.oy) / CELL)
  if gx1 - gx0 > 200 or gy1 - gy0 > 200 then return nil end
  local removed, nB, wsum = 0, 0, 0
  local R2 = R * R
  for gcy = gy0, gy1 do
    local y = ter.oy + gcy * CELL
    for gcx = gx0, gx1 do
      local x = ter.ox + gcx * CELL
      local rx, ry = x - cx, y - cy
      local f = rx * fwx + ry * fwy
      local s = rx * axx + ry * axy
      if f * f < R2 and s >= lo - rimW - bw and s <= hi + rimW + bw then
        local t, idx = vertexRef(gcx, gcy)
        if t and t.rest[idx] - t.floor[idx] > 0.002 then
          local bottom0 = cz - sqrt(R2 - f * f)
          -- which tyre covers this vertex (a: distance from that tyre's centre line)
          local inT, aIn, hwIn, edgeD = nil, 0, 0, huge
          for k = 1, nt do
            local ty = tyres[k]
            local a = abs(s - ty.o)
            local hw = ty.w * 0.5
            if a <= hw then inT, aIn, hwIn = k, a, hw; break end
            if a - hw < edgeD then edgeD = a - hw end
          end
          if inT then
            local bottom = bottom0
            local sh = aIn - (hwIn - rs)
            if sh > 0 then bottom = bottom + rs - sqrt(max(0, rs * rs - sh * sh)) end
            removed = removed + carve(gcx, gcy, t, idx, bottom, tr, dig, bottom0 - (digMax or 0))
          elseif s > lo and s < hi then
            -- between the tyres of a dual: carved down to a low rounded ridge
            local bottom = bottom0 + rs + ridge * min(1, edgeD / max(1e-3, rs))
            removed = removed + carve(gcx, gcy, t, idx, bottom, tr)
          else
            local aa = (s < lo) and (lo - s) or (s - hi) -- distance outside the tyre group
            if aa <= rimW then
              -- soft rim: the mud beside the tyre sags towards the tyre edge,
              -- fully at the edge, not at all rimW away (cosine falloff)
              local edge = bottom0 + rs
              local cur = decodeZ(t, idx)
              if edge < cur then
                local w = 0.5 * (1 + math.cos(math.pi * aa / rimW)) * st.rimDepth
                local fl = min(t.floor[idx], t.rest[idx])
                local target = cur + (max(fl, edge) - cur) * w
                if target < cur then
                  writeVertex(gcx, gcy, target, floor(tr * w))
                  removed = removed + (cur - decodeZ(t, idx))
                end
              end
            else
              local w = bump((aa - rimW) / bw)
              if w > 0 then
                nB = nB + 1
                bermGX[nB], bermGY[nB], bermW[nB] = gcx, gcy, w
                wsum = wsum + w
              end
            end
          end
        end
      end
    end
  end
  P.distributeBerm(nB, wsum, removed * (P.kBerm or st.bermFraction))
  return gx0, gy0, gx1, gy1
end

-- Swept footprint in one pass (rolling tyre): every vertex is carved once, at the
-- point of the path where the tyre centre passes it (deepest bottom), with the effect
-- of the k footprints of the sampled sweep that would have covered it (flow-back
-- fb^k, rim sag 1-(1-w)^k, spin dig k/n). The sampled sweep evaluated the whole
-- footprint every CELL along the path: ~2R/CELL (6-7) visits per vertex; measured
-- 0.09 ms per wheel report, ~1 ms per frame with 7 trucks.
-- Returns the cell box, or nil when the tyre moves sideways (caller samples instead).
local function stampSwept(p0x, p0y, p0z, dx, dy, dz, L, axx, axy, fwx, fwy, R, tyres, tr, dig, digMax, n)
  local dfw = dx * fwx + dy * fwy
  if dfw < 0 then fwx, fwy, dfw = -fwx, -fwy, -dfw end
  if dfw < 0.5 * L then return nil end
  local dax = dx * axx + dy * axy
  local st = cfg.stamp
  local nt = #tyres
  local lo, hi, minW = huge, -huge, huge
  for k = 1, nt do
    local ty = tyres[k]
    lo, hi = min(lo, ty.o - ty.w * 0.5), max(hi, ty.o + ty.w * 0.5)
    minW = min(minW, ty.w)
  end
  local rs = max(CELL * 0.5, minW * st.shoulderFactor)
  local ridge = rs * ((cfg.dually and cfg.dually.ridge) or 0.6)
  local rimW = max(CELL, st.rimCells * CELL)
  local bw = max(CELL, (hi - lo) / nt * st.bermWidthFactor)
  local latExt = max(abs(lo), abs(hi)) + rimW + bw
  local ex = abs(axx) * latExt + abs(fwx) * R
  local ey = abs(axy) * latExt + abs(fwy) * R
  local gx0 = ceil((min(p0x, p0x + dx) - ex - ter.ox) / CELL)
  local gx1 = floor((max(p0x, p0x + dx) + ex - ter.ox) / CELL)
  local gy0 = ceil((min(p0y, p0y + dy) - ey - ter.oy) / CELL)
  local gy1 = floor((max(p0y, p0y + dy) + ey - ter.oy) / CELL)
  if gx1 - gx0 > 300 or gy1 - gy0 > 300 then return nil end
  local sLo, sHi = lo - rimW - bw, hi + rimW + bw
  local fb0 = st.flowBack
  local rimDepth = st.rimDepth
  local removed, nB, wsum = 0, 0, 0
  local R2 = R * R
  local invD = 1 / dfw
  for gcy = gy0, gy1 do
    local ry0 = ter.oy + gcy * CELL - p0y
    for gcx = gx0, gx1 do
      local rx0 = ter.ox + gcx * CELL - p0x
      local f0 = rx0 * fwx + ry0 * fwy
      local u = f0 * invD
      if u < 0 then u = 0 elseif u > 1 then u = 1 end
      local f = f0 - u * dfw
      if f * f < R2 then
        local s = rx0 * axx + ry0 * axy - u * dax
        if s >= sLo and s <= sHi then
          local t, idx = vertexRef(gcx, gcy)
          if t and t.rest[idx] - t.floor[idx] > 0.002 then
            -- footprints of the sampled sweep covering this vertex
            local ua, ub = (f0 - R) * invD, (f0 + R) * invD
            if ua < 0 then ua = 0 end
            if ub > 1 then ub = 1 end
            local k = (ub - ua) * n
            if k < 1 then k = 1 end
            local bottom0 = p0z + dz * u - sqrt(R2 - f * f)
            local inT, aIn, hwIn, edgeD = nil, 0, 0, huge
            for q = 1, nt do
              local ty = tyres[q]
              local a = abs(s - ty.o)
              local hw = ty.w * 0.5
              if a <= hw then inT, aIn, hwIn = q, a, hw; break end
              if a - hw < edgeD then edgeD = a - hw end
            end
            if inT then
              local bottom = bottom0
              local sh = aIn - (hwIn - rs)
              if sh > 0 then bottom = bottom + rs - sqrt(max(0, rs * rs - sh * sh)) end
              removed = removed + carve(gcx, gcy, t, idx, bottom, tr, dig and dig * k / n, bottom0 - (digMax or 0), fb0 ^ k)
            elseif s > lo and s < hi then
              local bottom = bottom0 + rs + ridge * min(1, edgeD / max(1e-3, rs))
              removed = removed + carve(gcx, gcy, t, idx, bottom, tr, nil, nil, fb0 ^ k)
            else
              local aa = (s < lo) and (lo - s) or (s - hi)
              if aa <= rimW then
                local edge = bottom0 + rs
                local cur = decodeZ(t, idx)
                if edge < cur then
                  local w = 0.5 * (1 + math.cos(math.pi * aa / rimW)) * rimDepth
                  local wk = 1 - (1 - w) ^ k
                  local fl = min(t.floor[idx], t.rest[idx])
                  local target = cur + (max(fl, edge) - cur) * wk
                  if target < cur then
                    writeVertex(gcx, gcy, target, floor(tr * w))
                    removed = removed + (cur - decodeZ(t, idx))
                  end
                end
              else
                local w = bump((aa - rimW) / bw)
                if w > 0 then
                  nB = nB + 1
                  bermGX[nB], bermGY[nB], bermW[nB] = gcx, gcy, w
                  wsum = wsum + w
                end
              end
            end
          end
        end
      end
    end
  end
  P.distributeBerm(nB, wsum, removed * (P.kBerm or st.bermFraction))
  return gx0, gy0, gx1, gy1
end

-- Per-kind stamp rules (stamp.kinds) for the stamps that follow: berm share, wall slope
-- and the soil memory state of one wheel (key = vehicle and wheel: a pass identity).
P.soilState = {}
function P.setStampKind(kind, depth, key)
  local st = cfg.stamp
  local K = st.kinds and st.kinds[kind] or nil
  local bf = K and K.bermFraction or st.bermFraction
  if K and (K.bermDepthRef or 0) > 0 then bf = bf * clamp((depth or 0) / K.bermDepthRef, 0.4, 1.6) end
  P.kBerm = bf
  P.kSlope = K and K.maxSlope or st.maxSlope
  local so = st.soil
  if key and so and so.enabled and K and K.soilN then
    local S = P.soilState
    S.key, S.gap = key, so.passGap or 0.6
    S.e, S.soften = 2 / (2 * K.soilN + 1), K.soften or 0
    P.soil = S
  else
    P.soil = nil
  end
  return K
end

function P.kindAtWorld(x, y)
  return M.layerKindAt(floor((x - ter.ox) / ter.sq + 0.5), floor((y - ter.oy) / ter.sq + 0.5))
end

-- swept tyre stamp from the previous report to the current one (continuous at speed)
-- W: tyre width (single tyre) or a tyre list (see stampFootprint)
function P.stampWheel(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, fwx, fwy, R, W, tr, includeStart, dig, digMax)
  if type(W) == 'number' then W = { { o = 0, w = W } } end
  -- screen-space rut overlay (deepnode_overlay sets it while running)
  local ovs = P.overlayStamp
  if ovs then ovs(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, R, W) end
  local dx, dy, dz = p1x - p0x, p1y - p0y, p1z - p0z
  local L = sqrt(dx * dx + dy * dy)
  local n = max(1, min(64, ceil(L / CELL)))
  if includeStart and L < 1e-6 then n = 0 end
  if n >= 2 and cfg.stamp.sweep ~= false then
    local a, b, c, d = stampSwept(p0x, p0y, p0z, dx, dy, dz, L, axx, axy, fwx, fwy, R, W, tr, dig, digMax, n)
    if a then
      if not P.skipSlump then P.slump(a - 1, b - 1, c + 1, d + 1) end
      P.stats.stamps = P.stats.stamps + 1
      return
    end
  end
  local bx0, by0, bx1, by1 = huge, huge, -huge, -huge
  local digStep = dig and dig / max(1, n) or nil
  for k = includeStart and 0 or 1, n do
    local s = k / n
    local a, b, c, d = stampFootprint(p0x + dx * s, p0y + dy * s, p0z + dz * s, axx, axy, fwx, fwy, R, W, tr,
      digStep, digMax)
    if a then bx0, by0, bx1, by1 = min(bx0, a), min(by0, b), max(bx1, c), max(by1, d) end
  end
  if bx0 <= bx1 then P.slump(bx0 - 1, by0 - 1, bx1 + 1, by1 + 1) end
  P.stats.stamps = P.stats.stamps + 1
end

-- round dent under a submerged chassis node, swept from its previous position
function P.stampBody(x0, y0, z0, x1, y1, z1)
  local st = cfg.stamp
  local r, rw, skin = st.bodyRadius, st.bodyBermWidth, st.bodySkin
  local ext = r + rw
  local gx0, gx1 = ceil((min(x0, x1) - ext - ter.ox) / CELL), floor((max(x0, x1) + ext - ter.ox) / CELL)
  local gy0, gy1 = ceil((min(y0, y1) - ext - ter.oy) / CELL), floor((max(y0, y1) + ext - ter.oy) / CELL)
  if gx1 - gx0 > 200 or gy1 - gy0 > 200 then return end
  local sx, sy = x1 - x0, y1 - y0
  local l2 = sx * sx + sy * sy
  local removed, nB, wsum = 0, 0, 0
  local tr = floor(clamp(st.trackBase, 0, 1) * 255)
  for gcy = gy0, gy1 do
    local y = ter.oy + gcy * CELL
    for gcx = gx0, gx1 do
      local x = ter.ox + gcx * CELL
      local s = 0
      if l2 > 1e-8 then s = clamp(((x - x0) * sx + (y - y0) * sy) / l2, 0, 1) end
      local px, py = x0 + sx * s, y0 + sy * s
      local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
      if d < ext then
        local t, idx = vertexRef(gcx, gcy)
        if t and t.rest[idx] - t.floor[idx] > 0.002 then
          if d < r then
            local zc = z0 + (z1 - z0) * s
            local bottom = zc - skin + (r - sqrt(r * r - d * d))
            removed = removed + carve(gcx, gcy, t, idx, bottom, tr)
          else
            local w = bump((d - r) / rw)
            if w > 0 then
              nB = nB + 1
              bermGX[nB], bermGY[nB], bermW[nB] = gcx, gcy, w
              wsum = wsum + w
            end
          end
        end
      end
    end
  end
  P.distributeBerm(nB, wsum, removed * st.bodyBermFraction)
  P.slump(gx0 - 1, gy0 - 1, gx1 + 1, gy1 + 1)
end

-- Half-liquid mud: fresh ruts and berms settle back over a few seconds towards the
-- undisturbed surface but keep a share of their deepest/highest state, so a track
-- stays as a soft trough. Per vertex, active tiles only (frozen ruts stay as left).
function P.relaxTiles(dt)
  local st = cfg.stamp
  P.relaxAcc = (P.relaxAcc or 0) + dt
  if P.relaxAcc < 1 / max(0.5, st.relaxHz) then return end
  local alphaStep = 1 - math.exp(-P.relaxAcc / max(0.05, st.relaxTime))
  local alpha = alphaStep
  P.relaxAcc = 0
  local keepLo, keepHi = st.relaxKeep, st.relaxKeepBerm
  local NW = (N + 1) * (N + 1)
  -- settling runs at most relaxWindow s after a tile's last stamp, then snaps to its
  -- final shape in one step: no endless small changes (each change is a mesh rebuild)
  local window = st.relaxWindow or 2.5
  for _, t in pairs(P.act) do
    if t.state == 'active' and t.relaxing then
      if simTime - (t.lastStamp or 0) > window then alpha = 1 else alpha = alphaStep end
      local rut, lo, hi = t.rut, t.peakLo, t.peakHi
      local changed = false
      for k = 0, NW - 1 do
        local c = rut[k]
        if c < 128 then
          local target = 128 - keepLo * (128 - lo[k])
          if c < target - 0.5 then
            local d = floor((target - c) * alpha + 0.5)
            if d < 1 then d = 1 end
            c = min(c + d, floor(target + 0.5))
            rut[k] = c
            changed = true
          end
        elseif c > 128 then
          local target = 128 + keepHi * (hi[k] - 128)
          if c > target + 0.5 then
            local d = floor((c - target) * alpha + 0.5)
            if d < 1 then d = 1 end
            c = max(c - d, floor(target + 0.5))
            rut[k] = c
            changed = true
          end
        end
      end
      if changed then
        t.dirty = true
      end
      if not changed or alpha >= 1 then t.relaxing = false end
    end
  end
end

-- settle a tile to its end shape at once (it freezes now: frozen ruts do not settle)
function P.finishRelax(t)
  if not t.relaxing then return end
  local st = cfg.stamp
  local keepLo, keepHi = st.relaxKeep, st.relaxKeepBerm
  local rut, lo, hi = t.rut, t.peakLo, t.peakHi
  for k = 0, (N + 1) * (N + 1) - 1 do
    local c = rut[k]
    if c < 128 then
      local target = floor(128 - keepLo * (128 - lo[k]) + 0.5)
      if c < target then rut[k] = target end
    elseif c > 128 then
      local target = floor(128 + keepHi * (hi[k] - 128) + 0.5)
      if c > target then rut[k] = target end
    end
  end
  t.relaxing = false
  t.dirty = true
end

M.stampWheelForTests = P.stampWheel
M.stampBodyForTests = P.stampBody

-------------------------------------------------------------------------------
-- vehicles
-------------------------------------------------------------------------------
function P.newVehState(vid)
  return { id = vid, sent = {}, lastWheel = {}, lastNode = {}, configured = false, lastStream = 0,
    tyres = {}, lod = 1, stats = nil, box = nil }
end

function P.configureVehicle(vid)
  local veh = getObjectByID(vid)
  if not veh then return end
  local vs = P.vehs[vid] or P.newVehState(vid)
  P.vehs[vid] = vs
  local payload = {
    ter = { ox = ter.ox, oy = ter.oy, sq = ter.sq, ts = TS, key = KEY },
    report = cfg.report,
    dually = cfg.dually,
    lod = vs.lod or 1,
  }
  veh:queueLuaCommand('extensions.load("deepnode_vehicle")')
  veh:queueLuaCommand('if deepnode_vehicle then deepnode_vehicle.configure(' .. serialize(payload) .. ') end')
  vs.sent = {}
  vs.lastWheel = {}
  vs.lastNode = {}
  vs.configured = true
  vs.lastStream = -huge
end

-- The rest/depth grid of a tile never changes while it lives, so its command string is
-- built once and shared by every vehicle it is sent to.
function P.tilePayload(t)
  if t.payload then return t.payload end
  local W = TS + 1
  local r, d = {}, {}
  for k = 0, W * W - 1 do
    local rest, flo = t.vRest[k], t.vFloor[k]
    r[k + 1] = sfmt('%.3f', rest)
    local dep = rest - flo
    d[k + 1] = sfmt('%.3f', (t.vMem[k] ~= 0 and dep > 0) and dep or 0)
  end
  t.payload = sfmt('if deepnode_vehicle then deepnode_vehicle.setTile(%d,%d,%d,{%s},{%s}) end',
    t.key, t.gx0, t.gy0, table.concat(r, ','), table.concat(d, ','))
  return t.payload
end

-- Stream rest-surface/depth grids of the tiles round each vehicle's footprint box to its
-- VM: the box plus boxMargin, plus the distance it covers in two stream intervals.
P.streamBox = {}
function P.streamTiles()
  local margin = (cfg.ring.boxMargin or 3) + 1
  local b = P.streamBox
  for vid, vs in pairs(P.vehs) do
    if vs.configured and simTime - vs.lastStream >= cfg.ring.streamInterval then
      vs.lastStream = simTime
      local veh = getObjectByID(vid)
      if veh then
        local p = veh:getPosition()
        if p and isFinite(p.x) and isFinite(p.y) then
          local want = {}
          b.cx, b.cy, b.fx, b.fy, b.hl, b.hw = P.vehicleBox(vs, veh, p)
          b.ex = abs(b.fx) * b.hl + abs(b.fy) * b.hw
          b.ey = abs(b.fy) * b.hl + abs(b.fx) * b.hw
          local v = veh:getVelocity()
          local sp = (v and isFinite(v.x) and isFinite(v.y)) and sqrt(v.x * v.x + v.y * v.y) or 0
          local R = margin + min(sp, 40) * 2 * cfg.ring.streamInterval
          local tx0, tx1 = floor((b.cx - b.ex - R - ter.ox) / TILE), floor((b.cx + b.ex + R - ter.ox) / TILE)
          local ty0, ty1 = floor((b.cy - b.ey - R - ter.oy) / TILE), floor((b.cy + b.ey + R - ter.oy) / TILE)
          if tx1 - tx0 <= 64 and ty1 - ty0 <= 64 then
            for ty = ty0, ty1 do
              for tx = tx0, tx1 do
                local t = tiles[ty * KEY + tx]
                if t then
                  local x0, y0 = ter.ox + tx * TILE, ter.oy + ty * TILE
                  if P.rectBoxDist2(x0, y0, x0 + TILE, y0 + TILE, b) <= R * R then want[t.key] = t end
                end
              end
            end
          end
          local sentNow = 0
          for key, t in pairs(want) do
            if not vs.sent[key] and sentNow < cfg.ring.maxTilesPerStream then
              veh:queueLuaCommand(P.tilePayload(t))
              vs.sent[key] = true
              sentNow = sentNow + 1
            end
          end
          for key in pairs(vs.sent) do
            if not want[key] then
              vs.sent[key] = nil
              veh:queueLuaCommand(sfmt('if deepnode_vehicle then deepnode_vehicle.dropTile(%d) end', key))
            end
          end
        end
      end
    end
  end
end

-- wheel definitions from the vehicle (array order; pitfall 5)
-- flat stride 13: index, hubNode1, hubNode2, treadNode, treadRadius, treadWidth,
-- tyre count (1 or 2), tyre 1 offset/width, tyre 2 offset/width (offsets along hub1->hub2),
-- rim radius (0 = unknown), 1 when the tyre widths are visual (from the tyre meshes)
P.DEF_STRIDE = 13
function M.onWheelDefs(vid, flat)
  if not running or type(flat) ~= 'table' then return end
  local vs = P.vehs[vid]
  local defs = {}
  local S = P.DEF_STRIDE
  for k = 1, #flat - S + 1, S do
    local i, n1, n2, tn, R, W = flat[k], flat[k + 1], flat[k + 2], flat[k + 3], flat[k + 4], flat[k + 5]
    if isFinite(i) and isFinite(n1) and isFinite(n2) and isFinite(tn) and isFinite(R) and isFinite(W)
      and R > 0.05 and R < 3 and W > 0.02 and W < 2 then
      local tyres = { { o = 0, w = W } }
      local nt, o1, w1, o2, w2 = flat[k + 6], flat[k + 7], flat[k + 8], flat[k + 9], flat[k + 10]
      local rimR, vis = flat[k + 11], flat[k + 12] == 1
      if nt == 2 and isFinite(o1) and isFinite(w1) and isFinite(o2) and isFinite(w2)
        and w1 > 0.03 and w2 > 0.03 and abs(o1) < 1.5 and abs(o2) < 1.5 then
        tyres = { { o = o1, w = w1, vis = vis }, { o = o2, w = w2, vis = vis } }
      elseif nt == 1 and isFinite(o1) and isFinite(w1) and w1 > 0.03 and abs(o1) < 1.5 then
        -- single tyre centred on its tread nodes (o1), visual width or jbeam-like width
        tyres = { { o = o1, w = w1, vis = vis } }
      end
      if not (isFinite(rimR) and rimR > 0.05 and rimR < R * 0.95) then rimR = nil end
      defs[#defs + 1] = { index = floor(i), n1 = floor(n1), n2 = floor(n2), tread = floor(tn), R = R, W = W, tyres = tyres,
        rimR = rimR }
      if vs then vs.tyres[floor(i)] = tyres end
    end
  end
  local wm = P.mod('wheelMud')
  if wm then wm.setWheelDefs(vid, defs) end
end

-- tyre water level per wheel from the vehicle: flat stride 2 (index, share 0..1)
function M.onWheelWater(vid, flat)
  if not running or type(flat) ~= 'table' then return end
  local wm = P.mod('wheelMud')
  if not wm or not wm.onWheelWater then return end
  for k = 1, #flat - 1, 2 do
    local i, f = flat[k], flat[k + 1]
    if isFinite(i) and isFinite(f) then wm.onWheelWater(vid, floor(i), clamp(f, 0, 1)) end
  end
end

-- once a second from each vehicle: wheels in mud, chassis candidates, mud tiles held,
-- vehicle Lua KB, LOD, footprint hull nodes
function M.onVehicleStats(vid, wheels, cands, ntiles, luaKB, lod, hull)
  local vs = P.vehs[vid]
  if not vs then return end
  local s = vs.stats or {}
  s.wheels, s.cands, s.tiles, s.luaKB, s.lod, s.hull =
    wheels or 0, cands or 0, ntiles or 0, luaKB or 0, lod or 1, hull or 0
  s.t = simTime
  vs.stats = s
end

-- Footprint of a vehicle's main body (parts that broke loose left out), oriented with its
-- heading: centre, forward unit vector, half length, half width. Sent at report.boxHz
-- when it moved. The active tiles are the tiles near these boxes.
-- px, py: the vehicle position the box was measured at; between two updates (and while
-- the message travels) the box moves with the vehicle.
function M.onVehicleBox(vid, cx, cy, fx, fy, hl, hw, px, py)
  if not running then return end
  local vs = P.vehs[vid]
  if not vs then return end
  if not (isFinite(cx) and isFinite(cy) and isFinite(fx) and isFinite(fy) and isFinite(hl) and isFinite(hw)) then return end
  local fl = sqrt(fx * fx + fy * fy)
  if fl < 0.5 or hl < 0 or hw < 0 or hl > 60 or hw > 60 then return end
  local b = vs.box or {}
  b.cx, b.cy, b.fx, b.fy, b.hl, b.hw = cx, cy, fx / fl, fy / fl, hl, hw
  if isFinite(px) and isFinite(py) then b.px, b.py = px, py else b.px, b.py = nil, nil end
  b.t = simTime
  vs.box = b
end

P.REPORT_STRIDE = 15
-- wheels flat stride 15: i, hub xyz, axle xyz, forward x y, wheel load (N), radius, width, immersion,
-- slip, |omega|
-- nodes flat stride 4: cid, x, y, z
function M.onMudReport(vid, w, nodes)
  if not running then return end
  local vs = P.vehs[vid]
  if not vs then return end
  local st = cfg.stamp
  local wm = P.mod('wheelMud')
  -- vehicles beyond meshRange (lod >= 3): no slump pass (half the stamp time); their
  -- ruts are only seen later, frozen
  P.skipSlump = (vs.lod or 1) >= 3
  local guide = nil
  local heavyGuide = cfg.physics.mode == 'heavy' and cfg.physics.heavy and cfg.physics.heavy.rutGuide
    and cfg.physics.heavy.rutGuide.enabled ~= false
  if type(w) == 'table' then
    for k = 1, #w - P.REPORT_STRIDE + 1, P.REPORT_STRIDE do
      local wi = w[k]
      local px, py, pz = w[k + 1], w[k + 2], w[k + 3]
      local ax, ay, az = w[k + 4], w[k + 5], w[k + 6]
      local fx, fy = w[k + 7], w[k + 8]
      local load = w[k + 9]
      local R, W, d, slip, om = w[k + 10], w[k + 11], w[k + 12], w[k + 13], w[k + 14]
      local ok = isFinite(wi) and isFinite(px) and isFinite(py) and isFinite(pz) and isFinite(ax) and isFinite(ay)
        and isFinite(az) and isFinite(fx) and isFinite(fy) and isFinite(R) and isFinite(W) and isFinite(d)
        and isFinite(slip) and isFinite(om) and R > 0.05 and R < 3 and W > 0.02 and W < 2
      if ok then
        wi = floor(wi)
        local ah = sqrt(ax * ax + ay * ay)
        local prev = vs.lastWheel[wi]
        -- Predictive stamping: the rut is carved up to where the wheel will be when the
        -- new mesh shows (P.stampLead, the measured report-to-screen latency), so the rut
        -- front reaches the tyre instead of trailing it by speed x latency. The swept
        -- stamp starts at the last stamped (predicted) end, so the rut stays continuous.
        -- Velocity from the last two reports (actual positions), lightly smoothed.
        local tgx, tgy = px, py
        local pzs = pz -- hub height the stamp uses (lowered by slip sinkage below)
        if prev and prev.ax then
          local dtv = simTime - prev.at
          if dtv > 1e-3 and dtv < 0.3 then
            local vx, vy = (px - prev.ax) / dtv, (py - prev.ay) / dtv
            if prev.vx then vx, vy = prev.vx * 0.4 + vx * 0.6, prev.vy * 0.4 + vy * 0.6 end
            prev.vx, prev.vy = vx, vy
            local lead = P.stampLead or 0
            tgx, tgy = px + vx * lead, py + vy * lead
          end
        end
        if ah > 0.5 then -- axle roughly horizontal: the tyre rolls on the ground
          local axx, axy = ax / ah, ay / ah
          local fwx, fwy = -axy, axx
          if fwx * fx + fwy * fy < 0 then fwx, fwy = -fwx, -fwy end
          local spin = max(0, slip)
          -- a wheel standing still and not spinning has nothing new to carve: re-stamping
          -- it fights the settling pass (carve down, settle up, carve down...) and keeps
          -- its tiles rebuilding forever
          -- (prev.cx is the actual position at the last stamp, so slow creeping still adds up)
          local still = prev and prev.cx and (px - prev.cx) ^ 2 + (py - prev.cy) ^ 2 < 0.0004 and spin < 0.5
          local tr = floor(clamp(st.trackBase + st.trackSpinGain * spin + st.trackDepthGain * max(0, d), 0, 1) * 255)
          local Wt = vs.tyres[wi] or W
          if heavyGuide and d > 0.01 then
            -- lateral force from the rut walls under this tyre (before its own stamp)
            local tw = W
            if type(Wt) == 'table' then
              local lo, hi = huge, -huge
              for _, ty in ipairs(Wt) do lo = min(lo, ty.o - ty.w * 0.5); hi = max(hi, ty.o + ty.w * 0.5) end
              if hi > lo then tw = hi - lo end
            end
            local f = P.rutGuide(px, py, axx, axy, tw, isFinite(load) and load or 3500)
            guide = guide or {}
            guide[#guide + 1] = sfmt('%d,%.0f', wi, f)
          end
          -- spin dig, scaled by this wheel's share of the vehicle weight
          local ref = st.refWheelLoad or 3500
          local ls = clamp((isFinite(load) and load > 0) and load / ref or 1, 0.3, 3)
          local rdt = prev and clamp(simTime - prev.t, 0, 0.1) or (1 / 30)
          local dig = (st.spinDigRate or 0) * spin * rdt * ls
          local digMax = (st.spinDigMax or 0) * sqrt(ls)
          -- ground kind under the hub: berms, wall slope, soil memory, slip sinkage
          local K = P.setStampKind(P.kindAtWorld(px, py), d, (vid % 2000) * 32 + wi % 32)
          if K then
            local sd = K.spinDig or 1
            dig, digMax = dig * sd, digMax * sd
            -- slip sinkage: s = slip ratio, saturating (Reece 1965, Baek et al. 2020)
            local sr = spin / max(0.5, om * R)
            if (K.slipBeta or 0) > 0 and sr > 0.02 and d > 0 then
              pzs = pz - K.slipBeta * sr / (sr + 0.2) * min(d, R * 0.5)
            end
          end
          if prev then prev.still = still end
          if still then
            -- skip
          elseif prev and simTime - prev.t < 0.35 and (tgx - prev.x) ^ 2 + (tgy - prev.y) ^ 2 < st.maxSweep * st.maxSweep then
            P.stampWheel(prev.x, prev.y, prev.z, tgx, tgy, pzs, axx, axy, fwx, fwy, R, Wt, tr, false, dig, digMax)
          else
            tgx, tgy = px, py -- jump or first report: no prediction from a stale speed
            P.stampWheel(px, py, pzs, px, py, pzs, axx, axy, fwx, fwy, R, Wt, tr, true, dig, digMax)
          end
        end
        -- tyre mud only on soft ground: the tile meshes (and so the vehicle's reports)
        -- also cover the hard squares at the mud's edge, where mudLayerAt falls back to
        -- the zone/default kind; a tyre rolling there picked up "mud" of that kind and
        -- changed its coat colour (and kind) out of the mud
        if wm and P.softAtWorld(px, py) then
          local e, kind = M.mudLayerAt(px, py)
          wm.onWheelMud(vid, wi, d, slip, om, R, simTime, kind, e, px, py)
        end
        if not (prev and prev.still) then
          prev = prev or {}
          prev.x, prev.y, prev.z = tgx, tgy, pzs
          prev.cx, prev.cy = px, py
        end
        prev.ax, prev.ay, prev.at = px, py, simTime
        prev.t = simTime
        vs.lastWheel[wi] = prev
      end
    end
  end
  if guide or vs.guided then
    local veh = getObjectByID(vid)
    if veh then
      veh:queueLuaCommand('if deepnode_vehicle then deepnode_vehicle.setGuide({' .. (guide and table.concat(guide, ',') or '') .. '}) end')
    end
    vs.guided = guide ~= nil
  end
  -- body dents only where they are drawn (vehicles within meshRange, lod < 3): the
  -- chassis nodes under the mud were ~25 stamps per frame with 7 trucks
  P.soil = nil
  if type(nodes) == 'table' and (vs.lod or 1) < 3 then
    for k = 1, #nodes - 3, 4 do
      local cid, x, y, z = nodes[k], nodes[k + 1], nodes[k + 2], nodes[k + 3]
      if isFinite(cid) and isFinite(x) and isFinite(y) and isFinite(z) then
        P.setStampKind(P.kindAtWorld(x, y)) -- wall slope of the kind (no soil memory)
        local prev = vs.lastNode[cid]
        if prev and simTime - prev.t < 0.35 and (x - prev.x) ^ 2 + (y - prev.y) ^ 2 < st.maxSweep * st.maxSweep then
          P.stampBody(prev.x, prev.y, prev.z, x, y, z)
        else
          P.stampBody(x, y, z, x, y, z)
        end
        prev = prev or {}
        prev.x, prev.y, prev.z, prev.t = x, y, z, simTime
        vs.lastNode[cid] = prev
      end
    end
  end
  -- later stamps (relax, other callers) use the global rules
  P.soil, P.kBerm, P.kSlope = nil, nil, nil
end

-------------------------------------------------------------------------------
-- rings
-------------------------------------------------------------------------------
P.cxs = {}
P.cys = {}
P.ncent = 0
P.vehCenters = {}
P.boxes = {}
P.nbox = 0
P.desired = {}
P.desiredList = {}
P.desiredDist = {}

function P.addCenter(x, y)
  if not (isFinite(x) and isFinite(y)) then return end
  P.ncent = P.ncent + 1
  P.cxs[P.ncent], P.cys[P.ncent] = x, y
end

-- An oriented box in the ground plane: centre, forward unit vector, half length along
-- it, half width across. ex/ey: half extents of its axis-aligned bounds. Its centre is
-- also a centre point (sector loading follows the centre points) unless noCenter
-- (vehicles beyond ring.meshRange from the camera: their ruts are stamped, not meshed).
function P.addBox(cx, cy, fx, fy, hl, hw, noCenter)
  if not (isFinite(cx) and isFinite(cy)) then return nil end
  P.nbox = P.nbox + 1
  local b = P.boxes[P.nbox]
  if not b then b = {}; P.boxes[P.nbox] = b end
  b.cx, b.cy, b.fx, b.fy, b.hl, b.hw = cx, cy, fx, fy, hl, hw
  b.ex = abs(fx) * hl + abs(fy) * hw
  b.ey = abs(fy) * hl + abs(fx) * hw
  if not noCenter then P.addCenter(cx, cy) end
  return b
end

-- Current footprint box of a vehicle (world): the last box it sent, moved by how far the
-- vehicle went since. Before the first box arrives: a 5 m square round its position.
function P.vehicleBox(vs, veh, p)
  local b = vs and vs.box
  if b then
    local dx, dy = 0, 0
    if b.px and p then dx, dy = p.x - b.px, p.y - b.py end
    if dx * dx + dy * dy < 400 then return b.cx + dx, b.cy + dy, b.fx, b.fy, b.hl, b.hw end
  end
  local fx, fy = 1, 0
  local d = veh:getDirectionVector()
  if d and isFinite(d.x) and isFinite(d.y) then
    local l = sqrt(d.x * d.x + d.y * d.y)
    if l > 1e-3 then fx, fy = d.x / l, d.y / l end
  end
  return p.x, p.y, fx, fy, 2.5, 2.5
end

function P.gatherCenters()
  P.ncent = 0
  P.nbox = 0
  tclear(P.vehCenters)
  local camx, camy, camz = core_camera.getPositionXYZ()
  if not (isFinite(camx) and isFinite(camy)) then camx, camy = nil, nil end
  P.camx, P.camy = camx, camy
  local cand = {}
  for vid, vs in pairs(P.vehs) do
    local veh = getObjectByID(vid)
    if veh then
      local p = veh:getPosition()
      if p and isFinite(p.x) and isFinite(p.y) and isFinite(p.z) then
        local dc = camx and sqrt((p.x - camx) ^ 2 + (p.y - camy) ^ 2) or 0
        if dc <= cfg.ring.vehicleRange then
          local v = veh:getVelocity()
          local vx, vy = 0, 0
          if v and isFinite(v.x) and isFinite(v.y) then vx, vy = v.x, v.y end
          local cx, cy, fx, fy, hl, hw = P.vehicleBox(vs, veh, p)
          cand[#cand + 1] = { x = cx, y = cy, z = p.z, vx = vx, vy = vy, d = dc, vid = vid,
            fx = fx, fy = fy, hl = hl, hw = hw }
        end
      end
    end
  end
  table.sort(cand, P.byD)
  local R = cfg.ring.boxMargin or 3
  -- Vehicles beyond meshRange of the camera keep digging (tile data, stamps) but load
  -- no sectors and get no tile meshes: their uploads cost frame time and engine memory
  -- for ruts nobody can see at that distance. Meshes follow when the camera comes near.
  local meshR = cfg.ring.meshRange or huge
  for i = 1, min(#cand, cfg.ring.maxVehicles) do
    local c = cand[i]
    local far = c.d > meshR
    P.vehCenters[#P.vehCenters + 1] = c
    c.box = P.addBox(c.x, c.y, c.fx, c.fy, c.hl, c.hw, far)
    if c.box then c.box.own, c.box.veh = true, true end
    local s = sqrt(c.vx * c.vx + c.vy * c.vy)
    if s > 1 then
      -- the footprint moved ahead along the velocity: at least one box at any speed above
      -- 1 m/s, spaced so that neighbouring boxes plus their margins touch
      local ux, uy = c.vx / s, c.vy / s
      local look = max(s * cfg.ring.lookaheadTime, cfg.ring.minLookahead or 0)
      local along = abs(ux * c.fx + uy * c.fy) * c.hl + abs(-ux * c.fy + uy * c.fx) * c.hw
      local n = clamp(ceil(look / max(1, 2 * along + 2 * R)), 1, cfg.ring.maxLookaheadPoints)
      for k = 1, n do
        local o = look * k / n
        local b = P.addBox(c.x + ux * o, c.y + uy * o, c.fx, c.fy, c.hl, c.hw, far)
        if b then b.own, b.veh = k == 1, false end
      end
    end
  end
  P.updateLods()
  return camx, camy
end

-- Vehicles with an active ring run full-rate reports; the others run at 1/farLod
-- (they get no new tiles, but keep the ones they hold until the next stream).
P.lodCheck = 0
function P.updateLods()
  P.lodCheck = P.lodCheck - 1
  if P.lodCheck > 0 then return end
  P.lodCheck = 15 -- frames
  local far = max(1, floor(cfg.ring.farLod or 1))
  local nearD = cfg.ring.lodNearDist or 40
  local inRing = {}
  -- beyond meshRange nothing of the vehicle's ruts is drawn now: lowest rate (the swept
  -- stamp keeps the ruts continuous up to stamp.maxSweep per report)
  local meshR = cfg.ring.meshRange or huge
  for _, c in ipairs(P.vehCenters) do inRing[c.vid] = (c.d <= nearD) and 1 or (c.d > meshR and far or min(2, far)) end
  for vid, vs in pairs(P.vehs) do
    local want = inRing[vid] or far
    if vs.configured and vs.lod ~= want then
      vs.lod = want
      local veh = getObjectByID(vid)
      if veh then veh:queueLuaCommand('if deepnode_vehicle then deepnode_vehicle.setLod(' .. want .. ') end') end
    end
  end
end
M.getVehicleCenters = function() return P.vehCenters end
-- footprint and look-ahead box centres (sector loading follows these too)
M.getCenterPoints = function() return P.cxs, P.cys, P.ncent end
M.getBoxes = function() return P.boxes, P.nbox end

-- squared distance of a point to an oriented box (0 inside)
function P.pointBoxDist2(px, py, b)
  local dx, dy = px - b.cx, py - b.cy
  local f = abs(dx * b.fx + dy * b.fy) - b.hl
  local r = abs(-dx * b.fy + dy * b.fx) - b.hw
  if f < 0 then f = 0 end
  if r < 0 then r = 0 end
  return f * f + r * r
end

-- Squared distance between the axis-aligned rectangle x0..x1, y0..y1 and box b (0 when
-- they overlap). Separating axes: the rectangle's x and y, the box's forward and side.
-- When they are apart the closest pair is a corner of one against the other.
function P.rectBoxDist2(x0, y0, x1, y1, b)
  local cx, cy, fx, fy = b.cx, b.cy, b.fx, b.fy
  local apart = cx + b.ex < x0 or cx - b.ex > x1 or cy + b.ey < y0 or cy - b.ey > y1
  if not apart then
    local hx, hy = (x1 - x0) * 0.5, (y1 - y0) * 0.5
    local dx, dy = x0 + hx - cx, y0 + hy - cy
    if abs(dx * fx + dy * fy) > b.hl + abs(fx) * hx + abs(fy) * hy then
      apart = true
    elseif abs(-dx * fy + dy * fx) > b.hw + abs(fy) * hx + abs(fx) * hy then
      apart = true
    end
  end
  if not apart then return 0 end
  local best = huge
  local lx, ly, wx, wy = fx * b.hl, fy * b.hl, -fy * b.hw, fx * b.hw
  for k = 1, 4 do
    local sl = (k <= 2) and 1 or -1
    local sw = (k % 2 == 1) and 1 or -1
    local px, py = cx + sl * lx + sw * wx, cy + sl * ly + sw * wy
    local ex = max(x0 - px, 0, px - x1)
    local ey = max(y0 - py, 0, py - y1)
    local d = ex * ex + ey * ey
    if d < best then best = d end
  end
  local d = P.pointBoxDist2(x0, y0, b); if d < best then best = d end
  d = P.pointBoxDist2(x1, y0, b); if d < best then best = d end
  d = P.pointBoxDist2(x0, y1, b); if d < best then best = d end
  d = P.pointBoxDist2(x1, y1, b); if d < best then best = d end
  return best
end

-- squared distance of tile (tx,ty) to the nearest footprint or look-ahead box
-- (ownOnly: only vehicle boxes and their first look-ahead box; 'veh': vehicle boxes only)
function P.tileMinDist2(tx, ty, ownOnly)
  local best = huge
  local x0, y0 = ter.ox + tx * TILE, ter.oy + ty * TILE
  local x1, y1 = x0 + TILE, y0 + TILE
  for c = 1, P.nbox do
    local b = P.boxes[c]
    if ownOnly and not b.own then goto continue end
    if ownOnly == 'veh' and not b.veh then goto continue end
    -- lower bound from the box's axis-aligned bounds: skip boxes that cannot be nearer
    local gx = max(b.cx - b.ex - x1, 0, x0 - b.cx - b.ex)
    local gy = max(b.cy - b.ey - y1, 0, y0 - b.cy - b.ey)
    if gx * gx + gy * gy < best then
      local d = P.rectBoxDist2(x0, y0, x1, y1, b)
      if d < best then best = d end
      if best == 0 then return 0 end
    end
    ::continue::
  end
  return best
end

function P.updateRing()
  local R = cfg.ring.boxMargin or 3
  tclear(P.desired)
  tclear(P.desiredDist)
  local nd = 0
  for c = 1, P.nbox do
    local b = P.boxes[c]
    local tx0, tx1 = floor((b.cx - b.ex - R - ter.ox) / TILE), floor((b.cx + b.ex + R - ter.ox) / TILE)
    local ty0, ty1 = floor((b.cy - b.ey - R - ter.oy) / TILE), floor((b.cy + b.ey + R - ter.oy) / TILE)
    for ty = ty0, ty1 do
      for tx = tx0, tx1 do
        if P.inTerrain(tx, ty) then
          local key = ty * KEY + tx
          if not P.desired[key] and not P.emptyTiles[key] then
            local d2 = P.tileMinDist2(tx, ty)
            if d2 <= R * R then
              P.desired[key] = true
              nd = nd + 1
              P.desiredList[nd] = key
              P.desiredDist[key] = d2
            end
          end
        end
      end
    end
  end
  for k = nd + 1, #P.desiredList do P.desiredList[k] = nil end
  table.sort(P.desiredList, P.byDesiredDist)

  local timer = newTimer()
  local prepared = 0
  local canPrep = true
  for k = 1, nd do
    local key = P.desiredList[k]
    local t = tiles[key]
    if t then
      t.lastUse = simTime
      if t.state == 'frozen' then P.reactivate(t) end
    elseif canPrep then
      if prepared >= cfg.ring.maxPreparePerUpdate or timer:stop() > cfg.ring.prepBudgetMs then
        canPrep = false
      else
        local tx, ty = key % KEY, floor(key / KEY)
        local nt = P.prepareTile(tx, ty)
        prepared = prepared + 1
        if nt then P.addActive(nt) end
      end
    end
  end

  -- an active tile outside every box margin freezes after ring.freezeDelay s
  local delay = cfg.ring.freezeDelay or 1
  local toDemote = nil
  for _, t in pairs(P.act) do
    if t.state == 'active' then
      if P.desired[t.key] then
        t.outSince = nil
      else
        t.outSince = t.outSince or simTime
        if simTime - t.outSince >= delay then
          toDemote = toDemote or {}
          toDemote[#toDemote + 1] = t
        end
      end
    end
  end
  if toDemote then for _, t in ipairs(toDemote) do P.demote(t) end end
  if P.frozenCount > cfg.ring.frozenLimit then P.enforceFrozenLimit() end
end

P.bigCode = 7
-- Every terrain square written since the tile's last build lies under a vehicle body:
-- its footprint box grown by ring.bodyHideMargin (the truck hides them from a camera
-- above/behind; the margin takes in the berms beside the tyres).
function P.dirtyHidden(t)
  local hideM = cfg.ring.bodyHideMargin or 0.5
  local sqm = ter.sq
  local W = TS + 1
  for sq in pairs(t.dsq) do
    local px = t.x0 + (sq % W + 0.5) * sqm
    local py = t.y0 + (floor(sq / W) + 0.5) * sqm
    local inside = false
    for k = 1, P.nbox do
      local b = P.boxes[k]
      if b.veh then
        local dx, dy = px - b.cx, py - b.cy
        if abs(dx * b.fx + dy * b.fy) <= b.hl + hideM and abs(-dx * b.fy + dy * b.fx) <= b.hw + hideM then
          inside = true
          break
        end
      end
    end
    if not inside then return false end
  end
  return true
end

-- mesh replace tokens (cfg.ring.maxMeshBuildsPerSec)
P.buildTokens = 0
function P.refillBuildTokens(dt)
  local rate = cfg.ring.maxMeshBuildsPerSec or 0
  if rate <= 0 then P.buildTokens = huge; return end
  if P.buildTokens == huge then P.buildTokens = 0 end
  P.buildTokens = min(cfg.ring.meshBuildBurst or rate, P.buildTokens + rate * (dt or 0))
end
-- reserve: tokens that must stay after this one (kept for tiles being dug)
function P.takeBuildToken(reserve)
  if P.buildTokens < 1 + (reserve or 0) then return false end
  P.buildTokens = P.buildTokens - 1
  return true
end
M.takeBuildToken = function(reserve) return P.takeBuildToken(reserve) end

-- Camera view cone for the fast rut path (refreshed once per rebuild pass). A tile is in
-- view when its centre lies within the screen's diagonal half-angle (+8 degrees and its
-- own size); tiles right next to the camera always count.
P.view = { x = 0, y = 0, z = 0, fx = 0, fy = 1, fz = 0, cosA = 0.5, ok = false }
function P.viewConeCalc()
  local v = P.view
  local p, f = core_camera.getPosition(), core_camera.getForward()
  local l = sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
  if l < 1e-6 then error('no forward') end
  v.x, v.y, v.z = p.x, p.y, p.z
  v.fx, v.fy, v.fz = f.x / l, f.y / l, f.z / l
  local fov = core_camera.getFovDeg and core_camera.getFovDeg() or 60
  local half = math.atan(math.tan(math.rad(fov) * 0.5) * 2.04) + math.rad(8)
  v.cosA = math.cos(min(half, math.rad(85)))
end
-- no closure per call (a new function per frame stopped LuaJIT traces, jit.v FNEW)
function P.updateViewCone()
  P.view.ok = pcall(P.viewConeCalc)
end
-- point (+ radius) inside the camera view cone (same cone as the fast rut path)
function M.pointInView(x, y, z, r)
  local v = P.view
  if not v.ok then return true end
  local dx, dy, dz = x - v.x, y - v.y, z - v.z
  local d = sqrt(dx * dx + dy * dy + dz * dz)
  if d < (r or 0) * 1.5 + 1 then return true end
  return (dx * v.fx + dy * v.fy + dz * v.fz) / d >= v.cosA - (r or 0) / d
end
function P.tileInView(t)
  local v = P.view
  if not v.ok then return true end
  local dx, dy = t.x0 + TILE * 0.5 - v.x, t.y0 + TILE * 0.5 - v.y
  local dz = (t.vRest and t.vRest[0] or v.z) - v.z
  local d = sqrt(dx * dx + dy * dy + dz * dz)
  if d < TILE * 1.5 then return true end
  return (dx * v.fx + dy * v.fy + dz * v.fz) / d >= v.cosA - TILE * 0.75 / d
end

-- Mesh-on-screen snapshot per tile (heights as last uploaded) for minVisibleChange.
function P.snapshotShown(t)
  local NW = N + 1
  local sh = t.shown
  if not sh then sh = ffi.new('float[?]', NW * NW); t.shown = sh end
  for idx = 0, NW * NW - 1 do sh[idx] = decodeZ(t, idx) end
end

-- largest |height now - height on screen| of a tile (m); huge without a snapshot
function P.shownChange(t)
  local sh = t.shown
  if not sh then return huge end
  local mx = 0
  for idx = 0, (N + 1) * (N + 1) - 1 do
    local d = decodeZ(t, idx) - sh[idx]
    if d < 0 then d = -d end
    if d > mx then mx = d end
  end
  return mx
end

P.rebuildList = {}
function P.rebuildTiles()
  local tm = P.mod('tileMesh')
  local n = 0
  local minGap = 1 / max(1, cfg.ring.tileRebuildHz)
  -- Tiles within ownMeshRadius of a vehicle or its lookahead points get their own mesh
  -- before the wheels arrive, so their sector already leaves them out. Otherwise a fresh
  -- rut stays hidden under the sector surface (only 1.5 cm lower) until that sector is
  -- rebuilt, and ruts appear late while driving from tile to tile.
  local ownR = cfg.ring.ownMeshRadius or 3
  -- < 0: no own mesh for untouched tiles at all (the sector draws them; measured on
  -- gridmap_v2 with 8 trucks: ~54 uploads per 12 s run saved, same rut lag)
  local ownR2 = ownR >= 0 and ownR * ownR or -1
  -- Camera first: the mesh replace cap is shared by every vehicle, so tiles the player
  -- sees rebuild at tileRebuildHz while tiles far from the camera (AI digging 50 m away)
  -- drop to farRebuildHz; the rate falls off between camNearDist and camFarDist.
  local nearD, farD = cfg.ring.camNearDist or 30, cfg.ring.camFarDist or 90
  local farGap = 1 / max(0.5, cfg.ring.farRebuildHz or 3)
  local meshR = cfg.ring.meshRange or huge
  local meshR2 = (meshR + TILE) * (meshR + TILE)
  local settleGap = 1 / max(0.5, cfg.ring.settleRebuildHz or 2)
  local bodyWait = cfg.ring.bodyMaxWait or 0.6
  local smallWait = cfg.ring.smallChangeWait or 0.4
  local borderGap = cfg.ring.borderRebuildGap or 1
  -- rut code steps (2.7 mm each for a 0.35 m deep mud) that count as a visible change
  P.bigCode = max(1, floor((cfg.ring.bigChange or 0.02) / max(0.05, cfg.layers.defaultSinkDepth or 0.3) * 128 + 0.5))
  -- fast path: a fresh rut front (P.lastFresh) near the camera and inside its view cone
  -- rebuilds at tileRebuildHz; every other change (axles behind deepening the rut,
  -- settling, tiles out of view or far away) at most at deepenRebuildHz
  local freshWin = cfg.ring.freshWindow or 0.25
  local deepenGap = 1 / max(0.5, cfg.ring.deepenRebuildHz or 8)
  local digNear = cfg.ring.digNearDist or 50
  P.updateViewCone()
  for pass = 1, 2 do for _, t in pairs(pass == 1 and P.act or P.own) do
    -- a frozen tile that kept its own mesh still gets the rebuild it was waiting for
    -- (a rut written across its edge just before it froze), else its edge stays cracked
    local frozenOwn = t.state == 'frozen' and t.obj ~= nil and t.dirty
    -- beyond meshRange: stays dirty (no mesh) until the camera comes near
    if (t.state == 'active' or frozenOwn) and P.camDist2(t) <= meshR2 then
      local need = t.dirty
      if not need and t.borderDirty and simTime - t.lastBuild >= borderGap then need = true; t.dirty = true end
      local d2 = nil
      if not need and not t.obj and t.state == 'active' then
        d2 = P.tileMinDist2(t.tx, t.ty, true)
        if d2 <= ownR2 then need = true; t.dirty = true end
      end
      if need then
        local dc = sqrt(P.camDist2(t))
        local f = clamp((dc - nearD) / max(1, farD - nearD), 0, 1)
        local gap = minGap + (max(minGap, farGap) - minGap) * f
        -- no tyre on it for 0.3 s: only settling changes it (relax), slowly
        if t.lastStamp and simTime - t.lastStamp > 0.3 then gap = max(gap, settleGap) end
        local inView = P.tileInView(t)
        local seen = dc <= digNear and inView
        t.digNow = seen and t.lastFresh ~= nil and simTime - t.lastFresh < freshWin
        -- a rut being deepened in view (axles behind): first in line after the fresh fronts
        t.seenDeepen = seen and not t.digNow and t.rutted and t.lastStamp ~= nil and simTime - t.lastStamp < 1
        -- out of view, already meshed, no border change: defer (deadline below)
        if not inView and t.obj and t.built and t.pendSince and not t.borderDirty
          and simTime - t.pendSince < (cfg.ring.outViewMaxDefer or 4) then
          gap = huge
        end
        if not t.digNow then gap = max(gap, deepenGap) end
        -- new ruts all under a vehicle body (front/middle axles) are hidden by it: wait
        -- until they come out behind it (rut lag counts from then), at most bodyMaxWait
        local wait = false
        if t.obj and not t.bigChange and t.pendSince and simTime - t.pendSince < smallWait then
          wait = true
        elseif t.ndsq and t.ndsq > 0 and t.obj and P.dirtyHidden(t) then
          wait = simTime - (t.pendSince or simTime) < bodyWait
        elseif t.pendSince and not t.visSince then
          t.visSince = simTime
        end
        if not wait and simTime - t.lastBuild >= gap or not t.built or not t.obj then
          n = n + 1
          P.rebuildList[n] = t
          t.sortD = d2 or P.tileMinDist2(t.tx, t.ty, true)
          -- tiles being dug right now first (nearest the camera first), then the rest;
          -- look-ahead meshes for untouched tiles come last
          local dug = t.rutted and t.lastStamp and simTime - t.lastStamp < 1
          -- order: fresh fronts in view (nearest first), then earliest deadline: the change
          -- became visible (visSince / pendSince) + the target latency of its class
          if t.digNow then
            t.prio = dc * dc + (dug and 0 or 1e7)
          else
            local since = t.visSince or t.pendSince or simTime
            local target = inView and (cfg.ring.inViewTarget or 0.3) or (cfg.ring.outViewTarget or 1.5)
            t.prio = 1e5 + (since + target - simTime) * 1e3 + dc + (dug and 0 or 1e7)
          end
        end
      end
    end
  end end
  for k = n + 1, #P.rebuildList do P.rebuildList[k] = nil end
  if n == 0 then return end
  table.sort(P.rebuildList, P.byPrio)
  local timer = newTimer()
  local fm = P.mod('farMesh')
  local reserve = cfg.ring.prebuildReserve or 0
  local done = 0
  -- Tiles being dug near the camera (rut speed first): they rebuild at tileRebuildHz
  -- whatever the frame-rate governor says, up to digMaxPerFrame per frame; their upload
  -- time is still charged to the shared account, so sectors and settling wait instead.
  local digR2 = (cfg.ring.digNearDist or 50) ^ 2
  local digMax = cfg.ring.digMaxPerFrame or 16
  local digDone = 0
  -- Every frame that draws a freshly uploaded mesh costs the engine ~1 ms (shadow pass,
  -- measured; size does not matter): dig uploads only every digEvery-th frame, all
  -- together (2 at 60-80 fps = 30-40 Hz).
  local digEvery = max(1, floor(cfg.ring.digEvery or 1))
  if digEvery > 1 and (tm.frame() % digEvery) ~= 0 then digMax = 0 end
  for k = 1, n do
    local t = P.rebuildList[k]
    local dig = t.digNow and t.prio <= digR2
    if dig then
      if digDone >= digMax then break end
    elseif done >= cfg.ring.maxTileBuildsPerFrame or (done > 0 and timer:stop() > cfg.ring.meshBudgetMs) then
      break
    end
    local hadMesh = t.obj ~= nil
    local prebuild = not t.rutted and not hadMesh
    if fm and prebuild and t.sortD > ownR2 then
      -- Untouched tile: its sector already draws exactly this surface.
      -- No own mesh (and no sector rebuild) until the first rut, which saves most
      -- rebuilds while driving: every mesh replace costs engine memory for good.
      t.dirty = false
      t.lastBuild = simTime
      t.built = true
    elseif prebuild and P.buildTokens < reserve then
      -- keep the tokens for tiles that are being dug; this one stays dirty
    elseif not dig and not tm.canUpload('T', t.lastVerts or 450) then
      break -- the frame's upload budget is used up: nearest first next frame
    elseif not dig and not P.takeBuildToken() then
      break -- over the mesh replace cap: stays dirty, nearest first next frame
    else
      local minVis = cfg.ring.minVisibleChange or 0
      local skip = minVis > 0 and hadMesh and t.built and t.state == 'active' and not t.borderDirty
        and not t.freshPend and P.shownChange(t) < minVis
      local meshes = nil
      if skip then
        -- change too small to see: no upload (the mesh keeps the snapshot's heights)
        P.stats.skippedSmall = (P.stats.skippedSmall or 0) + 1
        if not dig then P.buildTokens = P.buildTokens + 1 end -- the token was not used
        t.pendSince, t.visSince, t.bigChange = nil, nil, nil
        if t.ndsq and t.ndsq > 0 then tclear(t.dsq); t.ndsq = 0 end
        t.dirty = false
        t.lastBuild = simTime
      else
        if dig then digDone = digDone + 1; P.buildTokens = max(0, P.buildTokens - 1) end
        done = done + 1
        meshes = tm.buildTile(t, P.borderRule(t, false))
      end
      if meshes and tm.present(t, meshes) then
        if minVis > 0 and t.obj then P.snapshotShown(t) end
        -- rut lag readout: visible changes only, from when they were made (or came out
        -- from under the vehicle)
        if t.pendSince and t.bigChange then P.noteLag(simTime - max(t.bigSince or t.pendSince, t.visSince or 0), P.camDist2(t)) end
        -- rut front latency (fresh carve to screen) of tiles in view near the camera
        if t.freshPend and t.digNow then
          local F, dt = P.lag.fresh, simTime - t.freshPend
          F.n, F.sum = F.n + 1, F.sum + dt
          if dt > F.max then F.max = dt end
          -- the front latency drives the stamp lead (predictive stamping, onMudReport)
          if dt < 1 then P.lagEma = (P.lagEma or dt) * 0.9 + dt * 0.1 end
        end
        t.freshPend = nil
        t.pendSince = nil
        t.visSince, t.bigChange, t.borderDirty = nil, nil, nil
        if t.ndsq and t.ndsq > 0 then tclear(t.dsq); t.ndsq = 0 end
        -- ruts under a sector that still draws this tile's old surface 1.5 cm above them
        -- stay hidden: that sector rebuild cannot wait (secOut: set by the sector build)
        if hadMesh and t.rutted and not t.secOut and fm then fm.markDirty(P.sectorKeyOfTile(t.tx, t.ty), true) end
        t.dirty = false
        t.lastBuild = simTime
        t.built = true
        if not hadMesh and t.obj and fm then
          -- The sector must leave this tile out before ruts appear. Urgent (no rebuild
          -- gap) only when the tile is dug already or lies at a vehicle box: a tile
          -- prebuilt for the look-ahead box has ~2 s before the wheels come, so its
          -- sector rebuild batches with the others (measured: 257 urgent sector
          -- re-meshes in 30 s with 6 trucks, most for look-ahead tiles).
          -- An untouched tile needs no sector rebuild at all: the sector draws the same
          -- surface 1.5 cm lower under it, and only rutted tiles are left out (the
          -- first rut escalates below: hadMesh and not secOut). That were ~3 urgent
          -- sector re-meshes per second for look-ahead tiles that no tyre touched.
          if t.rutted then fm.markDirty(P.sectorKeyOfTile(t.tx, t.ty), true) end
          P.markNeighboursDirty(t)
        end
      else
        t.dirty = false
        t.lastBuild = simTime
      end
    end
  end
end

-------------------------------------------------------------------------------
-- castRayStatic wrapper (camera collision with the render-only patch)
-------------------------------------------------------------------------------
function P.readXYZ(v) return v.x, v.y, v.z end

-- xy box of everything that draws mud: tiles and the lowered terrain
-- (twice a second: tiles only exist on lowered mud, inside the sink box; walking every
-- tile each frame cost 0.05-0.1 ms with ~1700 tiles)
P.boundsT = 0
function P.updateMudBounds(dtReal)
  P.boundsT = P.boundsT - (dtReal or 0)
  if P.boundsT > 0 and P.mudBounds then return end
  P.boundsT = 0.5
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for _, t in pairs(tiles) do
    if t.x0 < x0 then x0 = t.x0 end
    if t.y0 < y0 then y0 = t.y0 end
    if t.x0 + TILE > x1 then x1 = t.x0 + TILE end
    if t.y0 + TILE > y1 then y1 = t.y0 + TILE end
  end
  local sb = P.sinkBox
  if sb then
    x0 = min(x0, ter.ox + (sb[1] - 1) * ter.sq); y0 = min(y0, ter.oy + (sb[2] - 1) * ter.sq)
    x1 = max(x1, ter.ox + (sb[3] + 1) * ter.sq); y1 = max(y1, ter.oy + (sb[4] + 1) * ter.sq)
  end
  if x0 > x1 then P.mudBounds = nil; return end
  local b = P.mudBounds or {}
  b[1], b[2], b[3], b[4] = x0, y0, x1, y1
  P.mudBounds = b
end

function P.marchMud(ox, oy, oz, dx, dy, dz, maxD)
  local step = cfg.camera.step
  local n = min(cfg.camera.maxIter, ceil(maxD / step))
  local prevT, prevAbove = 0, nil
  for k = 0, n do
    local t = k * step
    if t > maxD then t = maxD end
    local z = oz + dz * t
    local s = surfaceAt(ox + dx * t, oy + dy * t)
    if s then
      local above = z >= s
      if k == 0 and not above then return nil end -- starts inside mud: leave it to the engine
      if prevAbove == true and not above then
        local a, b = prevT, t
        for _ = 1, 8 do
          local m = (a + b) * 0.5
          local sm = surfaceAt(ox + dx * m, oy + dy * m)
          if sm and oz + dz * m < sm then b = m else a = m end
        end
        return b
      end
      prevAbove = above
    else
      prevAbove = nil
    end
    prevT = t
    if t >= maxD then break end
  end
  return nil
end

function P.rayMud(o, d, maxD)
  if not P.castActive or not running or not cfg.camera.enabled then return nil end
  if type(maxD) ~= 'number' or maxD ~= maxD or maxD <= 0 or maxD > cfg.camera.maxDist then return nil end
  local to, td = type(o), type(d)
  if (to ~= 'table' and to ~= 'cdata' and to ~= 'userdata') or (td ~= 'table' and td ~= 'cdata' and td ~= 'userdata') then return nil end
  local ok1, ox, oy, oz = pcall(P.readXYZ, o)
  local ok2, dx, dy, dz = pcall(P.readXYZ, d)
  if not (ok1 and ok2) then return nil end
  if not (isFinite(ox) and isFinite(oy) and isFinite(oz) and isFinite(dx) and isFinite(dy) and isFinite(dz)) then return nil end
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-9 then return nil end
  -- cheap reject: the ray's xy box misses every drawn mud area
  local b = P.mudBounds
  if not b then return nil end
  local ex, ey = ox + dx / l * maxD, oy + dy / l * maxD
  if max(ox, ex) < b[1] or min(ox, ex) > b[3] or max(oy, ey) < b[2] or min(oy, ey) > b[4] then return nil end
  P.stats.rays = P.stats.rays + 1
  local hit = P.marchMud(ox, oy, oz, dx / l, dy / l, dz / l, maxD)
  if hit then P.stats.rayHits = P.stats.rayHits + 1 end
  return hit
end
M.rayMudForTests = P.rayMud

function P.castFinish(o, d, maxD, r1, ...)
  if type(r1) == 'number' and type(maxD) == 'number' and P.castActive then
    local lim = r1 < maxD and r1 or maxD
    local mud = P.rayMud(o, d, lim)
    if mud and mud < r1 then return mud, ... end
  end
  return r1, ...
end

function P.installCastWrapper()
  if P.castWrapper and castRayStatic == P.castWrapper then P.castActive = true; return end
  if type(castRayStatic) ~= 'function' then return end
  P.origCast = castRayStatic
  local orig = P.origCast
  P.castWrapper = function(o, d, maxD, ...)
    if not P.castActive then return orig(o, d, maxD, ...) end
    return P.castFinish(o, d, maxD, orig(o, d, maxD, ...))
  end
  castRayStatic = P.castWrapper
  P.castActive = true
end

function P.removeCastWrapper()
  P.castActive = false
  -- restore only if nobody wrapped after us; otherwise stay in the chain as a pass-through
  if P.castWrapper and castRayStatic == P.castWrapper and P.origCast then
    castRayStatic = P.origCast
    P.castWrapper, P.origCast = nil, nil
  end
end

-------------------------------------------------------------------------------
-- screen-space shadows
-------------------------------------------------------------------------------
function P.setSSSOff(off)
  local sss = scenetree.findObject('ScreenSpaceShadowsPostFx')
  if off then
    if not P.sssSaved then
      P.sssSaved = { enabled = sss and (sss:isEnabled() ~= false) or false, mask = VariableRegistry.get('$AL::UseSSSmask') }
    end
    VariableRegistry.set('$AL::UseSSSmask', false)
    if sss then sss:disable() end
  elseif P.sssSaved then
    if P.sssSaved.mask ~= nil then VariableRegistry.set('$AL::UseSSSmask', P.sssSaved.mask) end
    if sss and P.sssSaved.enabled then sss:enable() end
    P.sssSaved = nil
  end
end
function M.setScreenSpaceShadowsOff(off)
  cfg.render.disableSSS = off and true or false
  if running then P.setSSSOff(cfg.render.disableSSS) end
end
function M.screenSpaceShadowsOff() return P.sssSaved ~= nil end

-------------------------------------------------------------------------------
-- chunk debug overlay (debug.chunks): tile and sector borders drawn on the mud
--   blue        active tile with its own mesh (full detail, being dug or about to be)
--   pale blue   active tile drawn by its sector (untouched, no own mesh yet)
--   red         inactive (frozen) rut tile, keeping its own mesh near the camera
--   dark pink   inactive (frozen) rut tile, drawn by its sector
--   cyan        near sector (rebuilds first: within sectors.nearRadius of a vehicle)
--   orange      far sector (yellow while it is building or waiting to be built)
--   white       footprint box of each vehicle (grey: look-ahead boxes), dashed: + boxMargin
-------------------------------------------------------------------------------
P.dbgCache = {}
P.dbgSectors = {}
P.dbgCol = nil
P.dbgCount = { tiles = 0, sectors = 0, lines = 0 }

function P.dbgColors()
  if P.dbgCol or not ColorF then return P.dbgCol end
  P.dbgCol = {
    active = ColorF(0.1, 0.4, 1, 0.95), activeNoMesh = ColorF(0.45, 0.65, 1, 0.45),
    frozen = ColorF(1, 0.12, 0.08, 0.95), frozenSector = ColorF(0.6, 0.1, 0.35, 0.6), near = ColorF(0, 0.9, 0.9, 0.8),
    far = ColorF(1, 0.55, 0.1, 0.6), pending = ColorF(1, 0.95, 0.1, 0.9), ring = ColorF(1, 1, 1, 0.9),
    look = ColorF(0.75, 0.75, 0.75, 0.5),
  }
  return P.dbgCol
end

-- polyline around a rectangle of terrain squares (gx0,gy0)-(gx0+n,gy0+n), one point per
-- terrain vertex, at the undisturbed mud height + lift. Points off the mud take the
-- height of the nearest mud point on the line: the terrain under roads and static
-- meshes can be anywhere (on gridmap it pokes far above the concrete).
function P.dbgOutline(gx0, gy0, n, step)
  local xs, ys, zs = {}, {}, {}
  local lift = cfg.debug.lift or 0.12
  local function add(gx, gy)
    local rest, _, _, member = vertexInfo(gx, gy)
    xs[#xs + 1], ys[#ys + 1] = ter.ox + gx * ter.sq, ter.oy + gy * ter.sq
    zs[#xs] = member and rest or false
  end
  for i = 0, n - 1, step do add(gx0 + i, gy0) end
  for j = 0, n - 1, step do add(gx0 + n, gy0 + j) end
  for i = n, 1, -step do add(gx0 + i, gy0 + n) end
  for j = n, 1, -step do add(gx0, gy0 + j) end
  local m = #xs
  local any = nil
  for k = 1, m do if zs[k] then any = zs[k]; break end end
  if not any then any = ter.tb:getHeight(vec3(xs[1], ys[1], 0)) end
  -- fill gaps round the closed loop: forward twice, so a gap at the start sees the end
  local last = any
  for k = 1, 2 * m do
    local q = (k - 1) % m + 1
    if zs[q] then last = zs[q] elseif k > m then zs[q] = last end
  end
  for k = 1, m do if not zs[k] then zs[k] = last end end
  local pts = {}
  for k = 1, m do pts[k] = vec3(xs[k], ys[k], zs[k] + lift) end
  pts[m + 1] = pts[1]
  return pts
end

function P.dbgPoly(pts, col)
  for k = 1, #pts - 1 do debugDrawer:drawLine(pts[k], pts[k + 1], col) end
  P.dbgCount.lines = P.dbgCount.lines + #pts - 1
end

function P.drawDebug(camx, camy)
  if not (cfg.debug and cfg.debug.chunks) or not debugDrawer or not isFinite(camx) then return end
  local col = P.dbgColors()
  if not col then return end
  local R = cfg.debug.drawRadius or 120
  local R2 = R * R
  P.dbgCount.tiles, P.dbgCount.sectors, P.dbgCount.lines = 0, 0, 0
  local dc = cfg.debug
  if dc.tiles ~= false then for key, t in pairs(tiles) do
    local cx, cy = t.x0 + TILE * 0.5, t.y0 + TILE * 0.5
    local dc2 = (cx - camx) ^ 2 + (cy - camy) ^ 2
    if dc2 < R2 then
      -- full outline (one point per terrain vertex) near the camera, corners only further
      local nearT = dc2 < 900
      local ck = nearT and key or -key - 1
      local pts = P.dbgCache[ck]
      if not pts then pts = P.dbgOutline(t.gx0, t.gy0, TS, nearT and 1 or TS); P.dbgCache[ck] = pts end
      local c
      if t.state == 'frozen' then c = t.obj and col.frozen or col.frozenSector
      elseif t.obj then c = col.active else c = col.activeNoMesh end
      P.dbgPoly(pts, c)
      P.dbgCount.tiles = P.dbgCount.tiles + 1
    end
  end end
  local fm = P.mod('farMesh')
  if dc.sectors ~= false and fm and fm.debugSectors then
    local n = fm.debugSectors(P.dbgSectors)
    local span = SEC * TILE
    local R2s = (R + span) ^ 2
    for k = 1, n do
      local s = P.dbgSectors[k]
      local cx, cy = ter.ox + (s.sx + 0.5) * span, ter.oy + (s.sy + 0.5) * span
      if (cx - camx) ^ 2 + (cy - camy) ^ 2 < R2s then
        local ck = 'S' .. s.key
        local pts = P.dbgCache[ck]
        if not pts then pts = P.dbgOutline(s.sx * SEC * TS, s.sy * SEC * TS, SEC * TS, TS); P.dbgCache[ck] = pts end
        local c = s.near and col.near or col.far
        if not s.built or s.building or s.urgent then c = col.pending end
        P.dbgPoly(pts, c)
        P.dbgCount.sectors = P.dbgCount.sectors + 1
      end
    end
  end
  if dc.boxes == false then return end
  local own = {}
  for _, c in ipairs(P.vehCenters) do if c.box then own[c.box] = true end end
  local Rm = cfg.ring.boxMargin or 3
  for k = 1, P.nbox do
    local b = P.boxes[k]
    local c = own[b] and col.ring or col.look
    P.dbgBox(b, 0, c, false)
    if own[b] then P.dbgBox(b, Rm, col.look, true) end
  end
end

-- outline of box b grown by m metres, on the mud / ground (dashed: every other segment)
function P.dbgBox(b, m, col, dashed)
  local lx, ly = b.fx * (b.hl + m), b.fy * (b.hl + m)
  local wx, wy = -b.fy * (b.hw + m), b.fx * (b.hw + m)
  local cs = { { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 }, { 1, 1 } }
  local prev = nil
  local seg = 0
  for k = 1, 4 do
    local ax, ay = b.cx + cs[k][1] * lx + cs[k][2] * wx, b.cy + cs[k][1] * ly + cs[k][2] * wy
    local bx, by = b.cx + cs[k + 1][1] * lx + cs[k + 1][2] * wx, b.cy + cs[k + 1][1] * ly + cs[k + 1][2] * wy
    local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local n = max(1, ceil(len / 0.75))
    for i = (k == 1) and 0 or 1, n do
      local x, y = ax + (bx - ax) * i / n, ay + (by - ay) * i / n
      local z = M.groundAt(x, y)
      if isFinite(z) then
        local p = vec3(x, y, z + 0.2)
        seg = seg + 1
        if prev and (not dashed or seg % 2 == 0) then debugDrawer:drawLine(prev, p, col) end
        prev = p
      else
        prev = nil
      end
    end
  end
  P.dbgCount.lines = P.dbgCount.lines + seg
end

function M.setDebugChunks(on)
  cfg.debug = cfg.debug or {}
  cfg.debug.chunks = on and true or false
  P.debugChunksOverride = cfg.debug.chunks -- kept over restarts (zones, reload)
  if not on then P.dbgCache = {} end
  return cfg.debug.chunks
end
function M.debugChunks() return cfg.debug and cfg.debug.chunks or false end

-------------------------------------------------------------------------------
-- performance and memory sampling (debug tab), once a second
-------------------------------------------------------------------------------
P.perf = { meshBuildsPerSec = 0, lastBuilds = 0, acc = 0, luaKB = 0, procMB = 0, vramMB = 0, frameAvg = 0,
  frameSum = 0, frameN = 0, fps = 0, realAcc = 0, frames = 0 }

-- Once a second: below perf.targetFps the frame's upload budget shrinks by a third,
-- at the frame cap (within 1 fps of the best second seen) it grows by 0.25 ms.
P.bestFps = 0
function P.governor(fps)
  local tm = P.mod('tileMesh')
  local pc = cfg.perf or {}
  if not tm or not tm.setUploadBudget or not isFinite(fps) then return end
  P.bestFps = max(P.bestFps * 0.99, fps)
  local b = tm.uploadBudget()
  -- target: perf.targetFps, but never above 88 % of the best second seen (a slower PC
  -- whose plain frame rate sits near the target would otherwise starve the uploads)
  local target = min(pc.targetFps or 57, 0.88 * P.bestFps)
  if fps < target then
    b = b * 0.67
  elseif fps >= P.bestFps - 1 then
    b = b + 0.25
  end
  b = clamp(b, pc.uploadMsMin or 1, pc.uploadMsMax or 4)
  tm.setUploadBudget(b)
  P.perf.uploadBudget = b
  -- the sector builder's Lua time per frame follows the same budget
  P.sectorBudget = clamp(b, 0.5, cfg.sectors.buildBudgetMs or 2)
end

function P.samplePerf(dtReal)
  local pf = P.perf
  pf.frameSum = pf.frameSum + P.stats.lastFrameMs
  pf.frameN = pf.frameN + 1
  pf.realAcc = pf.realAcc + (dtReal or 0)
  if pf.realAcc < 1 then return end
  local tm = P.mod('tileMesh')
  local builds = 0
  if tm then local _, _, _, b = tm.stats(); builds = b or 0 end
  pf.meshBuildsPerSec = (builds - pf.lastBuilds) / pf.realAcc
  pf.lastBuilds = builds
  pf.fps = pf.frameN / pf.realAcc
  pf.frameAvg = pf.frameN > 0 and pf.frameSum / pf.frameN or 0
  P.governor(pf.fps)
  pf.frameSum, pf.frameN, pf.realAcc = 0, 0, 0
  pf.luaKB = collectgarbage('count')
  local okM, mem = pcall(function() return Engine.Platform.getMemoryInfo() end)
  if okM and type(mem) == 'table' then
    pf.procMB = (tonumber(mem.processPhysUsed) or 0) / 1048576
    pf.commitMB = (tonumber(mem.processVirtUsed) or 0) / 1048576
    -- growth of the process since the mod started, and per mesh upload since then
    if not P.startCommitMB then P.startCommitMB, P.startBuilds = pf.commitMB, builds end
    pf.growthMB = pf.commitMB - P.startCommitMB
    local up = builds - (P.startBuilds or builds)
    pf.growthPerUploadKB = up > 50 and pf.growthMB * 1024 / up or 0
    pf.sysUsedMB = (tonumber(mem.osPhysUsed) or 0) / 1048576
    pf.sysTotalMB = (tonumber(mem.osPhysAvailable) or 0) / 1048576
  end
  local okG, g = pcall(function() return Engine.Render.getMemoryInfo() end)
  if okG and type(g) == 'table' and g.valid ~= false and tonumber(g.usageBytes) then
    pf.vramMB = tonumber(g.usageBytes) / 1048576
    pf.vramBudgetMB = (tonumber(g.budgetBytes) or 0) / 1048576
  else
    local okV, v = pcall(function() return Engine.Render.getVRAMUsage() end)
    if okV and tonumber(v) then pf.vramMB = tonumber(v) / 1048576 end
  end
end

-- Lua cleanup (GUI button, console deepnode_main.flushMemory()):
--  * full Lua garbage collection in the game engine VM and in every vehicle VM (the GE
--    heap swings by 30-50 MB between collections while the mod builds meshes);
--  * hidden tyre meshes, landed lumps, cached ground sources and the mod's per-level
--    caches (debug outlines, surface samples) are dropped.
-- Ruts, mud coats and everything visible stay. One hitch of ~0.1 s.
-- What this does NOT do: shrink the game process. Measured in game: neither a full GC
-- (24 MB of Lua heap freed) nor deleting 93 hidden pooled mesh objects changed the
-- process commit at all; the engine and the Lua allocator keep freed memory for reuse
-- until the game restarts, and the FFI sandbox blocks the Windows trim calls. The way to
-- keep the process small is to upload less: pool.mode 'pair' (~13 KB kept per upload
-- against ~80 KB with 'swap').
function M.flushMemory(why)
  local t0 = newTimer()
  local luaBefore = collectgarbage('count')
  local commitBefore = P.perf.commitMB
  local tm, wm = P.mod('tileMesh'), P.mod('wheelMud')
  local cleared, deleted, tyres = 0, 0, 0
  if running then
    if wm and wm.flush then tyres = wm.flush() end
    P.dbgCache = {}
    tclear(P.frameVertexCache)
    for vid in pairs(P.vehs) do
      local veh = getObjectByID(vid)
      if veh then veh:queueLuaCommand('collectgarbage("collect")') end
    end
  end
  collectgarbage('collect')
  collectgarbage('collect')
  local luaAfter = collectgarbage('count')
  P.lastFlushT = os.clock()
  local commitAfter = nil
  local okM, mem = pcall(function() return Engine.Platform.getMemoryInfo() end)
  if okM and type(mem) == 'table' then commitAfter = (tonumber(mem.processVirtUsed) or 0) / 1048576 end
  local r = { why = why or 'manual', luaFreedMB = (luaBefore - luaAfter) / 1024, luaMB = luaAfter / 1024,
    poolCleared = cleared, poolDeleted = deleted, tyresCleared = tyres, ms = t0:stop(),
    commitBeforeMB = commitBefore, commitAfterMB = commitAfter }
  P.lastFlush = r
  log('I', logTag, sfmt('memory flush (%s): GE Lua %.1f MB freed (now %.1f MB), pool %d cleared %d deleted, %d tyre meshes, %.0f ms',
    r.why, r.luaFreedMB, r.luaMB, cleared, deleted, tyres, r.ms))
  return r
end
function M.lastFlush() return P.lastFlush end

-- Optional steady GC help (memory.gcStepKB > 0): one small incremental GC step per frame
-- keeps the GE Lua heap from swelling between full collections.
function P.gcStep()
  local k = tonumber(cfg.memory and cfg.memory.gcStepKB) or 0
  if k > 0 then collectgarbage('step', k) end
end

-- Memory the mod itself holds (estimates): tile grids, layer map / distance field,
-- terrain restore data, and mesh geometry (32 bytes per vertex: position, normal,
-- uv; 2-4 bytes per index) in engine/GPU memory.
function M.memoryEstimate()
  local NW = (N + 1) * (N + 1)
  local perTile = NW * (4 + 4 + 1 + 1 + 1 + 1) + N * N + (TS + 1) * (TS + 1) * 9 + TS * TS * 2 + 600
  local nt = P.activeCount + P.frozenCount
  local S = ter and ter.size or 0
  local terrain = (rows and S * S or 0) + (dist and S * S or 0) + P.sinkCapacity * 20
  local verts, corners = 0, 0
  local tm = P.mod('tileMesh')
  if tm and tm.geometry then verts, corners = tm.geometry() end
  local wm = P.mod('wheelMud')
  if wm and wm.geometry then local v2, c2 = wm.geometry(); verts, corners = verts + v2, corners + c2 end
  return {
    tilesMB = nt * perTile / 1048576, terrainMB = terrain / 1048576,
    meshVerts = verts, meshCorners = corners,
    meshMB = (verts * 32 + corners * (verts > 65535 and 4 or 2)) / 1048576,
  }
end

function M.perf() return P.perf end

-- per-vehicle state for the debug tab
function M.vehicleStats()
  local out = {}
  for vid, vs in pairs(P.vehs) do
    local s = vs.stats
    local b = vs.box
    out[#out + 1] = { id = vid, lod = vs.lod or 1, sent = (function() local n = 0 for _ in pairs(vs.sent) do n = n + 1 end return n end)(),
      wheels = s and s.wheels or 0, cands = s and s.cands or 0, luaKB = s and s.luaKB or 0, tiles = s and s.tiles or 0,
      hull = s and s.hull or 0, boxL = b and 2 * b.hl or 0, boxW = b and 2 * b.hw or 0 }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.setMeshBuildsPerSec(n)
  if isFinite(n) then cfg.ring.maxMeshBuildsPerSec = clamp(floor(n + 0.5), 5, 120) end
  return cfg.ring.maxMeshBuildsPerSec
end

function M.setMaxVehicles(n)
  if isFinite(n) then cfg.ring.maxVehicles = clamp(floor(n + 0.5), 1, 32) end
  return cfg.ring.maxVehicles
end

function M.setClodsEnabled(on)
  local was = cfg.clods.enabled
  cfg.clods.enabled = on and true or false
  local wm = P.mod('wheelMud')
  if wm and wm.setEnabled then wm.setEnabled(cfg.clods.enabled) end
  -- wheel definitions are only kept while tyre mud is on: ask every vehicle again
  if running and cfg.clods.enabled and not was then
    for vid in pairs(P.vehs) do P.configureVehicle(vid) end
  end
  return cfg.clods.enabled
end

-- Key binding "DeepNode: tyre mud on / off": flips tyre mud, says so on screen and
-- saves the choice with the other GUI settings (gui.json).
function M.toggleClods()
  local on = M.setClodsEnabled(not cfg.clods.enabled)
  local g = P.mod('gui')
  if g and g.markChanged then g.markChanged() end
  if ui_message then ui_message('DeepNode: tyre mud ' .. (on and 'ON' or 'OFF'), 2, 'deepnode_clods') end
  return on
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------
function P.loadSubModules()
  for _, n in ipairs({ 'tileMesh', 'farMesh', 'wheelMud', 'physics', 'decals', 'overlay', 'gui' }) do
    local name = 'deepnode_' .. n
    if extensions and not extensions[name] then
      extensions.load(name)
    end
    if setExtensionUnloadMode and extensions and extensions[name] then setExtensionUnloadMode(name, 'manual') end
  end
end

function P.start()
  if running then return true end
  local total = newTimer()
  P.loadConfig()
  if P.debugChunksOverride ~= nil then cfg.debug.chunks = P.debugChunksOverride end
  P.loadSubModules()
  P.session = P.session + 1
  simTime = 0
  P.levelName = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or 'unknown'
  P.levelName = tostring(P.levelName or 'unknown'):gsub('[^%w_%-]', '_')
  featherVerts = clamp(floor(cfg.layers.featherVerts), 1, 80)
  distCap = min(250, 3 * featherVerts + TOUCH + 1)
  edgeDip = cfg.layers.edgeDip
  bermMax = cfg.stamp.bermMax

  local ok, err = P.initTerrain()
  if not ok then
    log('W', logTag, 'not started: ' .. tostring(err))
    P.stats.lastError = tostring(err)
    return false
  end
  P.started = true -- from here on stop() must clean up, even if start fails later
  local anySoft = false
  for _, L in pairs(layers) do if L.soft then anySoft = true end end

  P.memberPad = 1.5 * ter.sq
  TS = max(1, floor(cfg.tiles.targetSize / ter.sq + 0.5))
  CPS = max(1, floor(ter.sq / cfg.tiles.cellSize + 0.5))
  N = TS * CPS
  CELL = ter.sq / CPS
  TILE = TS * ter.sq
  SEC = max(1, floor(cfg.sectors.tiles))
  M.ts, M.cps, M.N, M.cell, M.tileSize, M.sec = TS, CPS, N, CELL, TILE, SEC

  tiles = {}
  M.tiles = tiles
  P.act, P.own = {}, {}
  P.emptyTiles, P.frozenPerSector, P.changedTiles = {}, {}, {}
  P.floorTiles = {}
  P.frozenCount, P.activeCount, P.frozenOwnCount = 0, 0, 0
  P.dbgCache = {}
  P.startCommitMB = nil -- process growth is measured from here (debug tab)
  P.loadZones()
  -- sector size from the map's meshed soft ground (zones included), before the sink pass
  if cfg.sectors.autoSize then SEC = P.autoSectorTiles(SEC); M.sec = SEC end
  if not anySoft and #zones == 0 then
    log('I', logTag, 'level has no soft layers matching ' .. table.concat(cfg.softMatch, ', ') .. ' and no zones')
  end

  local tm = P.mod('tileMesh')
  tm.setContext(M)
  P.hash01 = tm.hash01
  if tm.setUploadBudget then tm.setUploadBudget((cfg.perf and cfg.perf.uploadMsStart) or 3) end
  if tm.setUploadEvery then tm.setUploadEvery((cfg.perf and cfg.perf.uploadEvery) or 3) end
  P.bestFps = 0
  -- the object group must exist before clods create their objects
  tm.initPool(0, P.session)

  local t0 = newTimer()
  P.createFallbackMaterial()
  P.createLayerMaterials()
  P.initGroundColors()
  local wm, fm = P.mod('wheelMud'), P.mod('farMesh')
  if wm then wm.start(M) end
  P.stats.materialsMs = t0:stopAndReset()

  local ph = P.mod('physics')
  if ph then ph.start(M, layers) end
  P.sinkPass()
  -- after the sink pass: the lifted copies build their cells on the lowered terrain
  if cfg.grass and cfg.grass.lift ~= false then P.liftGroundCover() end
  -- decal roads drawn into the mud meshes, or kept off the mud
  P.coverRoads(P.roadMode() == 'off')
  local dec = P.mod('decals')
  if dec and P.roadMode() == 'overlay' then
    local okDec, errDec = pcall(dec.start, M)
    if not okDec then log('E', logTag, 'decal overlay failed: ' .. tostring(errDec)) end
  end
  local ov = P.mod('overlay')
  if ov then
    local okOv, errOv = pcall(ov.start, M)
    if not okOv then log('E', logTag, 'rut overlay failed: ' .. tostring(errOv)) end
  end

  -- Pre-create the shared pool so normal driving never creates scene objects:
  -- sectors that can be inside the load radius, plus active tiles.
  local span = SEC * TILE
  local inRadius = floor(math.pi * (cfg.sectors.loadRadius / span + 1) ^ 2)
  local lowered = 0
  for _ in pairs(P.loweredSectors) do lowered = lowered + 1 end
  -- active tiles per vehicle: a footprint of about 12 x 3 m plus margins, and look-ahead
  local ringTiles = (2 * floor(((cfg.ring.boxMargin or 3) + 10) / TILE) + 3) ^ 2
  local want = min(lowered, inRadius) + 2 * ringTiles + (cfg.ring.frozenOwnMeshMax or 0) + 64
  tm.initPool(min(2000, max(cfg.pool.initial, want)), P.session)

  running = true
  if fm then
    fm.start(M)
    P.gatherCenters()
    local camx, camy = core_camera.getPositionXYZ()
    local t1 = newTimer()
    fm.buildSync(cfg.sectors.syncRadius, camx, camy, P.vehCenters)
    P.stats.syncSectorsMs = t1:stopAndReset()
  end
  P.createPreload()
  if P.roadMode() == 'drape' then
    P.collectMudRoads()
    if cfg.roads.drape ~= false then
      local okD, errD = pcall(P.drapeRoads, false)
      if not okD then
        log('E', logTag, 'road drape failed: ' .. tostring(errD))
        pcall(function() be:setPhysicsRunning(true) end)
      end
    end
  else
    P.roadsPending = {}
  end
  P.installCastWrapper()
  if cfg.render.disableSSS then P.setSSSOff(true) end

  for _, veh in ipairs(getAllVehicles and getAllVehicles() or {}) do
    P.configureVehicle(veh:getID())
  end
  P.stats.startMs = total:stopAndReset()
  log('I', logTag, sfmt('started on %s (%.0f ms, tile %d squares, %d cells/square)', P.levelName, P.stats.startMs, TS, CPS))
  local g = P.mod('gui')
  if g and cfg.gui.openOnStart and g.open then g.open() end
  return true
end

-- objectsAlive = false when the level is already gone (onClientEndMission)
function P.stop(objectsAlive)
  if objectsAlive == nil then objectsAlive = true end
  P.finishDrape(objectsAlive)
  P.removeCastWrapper()
  if not running and not sinkApplied and not P.started then
    P.setSSSOff(false)
    return
  end
  running = false
  local fm, wm, tm = P.mod('farMesh'), P.mod('wheelMud'), P.mod('tileMesh')
  if fm then fm.stop(objectsAlive) end
  if wm then wm.stop(objectsAlive) end
  local ph = P.mod('physics')
  if ph then ph.stop(objectsAlive) end
  local dec = P.mod('decals')
  if dec then dec.stop(objectsAlive) end
  local ov = P.mod('overlay')
  if ov then ov.stop(objectsAlive) end
  -- decal roads hidden while off are shown again
  if objectsAlive ~= false then P.coverRoads(false) else P.roadsHidden = {} end
  P.liftOn = false
  P.floorTiles = {}
  for _, t in pairs(tiles) do t.obj = nil end
  -- the preload mesh lives in the object group: delete it before the group goes
  if objectsAlive and P.preloadObj then P.preloadObj:delete() end
  P.preloadObj = nil
  if tm then tm.destroyAll(objectsAlive) end
  P.deleteOwnedMaterials(objectsAlive)
  P.restoreGroundCover(objectsAlive)
  if objectsAlive then
    P.restoreRoads()
    P.restoreTerrain()
    for vid in pairs(P.vehs) do
      local veh = getObjectByID(vid)
      if veh then veh:queueLuaCommand('extensions.unload("deepnode_vehicle")') end
    end
  else
    sinkApplied, P.sinkCount, P.shortfall, P.sinkBox = false, 0, {}, nil
    P.roadsChanged, P.roadsPending, P.roadsById = {}, {}, {}
  end
  P.setSSSOff(false)
  tiles = {}
  M.tiles = tiles
  P.act, P.own = {}, {}
  P.emptyTiles, P.frozenPerSector, P.changedTiles, P.loweredSectors = {}, {}, {}, {}
  P.frozenCount, P.activeCount, P.frozenOwnCount = 0, 0, 0
  P.vehs = {}
  P.mudBounds = nil
  P.started = false
  rows, dist, engineCache = nil, nil, nil
  ter = nil
  M.ter = nil
  log('I', logTag, 'stopped')
end

function M.start() P.startRequested = false; return P.start() end
function M.stop() P.startRequested = false; P.stop(true) end
function M.toggle() if running then M.stop() else M.start() end end

function M.setFlipV(b)
  if b == nil then b = not cfg.materials.flipV end
  cfg.materials.flipV = b and true or false
  for _, t in pairs(tiles) do if t.state == 'active' then t.dirty = true end end
  local fm = P.mod('farMesh')
  if fm then fm.markAllDirty() end
  return cfg.materials.flipV
end

function M.cleanWheels()
  local wm = P.mod('wheelMud')
  if wm then wm.cleanWheels() end
end

-- distance (m) round a vehicle's footprint box within which tiles are active
function M.setBoxMargin(r)
  if isFinite(r) then cfg.ring.boxMargin = clamp(r, 0, 30) end
  return cfg.ring.boxMargin
end

-- Idle reset (cfg.reset.idleSeconds), checked once a second: release every frozen
-- tile whose last dig and last time inside a vehicle ring are both older than the limit.
P.idleCheck = 0
function P.updateIdleReset(dt)
  local limit = tonumber(cfg.reset and cfg.reset.idleSeconds) or 0
  if limit <= 0 or P.frozenCount == 0 then return end
  P.idleCheck = P.idleCheck + dt
  if P.idleCheck < 1 then return end
  P.idleCheck = 0
  local old = nil
  for _, t in pairs(tiles) do
    if t.state == 'frozen' and simTime - max(t.lastUse or 0, t.lastStamp or 0) > limit then
      old = old or {}
      old[#old + 1] = t
    end
  end
  if not old then return end
  for _, t in ipairs(old) do P.releaseFrozen(t) end
  log('D', logTag, sfmt('idle reset: released %d rut tile(s) unused for %g s', #old, limit))
end

function M.setIdleReset(seconds)
  if isFinite(seconds) then
    cfg.reset = cfg.reset or {}
    cfg.reset.idleSeconds = max(0, seconds)
  end
  return cfg.reset and cfg.reset.idleSeconds or 0
end

function M.clearRuts()
  if not running then return end
  local fm = P.mod('farMesh')
  local list = {}
  for _, t in pairs(tiles) do list[#list + 1] = t end
  for _, t in ipairs(list) do
    if t.state == 'frozen' then
      P.releaseFrozen(t)
    else
      local NW = N + 1
      ffi.fill(t.rut, NW * NW, 128)
      ffi.fill(t.track, NW * NW, 0)
      ffi.fill(t.peakLo, NW * NW, 128)
      ffi.fill(t.peakHi, NW * NW, 128)
      if t.passN then ffi.fill(t.passN, NW * NW, 0); ffi.fill(t.z1, NW * NW, 0) end
      t.relaxing = false
      t.rutted = false
      t.dirty = true
      P.changedTiles[t.key] = true
      if P.overlayClear then P.overlayClear(t.x0, t.y0, t.x0 + TILE, t.y0 + TILE) end
      if P.liftOn then P.markFloor(t, 'reset') end
    end
  end
  if fm then fm.markAllDirty() end
end

function M.addZoneHere(radius, depth)
  if not running then return end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local x, y
  if veh then
    local p = veh:getPosition()
    x, y = p.x, p.y
  else
    x, y = core_camera.getPositionXYZ()
  end
  if not (isFinite(x) and isFinite(y)) then return end
  zones[#zones + 1] = { kind = 'circle', x = x, y = y, r = radius or 6, feather = 2, depth = depth or 0.35 }
  P.saveZones()
  -- zones change the sunk terrain: rebuild the whole mud state (user action, not while driving)
  P.stop(true); P.start()
end

function M.removeZones()
  zones = {}
  if P.levelName then P.saveZones() end
  if running then P.stop(true); P.start() end
end

function M.zoneCount() return #zones end

function M.reloadLevelData()
  if running then P.stop(true) end
  P.start()
end

function M.allMaterialNames() return P.allMaterialNames() end

function M.stats()
  local tm, fm, wm = P.mod('tileMesh'), P.mod('farMesh'), P.mod('wheelMud')
  local s = {
    running = running, level = P.levelName, roadsOver = P.stats.roadsOver or 0, roadsPending = P.stats.roadsPending or 0,
    roadsBad = P.stats.roadsBad or 0, drape = P.stats.drape, draping = P.drape ~= nil,
    grassLifted = P.stats.grassLifted or 0,
    activeTiles = P.activeCount, frozenTiles = P.frozenCount, orientation = P.stats.orientation,
    sunkVertices = P.stats.sunkVertices, startMs = P.stats.startMs, sinkMs = P.stats.sinkMs, distMs = P.stats.distMs,
    layerMapMs = P.stats.layerMapMs, materialsMs = P.stats.materialsMs, syncSectorsMs = P.stats.syncSectorsMs,
    lastFrameMs = P.stats.lastFrameMs, maxFrameMs = P.stats.maxFrameMs, slowCalls = P.stats.slowCalls,
    stamps = P.stats.stamps, rays = P.stats.rays, rayHits = P.stats.rayHits, zones = #zones,
    tileSquares = TS, cellsPerSquare = CPS, lastError = P.stats.lastError,
  }
  if tm then s.poolCreated, s.poolInUse, s.poolFree, s.meshBuilds, s.meshRejected, s.poolPeak = tm.stats() end
  if fm then s.sectors = fm.stats() end
  if wm then s.clods = wm.stats() end
  if s.timings == nil then s.timings = M.timings end
  s.perf = P.perf
  s.vehicles = 0
  for _ in pairs(P.vehs) do s.vehicles = s.vehicles + 1 end
  s.ringVehicles = #P.vehCenters
  if running then s.memory = M.memoryEstimate() end
  s.debugLines = P.dbgCount
  return s
end

-------------------------------------------------------------------------------
-- frame update with per-module timers (calls over 20 ms are logged)
-------------------------------------------------------------------------------
M.timings = {}
function P.timed(name, f, ...)
  local t = newTimer()
  f(...)
  local ms = t:stop()
  local e = M.timings[name]
  if not e then e = { last = 0, max = 0, maxAge = 0, peak = 0 }; M.timings[name] = e end
  e.last = ms
  if ms > e.max or e.maxAge > 5 then e.max = ms; e.maxAge = 0 end
  if ms > e.peak then e.peak = ms end
  if ms > 20 then
    P.stats.slowCalls = P.stats.slowCalls + 1
    log('W', logTag, sfmt('slow call %s: %.1f ms', name, ms))
  end
end

function P.onUpdate(dtReal, dtSim, dtRaw)
  if P.startRequested and not running then
    P.startRequested = false
    local ok, err = pcall(P.start)
    if not ok then
      P.stats.lastError = tostring(err)
      log('E', logTag, 'start failed: ' .. tostring(err))
      pcall(P.stop, true)
    end
  end
  if not running then return end
  local frame = newTimer()
  local dt = dtSim or 0
  if not isFinite(dt) or dt < 0 then dt = 0 end
  simTime = simTime + dt
  for _, e in pairs(M.timings) do e.maxAge = e.maxAge + (dtReal or 0) end
  tclear(P.frameVertexCache)
  -- stamp lead (s): fixed stamp.leadTime >= 0, else the measured near rut latency
  local sc = cfg.stamp
  local lt = tonumber(sc.leadTime) or -1
  if lt >= 0 then P.stampLead = lt
  else P.stampLead = clamp((P.lagEma or 0.03) + (sc.leadExtra or 0), sc.leadMin or 0.015, sc.leadMax or 0.06) end

  local tm, fm, wm = P.mod('tileMesh'), P.mod('farMesh'), P.mod('wheelMud')
  P.timed('deferred', tm.processDeferred)
  if P.drape then P.updateDrape(dtReal) end
  P.refillBuildTokens(dtReal or dt)
  local camx, camy = P.gatherCenters()
  -- before the sector update: sectors reported built were built in an earlier frame
  if #P.roadsPending > 0 then P.timed('roads', P.updateRoads) end
  P.watchRoadErrors(dtReal or dt)
  -- 20 Hz: tiles are prepared for the look-ahead boxes (ring.lookaheadTime ahead)
  P.ringT = (P.ringT or 0) - (dtReal or 0)
  if P.ringT <= 0 then
    P.ringT = 0.05
    P.timed('ring', P.updateRing)
  end
  P.timed('relax', P.relaxTiles, dt)
  P.updateMudBounds(dtReal)
  P.timed('tiles', P.rebuildTiles)
  P.timed('stream', P.streamTiles)
  if fm then P.timed('sectors', fm.update, dtReal or dt, camx, camy, P.vehCenters) end
  tclear(P.changedTiles)
  if wm then P.timed('clods', wm.update, dt) end
  local ph = P.mod('physics')
  if ph and P.liftOn then P.timed('floor', ph.update, dtReal or dt) end
  P.updateIdleReset(dt)
  P.updateFrozenOwn(dtReal or dt)
  P.updatePreload(dtReal or 0)
  if cfg.debug and cfg.debug.chunks then P.timed('debug', P.drawDebug, camx, camy) end
  if cfg.memory and (cfg.memory.gcStepKB or 0) > 0 then P.timed('gc', P.gcStep) end

  P.stats.lastFrameMs = frame:stop()
  P.stats.maxFrameAge = P.stats.maxFrameAge + (dtReal or 0)
  if P.stats.lastFrameMs > P.stats.maxFrameMs or P.stats.maxFrameAge > 5 then
    P.stats.maxFrameMs = P.stats.lastFrameMs
    P.stats.maxFrameAge = 0
  end
  P.samplePerf(dtReal)
end

function P.onPreRender(dtReal, dtSim)
  if not running then return end
  local wm = P.mod('wheelMud')
  if wm then wm.preRender(dtSim or 0) end
  -- screen-space overlay after the wheel frames are read
  local ov = P.mod('overlay')
  if ov and ov.frame then ov.frame() end
end

function P.onClientPostStartMission()
  P.loadConfig()
  if cfg.autoStart then P.startRequested = true end
end

function P.onClientEndMission()
  -- the level objects are already gone: drop state without touching the terrain
  P.startRequested = false
  P.stop(false)
end

function P.onVehicleSpawned(vid)
  if not running then return end
  P.configureVehicle(vid)
end

function P.onVehicleResetted(vid)
  if not running then return end
  P.configureVehicle(vid)
  local wm = P.mod('wheelMud')
  if wm then wm.onVehicleReset(vid) end
end

function P.onVehicleDestroyed(vid)
  P.vehs[vid] = nil
  local wm = P.mod('wheelMud')
  if wm then wm.onVehicleRemoved(vid) end
end

function P.onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
  P.loadConfig()
  if getMissionFilename and getMissionFilename() ~= '' and cfg.autoStart then P.startRequested = true end
end

function P.onExtensionUnloaded()
  P.stop(true)
end

-- GE Lua reload: the restore data cannot survive the VM, so restore now and start
-- again after the reload.
function P.onSerialize()
  local was = running
  if running or sinkApplied then P.stop(true) end
  return { restart = was }
end

function P.onDeserialized(data)
  if type(data) == 'table' and data.restart then P.startRequested = true end
end

-- never let the world editor see (and save) the lowered terrain
P.editorPaused = false
function P.onEditorActivated()
  if running then
    P.editorPaused = true
    P.stop(true)
  end
end

function P.onEditorDeactivated()
  if P.editorPaused then
    P.editorPaused = false
    P.startRequested = true
  end
end

M.onSerialize = P.onSerialize
M.onDeserialized = P.onDeserialized
M.onEditorActivated = P.onEditorActivated
M.onEditorDeactivated = P.onEditorDeactivated

M.onUpdate = P.onUpdate
M.onPreRender = P.onPreRender
M.onClientPostStartMission = P.onClientPostStartMission
M.onClientEndMission = P.onClientEndMission
M.onVehicleSpawned = P.onVehicleSpawned
M.onVehicleResetted = P.onVehicleResetted
M.onVehicleDestroyed = P.onVehicleDestroyed
M.onExtensionLoaded = P.onExtensionLoaded
M.onExtensionUnloaded = P.onExtensionUnloaded

-- private state for console debugging (deepnode_main.private.stats ...)
M.private = P

-- console helper: deepnode_main.gui.toggle()
M.gui = setmetatable({}, { __index = function(_, k)
  local g = extensions and extensions.deepnode_gui
  return g and g[k]
end })

return M
