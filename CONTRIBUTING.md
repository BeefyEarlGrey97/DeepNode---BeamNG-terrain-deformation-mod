# Contributing

Thanks for helping. Pick an item from [docs/OPEN_ISSUES.md](docs/OPEN_ISSUES.md) or the GitHub
issues, or open an issue first for larger changes.

## Branches

- `main` — last benchmarked, playable state. Only updated from `test` through a pull request.
- `test` — integration branch. Open pull requests against `test`.
- Topic branches from `test`: `feature/<name>`, `fix/<name>`, `perf/<name>`.

## Workflow

1. Clone into `<user folder>/mods/unpacked/deepnode` so the game loads your working copy.
2. Branch from `test`, make the change, keep the style of the file (comments explain *why*, with
   the measurement that justified a value).
3. Offline check: `bash tools/dev/luacheck.sh` (LuaJIT `-b` on every file; the only global write
   allowed is `castRayStatic`).
4. In game: reload Lua (Ctrl+L), then `deepnode_main.reloadLevelData()`. Vehicle-side edits need a
   vehicle extension reload (`extensions.reload('deepnode_vehicle')` in each vehicle).
5. Performance or rut-timing changes: run the gridmap_v2 benchmark
   ([docs/BENCHMARK.md](docs/BENCHMARK.md)) before and after, one warm-up run discarded, put both
   results in the pull request and add them to the result log.
6. Update `docs/REFERENCE.md` for new config keys and `CHANGELOG.md`.

## Rules learned the hard way

- Never pass incomplete face tables to `createMesh`; never create TerrainBlocks at runtime.
- Do not `deepnode_main.stop()` with trucks sunk in the mud.
- Physics stays BeamNG's own (the heavy-mode rut guide is the only mod force).
- Measure first, then change. State plainly in the PR what is not fixed.

## Commit messages

Imperative summary line (≤ 72 characters), blank line, body with the reason and the numbers.
AI-assisted commits carry a `Co-Authored-By:` trailer.
