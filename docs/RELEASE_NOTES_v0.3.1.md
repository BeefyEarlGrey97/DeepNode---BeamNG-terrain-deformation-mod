# DeepNode v0.3.1 — big maps: trees, grass and frame rate fixed (2026-11-01)

## Fixed
- **Trees and grass thinned out on big maps, frame rate under 25 fps** (seen on hw550). In heavy
  physics the mod gave every groundcover smaller cells, also the tree covers that reach 1500 m and
  3800 m: they went from 10 / 20 to 300 / 760 cells per side, so most trees on the slopes and the
  far grass disappeared, and the shadow pass grew to 20 ms as you drove. Only covers up to 150 m
  radius get smaller cells now (`grass.maxRadius`, at most `grass.maxGrid` 32 cells per side).
  hw550, same view: Render 23.2 -> 10.2 ms, shadows 20.0 -> 0.79 ms (mod off: 10.0 / 0.79 ms);
  forests and grass as without the mod.
- **Fewer hitches while digging on big terrains.** Every rut-floor terrain update costs the
  engine 15-78 ms on an 8192 x 8192 terrain like hw550 (1-2.5 ms on gridmap_v2), whatever the
  area. When updates are that slow, the mod now writes the floor at most every 2 s, all at once
  (`physics.heavy.slowUpdateMs` / `slowUpdateGap`): 90 s of digging in hw550 mud 70 -> ~30
  updates.

## Known issues
- On big terrains a new rut can take up to 2 s to show in heavy physics, and each floor update
  is still a short hitch (~15 ms). Vanilla physics writes no terrain while driving.
- Maps with small groundcovers (gridmap_v2, 45-100 m) are unchanged.
- See docs/OPEN_ISSUES.md for the full list.

## Install
Download `DeepNode-v0.3.1.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip first.
