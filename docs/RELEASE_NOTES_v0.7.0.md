# DeepNode v0.7.0 — ruts keep up with the truck, engine memory returned (2026-11-07)

## New
- **Ruts keep up with the truck.** The fresh rut shows right behind the front wheel instead of
  from the middle of the truck, ruts deepened by the axles behind show at once in view, and
  updates run faster overall (tiles 60 Hz, wheel reports 40 Hz, rut floor 20 Hz).
- **Engine memory is given back.** The memory the game kept for every mud mesh update was the
  physics collision of each mesh. DeepNode now clears it (one short pause of about 0.4-0.5 s)
  while the game is paused, after a vehicle reset, or when your vehicle is nearly stopped after
  the game grew 1000 MB. Long sessions no longer creep up in memory.
- **Status light** while the window is closed: green when running, red when stopped, amber
  spinner while a big map loads the next area.
- **Parallax tyre prints:** tread streaks and ripples sit sunk in at low camera angles.

## Changed
- Window in BeamNG's own UI look (dark panels, orange tabs and buttons, grouped Run options).
- Big maps: region mode only above 8 x 8 km (hw550 stays whole), 2 km regions, with a stutter
  warning.

## Fixed
- Dark slivers along mud edges after switching to a lower graphics preset.
- Long multi-axle trucks bogging in their own ruts (following axles counted as full passes).
- Pale stair-stepped patches in decal road copies; road copies now drape into ruts and fade.
- Grass blinking next to digging on big maps (hw550).

## Measured (gridmap_v2, 8 Percherons, heavy physics, run 2 of 2)
| | before | v0.7.0 |
|---|---|---|
| Rut behind the front wheel | 0.29 s | 0.075 s |
| Deepening in view (per update) | 0.60 s | 0.003 s |
| Worst near rut lag | 4.0 s | 1.5-2.4 s |
| fps (low 1 %) | 52-55 (37-42) | 46 (27) |
| Memory freed by one compaction | - | 52 MB after two runs, up to 3 GB after a long session |

The faster ruts cost about 6 fps with 8 trucks digging near the camera; with one or two
trucks the cost is much smaller. `ring.bodyFreshDist` (20 m) and `ring.bodyFreshHz` (20) trade
it back. No separate vanilla-physics or 2-truck benchmark for this release.

## Known issues
- Parked trucks on mud still cause steady mesh updates (~27 per second with 8 trucks).
- The collision compaction pause length was measured on gridmap_v2 only (bigger maps may pause
  longer).

## Install
Download `DeepNode-v0.7.0.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
