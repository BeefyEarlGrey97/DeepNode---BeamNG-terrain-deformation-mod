# Benchmark tools (not loaded by the game)

- `gridmap_setup.lua`, `jv_setup.lua` — place 8 Percherons for the two benchmarks.
- `ge_extensions/` — copy to `<user folder>/lua/ge/extensions/`: `dmtestRun` (straight runs with
  reset), `dmtestCircles` (circle driving), `dmtestProf` (per-function timing).
- `data/` — gridmap_v2 spawn reference, johnson_valley mud zones.
- `mcp.py`, `lua.py` — talk to an in-game MCP server (`run_lua`, `get_performance_metrics`).
- `bench2.py <label> <runs> [clear]` — scripted gridmap_v2 runs with engine metrics.
- `profrun.py <runs>` — mod function profile; `reload.sh` — reload GE Lua, vehicle extension, mod.

See [docs/BENCHMARK.md](../../docs/BENCHMARK.md).
