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

## 2. Deepening lag under load

2026-10-31: deadline-first queue (`ring.inViewTarget` / `outViewTarget`, out-of-view deepening
deferred up to `outViewMaxDefer`): worst near rut lag 1.5-3.9 s -> 0.8-1.0 s with 4 trucks. Not
re-measured with 8 trucks.

Fresh rut fronts in view rebuild at 30–40 Hz outside the governor; ruts deepened by the axles
behind rebuild at `ring.deepenRebuildHz` (8) inside the upload budget and can wait up to ~4 s with
8 trucks. Letting in-view deepening bypass the budget dropped fps to 40–45 (reverted). Knobs:
`perf.uploadMsMin`, `ring.deepenRebuildHz`, `ring.digEvery`.

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
- Puddles: the water level is a noise field, not a real fill of the rut's lowest parts; ruts
  whose ground height was unknown when stamped get no water.
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
  more sheen than the engine's decal); the decal overlay adds ~0.65 ms of Lua per rut tile build
  under a road (gridmap_v2, 419 builds), bench impact not measured yet.

## 15. Grass blinks next to digging (heavy mode)

Every `tb:updateGrid` (the rut-floor terrain writes) makes the engine rebuild the GroundCover
cells over its box; the grass there is missing for one frame (ENGINE_FINDINGS "Terrain").
2026-10-31: the writes are clustered (`physics.heavy.floorCluster` / `grassReach` / `grassHold`)
and the GroundCover cells are cut to 10 m while the floor is written (`grass.cellSize`): a
write 13 m from grass no longer touches it (probe). Still open: grass within one cell (~10 m)
of a digging truck blinks at most once a second (`grassHold`), e.g. johnson_valley where the
grass layer itself is soft, or the gridmap_v2 material ramp (grass 6-8 m from the mud strip).
Not found: a terrain update for physics only (setHeightGrid / setHeightWs alone leave physics
stale). Not tried: delaying near-grass writes while those cells are in view.

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
