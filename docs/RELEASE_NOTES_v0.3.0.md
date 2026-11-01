# DeepNode v0.3.0 — water in the ruts, trucks that stay put, tread prints on by default (2026-11-01)

## New
- **Water pools in the ruts.** Once a stretch of ruts is left alone for a moment, its closed
  hollows fill with muddy water (up to 70 % of each hollow's depth), with a shoreline that
  follows the rut. Ruts that drain along their length stay dry. Replaces the old random water
  level.
- **Wet trenches.** Deep mud ruts look wetter, smoother and darker than the churned mud around them.
- **Rear-wheel-drive squat.** Driven wheels dig in under drive torque, and each wheel's own load
  counts (weight moves to the rear under throttle). A rear-wheel-drive car launched hard in mud
  sinks at the rear while the front wheels stay on top (Moonhawk, 2 s: rear 0.35-0.43 m down,
  front 0.19-0.20 m).
- **Only the player's car digs (option).** GUI Run tab, "Ruts: all vehicles / player only /
  player + near": the other vehicles leave tread prints only. Default: all vehicles.
- **Decal roads over the ruts** are copies of the engine's own roads built with every mud mesh
  (when switched on, see below).
- **The whole body plows the mud**: bumpers, sills and skid plates dig in, not only the tyres.

## Changed defaults
- **Tread prints on** (GUI "Experimental tread prints"): tyre prints, wet churned mud, pooled
  water, crumbs, mud carried onto hard ground and wet glossy tyres.
- **Decal roads on the mud off** (GUI "Experimental decal road", `roads.mode` 'off'), and the
  screen-space road look is off too (`overlay.roads.enabled` false). Settings saved in your
  `settings/deepnode/gui.json` keep their values.

## Fixed
- **Vehicles no longer sink after stopping** in heavy mud. The ground under a driving truck was
  lowered with a delay and caught up under the parked wheels (-22 cm in 6 s, measured); now the
  ground under the wheels of a stopped vehicle holds unless a wheel spins. A small settle (~5 cm)
  when the wheels stop rolling remains.
- Grass beside a digging truck no longer blinks when the truck is 13 m or more away from it.

## Performance
6 Percherons on gridmap_v2 (3 in the mud pit, 3 in the sand pit), straight runs at 45 km/h,
release defaults with the author's GUI settings (tread prints on, decal roads off, target 70 fps),
vsync and frame limiter off, orbit camera on truck 1, runs 2-5, one session:

| | fps | low 1 % | GE Lua |
|---|---|---|---|
| Mod off | 88.7 | 84.2 | 0.57 ms |
| v0.3.0, vanilla physics | 63.7 | 51.0 | 2.65 ms |
| v0.3.0, heavy physics | 59.5 | 47.5 | 3.13 ms |
| v0.3.0, heavy, only the player's truck digs | 69.5 | 58.1 | 1.26 ms |

The pooled water and wet trenches cost about 1 fps against the code before them (same session:
59.6 -> 58.5-58.75 fps with the old road look on). Heavy physics slows the trucks in mud
(3-3.5 m/s at the end of a run against 12 m/s in vanilla), so they dig deeper ruts.

## Known issues
- Two rut lines of one truck feel like one wide rut when crossed: the terrain grid (1 m) is
  coarser than the ridge between them (0.8 m).
- The camera truck's rut front can trail its wheels by ~0.6 s in heavy mode.
- See docs/OPEN_ISSUES.md for the full list.

## Install
Download `DeepNode-v0.3.0.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
