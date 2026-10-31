# DeepNode

Terrain deformation for BeamNG.drive 0.40: deep mud and sand that sink, rut and remember every tyre.

**Install:** download `DeepNode-v0.1.0.zip` from [Releases](../../releases) and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. *Physics* **HEAVY** is the default (DeepNode
window, Run tab); decal roads on the mud and sand are under **Experimental decal road** (off by default:
no decal road on soft ground). To set the mod UI keybinds: Search for DeepNode under Controls

## Clean-room build

DeepNode is written from scratch. It uses only BeamNG's public Lua interface. How that interface
behaves was learned from the game's shipped Lua scripts and from measurements in the running game MCP server. The engine facts it relies
on are documented in [docs/ENGINE_FINDINGS.md](docs/ENGINE_FINDINGS.md). The post-effect technique behind the
experimental tread prints (own HLSL passes fed by shader constants, a world-space map in a named render target) was
learned by reading the Dynamic Dirt mod; none of its code, shaders or textures are used.

## Features

- Mud and sand deformation from the level's own terrain layers
- Tyre ruts at 0.2 m resolution with berms and slumping walls, chassis dents, dual wheels
- Ruts carved ahead of each wheel, so they appear under the tyre (front latency ~0.1 s)
- Heavy physics: customized physic for deeper ground models and a terrain rut floor affect how tyres behave (its very subtle)
- Mud and sand buildup on the tyres, built up gradually, with falloff and chunks particles that fly off when driving; the coat colour blends over ~1 s (after a 1 s delay) between mud, sand and clean ground
- Experimental screen-space ground look (after MudRunner): universal tyre prints, wet churned mud, crumbs on the berms, puddles in deep ruts, mud splats from spinning wheels, mud carried onto hard ground, grass / dirt tracks, wet tracks that dry, wet glossy tyres, all drawn by GPU post effects (no mesh uploads), off by default
- Simple UI with live settings and performance stats
  
## Benchmarks included

Two repeatable tests with 8 Percheron 8x8 trucks (`tools/benchmark`, see [docs/BENCHMARK.md](docs/BENCHMARK.md)):

- **gridmap_v2 straight run** — 4 trucks through the mud pit, 4 through the sand pit, reset and repeat
- **johnson_valley circles** — each truck on its own 100 m circle at 40 km/h in mud zones


## Open issues

Details and measurements: [docs/OPEN_ISSUES.md](docs/OPEN_ISSUES.md). Contributions welcome on the `test` branch.

1. Frame rate: ~45 fps with 8 trucks in vanilla physic mode (75–79 with the mod off); every mesh upload also costs engine shadow and reflection time (~0.6 ms per `createMesh`, linear in uploads per frame: measured 2026-10-31).
2. Ruts deepened by the axles behind the front wheel can lag under heavy load (deadline-first queue 2026-10-31: worst ~1 s with 4 trucks, 8 trucks not re-measured).
3. Rut updates are 30–40 Hz for fresh ruts in view, not for every wheel.
4. Sand: terrain-first in heavy mode since 2026-10-31; vanilla physics mode still meshes all sand.
5. Vanilla physics mode: full mud mesh, high memory growth; the experimental decal overlay looks duller than the engine decals (alpha clip).
6. Decal roads over ruts are copies drawn forward-lit with the road's own material; the end fades (`startEndFade`) are approximated by narrowing the strip.
7. Tyre mud costs ~1.6 ms per frame with 8 trucks.
8. Heavy physics slows Percherons to ~3–4 m/s in deep mud.
9. johnson_valley benchmark not yet achieve internal goals.
10. Vehicle reports are Lua strings compiled by the game (~160 per second): measured 0.06 ms per frame, not worth changing.
12. Research follow-ups still open (layer-map rut material, engine tread decals, ground-model speed calibration, rut persistence): see docs/OPEN_ISSUES.md §13.
11. Tyre coat colour from the ground: tuned on puresands (sand) and gridmap_v2 (mud, wet); johnson_valley and other tyre models not checked yet.
13. Experimental ground look: GPU cost not measured exactly, puddle level is noise, night/rain unchecked: see docs/OPEN_ISSUES.md §14.
14. Heavy mode: grass within ~24 m of a digging truck still blinks about once a second (every terrain update rebuilds the groundcover there; was ~4-5 times a second): docs/OPEN_ISSUES.md §15.

## Contributing and forking

Fork freely (MIT). To contribute: fork, branch from `test`, run `bash tools/dev/luacheck.sh`
(needs LuaJIT; CI runs it on every pull request), and open the pull request against `test`.
Full workflow, benchmark rules and the mistakes to avoid are in [CONTRIBUTING.md](CONTRIBUTING.md).
Look for issues labelled `good first issue` and `help wanted`. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

To build on DeepNode: the mod lives in `lua/` (runtime), `shaders/` (tread print post effects) and `scripts/` (game hooks); config keys are in
[docs/REFERENCE.md](docs/REFERENCE.md), engine facts in [docs/ENGINE_FINDINGS.md](docs/ENGINE_FINDINGS.md).

## License

MIT — see [LICENSE](LICENSE).
