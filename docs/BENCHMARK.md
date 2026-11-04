# Benchmarks

Both benchmarks use **8 Percheron** trucks, config `vehicles/percheron/s450_8x8_flatbed_A.pc`.
Report fps mean and low 1 %, rut latency and memory growth, and compare against the mod switched
off in the same session (absolute fps drifts by several fps over a long session).

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
