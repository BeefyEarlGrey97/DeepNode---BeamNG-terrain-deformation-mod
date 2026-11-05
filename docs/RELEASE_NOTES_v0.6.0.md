# DeepNode v0.6.0 — pre-rutted decal roads, no grass blink (2026-11-05)

## New
- **Pre-rutted decal roads (on by default).** The level's mud and sand decal roads (furrows,
  tyre tracks, puddles) start as real ruts: mud up to 0.3 m deep, sand 0.17 m, with berms, a wet
  slick floor where a groove is deep and water in its closed hollows. The heavy physics floor
  follows them, so trucks drop into the old tracks. Turn them off with the Run tab tick
  "Experimental pre-rutted roads" (applies when you press Restart).
- **Wet tyres** darken and turn glossy through the vehicle's own tyre material, and dry over
  about 90 s.
- **Torn berm crests**, steeper mud walls and puddles that reflect a muddy, dimmer sky.

## Fixed
- **Grass next to digging no longer blinks** (heavy physics). Soft ground near grass is drawn
  low once at load; later rut-floor writes there only change physics, so the engine never drops
  the grass around them.
- **Decal roads lying over fresh ruts** (with "Experimental decal road" on): the road copies
  leave out the dug cells, so a digging truck's trail shows.
- Pre-rut shape: clod-only decals no longer turn the ground into 15 cm blobs; wheel grooves are
  wide, continuous and drawn at full resolution.

## Measured (gridmap_v2, 2 Percherons, stripped bench, run 2 of 2)
| Build | Physics | fps (low 1 %) |
|---|---|---|
| v0.6.0 | heavy | 117.2 (102.0) |
| v0.6.0 | vanilla | 122.1 (107.4) |
| mod off | - | 107.6 (97.2) |

Mod off is slower here because the level's 238 stacked decal roads over the pits draw again
(the mod hides those on soft ground). Pre-ruts cost about 4-5 fps with 2 trucks (heavy).

## Known issues
- With "Experimental decal road" on, flat undug squares right beside a rut can show plain mud
  instead of the road pattern (docs/OPEN_ISSUES.md §14).
- The pre-rut wet floor and pools need "Experimental tread prints" on; clod-only decals get
  depth but no wet floor.
- Grass fix: soft ground near grass is drawn by the mod only within its load radius; maps whose
  grass layer is itself soft (johnson_valley) are not checked yet. An editor terrain edit near
  grass hides ruts there until Restart.

## Install
Download `DeepNode-v0.6.0.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
