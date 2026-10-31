# Benchmark tools (not loaded by the game)

- `gridmap_setup.lua`, `jv_setup.lua` — place 8 Percherons for the two benchmarks.
- `ge_extensions/` — copy to `<user folder>/lua/ge/extensions/`: `dntestRun` (straight runs with
  reset), `dntestCircles` (circle driving), `dntestProf` (per-function timing).
- `data/` — gridmap_v2 spawn reference, johnson_valley mud zones.
- `mcp.py`, `lua.py` — talk to an in-game MCP server (`run_lua`, `get_performance_metrics`).
- `bench2.py <label> <runs> [clear]` — scripted gridmap_v2 runs with engine metrics.
- `profrun.py <runs>` — mod function profile; `reload.sh` — reload GE Lua, vehicle extension, mod.
- `gridmap_spawn4.lua` — the 4-truck variant (2 in the mud pit, 2 in the sand pit).
- `ge_extensions/dntestEng.lua` — engine cost probes: first-draw shadow cost per upload case,
  uploads per frame (`cases = {'idle','fresh','same','newmat','nocoll','k1','k4',...}`).
- `probe_upload_depth.lua` (+ `_result`) — histogram of tile uploads by rut depth and change;
  `probe_soil_depth.lua` — rut depth by pass count and kind.

See [docs/BENCHMARK.md](../../docs/BENCHMARK.md).
