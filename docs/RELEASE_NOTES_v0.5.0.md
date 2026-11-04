# DeepNode v0.5.0 — choose what deforms, snow (2026-11-04)

## New
- **Deformable ground list (Run tab).** One tick box per ground model of the level, so you pick
  which terrain deforms. Hard ground (asphalt, concrete, rock, ice, cobblestone ...) is not
  listed. Every session starts with mud, sand and snow ticked; your ticks apply when you press
  Restart and are not saved.
- **Snow.** Terrain layers with `snow` in their name or ground model now deform: 0.2 m deep
  ruts with small berms and steep walls, white snow packed into the tyre tread, dry tread
  prints. Heavy physics uses the deep-snow values of the Polish Roads Winter map (SNOW_DEEP).
  Tested on Polish Roads - Winter; among the stock maps only Automation Test Track has snow.
- **Grass, dirt and other ground you tick by hand** (kind `firm`): shallow 8 cm prints, a thin
  soft layer in heavy physics that keeps the level's own grip, no mud on the tyres.

## Changed
- The mud zone tools (Zone radius, Zone depth, Add zone here, Clear zones) moved from the Run tab
  to the Debug tab (Zones section).

## Fixed
- Snow maps lost all their decal tracks (ploughed paths, tyre tracks: 3478 roads on Polish Roads
  Winter). Decal roads are now only hidden over mud and sand.

## Measured (gridmap_v2, 8 Percherons, runs 2-5)
| Build | Physics | fps (low 1 %) |
|---|---|---|
| v0.4.0 | heavy | 51.5 (37.9) / 45.2 (33.8) |
| v0.5.0 | heavy | 45.0 (34.4) / 48.5 (35.1) |
| v0.5.0 | vanilla | 51.3 (41.5) |
| mod off | - | 88.8 |

Same speed as v0.4.0 within the session noise (whichever build ran first was faster both times).

## Known issues
- Snow values are first values, tuned on one map. Automation Test Track's snow is broken into
  thousands of small patches, so about 40 % of it gets no ruts at the patch edges.
- Ticks are lost after a Lua reload (Ctrl+L): tick again, then Restart.
- 8 trucks: ~45-55 fps against ~89 with the mod off; every mesh upload costs engine shadow time
  (see docs/OPEN_ISSUES.md §1).

## Install
Download `DeepNode-v0.5.0.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
