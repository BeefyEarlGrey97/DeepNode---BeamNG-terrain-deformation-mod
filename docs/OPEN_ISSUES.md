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

## 12. Tyre coat colour and sand look

Tuned on puresands (sand) and gridmap_v2 (mud, wet) on 2026-10-28 with Percherons: sand in the
tread grooves, a clay coat for mud, a muddy water film. Not checked yet: johnson_valley mud (its
ground colour differs; mud `groundGain` 2 was tuned on gridmap_v2's dark mud); `treadInset` 10 mm is
one value for every tyre model (tread depth differs: on a shallow tyre the skin may hide under the
lugs, on a deep one sit too low). Sidewall dust is alpha-clipped specks, no soft haze (a translucent
dust layer like the water film would cost another material per wheel).
