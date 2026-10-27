# DeepNode — Deep Mud terrain deformation for BeamNG.drive

An AI-assisted experiment mod that adds terrain deformation to BeamNG.drive.

Deep, persistent mud and sand for BeamNG.drive. Vehicles sink into soft terrain layers, every
tyre cuts a real rut (0.2 m resolution, berms, settling), chassis drag dents, tyres pick up and
fling mud, and following vehicles drive in the ruts left before them. Physics stays BeamNG's own
(optional "heavy" ground models plus a terrain rut floor); the mod adds the deformation, the
visuals and the bookkeeping.

> Status: active development. Works on BeamNG.drive 0.40. Tested on `gridmap_v2` and
> `johnson_valley` with 8 Percheron 8x8 trucks. See [open issues](#open-issues) — contributions welcome.

## Features

- **Soft layers from the level:** terrain layers whose name or ground model matches `mud` / `sand`
  become deformable; optional circle/rect mud zones per level.
- **Ruts at 0.2 m:** swept tyre stamps with tyre profile, berms, rim sag, slope slump, spin digging,
  dual wheels, chassis dents. Settled shape written at once (no re-mesh churn).
- **Predictive stamping:** each wheel carves up to where it will be when the new mesh reaches the
  screen, so the rut front stays under the tyre instead of trailing it.
- **Terrain-first drawing (heavy physics):** undug mud *is* the level terrain — the level's own
  decal roads, colours and grass show exactly as in vanilla, at any distance. Mud meshes are drawn
  only where wheels dug.
- **Heavy physics option:** thicker ground models and a terrain rut floor, so ruts are real
  walls the tyres climb (4WD, diff locks and low range matter).
- **Tyre mud:** per-wheel coverage skin, sand/mud textures, wet film, flung chunks.
- **Frame-rate governor and camera-aware scheduling:** fast updates where the camera looks,
  budgeted updates elsewhere.
- **In-game GUI:** Run / Config / Debug tabs (settings saved to the user folder).

## Install

1. Download or clone this repository into
   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\deepmud`
   (or zip the repository content — `lua/`, `art/`, `settings/`, `scripts/` at the zip root — into `mods/`).
2. Start BeamNG.drive and load a level with mud or sand layers (e.g. *Grid Map v2*, *Johnson Valley*).
   The mod starts automatically; the GUI opens with it.
3. **Recommended:** click the *Physics* button in the GUI Run tab until it shows **HEAVY**. Heavy mode enables terrain-first
   drawing (vanilla-identical decal roads, unlimited mud view distance) and is much lighter on memory;
   the shipped default is `vanilla` physics.

Configuration: [`settings/deepmud/config.json`](settings/deepmud/config.json) (every value is
explained in [docs/REFERENCE.md](docs/REFERENCE.md)). GUI changes are saved to
`<user folder>/settings/deepmud/gui.json` and merged over it.

## Repository layout

| Path | Content |
|---|---|
| `lua/ge/extensions/deepmud/` | game-engine side: `main.lua` (terrain, stamping, tiles, scheduler), `tileMesh.lua` (mesh building, pool, upload governor), `farMesh.lua` (sectors), `decals.lua` (decal overlay for vanilla physics), `wheelMud.lua` (tyre mud), `physics.lua` (heavy mode), `gui.lua` |
| `lua/vehicle/extensions/deepmud/vehicle.lua` | vehicle side: wheel/chassis reports, footprint box, rut guide |
| `settings/deepmud/config.json` | defaults |
| `art/deepmud/` | tyre mud/sand textures and their bake scripts |
| `docs/` | reference, benchmark, open issues, engine findings, status notes |
| `tools/benchmark/` | benchmark harness (not loaded by the game) |
| `tools/dev/` | offline LuaJIT syntax/global check |

## Benchmarks

Two standard benchmarks with **8 Percherons** (`s450_8x8_flatbed_A`) — full instructions in
[docs/BENCHMARK.md](docs/BENCHMARK.md):

- **gridmap_v2 straight run:** 4 trucks through the mud pit, 4 through the sand pit, 12.5 m/s target,
  reset and repeat (`tools/benchmark/gridmap_setup.lua` + `dmtestRun`).
- **johnson_valley circles:** each truck on its own 100 m circle at 40 km/h inside flat mud zones
  (`tools/benchmark/jv_setup.lua` + `dmtestCircles`).

Latest gridmap_v2 results (BeamNG 0.40.3, i7-12700K, heavy physics):

| | fps (low 1 %) | rut front latency | memory growth |
|---|---|---|---|
| mod off | 77–84 (66–72) | – | – |
| before the 2026-10 overhaul | 53 (42) | 0.40–0.54 s avg, max 4.2 s | +199 MB/min |
| current, fresh mud every run | 54–56 (36–40) | 0.10 s avg, max 0.15 s (+ predictive lead) | ~15 MB/min |
| current, repeat runs in existing ruts | 50–55 (39–42) | deepening 0.15–0.18 s avg | flat–25 MB/min |
| v0.1.0, 70 m view, heavy, fresh / repeat | 45–47 / 47.5–49 | front 0.10 s | 63 / 25 MB/min |
| v0.1.0, 70 m view, vanilla, fresh / repeat | 39–41 / 34–48 | front 0.10–0.11 s | 253 / 132 MB/min |

## Open issues

Detailed write-ups with measurements and ideas: [docs/OPEN_ISSUES.md](docs/OPEN_ISSUES.md).

1. **Frame rate:** ~6 ms/frame over vanilla with 8 trucks (goal: 70–80 fps). Engine cost of every
   frame that first draws a re-uploaded ProceduralMesh (~1 ms shadow pass) dominates.
2. **Rut update rate under load:** fresh rut fronts in view update at 30–40 Hz; deepening by the
   axles behind is budgeted and can lag up to ~4 s with 8 trucks.
3. **Rut deepening goal of ≥ 40 Hz everywhere** not met for 8 trucks (engine limit, see 1).
4. **Sand is still fully meshed** (heavy `floorLift.sand = 0`): no terrain-first decals/distance
   for sand; moving it needs a deeper sand ground model to keep the same feel.
5. **Vanilla physics mode:** still the alpha-clipped decal overlay (matte, dark fringes) and the full mud mesh —
   memory growth 130–250 MB/min with 8 trucks (heavy: 25–63 MB/min).
6. **Rut mesh vs decal look:** dug areas use the terrain-matched mud material without the
   decal pattern; the change at rut edges is visible up close.
7. **Tyre mud cost:** ~1.6 ms/frame with 8 trucks, mostly engine shadow pass.
8. **Heavy physics speed:** Percherons bog down to 3–4 m/s in heavy mud; a 45 km/h benchmark
   in mud is not reachable with the current ground models.
9. **johnson_valley benchmark not re-run** with the current code (last JV numbers predate the overhaul).
10. **Vehicle report transport:** reports are Lua strings compiled by the GE (~160/s); a compact
    format would save Lua time.
11. **Licensing of baked textures:** `art/deepmud` tyre textures are baked from BeamNG's
    decal-road mud textures — check redistribution terms before a public release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Work happens on the `test` branch; `main` holds the
last benchmarked state. Every performance PR includes before/after numbers from the gridmap_v2 benchmark.

## License

Code: [MIT](LICENSE). The baked tyre textures in `art/deepmud` derive from BeamNG assets (see open issue 11).

## Credits

- Author: BeefyEarlGrey97
- Co-developed with Claude (Anthropic) — engine measurements, overhaul, tooling.
