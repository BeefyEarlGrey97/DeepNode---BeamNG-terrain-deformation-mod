# Benchmarks

Both benchmarks use **8 Percheron** trucks, config `vehicles/percheron/s450_8x8_flatbed_A.pc`.
Report fps mean and low 1 %, rut latency and memory growth, and compare against the mod switched
off in the same session (absolute fps drifts by several fps over a long session).

**Runs per test (2026-11-05):** every variant runs twice (`bench2.py <label> 2 clear`); compare
run 2 and interleave variants (A, B, A). Quick A/B: the stripped 2-Percheron bench (section 13).

## Common setup

1. Copy `tools/benchmark/ge_extensions/*.lua` to `<user folder>/lua/ge/extensions/`
   (`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\lua\ge\extensions\`). These are test helpers, not
   part of the mod.
2. Optional, for scripted runs: an in-game MCP server exposing `run_lua` and
   `get_performance_metrics` at `http://127.0.0.1:29292/mcp`. `tools/benchmark/mcp.py` /
   `lua.py` talk to it. Without it, paste the Lua into the GE console (`~`).
3. Keep the game window focused, or disable the background frame cap
   (`settings.setValue('fpsLimitBackgroundEnabled', false)`; the setup scripts do this).
4. Physics mode is part of the result: state `physics.mode` (`heavy` or `vanilla`).

Pitfalls (measured):
- Vehicles spawned from Lua are in `realistic` gearbox mode and stay in neutral; the setup scripts
  switch them to `arcade`.
- Stop trucks with the parking brake: in arcade mode a held brake at standstill reverses.
- The first 1–2 runs after a Lua reload include cache/pool warm-up: discard one warm-up run.
- Do not `deepnode_main.stop()` while trucks sit sunk in the mud (restored terrain wedges them).

## 1. gridmap_v2 straight run

Mud pit x −334…−306, sand pit x −368…−340, both y −278…−370. Trucks start at y ≈ −269 facing south.

```lua
-- GE console / run_lua, gridmap_v2 loaded
-- (contents of tools/benchmark/gridmap_setup.lua)
dntestRun.start{ runs = 3, speed = 12.5, dist = 110, timeout = 30, clear = true }
-- wait ~70 s
dntestRun.result()          -- per run: fps, low1, low5, minFps, dCommit (MB), modMs, done, endSpeed
deepnode_main.rutLag(true)   -- near/far tile latency, .fresh = rut front latency, .lead = stamp lead
```

- `clear = true` resets the ruts before every run (worst case: fresh mud every run). Leave it out for
  "repeat" runs that drive in existing ruts.
- Scripted: `cd tools/benchmark && python -I bench2.py <label> <runs> [clear]` prints per-run numbers,
  memory per minute (commit, after GC) and averaged engine metrics (`Render`, `RenderShadows`, `Lua`, …).
- Profile mod functions: `python -I profrun.py 1` (uses `dntestProf`).
- Reload after code edits: `./reload.sh` (GE Lua reload, per-vehicle `deepnode_vehicle` reload,
  `reloadLevelData`, arcade gearbox).

## 2. johnson_valley circles

The JV dunes are too steep for a straight run (trucks bog down), so each truck drives its own
100 m circle at 40 km/h inside a flat mud zone (7 zones r = 108 m in a hex around (−418, −994);
truck 8 shares the centre circle half a lap behind truck 1).

1. Copy `tools/benchmark/data/johnson_valley/zones.json` to
   `<user folder>/settings/deepnode/levels/johnson_valley.json`, load johnson_valley,
   `deepnode_main.reloadLevelData()`.
2. Spawn 8 Percherons, run `tools/benchmark/jv_setup.lua`.
3. Sample for ≥ 4 minutes (memory needs caches to fill): `get_performance_metrics`,
   `deepnode_main.perf()`, `deepnode_main.rutLag(true)`, `dntestCircles.state()`.
   `deepnode_main.removeZones()` removes the test zones afterwards.

Historical JV result (7 trucks, before the 2026-10 overhaul code): vanilla 97–102 fps;
mod 75–83 fps, rut lag 0.10–0.13 s, 7–20 MB/min. Needs re-measurement with the current code.

## 3. gridmap_v2, 4 trucks (2026-10-31)

Same pits, 4 Percherons: trucks 1-2 of the 8-truck row in the mud pit, 5-6 in the sand pit
(`tools/benchmark/gridmap_spawn4.lua`). Orbit camera on truck 1 (yaw 160, pitch 14, 16 m),
vsync off, `bench2.py <label> 5 clear`; compare runs 2-5 (run 1 after a Lua reload is inflated),
interleave variants by swapping the Lua files and reloading (`reload.sh`).

## 4. gridmap_v2, 6 trucks (2026-10-31)

Same pits, 6 Percherons: trucks 1-3 of the 8-truck row in the mud pit, 5-7 in the sand pit
(`tools/benchmark/gridmap_spawn6.lua`, removes every other vehicle and rewrites bench_spawn.json),
orbit cam yaw 160 / pitch 14 / 16 m on truck 1, `bench2.py label 5 clear`, compare runs 2-5.
Used for the screen-space overlay A/B (`deepnode_main.setRutOverlay(true/false)` between sets).

## Result log

| date | map | mode | variant | fps (low1) | rut latency | memory |
|---|---|---|---|---|---|---|
| 2026-10-27 | gridmap_v2 | heavy | mod off | 77–84 (66–72) | – | – |
| 2026-10-27 | gridmap_v2 | heavy | before overhaul | 53 (42) | 0.40–0.54 s | +199 MB/min |
| 2026-10-27 | gridmap_v2 | heavy | current, fresh mud | 54–56 (36–40) | front 0.10 s, max 0.15 s | ~15 MB/min |
| 2026-10-27 | gridmap_v2 | heavy | current, repeat | 50–55 (39–42) | deepening 0.15–0.18 s | flat–25 MB/min |
| 2026-10-27 | gridmap_v2 | vanilla | 150 m view, fresh mud | 34–39 (25–30) | front 0.11–0.13 s | 162 MB/min (incl. warm-up growth) |
| 2026-10-27 | gridmap_v2 | vanilla | 150 m view, repeat (5 runs) | 46–51 (39–44) | deepening 0.24–0.77 s | 23 MB/min |
| 2026-10-27 | gridmap_v2 | vanilla | v0.1.0, 70 m view, fresh mud | 39–41 (25–31) | front 0.10–0.11 s | 253 MB/min |
| 2026-10-27 | gridmap_v2 | vanilla | v0.1.0, 70 m view, repeat | 34–48 (24–36) | deepening 0.11–0.22 s | 132 MB/min |
| 2026-10-27 | gridmap_v2 | heavy | v0.1.0, 70 m view, fresh mud | 45–47 (32–35) | front 0.10 s | 63 MB/min |
| 2026-10-27 | gridmap_v2 | heavy | v0.1.0, 70 m view, repeat | 47.5–49 (37–39) | deepening 0.14–0.21 s | 25 MB/min |

| 2026-10-28 | gridmap_v2 | vanilla | before builder fix, user GUI settings, vsync off, fresh mud | 37.2–39.6 (25.8–30.7) | front 0.09–0.11 s | 113 MB/min |
| 2026-10-28 | gridmap_v2 | vanilla | builder fix + size classes 6/96, fresh mud | 38.5–42.5 (29.3–33.8) | front 0.10–0.11 s | 36–122 MB/min |
| 2026-10-28 | gridmap_v2 | vanilla | mod off (same session, 60 fps cap) | 60 (59–60) | – | – |
| 2026-10-28b | gridmap_v2 | vanilla | mod off, orbit camera on truck 1 (16 m), vsync off | 74.6–79.3 (64–70) | – | flat |
| 2026-10-28b | gridmap_v2 | vanilla | v0.1.1 code, 3 sets x 4–5 runs after reload | 40.8–50.6, mean 45.9 (24–35) | front 0.10 s | +244–268 MB per 5 runs; runs 4–5 +12 to +26 MB each |
| 2026-10-28b | gridmap_v2 | vanilla | size-affine pool, decal classes, identical-upload skip, 4–5 runs after reload | 42.4–47.9, mean 45.3 (28–34) | front 0.10 s | +96–113 MB per 5 runs; runs 4–5 +0.6 to +5 MB each |

2026-10-28b protocol: `tools/benchmark` bench2 with an orbit camera on truck 1 (yaw 160, pitch 14,
16 m), vsync off, `clear`; the original and current Lua/config swapped in turn in one session.
Physics stayed realtime in every run (sim/wall 0.998–1.000, `PhysicsNodes` 1.5–1.7 ms with or
without the mod). Single runs of one setup spread ±3 fps: compare means of ≥ 8 runs. Per-module
CPU (dntestModProbe): an upload 1.24 -> 1.19 ms, 4.4 % of builds skipped as identical.

Per-module time while driving: `dntestModProbe.start(true)` before `bench2.py`, then
`dntestModProbe.result()` (mod modules, wrapped mesh functions, engine metrics, driving frames only).

The v0.1.0 session ran slower overall than the earlier ones (frame limiter visible in the metrics); compare
against a mod-off run from the same session before drawing conclusions.

| date | map | mode | variant | fps (low1) | rut latency | memory |
|---|---|---|---|---|---|---|
| 2026-10-31 | gridmap_v2, 4 trucks | heavy | before research changes, runs 2-5 x 2 sets | 76.1 (59.7) | near 0.12 s avg, max 1.5-3.9 s; front 0.09 s | +5-15 MB per run |
| 2026-10-31 | gridmap_v2, 4 trucks | heavy | soil memory + kinds + deadline queue + minVisibleChange | 78.3 (62.3) | near 0.12 s avg, max 0.6-3.0 s (0.8-1.0 s runs 3-5); front 0.09 s | +3-19 MB per run |
| 2026-10-31 | gridmap_v2, 4 trucks | heavy | final A/B: a8ddbc0 (session start) | 75.6 (58.0) | worst near 1.5-3.9 s, median ~2.0 s; front 0.09 s | ~20.5 MB per runs 2-5 |
| 2026-10-31 | gridmap_v2, 4 trucks | heavy | final A/B: f03cc18 + docs (soil memory, kinds, deadline queue, minVisibleChange, terrain-first sand, JIT fixes) | 77.7 (62.2) | worst near 0.46-3.3 s, median ~0.75 s; front 0.09 s | ~17 MB per runs 2-5 |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | 36d586e, overlay off | 59.3 (44.3) | near 0.13 s avg, max 3.6-3.8 s; front 0.09 s | ~+20 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | 36d586e, overlay on (prints + tyre pass) | 58.0 (43.4) | near 0.13 s avg, max 3.5-3.7 s; front 0.09 s | ~0 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | cd2f2d6, overlay off | 59.9 (45.0) | near 0.13 s avg, max 3.5-3.7 s; front 0.09 s | ~+6 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | cd2f2d6, overlay on (universal prints, puddles, tyre pass) | 58.4 (43.9) | near 0.14 s avg, max 3.4-3.7 s; front 0.09 s | ~+4 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | b1d68f8, overlay off | 59.9 (44.6) | near 0.13 s avg, max 3.5-3.6 s; front 0.09 s | ~+7 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | b1d68f8, overlay on (prints, puddles, splats, carried mud, tyre pass; 0 of 105 581 prints dropped) | 58.3 (44.3) | near 0.13 s avg, max 3.6-3.7 s; front 0.09 s | ~+3 MB per run |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | d2473d5, overlay on (all defaults) | 56.9 (43.6) | - | runs on before off; the whole set ~2 fps slower than earlier sets (session drift) |
| 2026-10-31 | gridmap_v2, 6 trucks | heavy | d2473d5, overlay off | 57.8 (43.9) | - | same set |

## 4b. gridmap_v2, 6 trucks, review items (2026-11-01)

Protocol of section 4 (heavy, user GUI settings: overlay on, targetFps 70; vsync and the 60 fps
limiter off for the runs), runs 2-5. Old = 8455e64, new = pooled water, wet trenches, torque dig
with per-wheel load, stopped-vehicle floor hold. The first set of the session (old code, 63.6 fps)
ran before the session settled; compare the later sets.

| variant | fps (low1) | Lua ms | Render ms | RenderShadows ms |
|---|---|---|---|---|
| old, first set of the session | 63.6 (48.6) | 2.60 | 4.50 | 4.96 |
| new, set 1 | 58.6 (43.5) | 2.89 | 4.66 | 4.92 |
| old, set 2 | 59.6 (46.1) | 2.63 | 4.50 | 4.83 |
| new, set 2 | 58.5 (43.4) | 2.72 | 4.67 | 4.74 |
| new, trench noise only in deep ruts | 58.75 (45.5) | 2.77 | 4.64 | 4.88 |
| new, `ring.physicalVehicles` 'player' (truck 1 digs, 5 print only) | 69.5 (58.1) | 1.26 | 4.63 | 4.14 |
| new, truck 1 alone (all physical, 3 runs) | 76.9 (62.1) | 0.99 | 4.90 | 2.99 |

Release v0.3.0 defaults (tread prints on, decal roads and road look off), same session, runs 2-5:

| variant | fps (low1) | Lua ms | Render ms | RenderShadows ms | end speed |
|---|---|---|---|---|---|
| mod off | 88.7 (84.2) | 0.57 | 3.02 | 3.89 | 12.2 m/s |
| v0.3.0 vanilla physics | 63.7 (51.0) | 2.65 | 3.25 | 4.82 | 12.0 m/s |
| v0.3.0 heavy physics | 59.5 (47.5) | 3.13 | 4.41 | 5.02 | 3.0-3.7 m/s |

The new code costs about 1 fps (Render +0.15 ms: the pooled water and trench terms in the overlay
shader; Lua +0.1-0.2 ms), about the spread of single sets. Rut front latency of truck 1 (the
camera truck) is 0.60-0.66 s alone and in 'player' mode; the 6-truck figure (0.13-0.20 s) is an
average over all trucks (OPEN_ISSUES 16).

## 5. gridmap_v2, 8 trucks, user GUI settings (2026-10-31c)

8 Percherons (`gridmap_setup.lua`), heavy physics, the user's GUI settings (overlay on, tileRebuildHz 40,
maxMeshBuildsPerSec 120, uploadEvery 2, loadRadius 70), vsync and the 60 fps limiter off, orbit cam yaw
160 / pitch 14 / 16 m on truck 1, `bench2.py label 5 clear`, runs 2-5; main and test swapped in turn
(`git checkout main -- lua`, reload). Static scene with the trucks parked: 76 fps, RenderShadows 3.6 ms
(driving: 6.2-6.5 ms: the mesh uploads).

| variant | fps (low1) | Lua ms | uploads / 5 runs | terrain updates / 5 runs | commit per run 2-5 |
|---|---|---|---|---|---|
| main 39af92b, set A | 48.6 (35.9) | 4.05 | - | - | -6 to -60 MB |
| main 39af92b, set B | 48.6 (36.6) | 3.53 | 8684 | 167 | -21 to -38 MB |
| test 855fa6c (road look, grass clusters, HT-55 fix), 2 sets | 47.4 / 47.2 (36.1 / 35.1) | 3.83 / 4.08 | - | - | -94 to +31 MB |
| same, road look off | 48.3 (36.9) | 3.55 | - | - | -26 to -31 MB |
| dd5ab4c (cached vehicle boxes / shared constants) | 47.7 (35.6) | 3.60 | - | - | -60 to +6 MB |
| + sky sampled only for glossy roads | 48.1 (35.2) | 3.68 | 8435 | 99 | -43 to +1 MB |
| + ring.digEvery 2 (rejected) | 47.5 (34.2) | 4.00 | 8271 | 101 | -57 to +43 MB |
| + distance-scaled minVisibleChange (rejected: uploads 8891, no change) | 47.4 (35.8) | 3.85 | 8891 | 113 | -58 to +11 MB |

| + ring.camNearDist 12 / camFarDist 45 (rejected: uploads 8577) | 47.5 (35.6) | 3.77 | 8577 | 132 | -55 to +10 MB |
| + tileRebuildHz 15 / maxMeshBuildsPerSec 60 (rejected: uploads 8564) | 47.4 (35.2) | 3.56 | 8564 | 135 | -57 to -14 MB |
| **ring.bodyMaxWait 0.1 -> 1.5** (one upload per truck pass, config.json) | **52.3 (39.9)** | 2.63 | 3865 | 453 | -38 to -25 MB |

Uploads are set by the work per dug tile (~4 per tile: one per axle of an 8x8, then settling), not by
the rebuild rates: holding a tile's rebuild while all its new ruts are under the truck body (up to
1.5 s, an 8x8 at walking pace) shows the whole pass in one upload. RenderShadows 6.3 -> 5.5 ms, Lua
3.7 -> 2.6 ms. Rut lag readouts rise (near avg 0.12 -> 0.29 s, front 0.10 -> 0.30 s: counted from
the carve, mostly under the body); in screenshots the ruts reach right up behind the rear wheels.
The rut floor now keeps up (terrain updates 453 vs ~130 per 5 runs: the upload budget no longer
starves them); 2 of 5 runs ended with a slower truck (avg end speed ~2.2 m/s, all finished).

The road look costs ~0.5 fps after the Lua fix (GPU side: 5 material passes); trimming the 257 free
pooled mesh objects changed nothing (hidden objects cost no render time). In 2 of the test sets one run
had a mud-lane truck slow down (avg end speed 1.1 m/s, all 8 finished): watch for floor writes held
near grass (pits lie 8-9 m from grass).

## 6. gridmap_v2, 8 trucks, decal copies in the mud mesh (2026-10-31d)

Same protocol as section 5 (user GUI settings, vsync and limiter off, runs 2-5), one session, test
branch after d44ae41 / f0a2a93 / 9cebda4:

| variant | fps (low1) | Lua ms | RenderShadows ms | end speed |
|---|---|---|---|---|
| decal copies on every tile build, hull stamps | 46.2 (24.8) | 8.63 | 7.95 | 1.2 m/s (4 of 5 runs) |
| same, hull stamps off | 45.3 (24.9) | 7.49 | 7.69 | 1.2 |
| same, grassReach 24 | 43.3 (20.3) | 7.71 | 8.24 | 1.6-2.0 |
| decal copies off (roads hidden) | 56.9 (44.4) | 2.62 | 5.56 | 2.7-3.3 |
| **copies only on quiet tiles (overlayQuiet 1 s), hull on** | 53.5 (37.4) | 3.21 | 5.63 | 2.4-3.6 |
| + quiet rebuild forced, copies on freezing | 54.2 (34.9) / 53.3 (36.0) | 4.8 / 5.2 | 5.56 | 2.7-3.6 |

The copies cost ~3.5 fps against no decal roads on the mud at all; main's logged 52.3 (39.9) was a
different session.

## 7. gridmap_v2, 8 trucks, road copies rebuilt (deepnode_roadCopy, 2026-11-01)

Same protocol, one session, runs 2-5 (copyA: runs 2-3 of 3):

| variant | fps (low1) | Lua ms | RenderShadows ms | tile upload |
|---|---|---|---|---|
| old copies (deepnode_decals) on every build, probe | 43.9 (24.3) | 8.30 | 7.58 | 4617 verts, 5.9 ms |
| **roadCopy, copies on every build** (copyA / copyB) | 51.9 (35.2) / 50.8 (32.6) | 4.06 / 4.47 | 6.31 / 6.71 | 1066 verts, 2.8 ms |
| no decal roads on the mud (noDec2) | 57.4 (44.4) | 2.54 | 5.55 | - |

gridmap_v2's mud pit is the worst case: 3-4 overlapping decal layers (puddle water 25 m wide,
mud_large, furrows, tire tracks) over every dug cell. Copy Lua ~1.2 ms per tile build, much of it
clipping triangles along the narrow furrow strips.

## 8. gridmap_v2, one lc300 in a 60 m circle, decal roads on (2026-11-02)

User question: why does turning decal roads on drop the frame rate so much? One lc300 (player),
`dntestCircles` R = 30 m around (-337, -310) at 25 km/h through both pits, fixed free camera,
vsync and the 60 fps limit off, user GUI settings (cellSize 0.2, tileRebuildHz 40, uploadMsMax 6).
Frame times from a per-frame recorder; ruts cleared before every run; variants interleaved.

Where the drop comes from (static views, no ruts, fps):

| view | mod on, roads `copy` | vanilla (mod stopped) | mod on, decal roads on soft ground hidden (`off`) |
|---|---|---|---|
| close over the mud pit | 122.7 / 124.3 | 124.5 / 124.5 | 183.8 / 188.1 |

The level's own decal roads over the pits (238 roads; 28 stacked over the mud pit, up to 5 layers
per point) cost ~2.6 ms in that view in vanilla too. Mode `off` hides them, so it runs faster than
vanilla; most of the on / off difference is the engine's decals, not the mod.

What the copies cost while digging (30 s runs, fresh ruts, fps):

| variant | fps | copy corners / upload (+ padding) | tile upload ms / frame |
|---|---|---|---|
| decals only (copies off, engine decals shown) | 122.6 / 122.0 | - | 0.16 / 0.19 |
| copies, one quad per dug cell (before) | 115.5 / 114.7 | 2818 / 2674 (+1200) | 0.42 / 0.44 |
| **copies, merged planar rectangles (copyMerge)** | 116.0 / 113.0 | 2194 / 2031 (+860) | 0.36 / 0.44 |

Copies cost ~0.55 ms a frame with one truck: uploads ~0.22 (copy submeshes more than double the
tile upload), drawing ~0.25 (about half of it pixel shading of the translucent forward-lit copies:
stripping their normal / roughness / AO maps saved half; the other half per draw), copy emission
~0.08. Merging cut the copy corners 23-37 %; the fps change stayed inside the run-to-run noise.

## 9. Region mode and large maps (2026-11-03, v0.4.0)

No truck fps benchmark. Region numbers from single-truck tests (teleports of 300-5000 m, log
"region moved to"): gridmap_v2 forced to a 1 km region: load 8-14 ms over 3-4 frames, switch
frame 4-13 ms; hw550 (auto): start 1.35 s, load 9-15 ms, switch 4-12 ms; huge_desert (8192^2 x
64 m, packed, virtual 1 m grid): start 0.8 s, load 14-31 ms over 4-7 frames, switch 17-59 ms,
lc300 digging at 58-60 fps (mod frame <= 8.5 ms). Terrain after leaving a region: max height
difference to the original 0 (gridmap_v2 heavy and vanilla, huge_desert).

## 10. gridmap_v2, 8 trucks, upload holds (2026-11-04) - rejected for looks

8 Percherons (`gridmap_setup.lua`), heavy, user GUI settings, vsync and limiter off, orbit cam yaw 160 /
pitch 14 / 16 m, `bench2.py label 5 clear`, runs 2-5, variants interleaved through gui.json + restart.
Session noise is large (one baseline set 45.5-62.4 fps). Mod off (trucks drive at 12.2 m/s, no mud):
88.8 fps, 11.6 ms; mod on adds GE Lua +1.9, LuaPre +0.45, RenderShadows +0.9, RenderReflections +0.7,
Render +0.5 ms.

| variant | fps runs 2-5 (low1) | RenderShadows | Lua |
|---|---|---|---|
| base (bodyMaxWait 1.5), 3 sets | 50.5 (41.0) / 55.2 (40.0) / 51.1 (39.9) | 5.83 / 4.52 / 5.27 | 3.66 / 2.95 / 3.52 |
| tiles.targetSize 8 | 49.1 (35.1) | 5.46 | 3.75 |
| bodyMaxWait 3, 3 sets | 64.0 / 66.3 / 65.9 (~50) | 3.45 | 2.75 |
| bodyMaxWait 5 | 65.0 (49.7) | 3.55 | 2.82 |
| bodyMaxWait 3 + tileRebuildHz 20 | 65.0 (48.2) | 3.44 | 2.61 |

bodyMaxWait 3 is rejected although it is the biggest win measured: in a low side view the wheels of a
truck crawling through the mud ride on a flat surface until the pass ends (the rut shows only behind
it). The user rule: ruts must keep up as before. The body test (P.dirtyHidden) is view-independent;
a camera-aware occlusion test would be needed to hold uploads only where the deck really hides them.

Camera-aware follow-up (same day): holding a tile up to 3 s only while the camera's line of sight to
every new rut square crosses the truck deck (a plane at 0.35 of the vehicle's OOBB height over the
footprint; low side views keep 1.5 s) gave 47.0 vs 47.0 fps for the original: no gain. The 3 s win came
from holding changes the camera can see (berms and rut edges beside the deck). Code not kept.

## 11. v0.5.0 release check (2026-11-04)

8 Percherons, gridmap_v2, user GUI settings, vsync and limiter off, orbit cam yaw 160 / pitch 14 /
16 m, `bench2.py label 5 clear`, runs 2-5, main (v0.4.0) and test checked out in turn after a game
restart. Default ticks (MUD, SAND) on gridmap_v2.

| variant | physics | fps runs 2-5 (low1) | RenderShadows | Lua |
|---|---|---|---|---|
| main v0.4.0, set 1 / set 2 | heavy | 51.5 (37.9) / 45.2 (33.8) | 5.26 / 6.40 | 3.48 / 4.16 |
| test v0.5.0, set 1 / set 2 | heavy | 45.0 (34.4) / 48.5 (35.1) | 6.08 / 5.59 | 4.00 / 3.58 |
| test v0.5.0 | vanilla | 51.3 (41.5) | 4.95 | 3.47 |

The order of the sets decides which is faster (drift over the session): v0.5.0 is not slower than
v0.4.0 within the noise (avg 46.8 vs 48.4, each build ran first once and second once).

## 12. Wet rubber, pre-rutted decal roads, torn berms (2026-11-04, test 24a9a4f)

8 Percherons (`gridmap_setup.lua`), heavy, user GUI settings, vsync and limiter off, orbit cam yaw 160 /
pitch 14 / 16 m, `bench2.py label 5 clear`, runs 2-5, two interleaved sets (new, off, off, new). "off" =
`roads.preRut` false, `clods.rubberWet` false, `stamp.bermCrumble` 0 through gui.json + restart.

| variant | set 1 fps (low1) | set 2 fps (low1) | mod ms | GE Lua ms |
|---|---|---|---|---|
| new | 59.8 (37.5) | 52.0 (36.0) | 0.8-1.4 | 3.12 / 3.42 |
| off | 54.5 (37.8) | 55.2 (39.3) | 0.4-0.5 | 2.79 / 2.66 |

Mean fps equal within the noise (55.9 vs 54.9); low1 ~2 lower and the mod's own Lua ~0.7 ms higher with
the new features. Fresh-front rut lag 0.21-0.26 s (new) vs 0.29-0.37 s (off). Not split per feature yet
(likely: sectors re-meshing the 541 pinned tiles at full resolution).

Split (same session, one set of 5 runs each, mod ms runs 1-5): only `roads.preRut` off 0.43-0.54;
pre-rut with `roads.preCellStride` 4 for undug pinned tiles in sectors 0.60-1.21; pre-rut without
pinned tiles (`roads.prePin` false) 0.56-0.79. The pre-rut pass is the cost (~+0.2-0.5 ms); pinning
adds part of it. Not resolved.

## 13. Stripped bench: 2 Percherons, pre-rut shape fix (2026-11-05)

Stripped gridmap_v2 bench for quick A/B: 2 Percherons (`tools/benchmark/gridmap_spawn2.lua`: truck 2 in
the mud pit, 6 in the sand pit; rerun `gridmap_setup.lua` first to get the 8-truck spawn list back),
heavy, user GUI settings, vsync and limiter off, orbit cam yaw 160 / pitch 14 / 16 m,
`bench2.py label 5 clear`, runs 2-5. Variant switched through gui.json + `reloadLevelData`.

| variant | fps runs 2-5 | low1 | mod ms |
|---|---|---|---|
| first set (pre-rut on, old shape, stride 4) | 116.8 | 97.9 | 0.32-0.48 |
| pre-rut on, new shape, `preCellStride` 1 | 132.8 | 117.4 | 0.21-0.30 |
| pre-rut off | 136.1 | 120.4 | 0.21-0.29 |
| pre-rut on, stride 4 | 137.8 | 120.2 | 0.24-0.33 |
| pre-rut on, stride 1 (repeat) | 136.8 | 120.0 | 0.25-0.30 |

From now on each variant runs twice (`bench2.py label 2 clear`, user 2026-11-05); compare run 2
(run 1 after a reload is inflated) and interleave variants.

| `physics.heavy.grassLowDraw` (roads off) | fps runs 2-5 | low1 |
|---|---|---|
| on | 127.7 | 108.4 |
| off | 131.3 | 110.1 |
| on (repeat) | 138.9 | 116.2 |

Deeper pre-rut with dark wet wheel lines (2 runs each, run 2): on 118.7, off 123.8, on 119.5 fps
(low1 96.8 / 108.7 / 99.0; mod Lua 1.57 / 1.10 / 1.43 ms).

The first set ran right after a long session (drift). With 2 trucks the full-resolution pinned
tiles cost nothing measurable (noise +-3 fps).

## 15. 8 trucks, decal copies draped with fade levels (2026-11-06, test a4e358f)

8 Percherons (`gridmap_setup.lua`), heavy, user GUI settings (roads.mode copy), vsync and limiter
off, orbit cam yaw 160 / pitch 14 / 16 m, `bench2.py label 4 clear`, interleaved in one session
(fade, no fade, fade). "no fade" = `roads.copyFade` {} set live + `setDecalRoads(true)`.

| variant | fps runs 2-4 | low1 runs 2-4 | RenderShadows | RenderReflections | Lua | commit |
|---|---|---|---|---|---|---|
| fade (5 levels), set 1 | 33.0-35.6 | 17.0-23.7 | 10.61 | 3.23 | 6.04 | +504 MB/min (fresh start) |
| no fade | 42.7-45.4 | 25.5-33.0 | 6.81 | 1.72 | 4.99 | +69 MB/min |
| fade (5 levels), set 2 | 31.9-34.9 | 17.2-18.9 | 11.25 | 3.14 | 6.02 | +91 MB/min |

The fade clones multiply copy submeshes (up to 6 per road material per mesh): -10 fps, shadow
pass +4.5 ms and reflections +1.4 ms although the clones cast no shadows (cost per submesh, like
the known per-object shadow cost). Not acceptable as is (OPEN_ISSUES 23).

## 16. Optimization pass toward 55-60 fps, 8 trucks (2026-11-06, test 010be0d)

Same bench as 15 (2 runs per variant, run 2 shown unless noted), one long session.

| variant | run 2 fps | note |
|---|---|---|
| mod off | 88.6-90.9 (runs 2-4) | trucks run through at 12 m/s (not the same scene) |
| copies, fade off | 42.6-45.4 | reference |
| fade 5 levels / 2 levels | 32-35 / 38.1 | cost is per copy submesh (copy vertices equal) |
| no road copies | 48.5 | copies cost ~3.4 fps |
| every mod mesh hidden while digging | 52.1 | ceiling with today's mesh approach |
| finer padding classes (decal 1.25x, 12 tile classes) | 44.0 | padding -40 %, no fps change: reverted |
| tiles.targetSize 10 | 42.7 | uploads -40 %, vertices x2, Lua 7.9 ms: worse |
| hideInRenderView(63) on mod meshes | 42.8 | no change |
| frozen tiles handed to sectors | static Render 3.1 -> 10.6 ms | sector meshes draw far heavier: rejected |
| tandem axles 1/4 pass (kept) | 44.6 vs 40.0 | trucks no longer bog (end speed 3.5 vs 1.9 m/s) |

Mod Lua while digging ~2.8 ms (tiles 1.6 incl. createMesh, reports 0.38, tyre mud 0.63,
overlay 0.29, sectors 0.23, floor 0.10). Report string compile ~0.04 ms/frame. Static frame
with the pit dug: 14.6 ms; hiding all mod meshes there saves ~0.7 ms (overview) / 1.6 ms (6 m
close-up). 55-60 fps not reached; see OPEN_ISSUES 23.

## 14. v0.6.0 release check (2026-11-05)

Stripped bench (section 13), 2 runs each, run 2: heavy 117.2 fps (low1 102.0), vanilla physics
122.1 (107.4), mod off 107.6 (97.2). Mod off draws the level's 238 stacked decal roads over the
pits again (the mod hides them on soft ground with `roads.mode` 'off'), hence slower.

## 17. Collision compaction and fast rut updates, 8 trucks (2026-11-07, test)

gridmap_v2, 8 Percherons, heavy physics, `bench2.py <label> 2 clear`, run 2 shown, variants
interleaved, rates set live. Lag = rut lag near (avg / max s), front = fresh front from the carve
(mostly under the truck body).

| variant | fps | low1 | lag | front |
|---|---|---|---|---|
| A: old rates (tile 40 Hz, cap 120, far 10, deepen 8, uploadEvery 2), x3 | 55.5 / 59.9 / 56.4 | 42.7 / 49.0 / 46.0 | 0.29-0.34 / 2.8-4.0 | 0.26-0.32 |
| B: tile 60 Hz, cap 400, far 20, deepen 20, smallWait 0.05, uploadEvery 1, x2 | 55.4 / 57.7 | 41.5 / 39.1 | 0.19-0.37 / 3.3-4.0 | 0.28-0.31 |
| C: B + uploadMsMin 4, x3 | 53.3 / 54.6 / 54.4 | 41.5 / 42.8 / 42.7 | 0.20-0.28 / 3.2-3.8 | 0.23-0.29 |
| D: C + digEvery 1, freshWindow 0.5, digNearDist 70, outViewMaxDefer 1, report 40 Hz, x3 | 52.8 / 51.2 / 53.4 | 38.0 / 33.4 / 37.7 | 0.21-0.25 / 2.5-3.3 | 0.22-0.27 |
| E: D + deepenFast, x2 | 55.0 / 54.3 | 37.6 / 36.5 | 0.16-0.17 / 1.5-2.1 | 0.25-0.26 |
| E from the saved config (after reload) | 54.2 | 36.4 | 0.20 / 2.3 | 0.29 |
| E + floorHz 20 (terrain updates 390-501 vs 163 per bench), x2 | 46.6 / 58.2 | 31.9 / 44.1 | 0.14-0.24 / 1.5-2.4 | 0.20-0.36 |

Lag by class (one run, E): in-view fresh fronts 0.000 s, in-view deepening 0.003 s (D: 0.163 /
0.602 s); the rest is out of view or under the body. The 4.0 s maximum of A-C was
`outViewMaxDefer`. fps drifts ~4 between repeats of one variant in this session. No collision
compaction ran during these benches (growth per reset < 50 MB).

### 17b. Fresh front under the truck body (bodyFreshHz, same session)

Same bench, settings E, run 2, uploads per bench (2 runs).

| bodyFreshHz / dist | fps | low1 | front lag | uploads |
|---|---|---|---|---|
| 0 (hold, x3) | 49.2 / 52.7 / 52.3 | 32.0 / 37.5 / 35.3 | 0.20-0.35 | 1882-2206 |
| 20, no limit (x2) | 38.9 / 43.2 | 25.9 / 21.1 | 0.057 | 5227-5994 |
| 30, no limit | 33.0 | 16.0 | 0.047 | 8052 |
| 20, 30 m (x2) | 41.0 / 39.3 | 26.4 / 26.0 | 0.062-0.064 | 4727-5260 |
| 20, 20 m (kept) | 46.2 | 26.9 | 0.075 | 4096 |
| 10, 20 m | 46.9 | 32.0 | 0.091 | 3219 |

A tile stays under an 8x8 body ~1 s, so a fresh front at 20 Hz is ~20 uploads per tile per
truck instead of 2-3; the cost is per upload (engine first-draw), not per vertex. One more 10 Hz
run read 87.7 fps / mod 0.44 ms (camera off the pits): discarded.


## 18. Tyre material updates: CPU cost vs the screen-space tyre pass (2026-11-07, test d3d8eb2 + working tree)

gridmap_v2, 4 Percherons (`gridmap_spawn4.lua`), orbit cam yaw 160 / pitch 14 / 16 m, vsync off,
`bench2.py <label> 2 clear`, variants interleaved A B A B, set live. Run 2 shown. Counts per bench
(2 runs) from `deepnode_wheelMud.stats()`.

| variant | fps (run 2) | low1 | tyre updates per bench |
|---|---|---|---|
| A: as shipped (`clods.rubberWet` on, coat flushes on), x4 | 53.6 / 51.7 / 49.9 / 51.5 | 31.7 / 30.8 / 27.7 / 31.0 | coat flushes ~600 at 0.93 ms; rubber `Material:reload` ~10 at ~7.5 ms |
| B: `rubberWet` off (the overlay tyre pass still darkens wet tyres), x2 | 53.7 / 51.2 | 33.2 / 29.8 | rubber reloads 0 |
| C: coat flushes off (`clods.flushPerFrame` 0: coverage frozen, ceiling only), x2 | 53.1 / 52.9 | 29.6 / 31.1 | coat flushes 0 |

B = A within noise: the rubber reloads are a rare ~7 ms spike, not an average cost. C is +1.4 to
+3.2 fps over its neighbouring A runs: that is the most a shader-drawn coat (`overlay.tyreCoat`)
could save with 4 trucks, if it replaced the coat meshes' material flushes. The shader pass draws
at most 16 wheels (`tyreMaxWheels`); 4 Percherons have 32.

## 19. Liquid mud, dig bursts, frame limiter (2026-11-08, test)

gridmap_v2, 4 Percherons (`gridmap_spawn4.lua`), orbit cam yaw 160 / pitch 14 / 16 m, user GUI
settings (tileRebuildHz 60, maxMeshBuildsPerSec 400, uploadMsMax 6, overlay on, heavy physics),
`bench2.py <label> 2 clear`, run 2 (both runs where they differ). Limiter off unless stated.

| variant | fps | low1 | front lag s | notes |
|---|---|---|---|---|
| liquid mud working (scope fix), as first committed | 42.6 | 23.5 | 0.065 | Lua 10.7 ms; liquid writes counted as tyre stamps |
| liquid off (same code) | 55.8 | 30.9 | 0.063 | Lua 6.8 ms |
| liquid: writes not tyre stamps, 1 Hz liquid-only rebuilds, minStep 1 cm, damping 2, life 1.2 s | 49.2 / 50.1 | 26.5 | 0.070 | tile uploads 3092 -> 2866 per run |
| same, liquid off (interleaved) | 49.6 / 52.8 | 31.7 | 0.076 | |
| same, frame limiter 120 | 48.4 / 48.8 | 27.2 | 0.064 | |
| same, frame limiter 60 | 45.2 | 28.2 | 0.070 | FPSLimiter 1.0 ms a frame below the cap |
| limiter 60, digMaxPerFrame 4 | 48.1 | 32.9 | 0.093 | fewer uploads, +20 ms front lag |
| limiter 60, digMaxPerFrame 6 | 45.8 | 31.3 | 0.070 | |
| no limiter, digMaxPerFrame 6 (new default) | 51.5 / 53.5 | 32.2 | 0.072 | |
| same, road shader passes off | 52.6 / 54.2 | 32.9 | 0.068 | road shader ~1 fps, Render -0.2 ms |
| mod off (trucks do not sink: 12 m/s instead of 3.5) | 112.7 | 102.0 | - | Lua 0.63 ms |
| final (1ec9cb2: + overlay engine light) | 52.5 / 51.2 | 32.9 / 27.8 | 0.058 / 0.062 | |

Frame times while driving (no limiter, digMaxPerFrame 16): 30 % of frames under 16.7 ms with
~0.5 ms of mod work, 41 % at 20-50 ms with 4-10 ms (uploads 2.6-6.7 ms in the frame). A
frame limiter pads the short frames and cannot shorten the long ones, so bursts lose fps under
a cap even below it; spreading the dig uploads (digMaxPerFrame 6) evens them out. A per-frame
budget that follows the limiter (grow after a padded frame) was tried: 45.7-46.8 vs 45.2, dropped.
Mod GE Lua per frame (profile run): tile rebuilds + uploads 2.4 ms (2849 uploads / run, ~1 ms
each plus engine draw cost), vehicle reports 0.6, overlay 0.27, liquid 0.22, tyre mud 0.26,
physics floor 0.24. Tyre-layer material reloads ~8.6 ms each (shared by 4 trucks), ~20 per run.
