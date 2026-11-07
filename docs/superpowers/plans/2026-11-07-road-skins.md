# Road Skins (one decal road system) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw the baked decal roads on undug ground with one see-through mesh per region, hide the level's DecalRoads on soft ground, and remove the copy / overlay / drape road modes.

**Architecture:** New GE extension `deepnode_roadSkin` builds one ProceduralMesh per baked region from road-quad squares (pure helpers in `roadBakeCore`), hides each soft-ground DecalRoad once all its regions have skins, and rebuilds a region's skin when its tiles' mesh state changes (polled). `main.roadMode()` returns only `'bake'` or `'off'`; roadCopy.lua and decals.lua are deleted.

**Tech Stack:** BeamNG GE Lua (LuaJIT), ProceduralMesh, Material; offline tests with LuaJIT; live checks through the in-game MCP (`~/.claude/skills/beamng-deepnode-dev/scripts`).

**Spec:** `docs/superpowers/specs/2026-11-07-road-skins-design.md`

## Global Constraints
- Skin material: `baseColorMap` b, `baseColorFactor` `2 2 2 1`, `opacityMap` o, `opacityFactor` `2`, `normalMap` nm, `roughnessMap` r, `roughnessFactor` `2`, `metallicMap` m, `metallicFactor` `2`, `translucent` `1`, `translucentZWrite` `0`, `translucentBlendOp` `LerpAlpha`, `castShadows` `0`, `activeLayers` `1`.
- Skin mesh UV = `main.uvOf(x, y, e)` times the region mapping (`u * map.sx`, `v * map.sy`); `e` and `map` as roadBake's `prepare` (layer at the region centre, `C.tileMapping(uvOf, e, x0, y0, 4 * tileSize)`).
- createMesh faces are 0-based `{ v = i, n = i, u = i }`; never pass malformed face tables (crashes the game).
- A Material once drawn keeps its compiled shader: material names carry a version (`deepnode_rs<VERSION>_<rk>`); never delete a Material a mesh may reference during a session.
- Never delete cache images while the game runs.
- New config keys: `roads.skinLift` 0.004 (m), `roads.skinRebuildPerSec` 2.
- Default `roads.mode` stays `'off'` (ask the user before changing it).
- Docs, comments, commits in plain English; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Benches: gridmap_v2, `bench2.py <label> 2 clear`, compare run 2, interleave variants, after a fresh game start.

## Review Focus
1. A road crossing a region that never gets ready (no quads, failed bake): the road must stay visible → Task 2 test `road hidden only when all regions skinned`.
2. Mode switched off live (GUI): skins hidden, every hidden road shown again; switched on: roads hidden again as their regions are skinned → Task 3 live step.
3. A tile dug inside a skinned region: its squares leave the skin within 1 s, no skin square over a rut → Task 2 live dig step.
4. `stop()` / level change / Lua reload: no `deepnode_rs*` meshes left, every DecalRoad the mod hid is shown → Task 2 live step.
5. Old user configs with `roads.mode` `copy` / `overlay` / `drape` → treated as `'bake'` → Task 3 Step 4 (live; main is not loadable offline).

---

### Task 1: Pure skin helpers in roadBakeCore

**Files:**
- Modify: `lua/ge/extensions/deepnode/roadBakeCore.lua`
- Test: `tests/roadBake_test.lua`

**Interfaces:**
- Produces:
  - `C.quadSquares(q, ox, oy, sq, out) -> out` — q = `{ ax, ay, bx, by, cx, cy, dx, dy }` (a convex quad, any winding); adds every terrain square `(gx, gy)` whose cell `[ox + gx*sq, ox + (gx+1)*sq] x [oy + gy*sq, ...]` overlaps the quad polygon (separating-axis test, touching edges do not count) to `out[gy * 1000003 + gx] = { gx, gy }`; returns `out`.
  - `C.skinFields(files) -> { { field, value }, ... }` — the Global Constraints material list, layer 0.
  - `C.roadRegions(edges, ox, oy, tileSize, R) -> { [rk] = true }` — regions (keys from `C.regionKey`) touched by any quad between consecutive edge pairs of a flat `{ lx, ly, rx, ry, ... }` list (bounding box of each quad).

- [ ] **Step 1: Write the failing tests** (append before the final print)
```lua
local sqs = C.quadSquares({ 0.2, 0.2, 2.8, 0.2, 2.8, 0.8, 0.2, 0.8 }, 0, 0, 1, {})
local n = 0; for _ in pairs(sqs) do n = n + 1 end
expect(n == 3 and sqs[0] and sqs[1] and sqs[2], 'quad_squares_strip')
local diag = C.quadSquares({ 0, 0, 0.1, 0, 3, 2.9, 2.9, 3 }, 0, 0, 1, {})
local nd = 0; for _ in pairs(diag) do nd = nd + 1 end
expect(nd <= 7 and diag[0] and diag[1000003 + 1] and not diag[2 * 1000003], 'quad_squares_diagonal_not_bbox')
expect(next(C.quadSquares({ 5, 5, 6, 5, 6, 6, 5, 6 }, 0, 0, 1, {})) ~= nil, 'quad_squares_offgrid_origin')
local sf = {}; for _, f in ipairs(C.skinFields(cp)) do sf[f[1]] = f[2] end
expect(sf.baseColorMap == cp.b and sf.opacityMap == cp.o and sf.baseColorFactor == '2 2 2 1' and sf.translucentZWrite == '0', 'skin_fields')
local rr = C.roadRegions({ 1, 1, 1, 3, 41, 1, 41, 3 }, 0, 0, 5, 4)
expect(rr['r0_0'] and rr['r2_0'] and rr['r1_0'], 'road_regions_span')
```
(`cp` is the existing cachePaths table in the test file.)

- [ ] **Step 2: Run** `"$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" tests/roadBake_test.lua` — Expected: FAIL `quadSquares (a nil value)`.
- [ ] **Step 3: Implement the three functions** in roadBakeCore.lua (SAT over the quad's 4 edge normals + the 2 cell axes; candidate cells from the quad bounding box).
- [ ] **Step 4: Run the test** — Expected: `ALL OK`; `bash tools/dev/luacheck.sh` clean.
- [ ] **Step 5: Commit** `Add road skin helpers to the road bake core`.

### Task 2: deepnode_roadSkin module

**Files:**
- Create: `lua/ge/extensions/deepnode/roadSkin.lua`
- Modify: `lua/ge/extensions/deepnode/roadBake.lua` (expose region data + road regions), `lua/ge/extensions/deepnode/main.lua` (load the module, start/stop it with roadBake, config defaults), `settings/deepnode/config.json`, `docs/REFERENCE.md`

**Interfaces:**
- Consumes: Task 1 helpers; roadBake `M.region(rk) -> { x0, y0, S, e, map, files, state }` or nil (new), `M.regionKeys() -> { rk, ... }` (new), roads list `M.roads() -> { { obj = DecalRoad, regions = { [rk] = true } }, ... }` (new: roadBake already reads the edges in `addRoad`; store the road object and its regions there).
- Produces: `deepnode_roadSkin.start(main)`, `.stop()`, `.onUpdate()` (extension hook), `.stats() -> { skins, squares, hiddenRoads, rebuilds }`, `.setShown(on)`.

Behaviour:
- Each frame (budget: one region build, never in a frame where `tileMesh.uploadsThisFrame() > 0`, at most `roads.skinRebuildPerSec` a second): build the next ready region without a skin, else the next dirty one.
- Build: squares = union of `C.quadSquares` over every road quad of the region (roadBake's clipped quads `C.tileQuads(road, x0, y0, S, 0.3)`, corners a b c d = items 1-8), minus squares of tiles (`main.tiles[k]`) that have `t.obj` or `t.rutted`; z = rest surface + `roads.skinLift` (terrain height in terrain-first mode; where the terrain is sunk add the sink lift: see `P.sinkLift` in main); one submesh, material `deepnode_rs<VERSION>_<rk>` with `C.skinFields`; ProceduralMesh `deepnode_rsMesh_<rk>`, `canSave = false`. Zero squares: delete the mesh, keep the region marked skinned.
- Poll every 0.5 s: per skinned region a string of its tiles' `obj`/`rutted` state; changed → dirty.
- Hide: a road is hidden (`setHidden(true)`, remembered) once every region in its `regions` has a skin; `stop()` and `setShown(false)` show every road it hid and hide/delete its meshes.

- [ ] **Step 1: roadBake accessors** — add `M.region`, `M.regionKeys`, `M.roads`; record `obj` and `regions` per road in `addRoad` (regions = keys added to `seenR`). Luacheck.
- [ ] **Step 2: Write roadSkin.lua** per the behaviour above; main loads `'roadSkin'` after `'roadBake'` in its module list and calls `start(M)` where roadBake starts (mode `'bake'` only) and `stop()` in `P.stop`.
- [ ] **Step 3: Config** — defaults + config.json + REFERENCE rows for `skinLift`, `skinRebuildPerSec`.
- [ ] **Step 4: Luacheck + offline tests** — `bash tools/dev/luacheck.sh` clean, roadBake_test ALL OK.
- [ ] **Step 5: Live (gridmap_v2, mode bake)** — `reload_lua`, `deepnode_main.reloadLevelData()`; expected: `stats().skins` ≈ 115-121, every soft-ground road hidden after the load phase, a screenshot of the pit view (cam `-323 -276 103.5` → `-329.5 -287 100.3`) shows roads, no grey squares.
- [ ] **Step 6: Live dig** — spawn one Percheron with the scratch script (never delete the player's vehicle), drive 25 m south from `(-329.17, -269.52)`; expected: no skin square over the new ruts after 1 s, roads visible in the ruts (tile material), `stats().rebuilds` small (≤ 2 per dug region).
- [ ] **Step 7: Live stop** — `deepnode_main.stop()` then `start`: no `deepnode_rsMesh_*` objects after stop, all DecalRoads visible.
- [ ] **Step 8: Commit** `Draw baked roads on undug ground with road skins`.

### Task 3: Remove the copy, overlay and drape road modes

**Files:**
- Delete: `lua/ge/extensions/deepnode/roadCopy.lua`, `lua/ge/extensions/deepnode/decals.lua`
- Modify: `main.lua` (roads defaults, `P.roadMode`, `M.setDecalRoads(on)`, `M.decalRoadsOn`, remove `P.collectMudRoads` / `P.drapeRoads` / `P.finishDrape` / `M.redrapeRoads` / `P.decalQuiet` copy branches, module list, region shift block, start/stop blocks), `tileMesh.lua` (copy + decal emission and `decalMod` / `roadCopy.isMat` size classes; keep `rbk.ready` / `prioritize`), `farMesh.lua:299-322` (decal + copy emission), `gui.lua:425-450` (one checkbox "Decal roads on the mud"; any "Redrape roads" button goes), `settings/deepnode/config.json`, `docs/REFERENCE.md`, `tools/dev` scripts that reference removed functions (grep).

**Interfaces:**
- Produces: `P.roadMode() -> 'bake' | 'off'` (`roads.mode` `'off'` or roads disabled or map too big → `'off'`; anything else → `'bake'`); `M.setDecalRoads(on: boolean)`; `M.decalRoadsOn() -> boolean`. `M.roadBakeOn()` stays (= `decalRoadsOn`).

- [ ] **Step 1: Delete and unhook** — remove the files and every reference (`grep -rn "roadCopy\|deepnode_decals\|drape\|overObjects\|overlayQuiet\|copyLift\|copyEvery\|copyCut\|copyFade" lua tools settings`); in mode `'off'` `P.coverRoads(true)` still hides soft-ground roads; in mode `'bake'` roadSkin hides them.
- [ ] **Step 2: Config + REFERENCE** — drop the removed keys; `mode` row: `'bake'` | `'off'`, old values read as `'bake'`.
- [ ] **Step 3: Luacheck + offline tests** — clean / ALL OK; `tests/gui_tabs_test.lua` keeps its old failure only.
- [ ] **Step 4: Live** — reload; GUI checkbox off → skins gone, roads over soft ground hidden (mode off behaviour), on → skins back; a gui.json with `"mode": "copy"` loads as bake (log line `road mode bake`); no Lua errors in the log (`get_log` / console).
- [ ] **Step 5: Commit** `Merge decal road options into the baked layer`.

### Task 4: Skin look, bench, docs

**Files:**
- Modify: `roadSkin.lua` (material constants only, if the calibration needs it), `tools/dev/roadbake_rig.lua` (a `skin` command comparing skin vs vanilla), `docs/ENGINE_FINDINGS.md`, `docs/BENCHMARK.md`, `docs/OPEN_ISSUES.md` (§24, §23 closed), `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Calibrate** — rig on undug pit tile 8913037 at 6 m and 3 m: skin vs vanilla mean and luminance std within 5 %. Try in order, re-measuring each: `translucentRecvShadows`, roughness/metallic factors 1 vs 2, normal strength 0.5. Keep the first variant inside the gate; record numbers in ENGINE_FINDINGS.
- [ ] **Step 2: Bench after a fresh game start** — 4 trucks (`gridmap_spawn4.lua`), mode off / bake / off / bake, 2 runs each; VRAM per variant (`deepnode_main.stats().perf.vramMB`); if bake gains, 8 trucks too. Log in BENCHMARK.
- [ ] **Step 3: Docs** — CHANGELOG (Removed: copy / overlay / drape modes; Added: road skins), README features + open issues, OPEN_ISSUES.
- [ ] **Step 4: Whole-branch review, push `test`**, ask the user about the default mode.
