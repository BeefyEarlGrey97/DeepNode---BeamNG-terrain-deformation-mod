# Open issues

Each item lists what was measured and what has already been tried, so nobody repeats a dead end.
Engine facts behind them: [ENGINE_FINDINGS.md](ENGINE_FINDINGS.md).

## 1. Frame rate with 8 trucks (goal 70–80 fps)

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

## 2. Deepening lag under load

Fresh rut fronts in view rebuild at 30–40 Hz outside the governor; ruts deepened by the axles
behind rebuild at `ring.deepenRebuildHz` (8) inside the upload budget and can wait up to ~4 s with
8 trucks. Letting in-view deepening bypass the budget dropped fps to 40–45 (reverted). Knobs:
`perf.uploadMsMin`, `ring.deepenRebuildHz`, `ring.digEvery`.

## 3. ≥ 40 Hz rut updates for every visible wheel

Literal 40 Hz needs `digEvery 1` at < 80 fps; cost scales with uploads (see 1). Predictive
stamping (`stamp.leadTime -1`, adaptive 15–60 ms) keeps the front under the tyre at ~20–30 Hz.

## 4. Sand still fully meshed

Heavy `floorLift.sand = 0` lowers the terrain under sand, so sand keeps the old mesh everywhere
(no terrain-first decals, limited view distance through `sectors.loadRadius`). Setting it to 1
needs a deeper sand ground model (`defaultDepth`) to keep the same sinking.

## 5. Decals in vanilla physics mode

Terrain-first needs the heavy rut floor. Vanilla mode still copies decal roads into the mud meshes
as alpha-clipped materials (matte, dark fringes at `overlayAlphaRef 110`). Ideas: higher alphaRef,
keep the roughness map, premultiplied colour fix.

## 6. Dug areas lose the decal pattern

Dug cells use the terrain-matched mud material without the decal roads, so the look changes at the
rut edge. Untouched cells inside dug squares are already left to the terrain.

## 7. Tyre mud cost

~1.6 ms/frame with 8 trucks. Flushes and per-frame transforms are already limited to trucks in view.

## 8. Heavy physics speed

Percherons reach only 3–4 m/s in heavy mud (`groundModels.mud`), so a 45 km/h run through mud is
not possible with current values.

## 9. johnson_valley benchmark with current code

Not re-measured since the overhaul. See [BENCHMARK.md](BENCHMARK.md).

## 10. Report transport

Vehicle reports are Lua source strings (`queueGameEngineLua`) compiled in the GE, ~160 per second
with 8 trucks at 20 Hz. A compact numeric format would cut Lua time.

## 11. Texture licensing

`art/deepmud/t_tyre*` are baked from BeamNG's decal-road mud textures (`bake_tyremud.py`);
check redistribution terms before publishing a release.
