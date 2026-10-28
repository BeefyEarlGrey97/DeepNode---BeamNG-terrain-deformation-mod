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

Per-module time while driving: `dntestModProbe.start(true)` before `bench2.py`, then
`dntestModProbe.result()` (mod modules, wrapped mesh functions, engine metrics, driving frames only).

The v0.1.0 session ran slower overall than the earlier ones (frame limiter visible in the metrics); compare
against a mod-off run from the same session before drawing conclusions.
