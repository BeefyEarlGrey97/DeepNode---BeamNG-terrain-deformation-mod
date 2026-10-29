# DeepNode

Terrain deformation for BeamNG.drive 0.40: deep mud and sand that sink, rut and remember every tyre.

**Install:** download `DeepNode-v0.1.0.zip` from [Releases](../../releases) and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. *Physics* **HEAVY** is the default (DeepNode
window, Run tab); decal roads on the mud and sand are under **Experimental decal road** (off by default:
no decal road on soft ground).

## Clean-room build

DeepNode is written from scratch. It uses only BeamNG's public Lua interface. How that interface
behaves was learned from the game's shipped Lua scripts and from measurements in the running game MCP server. The engine facts it relies
on are documented in [docs/ENGINE_FINDINGS.md](docs/ENGINE_FINDINGS.md).

## Features

- Mud and sand deformation from the level's own terrain layers
- Tyre ruts at 0.2 m resolution with berms and slumping walls, chassis dents, dual wheels
- Ruts carved ahead of each wheel, so they appear under the tyre (front latency ~0.1 s)
- Heavy physics: customized physic for deeper ground models and a terrain rut floor affect how tyres behave (its very subtle)
- Mud and sand buildup on the tyres, built up gradually, with falloff and chunks particles that fly off when driving; the coat colour blends over ~1 s (after a 1 s delay) between mud, sand and clean ground
- Simple UI with live settings and performance stats
  
## Benchmarks included

Two repeatable tests with 8 Percheron 8x8 trucks (`tools/benchmark`, see [docs/BENCHMARK.md](docs/BENCHMARK.md)):

- **gridmap_v2 straight run** — 4 trucks through the mud pit, 4 through the sand pit, reset and repeat
- **johnson_valley circles** — each truck on its own 100 m circle at 40 km/h in mud zones


## Open issues

Details and measurements: [docs/OPEN_ISSUES.md](docs/OPEN_ISSUES.md). Contributions welcome on the `test` branch.

1. Frame rate: ~45 fps with 8 trucks in vanilla physic mode (75–79 with the mod off); every mesh upload also costs engine shadow and reflection time.
2. Ruts deepened by the axles behind the front wheel can lag up to ~4 s under heavy load.
3. Rut updates are 30–40 Hz for fresh ruts in view, not for every wheel.
4. Sand is still fully meshed (no terrain-first drawing for sand yet).
5. Vanilla physics mode: full mud mesh, high memory growth; the experimental decal overlay looks duller than the engine decals (alpha clip).
6. Dug areas lose the decal-road pattern; the change at the rut edge is visible up close.
7. Tyre mud costs ~1.6 ms per frame with 8 trucks.
8. Heavy physics slows Percherons to ~3–4 m/s in deep mud.
9. johnson_valley benchmark not yet re-run with the current code.
10. Vehicle reports are Lua strings compiled by the game (~160 per second): measured 0.06 ms per frame, not worth changing.
11. Tyre coat colour from the ground: tuned on puresands (sand) and gridmap_v2 (mud, wet); johnson_valley and other tyre models not checked yet.

## Contributing and forking

Fork freely (MIT). To contribute: fork, branch from `test`, run `bash tools/dev/luacheck.sh`
(needs LuaJIT; CI runs it on every pull request), and open the pull request against `test`.
Full workflow, benchmark rules and the mistakes to avoid are in [CONTRIBUTING.md](CONTRIBUTING.md).
Look for issues labelled `good first issue` and `help wanted`. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

To build on DeepNode: the mod lives in `lua/` (runtime) and `scripts/` (game hooks); config keys are in
[docs/REFERENCE.md](docs/REFERENCE.md), engine facts in [docs/ENGINE_FINDINGS.md](docs/ENGINE_FINDINGS.md).

## License

MIT — see [LICENSE](LICENSE).
