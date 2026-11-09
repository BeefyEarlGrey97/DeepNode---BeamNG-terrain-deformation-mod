# Open issues

Each item lists what was measured and what has already been tried, so nobody repeats a dead end.
Engine facts behind them: [ENGINE_FINDINGS.md](ENGINE_FINDINGS.md).

## 1. Frame rate with 8 trucks (goal 70–80 fps)

Vanilla physics, user GUI settings (2026-10-28): 40.7–41.9 fps fresh mud vs 60 (capped) with the
mod off. Remaining split per frame: GE Lua +4.0–4.6 ms (createMesh ~1.5, reports ~1.1, stamping),
`RenderShadows` +3 ms, `RenderReflections` +1.2–2.3 ms, `PreRender` +0.5 ms. The engine cost follows
the number of uploads; ProceduralMesh shares its type bits with TSStatic (see ENGINE_FINDINGS), so
the mud cannot be masked out of the shadow casters by type.

Now 50–56 fps vs 77–84 fps with the mod off (gridmap_v2, heavy physics). Split at the end of the
last session (repeat runs, 19.2 ms vs 12.8 ms per frame):
- idle mod (no digging): ~1.8 ms — Lua ~0.8 ms, mud objects in shadow/reflection passes
- tyre mud: ~1.6 ms — mostly engine shadow pass (materials already `castShadows 0`)
- rut pipeline (reports, stamping, tile uploads and their engine cost): ~2.9 ms

The dominant engine cost: every frame that first draws a freshly re-uploaded `ProceduralMesh`
costs ~1 ms in `RenderShadows` (+0.2 ms reflections), whatever the mesh size. Tried without
effect: `collisionType None`, `hideInRenderView(63)`, local-light shadows off, delaying the show,
moving the object, rotating objects. Ideas: fewer/smaller dirty regions per visible dig, fewer
frozen tile objects, cheaper reports.

Measured 2026-10-28 (orbit camera on truck 1, vanilla, 8 trucks, 3 runs): tile uploads 870 per
run at 1.16-1.21 ms each (createMesh), sector uploads 85 per run at 1.8-1.9 ms, tyre material
flushes 200 per run at 0.83 ms (engine material re-init; already confined to upload frames by
the shared budget). Every mod material has `castShadows 0`; the extra `RenderShadows` time
(+3-4 ms) follows the uploads. Tried without effect: finer tile size classes (12: -20 %
padding, -2 % createMesh time, twice the memory growth), deferring colour-only tyre flushes
(colour already rides along with coverage steps: same flush count).

Measured 2026-10-31 (research tests, `tools/benchmark/ge_extensions/dntestEng.lua`, see
ENGINE_FINDINGS): the shadow-pass cost is paid per `createMesh` call (also re-uploads into the same
object, also with `collisionType 'None'`, no shader generation) and grows almost linearly with
uploads per frame (~0.5-0.6 ms each): fewer uploads is the only Lua-side lever; batching is not.
`lastSplitCastersEnabled` off: no change. Upload depth histogram (4 trucks, 5687 tile uploads):
largest rut depth 12-20 cm in 83 %, < 5 cm in 6 % (a depth ladder by rut depth saves little
with heavy trucks); largest change < 1 cm in 7.6 %, < 3 cm in 14 % (`ring.minVisibleChange`
now skips the sub-6 mm ones). The remaining fix is engine side: an in-place ProceduralMesh update.

2026-11-04 (8 trucks, user settings, heavy): ~51-55 fps vs 88.8 mod off. Holding uploads under a
truck body for 3 s gives 64-66 fps but ruts then lag under the wheels in a side view: rejected
(BENCHMARK.md section 10). Idea: a camera-aware occlusion test for P.dirtyHidden.

## 2. Deepening lag under load

2026-10-31: deadline-first queue (`ring.inViewTarget` / `outViewTarget`, out-of-view deepening
deferred up to `outViewMaxDefer`): worst near rut lag 1.5-3.9 s -> 0.8-1.0 s with 4 trucks. Not
re-measured with 8 trucks.

2026-11-07 (8 trucks, gridmap_v2): in-view deepening (axles behind) waited 0.60 s on average
behind the fresh fronts in the shared budget. `ring.deepenFast` (default on) gives it the fresh-front
fast path: in-view lag fresh 0.000 s / deepening 0.003 s per upload, near lag 0.157-0.174 s (was
0.205), same fps (54-55 vs 53.4, interleaved). The earlier attempt that cost 40-45 fps ran without
'pair' mode and the body wait. What is left in the near-lag figure is out-of-view tiles
(`outViewMaxDefer` 1 s) and tiles still under a slow truck body (`bodyMaxWait`). Not measured: the
time from a carve to its terrain floor write on screen (`physics.heavy.floorHz`, now 20).

Fresh front under the body: `ring.bodyFreshHz` 20 / `bodyFreshDist` 20 m (2026-11-07) shows
the rut right behind the front wheel (front lag 0.075 s) at -6 fps with 8 trucks; trucks farther
than 20 m from the camera still hold until mid truck. Cheaper per-upload cost would let the
distance grow (see 1).

Idle: 8 parked Percherons on the pits still made ~27 tile uploads per second (2026-11-07), not
looked at.

## 3. ≥ 40 Hz rut updates for every visible wheel

Literal 40 Hz needs `digEvery 1` at < 80 fps; cost scales with uploads (see 1). Predictive
stamping (`stamp.leadTime -1`, adaptive 15–60 ms) keeps the front under the tyre at ~20–30 Hz.

## 4. Sand still fully meshed (fixed 2026-10-31, heavy mode)

Heavy `floorLift.sand` is now 1 (config.json; code default 0.3): undug sand is the terrain, as
for mud. Measured on gridmap_v2 (4 Percherons, full throttle): sand trucks reach 30 / 60 / 90 m
at 5.9 / 9.1 / 11.8 s with and without it, so no deeper sand ground model was needed (the floor
follows the dug ruts). Same fps (77.2 vs 77.15, 2 x 4 runs), engine memory per 4 runs
15.9 -> 4.9 MB. Vanilla physics mode still meshes all sand.

## 5. Vanilla physics mode: decals and memory

v0.1.0 benchmark: vanilla mode grows memory 132–253 MB/min with 8 trucks (heavy 25–63 MB/min) because every
soft square is meshed and rebuilt.

Terrain-first needs the heavy rut floor. Vanilla mode can copy decal roads into the mud meshes
(overlay, now "Experimental" and off by default) as alpha-clipped materials (matte, dark fringes at
`overlayAlphaRef 110`). Measured 2026-10-29 (gridmap_v2): the clip drops the soft translucent parts
of the furrow / tiretrack decals, so vanilla mud with the overlay looks duller than the engine
decals on the heavy-mode terrain; on sand the dirt-variation decals look about the same at alphaRef
110, 40 and 10. Ideas: keep the roughness map, premultiplied colour fix, a dithered alpha texture.
Debug pitfall: recolouring the overlay materials (alphaTest off, maps removed) only shows on meshes
uploaded afterwards.

## 6. Dug areas lose the decal pattern

Dug cells use the terrain-matched mud material without the decal roads, so the look changes at the
rut edge. Untouched cells inside dug squares are already left to the terrain.

## 7. Tyre mud cost

~1.6 ms/frame with 8 trucks. Flushes and per-frame transforms are already limited to trucks in view.
Measured 2026-10-28 (gridmap_v2, 8 trucks, interleaved 8 + 8 runs): drawing the 64 skins costs
~0.8 ms (45.6 fps shown vs 47.4 hidden, Lua unchanged); the water film layer adds nothing
measurable (46.1 vs 45.9 fps without / with it); Lua (coat, flushes at 0.83 ms each,
transforms) ~1 ms. Fewer skin segments would cut the draw cost but show on close-ups.

## 8. Heavy physics speed

Percherons reach only 3–4 m/s in heavy mud (`groundModels.mud`), so a 45 km/h run through mud is
not possible with current values.

## 9. johnson_valley benchmark with current code

Not re-measured since the overhaul. See [BENCHMARK.md](BENCHMARK.md).

## 10. Report transport (measured: not a cost)

Vehicle reports are Lua source strings (`queueGameEngineLua`) compiled in the GE, ~160 per second
with 8 trucks at 20 Hz. Measured 2026-10-28: compiling and running a 1 KB report chunk takes
16 us, ~0.06 ms per frame in total. A binary format is not worth it.

## 11. Texture licensing

The tyre textures are procedural now (`bake_tyremud.py`, `bake_tyresand.py`, `bake_tyrefilm.py`,
no game asset read). `clods.texDir`/`texBase` still name BeamNG's decal-road mud set as the
fallback normal map of a kind without its own `texN` (none in the shipped config).

## 13. Research follow-ups not done yet (2026-10-31)

From the terrain-deformation techniques review (IDs as in that review):
- T7 / PHYS-7 (rut terrain material through the layer map, `setMaterialIdxWs` +
  `updateGridMaterials`): not tried (device-loss risk named in the review, two engine crashes from
  terrain experiments already in ENGINE_FINDINGS).
- T14 / VIS-2 / VIS-6 (engine `DecalMgr` tread decals): one try showed no decal at all (see
  ENGINE_FINDINGS); needs the right template / flags first.
- T3, T5 (graphics API comparison), T8, T9 (D3D12 soak), PHYS-1 (calibrating `dragAnisotropy` /
  `flowBehaviorIndex` against resistance targets; sinkage is inside the 10-30 cm target: mud ruts
  0.15-0.18 m, sand 0.15 m), MEM-3 (rut persistence: conflicts with `reset.idleSeconds`), VIS-4 /
  VIS-5 (bow wave, standing water).
- Done or settled 2026-10-31: T1/T2/T4/T6/T17 (upload cost, ENGINE_FINDINGS), T10 (updateGrid
  span: no box split needed), T11 + MEM-2, T13 + `minVisibleChange`, T16 + PHYS-2, T18 (no LOD via
  the outer table), PERF-2 (jit.v), PERF-4, PHYS-3/4/5/6. Dropped: VIS-1 (dynamic decals paint the
  tyres), PERF-6 (span does not matter), PERF-7 (no effect). PERF-8: draft in ENGINE_REQUEST.md.
- Soil memory values (`stamp.kinds.*.soilN/soften/slipBeta`) are literature starting points, not
  tuned against driving tests; with Percherons the sand ruts reach the 0.15 m floor by pass 2.

## 12. Tyre coat colour and sand look

Tuned on puresands (sand) and gridmap_v2 (mud, wet) on 2026-10-28 with Percherons: sand in the
tread grooves, a clay coat for mud, a muddy water film. Not checked yet: johnson_valley mud (its
ground colour differs; mud `groundGain` 2 was tuned on gridmap_v2's dark mud); `treadInset` 10 mm is
one value for every tyre model (tread depth differs: on a shallow tyre the skin may hide under the
lugs, on a deep one sit too low). Sidewall dust is alpha-clipped specks, no soft haze (a translucent
dust layer like the water film would cost another material per wheel).

## 14. Screen-space ground look (overlay, experimental, 2026-10-31)

`overlay` / GUI "Experimental tread prints", off by default. After MudRunner / SnowRunner
(Zagrebelnyy, "Mud and Water of Spintires: MudRunner": GPU-painted rut texture, wheel track
pass over the depth buffer, z-projected mud / wet decals, water pooling). Built and checked on
gridmap_v2 with 6 Percherons: universal print relief (no tread pattern), wet churned mud,
crumbs on the berms, puddles in deep mud ruts (none under vehicles), mud splats from spinning
wheels, carried mud / sand dust on hard ground, grass / dirt tracks, wet tracks that dry,
dry-soil look for dusty desert layers, wet glossy tyres. Cost: 6 trucks, about 0.5-1 fps
(~0.3-0.5 ms) in interleaved sets; 0 of 105 000 prints dropped (segment merging).
Not done yet:
- GPU cost not measured exactly (GPU timer not readable); the A/B fps difference is near the
  session drift.
- Wet sky sheen uses the sampled sky colour, so under an overcast or dark sky it follows that; with
  no sky on screen (looking down) it falls back to an estimate.
- Puddles: since 2026-11-01 the water fills the closed hollows of the ruts (`puddleMode`
  'fill', flood fill per quiet tile). Open: water only shows on texels that hold a mud print
  (body dents and slumped cells without a print stay dry); the flood window is the tile and one
  tile around it, so a hollow longer than that drains at the window edge; the level is fixed per
  pool (no rain / evaporation); not checked on johnson_valley.
- Night / rain not checked (gridmap_v2's sky ignores the time of day). johnson_valley only
  checked briefly (dusty dirt prints are subtle).
- Grass tracks hide under the grass blades (groundcover); the groundcover itself is not bent.
- Multi-axle trucks overwrite each other's print phase; the streaks can step where two meet.
- Prints further than 64 m from the camera are dropped (map window 128 m); the idle reset
  (120 s) erases prints with the ruts.
- Tyre pass: rubber albedo is a guess (`tyreAlbedo`); `tyreCoat` (shader coat, the way to drop
  the tyre mud meshes) is untuned.
- Road look (`overlay.roads`): replaced 2026-10-31 (late) by decal copies in the mud mesh
  (`roads.mode` 'overlay', `overlayOriginal`, `overlayOnRuts`): the screen-space redraw looked
  nothing like the engine's decals and masked vehicles with boxes. Only used now with
  `roads.mode` 'off'. Open for the mesh copies: `startEndFade` is approximated by narrowing the
  strip (no vertex alpha in ProceduralMesh); copies are lit forward (on glossy ground slightly
  more sheen than the engine's decal). 2026-11-01: rebuilt as `deepnode_roadCopy` (`roads.mode`
  'copy'): copies on every build, coarse quads on planar squares; ~5 fps against no roads on
  the mud with 8 trucks (BENCHMARK §6). 2026-11-02 (BENCHMARK §8): with one truck the copies
  cost ~0.55 ms (uploads, translucent forward drawing, emission); planar rectangles cut the copy
  corners 23-37 %. Ideas not done: copies in their own objects rebuilt at a lower rate (saves
  uploads, costs ~2 us of shadow pass per extra object), fewer copy draws by sector. The bigger
  on / off difference is the level's own stacked decal roads (vanilla cost). Research notes (engine routes that do not exist):
  ENGINE_FINDINGS "Decal roads". After the 8-truck bench the deep, wide rut bands
  in the gridmap_v2 mud pit showed the water layer but few furrow clumps: not checked whether
  the furrow strips cover those cells or copies are missing there. Faint lines along some tile
  edges were seen before the border-drop fix; not re-checked after it.
  2026-11-05: copies drawn into the ruts painted them with the road pattern, so a digging truck
  left no visible trail (user: "still lays over the ruts"); `roads.copyCut` 0.03 leaves copy
  quads out where the mud is dug deeper than 3 cm (the rut shows mud + ground look, berms keep
  the road). Still open, seen top-down behind one Percheron (x -325..-320, y -345): the flat,
  undug squares of the meshed band beside the ruts show plain mud, no copy, even with
  `copyLift` 0.06 (copies emitted for the tile: 512 vertices; the copies that do show in the
  band look paler than the engine decals beside them). Hiding the tile mesh shows the engine
  decal there. Not found yet whether those quads are rejected (u / d map) or hidden. Draw
  order (`copyHighOnTop` test: low or high renderPriority on top) changed nothing visible.
  Custom-shader routes for the road look on the mud: a CustomMaterial on a ProceduralMesh gets
  no cbuffers / textures (crash, ENGINE_FINDINGS "Custom shaders"), a post effect has no albedo
  buffer (screen-space redraw tried 2026-10-31, rejected): the copies stay the route.

## 15. Grass blinks next to digging (heavy mode)

Every `tb:updateGrid` (the rut-floor terrain writes) makes the engine rebuild the GroundCover
cells over its box; the grass there is missing for one frame (ENGINE_FINDINGS "Terrain").
2026-10-31: the writes are clustered (`physics.heavy.floorCluster` / `grassReach` / `grassHold`)
and the GroundCover cells are cut to 10 m while the floor is written (`grass.cellSize`): a
write 13 m from grass no longer touches it (probe). Still open: grass within one cell (~10 m)
of a digging truck blinks at most once a second (`grassHold`), e.g. johnson_valley where the
grass layer itself is soft, or the gridmap_v2 material ramp (grass 6-8 m from the mud strip).
2026-11-02: found the physics-only update after all: `updateGrid` with a far dummy box refreshes
physics everywhere and drops no grass. `physics.heavy.grassSplit` writes near-grass floor at once
(physics) and redraws its terrain when the grass cells are out of view or after `grassHold`
(REFERENCE "Heavy physics option"): visible blinks about halved, no physics delay near grass.
Still open: with a chase camera the grass beside the truck is nearly always in view, so it still
blinks about once per `grassHold` while digging next to it; the redraw is what drops the cells
(no redraw-only call found). Ideas: exact GroundCover cell bounds instead of the padded box,
flushing while the camera turns fast, a longer hold now that physics no longer waits.
2026-11-05: `grassLowDraw` (REFERENCE) removes the redraws near grass: the terrain there is drawn
at the full sink level from the start and only physics follows the floor. Left: the zone's
squares are drawn by sectors only within `sectors.loadRadius` of the camera / vehicles (beyond,
the lowered terrain shows; looked fine from 112 m on gridmap_v2, not checked on johnson_valley
where the grass layer itself is soft and the zone is large); a foreign full-terrain `updateGrid`
(editor, other mods) would draw the zone at physics height (the terrain then hides the ruts
there until Restart).
2026-11-05 (late): region mode draws the zone low too (hw550 still blinked: the zone was skipped
there and the slow-terrain path redraws every write). hw550 test: 17 -> 0 real redraws near the
camera in 40 s of digging beside grass. Left: a region shift's own terrain update (restored and
newly sunk vertices at the region edge, 250+ m away) still drops the cells it touches once;
hw550's tree GroundCover cells are 300 m wide (r 1500, gridSize 10, over `grass.maxRadius`), so
a real redraw anywhere near trees drops a big block of trees for a frame.

## 18. Big terrains (hw550, 2026-11-01)

Fixed: groundcover cell shrink limited to small covers (trees / grass back, shadows 20 -> 0.8 ms).
Open: each rut-floor terrain update costs 15-78 ms on an 8192 x 8192 terrain (engine, any box
size); now at most one every 2 s while digging (a hitch each time), and the rut shows up to 2 s
later. Vanilla physics mode writes no terrain while driving (no hitches). Covers larger than
`grass.maxRadius` keep their level cells, so a floor write near them blinks a bigger cell.

## 19. Region mode on big maps (2026-11-03)

Region mode (`region`, REFERENCE) keeps start and memory bounded on maps of any size; tested on
gridmap_v2 forced to regions of 300 m and 1 km (shift switch frame 4-13 ms, load 8-14 ms over 3-4
frames, exact terrain restore) and on hw550 (8192 x 8192, auto: switch 4-12 ms, load 9-15 ms over
3-4 frames, no rut writes in those shifts). Not tested on a real BeamNG.earth map yet. Known limits:
- Ruts outside the stable overlap are dropped at a shift (they are >= size / 2 - shiftAt from
  the player); AI vehicles outside the region leave no ruts.
- `roads.mode` 'drape': roads stay draped as at start (a collision reload per shift is ~370 ms).
- Lifted grass copies (vanilla physics) lift soft-layer grass outside the region too; GroundCover
  draws only near the camera, so mostly beyond view.
- The switch frame walks the whole region (1M vertices per km2 on a 1 m grid); each vertex that
  enters needs a getHeightGrid. With a terrain update (vanilla mode, or rutted vertices
  restored) one `updateGrid`, which costs 15-78 ms on 8192 x 8192 terrains (§18).
- Coarse terrains (squares over `region.maxSquare`, huge_desert 64 m) run on a 1 m virtual grid
  (fixed 2026-11-03, was a hang). Left: the terrain is lowered per real vertex, so within one
  square (64 m) of hard ground, roads or the region border it stays up and ruts there are hidden
  under it; no rut floor (vehicles sink by the lowering, not into the ruts); the lowering between
  real vertices is taken bilinear while the terrain draws triangles (a few cm off in border
  squares); lifted grass copies float where the terrain is not lowered; the height grid rounds
  writes to ~9 cm on huge_desert (the lowering read back is used, so it can be 0.11-0.29 m).
- Zones count inside the region only.

## 20. Mud material beyond ~80 m (huge_desert, 2026-11-03)

Near tiles match the terrain. Sector meshes 80-150 m out still read a little lighter: the
terrain fades its macro/detail maps (and their roughness) by distance (`macroDistances`,
`detailDistances`, `*DistAtten`), an object material cannot. Roughness is the lever (roughness
1.0 turned the patch darker than the terrain, the map lighter). Idea: a second, far material
with the far-distance strengths for sectors.

## 17. Review items left open (2026-11-01)

From an outside play test (gridmap_v2): what was done is in CHANGELOG [Unreleased]. Left:
- Crossing ruts (dip, rise, dip): the terrain grid is coarser than the ridge between a truck's
  rut lines (measured, REFERENCE "Heavy physics option"); `floorReach` 0.3 kept.
- A ~5 cm settle into the engine soft layer when a vehicle stops (ground model, not the floor).
- Torque dig: Moonhawk launch shows the driven rear squatting, but no clean A/B against
  `torqueDigRate` 0 yet (the second launch started in an old rut and bogged); Percheron ruts reach
  the hard floor either way (-17.8 vs -18.0 cm mean).
- Mud mesh squares next to the ruts and material seams: the mud material already uses the
  terrain's world-space top-down UV; the visible edges come from per-square layer materials (no
  layer blend) and missing decal patterns (6). Smaller tiles cost more uploads (1).
- Tyre mud flicker reported; not looked at (the tester's weather mod will own tyre / body dirt).

## 16. Rut lags behind trucks in sand / mud at speed (heavy mode, 8 trucks) - open, 2026-10-31

User report: ruts lag behind trucks on sand; requirement: the rut keeps up with the first front wheel
at 40 km/h with >= 48 fps (8 Percherons). Findings:
- Heavy mode is terrain-first for mud and sand (config `floorLift` 1.0): a fresh rut mesh lies below
  the undug terrain surface and only shows once the rut-floor terrain write lowers the terrain there.
  With 8 trucks those writes were starved (upload budget 'F', 5 Hz collect; ~130 terrain updates per
  5 runs) and near grass (pits are 8-9 m from grass) also held 1 s, and near-grass clusters only went
  out in frames without grass-free work.
- `bodyMaxWait` 1.5 (main 6e7fd28) also holds the fresh front, since the front axle lies inside the
  vehicle box (front-latency readout 0.10 -> 0.30 s).
- Attempt (not merged, diff in docs/attempts/2026-10-31-rut-front-fast-floor.diff): fresh fronts
  (t.digNow) skip the body / small-change waits; hot tiles (stamped < 0.4 s ago) get their floor
  collected and written at floorFastHz outside the budget, grassHoldHot 0.12 s, near-grass / free
  clusters take turns; stamp leadMax 0.12 / leadExtra 0.05-0.08. Result: rut lag near 0.03 s, front
  0.03-0.06 s (was 0.29 / 0.30), ruts visibly up to the wheels, but 37-38 fps (main 52.3) and
  uploads 13-15k per 5 runs (3.9k); with the fast floor off (hotAge 0) still 38 fps / 14.9k uploads,
  so the upload count comes from the fresh-front exemption (and maybe the bigger stamp lead), not the
  terrain writes. Trucks also bog more (avg end speed ~1 m/s in some runs) once the floor keeps up.
- 2-truck 40 km/h sand pass (`fast_setup` / `fast_run` recipe: Percherons at y -140 north of the pits
  heading south, dntestRun speed 11.1, dist 215): front axles press ~5 cm, the rear tandem ~12 cm; the
  mesh rebuilds every frame there and the floor follows the carve within ~0.1 s.
Next: find why the exemption multiplies uploads (fresh fronts at tileRebuildHz 40 from the user GUI?
cap fresh uploads per tile, e.g. 15-20 Hz, and keep the hold for the axles behind), then re-add the
fast floor for hot clusters only.

## 24. Baked decal road layer (removed 2026-11-07)

Removed before release (load-time bake up to 2 min, 28 MB cooked DDS per region, VRAM). The code
is in git history (last at commit 2012f07). Old images: delete
`<user folder>/deepnode_cache/roadbake/` and `temp/deepnode_cache/roadbake/` with the game closed.

## 23. Decal road copies over ruts (2026-11-06)

Copies drape over ruts and berms and fade by disturbance (`roads.copyFade`); depth writes off,
bottom layer first. Left: where a faded rut quad borders plain terrain (engine decal), the band
edge still follows the 1 m terrain squares; the mud mesh base is ~2 % darker than the terrain
in the gridmap_v2 pit (measured 159.7 vs 163.4 mean level); fade levels multiply copy
submeshes (up to 6 per road material per mesh): 8-truck bench -10 fps, shadows +4.5 ms (BENCHMARK 15); the
fullsuv circle harness (dntestCircles R 9) loses the car after a place().
2026-11-06 8-truck findings (BENCHMARK 16): every extra copy submesh costs shadow and reflection
pass time even with castShadows 0 (fade levels -4.5 / -10 fps); `hideInRenderView(63)` does not
help. After the 8-truck runs the fully meshed pit looks washed out pale (copy stack water, water,
mud_large drawn as if water were on top). Suspect: `mud_large` has `alphaTest` 1, so its copy may
render in an earlier bin than the other translucent copies; alphaTest 1 on every clone fixed the
centre but not all stripes (unfinished). Fade default must change (cost) once the stack is right.

## 26. Road shader (`roads.mode` 'shader', 2026-11-08, first version)

Replaces the copies in the GUI (OPEN_ISSUES 14 / 23 hold their history). Measured on gridmap_v2
(static pit view, 1 parked truck, RTX 5070, uncapped): off 189.9 fps, shader 162.3 (+0.89 ms),
vanilla decals 149.3 (+1.43 ms), copies 146.3 (+1.57 ms, before any digging; copies add uploads
and submeshes per dug tile, the shader costs the same dug or not). Lua +0.07 ms.
Open:
- 2026-11-08 later: opacity / AO maps fixed (were flat); the numbers in the next item are from
  before that fix. Full stack now mean 147.5 vs 143.3, spread 37.9 vs 39.4.
- Look against the engine (pre-rut off, one material at a time, mean 8-bit level change vs no
  road): mud_furrows +1.9 vs -0.8 (match), mud_water +12.6 vs +16.7, mud_large -26 vs -12 (too
  dark; -17 without the relight pass, so both the colour and the relight overshoot). The engine's
  full stack shows crisp holes in the mud layers where the cream water shows through; the shader
  draws the layers softer. Not found why (alphaTest clips at opacity - alphaRef, ref 0 there).
- `relief` 0.5 from one contrast measurement (mud_large spread: 1.0 = 26.6, engine 22.4, none 21.1).
- Light triangular wedges seen in the full stack (top of the pit view), not explained; not layer
  overflow (same with `layers` 8).
- Road ends clip at the map texels (37.5 cm) where a road has no `startEndFade`.
- 8 layers at 512 texels (fix for missing layers and the vehicle box, same day): look checked on one
  frame with a sunk SUV, GPU cost not re-measured (the stamp pass reads 16 texels a texel; the
  draw passes stop at the first empty entry).
- Not in the GPU-bound 8-truck bench yet; GPU cost measured by utilisation only.
- 2026-11-08b: vehicle mask = tyre cylinders (24 tyres within 100 m, from their hub nodes) +
  down-facing faces dropped; no footprint box (it cut the road in rectangles). Road height
  across a road is linear between its edges: a wide road over a ridge or a hollow (not a plane)
  can still be off by more than `zAbove` (0.4 m) in its middle; debug view `overlay.roads.debug`
  6 shows the height over the road (red < -0.5, yellow, green, blue +-0.1, white above). Not
  covered: upward-facing body parts within `zAbove` of the road height (running boards, a
  deeply sunk body), more than 24 tyres near the camera. Road map now 32-bit float
  (2 x 64 MB at 512 x 8 layers): GPU cost not re-measured; johnson_valley not re-checked in game.
- Sky reflection of metallic roads uses the SH9 sky, roughness factor only (no roughness map:
  no texture slot left); no sun specular.
- Engine decal reference with pre-rutted roads on is impossible in the pit (the engine decals
  lie under the pre-rut meshes).

## 25. Liquid mud (2026-11-08, first version)

`stamp.liquid` (CHANGELOG Unreleased). Open:
- It never ran before 2026-11-08 (scope bug: liqStep threw every frame). Benchmarked since
  (BENCHMARK 19): first -13 fps with 4 trucks, now ~1-2 fps after the write/rebuild fixes.
  Not done: run windows only near the camera / in view (the flow out of view is unseen).
- 8-truck bench run 2026-11-08 (BENCHMARK 20): liquid ~0.4-0.66 ms/frame with yield 0.6.
- yield 0.15 (first version) halved the ruts (rut 12-15 cm, berms 3-5 cm vs 20-24 / 10-16 cm
  without flow); 0.6 keeps 17-19 / 6-12 cm. User found 0.15 "too soft, loses the rut structure".
- One window per vehicle; two vehicles side by side in the same mud simulate their overlap twice.
- Tyre obstacles come from the 20 Hz reports (no lead): mud can run into the space ahead of a
  fast tyre for one report.
- The liquid state lives only on active tiles; it stops when a tile freezes.
- The colour / wetness of the SnowRunner reference (dark glossy mud, water in the ruts) is not
  done: the mud mesh keeps the terrain material.

## 22. Pre-rutted decal roads (2026-11-04, first version)

2026-11-08: procedural ruts (no road material); the "lighter rectangle beside a driving truck"
was the own-mesh plain-square merge (fixed, see CHANGELOG).

2026-11-05: deeper (mud 0.3 m), wider grooves, dark wet wheel lines + pools through the overlay.
Open: ~4.5 fps with 2 trucks (Lua +0.35 ms: print feeding, pools; shadows +0.3 ms: full-res
pinned tiles); commit growth looked higher (+53 vs +8 MB/min, one 2-run set each); prints only
on tiles that exist (pinned); lumpy decals (mud_large) get no wheel lines; groove lines follow
the across-road profile mean, so a groove that wanders across its texture can sit up to ~0.2 m
beside its print.

`roads.preRut` turns the soft decal roads into ruts at start (see CHANGELOG). Open:
- gridmap_v2 mud pit: the stacked mud_large / mud_water decals give a lumpy field; the converging
  furrows of the decals read only faintly. Ideas: per-material depth (furrows deeper), keep the
  decal copies on top (`roads.mode 'copy'`) for the dark wet colour.
- One long straight crease along the mud pit and a lighter rectangle beside a driving truck
  (seen once, not identified: tile / sector border or flush square edge).
- Cost: ~0.35-0.65 ms per frame in the pit overview (frozen tile data drawn at full resolution
  in the sectors). Not measured with 8 trucks.
- 8 trucks (BENCHMARK 12): mod Lua +0.7 ms, low1 -2 with the new features; not split per feature.
  Candidate: sector rebuilds over pinned full-resolution tiles (`sectors.frozenCellStride` for
  untouched pinned tiles?).
- Region mode and coarse terrains skip it. Roads hidden after start (mode 'off') keep their
  ruts; a road with startEndFade is faded by `preEndFade` only.

## 21. Snow and the material tick list (2026-11-04)
- Snow kind values are first guesses (stamp.kinds.snow, clods.kinds.snow, overlay uses the
  sand look): tune on polish_roads_winter with a Percheron at speed; the snow tyre coat has not
  been looked at close up yet.
- automation_test_track snow: 0.28 km2 in 6535 patches, only 59 % of snow vertices interior
  (mud 95 %): about 41 % of its snow gets depth 0 at the layer edges. A minimum patch size or
  softer edge rule may help; not done.
- Tick list: a tick toggled back to its default before Restart still shows "changes apply on
  Restart". Row areas (km2) shown in the design preview are not drawn yet.
- polish_roads_winter is 3.8 km2 of SNOW_DEEP: region mode; fps with several trucks not measured.

## 27. SnowRunner look: tyre layer, berms, frame limiter (2026-11-08)

- Tyre layer (`clods.tyreLayer`): one material per tyre name, so every vehicle with that tyre
  shows the muddiest one (vehicle materials cannot be instanced, see 5b). Masks assume the
  common strip UV layout (U around, V across); tyres with other layouts get blotches in odd
  places. A reload costs ~8.6 ms with 4 trucks sharing it (~20 per bench run): rare spikes.
  Colour still from the ground pipeline; not compared side by side with the terrain yet.
- Berms / bow wave: tuned on gridmap_v2 mud only; sand and snow values are first guesses.
  The bow wave is a shape (not volume): the tyre carves it into the side berms as it rolls.
- Frame limiter: a cap pads short frames and cannot shorten long ones; uploads (~1 ms each +
  engine draw cost) and dig bursts make frames uneven. digMaxPerFrame 6 helped low1; a
  limiter-aware budget did not (dropped). Next lever: fewer uploads per visible change
  (user GUI tileRebuildHz 60 / maxMeshBuildsPerSec 400 are far above the defaults 5 / 33).
- Overlay engine light: checked at one sun angle on gridmap_v2 only (looks as before, relief a
  bit crisper); wet glint / sheen against the sun not checked yet.
- Region mode on big maps (> 8 x 8 km) now keeps decal roads on (map limit removed): not tested
  on a big map.

## 28. Firm mud: bearing ruts, debounced terrain physics (2026-11-08, test e1362a0..)

Engine: the vehicle physics takes `tb:updateGrid` changes only ~0.55 s after the LAST call
(ENGINE_FINDINGS). The heavy rut floor written at 16-20 Hz never reached moving wheels; it all
landed when the trucks stopped ("sinks to the bed"). Now: `physics.heavy.floorGap` 0.6 s,
floor writes outside the upload budget, `lowDrawAll` (floor = drawn rut + soft layer, terrain
drawn low), `stamp.bearing` (Bekker rigid-wheel depth). Open:
- The floor reaches the physics 0.55-1.2 s after the stamp: the rear axles of the same truck
  ride the soft layer, not the front axle's rut floor; only ruts older than ~1 s are walls.
  A predictive floor (lowered ahead of the wheels, lead 0.4 / 0.8 s) did not help under the
  debounce (removed).
- While driving the tyre sits 5-10 cm below the drawn rut surface at the hub (soft layer 0.2 m vs
  drawn rut ~0.12-0.15 m right under the tyre; deeper after the following axles).
- `lowDrawAll` (all soft ground drawn low) looked wrong on johnson_valley (mesh dunes lighter, no
  ripples, hard road edges): replaced by `lowDrawRuts` (only dug squares drawn low, once; not
  undone when ruts reset, those squares stay meshed until a restart). Checked on johnson_valley
  sand (look + parked SUV -8 mm in 4 s); gridmap_v2 one-truck sink numbers not re-run with it.
- Bekker kc / kphi are game-soft values fitted to one Percheron (6x6 and 8x8 configs); light
  cars, wide tyres and snow not checked. Drive torque / spin dig on top: full throttle from
  standstill dug the front wheels to 0.25-0.27 m (cruise 0.20-0.21).
- Multi-pass: flowBack 0.12 leaves 12 % per pass, so every following axle carves a little (the
  slump pass cannot be skipped for them, BENCHMARK 20).
- Tyre-layer reloads now wait (<= 1 s) for a frame of their own: the coat steps show up to 1 s
  later with many trucks.
- Perf at 8 trucks (BENCHMARK 20): mod Lua ~8.8 ms (tile rebuild + upload 2.3-2.9, wheel reports
  1.5, liquid 0.4, tyre layers 0.3-0.45, overlay 0.35) and ~6 ms of extra render while driving,
  which is the engine's first-draw cost of fresh meshes (static, the mud meshes, overlay and tyre
  layer cost ~0). Since `lowDrawAll` every soft cell is meshed (avg 2300 face corners per tile
  upload). Next lever, not done: merge flat 2x2 / 4x4 cell blocks in `emitTileCells` (corners
  dominate createMesh), keeping size classes, road-copy quads and decals intact.

## 29. Deeper ruts, tyre sectors (2026-11-09, test)
- Ural-4320 (uralivannq mod) on gridmap_v2 only. Not benched with 8 trucks: the sectored skin
  costs 8 materials per wheel (48 per 6x6) and up to one flush per frame while coats change,
  plus 8 draw calls per wheel. Bench before merging to main.
- Sand / snow / water sectors untested in game (same code path as mud).
- Mod tyres whose UVs are not the common strip layout (Ural: one disc atlas, lugs in a corner)
  get the tyre-layer masks in the wrong places; the sectored skin (own UVs) carries the look.
  The clean Ural tyre itself is a flat 256 px texture (asset, not the mod).
- treadInset 0.07 suits big-lug truck tyres; a road tyre may show the cake sunk into it.

