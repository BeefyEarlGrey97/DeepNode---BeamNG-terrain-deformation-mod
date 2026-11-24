# Handoff: baked road layer, Revision B (2026-11-07)

Paste or point a new session at this file. Branch `test`, repo = this mod folder. **Not pushed.**

## Read first
- Design: `docs/superpowers/specs/2026-11-07-baked-road-layer-design.md` (see the "Revision B" section)
- Plan: `docs/superpowers/plans/2026-11-07-baked-road-layer.md` (Tasks 7–9 = Revision B)
- Ledger: `.superpowers/sdd/2026-11-07-baked-road-layer/progress.md`
- Memory: `beamng-material-named-target.md`, `beamng-deleted-texture-crash.md`

## Why Revision B
With per-tile baking, areas with many stacked decal roads (gridmap_v2 mud pit) baked while driving (+5 ms per frame from GPU readback), caused material churn, and ate VRAM (11 GB late in a session; the bench went down to 17–19 fps). What the user asked for:
- Bake **all roads at map load**, whatever the mode is, and cache the results to disk for later loads.
- Load time can be **up to 2 min** (`roads.bakeLoadMax` = 120 s). Whatever is left after that bakes in the background.
- **Only on maps up to 8×8 km** (`roads.maxMapKm2` = 68; hw550 at 8192 m = 67.1 km²). On bigger maps there is no bake, and decal roads are off (`P.roadMode()` returns 'off').

## Commits so far (branch test)
c6d9027 design/plan · 1228d1e core · f8e9a93 shaders + shadercheck · ef90536 roadBake · 072427f wiring · 8f9a502 calibration · 61f541e signature fix · fb6e5f6 Revision B design · e12b695 2 min cap + 8×8 km

## Update: Task 9 rig check + docs DONE, pushed test at 81d475d. Left: bench after a fresh game
start (copy/bake/copy/bake, 2 runs each, spawn4 now keeps the player vehicle), VRAM per mode,
BENCHMARK result log, then ask the user about the default mode.

## Current state (2026-11-07, later session): Tasks 7 + 8 DONE, Task 9 next
- f20bf02 region helpers · 627c603 region bake at map load (not pushed).
- Live gridmap_v2: 121 regions, empty cache 100.9 s / 0 failures, cache load 0.55 s, dig test OK.
- Cooked DDS 5.6 MB each (28 MB/region). /temp still holds ~2.3 GB of old per-tile cooks: clear
  `temp/deepnode_cache/roadbake/` only with the game closed.
- `tools/benchmark/gridmap_spawn4.lua` deletes the player vehicle: the player is now the user's
  fullsuv, so do not run it as is (make it skip a non-percheron player).
- REFERENCE `mode` row still says "per tile" (fix with the Task 9 docs).
- VRAM copy vs bake not measured cleanly (needs a fresh game start per variant).

## Old state: Task 7 (RED)
`tests/roadBake_test.lua` lines 78–90 hold the new tests. They fail with `regionOf (a nil value)`. Add these to `lua/ge/extensions/deepnode/roadBakeCore.lua`:
```lua
function M.regionOf(tx, ty, R) return floor(tx / R), floor(ty / R) end
function M.regionOrigin(rx, ry, R, tile, ox, oy) return ox + rx * R * tile, oy + ry * R * tile end
function M.regionKey(rx, ry) return 'r' .. rx .. '_' .. ry end
function M.mapAllowed(worldSize, maxKm2) return (worldSize / 1000) ^ 2 <= maxKm2 end
```
Run `luajit tests/roadBake_test.lua` and check for ALL OK, then run luacheck and commit "Add region helpers to the road bake core".

## Task 8: region bake at map load (roadBake.lua + main.lua)
- A region is 4×4 tiles (20 m) with 2048² images (`bakeSize` 2048). Clones are named `deepnode_rb_r<rx>_<ry>_<layer>` and shared by 16 tiles. `ready(tileKey)` and `matFor(tileKey, e)` resolve through the region.
- Map load: pause physics with `be:setPhysicsRunning(false)`, show progress with `ui_message(text, secs, cat)`, run one step per frame, stop at 120 s, then continue in the background at `bakeMaxPerSec` regions per second, then resume physics.
- The bake runs in every mode. A map with `(ter.worldSize/1000)^2 > 68` gets no bake and the road mode is 'off'.
- Cache files are `r<rx>_<ry>_<sig>_*.png`. Cook them without keeping ImGui handles, to save VRAM.
- Update `settings/deepnode/config.json` and `docs/REFERENCE.md` (CRLF) with the new keys.
- Live checks: load time with an empty cache, a second load from cache, a dig test, and VRAM in copy vs bake.

## Task 9
- Rig calibration check at 5% gates (`tools/dev/roadbake_rig.lua`, `roadbake_compare.py`).
- Bench **after a fresh game start**: 4 trucks, copy/bake/copy/bake, 2 runs each. If bake wins, also run 8 trucks.
- Docs: CHANGELOG, BENCHMARK, OPEN_ISSUES, README, ENGINE_FINDINGS.
- Do a whole-branch review, then push `test`. **Ask the user before changing the default mode.**

## Hard rules
- Stage only my own hunks. Another session's WIP is uncommitted in `docs/ENGINE_FINDINGS.md`, `docs/REFERENCE.md`, `main.lua`, `roadCopy.lua` and `tileMesh.lua`. Replay my edits onto the HEAD content (scratchpad `stage_head.py` used `git hash-object -w` + `git update-index --cacheinfo`), because `git add -p` doesn't work here.
- **Never delete cache PNG/DDS files while the game runs (it crashes).** `sweepCache()` runs only at start.
- The signature uses plan geometry only (corners and width to 1 cm), never v.
- Lower renderPriority draws on top (`bakeHighOnTop = false`).
- Never trade visuals for fps. Run every bench variant twice, interleaved. Don't delete the user's vehicles (use our own spawn script).
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- `tests/gui_tabs_test.lua` was already failing (ImGui stub). Not ours.

## Key engine facts
- Saving a target to PNG: `require('screenshot').createScreenshotTracked{filename=..., bufferType='<target without #>', superSampling=1}`. Wait until the file size stops changing, then call `clearScreenshotJobs()`.
- Cook at once with `ui_imgui.ImTextureHandler(path)`. Files written by outside processes are invisible to the VFS.
- Detail-only layer: colour = saturate(2·detail), so the images store value/2. Mud UV = terrain UV (ox = oy = −1023.5 on gridmap_v2).
- Leftover state: 4 bench Percherons are still in the game, and the user's fullsuv is untouched. Vsync and the fps limit are off.
