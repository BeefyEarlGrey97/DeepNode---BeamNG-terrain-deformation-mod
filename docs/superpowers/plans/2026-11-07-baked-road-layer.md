# Baked Road Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `roads.mode = 'bake'`: decal roads over dug mud drawn by a per-tile baked layer in the tile's own mud material instead of copy submeshes, with copies as fallback until a tile's bake is loaded.

**Architecture:** A pure core (`roadBakeCore.lua`, offline-tested) computes tile mappings, road quads, draw order, signatures, cache paths, queue order and material layer fields. An engine module (`roadBake.lua`) runs a GPU bake per tile with PostEffects (one effect pair per road material, ping-pong accumulators, one material per frame), saves five PNGs via named-buffer screenshots, waits for the engine's DDS cook, then creates a per-tile mud material clone with one detail-only layer. tileMesh asks `main.tileMatName(t, m)` for each layer's material and skips copy emission on ready tiles.

**Tech Stack:** BeamNG GE Lua (LuaJIT 2.1), HLSL PostEffects (D3D12, `pixVersion 5.0`), BeamNG MCP (`127.0.0.1:29292/mcp`, skill `beamng-deepnode-dev` scripts `lua.py`, `mcp.py`, `cam.py`, `bench2.py`).

**Spec:** `docs/superpowers/specs/2026-11-07-baked-road-layer-design.md`

## Global Constraints

- Work on branch `test`. The working tree holds another session's uncommitted changes (`docs/ENGINE_FINDINGS.md`, `docs/REFERENCE.md`, `main.lua`, `roadCopy.lua`, `tileMesh.lua`): never `git add -A`; stage only the hunks/files a task changed (`git add -p` for shared files). Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `bash tools/dev/luacheck.sh` passes after every task (only global write allowed: `castRayStatic`; PostEffect callback tables via `rawset(_G, name .. 'Callbacks', {...})`, never plain global assignment).
- Offline tests: `for t in tests/*_test.lua; do luajit $t || echo FAIL $t; done` all pass.
- Shaders: compile offline with Windows SDK dxc before loading (`ps_6_0`/`vs_6_0`, `-D SHADER_STAGE_PS=1` / `VS`, include tree = game `shaders/common` + mod shaders); PostEffect shader compile failures are silent in game. ShaderData names carry the source revision (overlay.lua `sourceRev` pattern); toggle effects with `skip`, never `disable()`.
- Never call `createMesh` with face tables that were not built by tileMesh's Builder (malformed tables crash the game).
- `'copy'` stays the default `roads.mode`; `'bake'` is opt-in until Task 6's bench and look check pass.
- Config defaults (spec): `roads.bakeSize` 512, `roads.bakeRadius` 300, `roads.bakeMaxPerSec` 10, `roads.bakeCache` true, `roads.bakeHighOnTop` set by Task 5.
- Cache dir: `deepnode_cache/roadbake/<level>/` (user folder, written by the game only). File names `<tileKey>_<sig>_b.color.png`, `_o.data.png`, `_nm.normal.png`, `_r.data.png`, `_m.data.png`.
- Detail images store value/2 (layer maths: colour = saturate(2·detail), opacity = saturate(2·r), roughness/metallic = factor·saturate(2·x)); colour image is sRGB-encoded C/2 in a `.color` file.
- Benches: gridmap_v2, `python -I bench2.py <label> 2 clear`, compare run 2, interleave variants; vsync + fps limit off during benches, restore after (user keeps vsync on, fpsLimit 60). Never bench while another session uses the game or edits the repo.
- Docs, comments and commits in plain English (no caveman style).

## Review Focus

1. Level with no DecalRoads over soft ground (or `roadCopy` finds 0 road tiles): bake mode starts, queues nothing, logs one line, no effects created, no errors. → Task 3 Step 6.
2. One material with more than 64 quads over a tile (gridmap_v2 pit stacks ~30 roads): the material is baked in several steps, none dropped. → Task 1 test `groups_split_at_64`.
3. Mud material already using 4 layers: no clone, tile keeps copies (never a broken material). → Task 1 test `layer_fields_full_material`; Task 3 Step 6.
4. `stop()` / Lua reload / level change during a bake (screenshots pending, cook pending, clones alive): no leftover `dnrb_*` PostEffects or `deepnode_rb_*` materials, tiles rebuilt with plain material names. → Task 3 Step 6, Task 4 Step 5.
5. Changed roads with an old cache: signature mismatch rebakes the tile and deletes its old files; unchanged roads load from cache with no GPU work. → Task 1 test `signature_changes_with_roads`; Task 4 Step 5.

---

### Task 1: Pure core (`roadBakeCore.lua`) with offline tests

**Files:**
- Create: `lua/ge/extensions/deepnode/roadBakeCore.lua`
- Test: `tests/roadBake_test.lua`

**Interfaces:**
- Consumes: nothing (no engine globals at load or call time; `uvOf` passed in).
- Produces (module table `C`, loaded in game as `extensions.deepnode_roadBakeCore` or `require('ge/extensions/deepnode/roadBakeCore')`, offline via `dofile`):
  - `C.tileMapping(uvOf, e, x0, y0, size) -> { sx, sy, cu, su, cv, sv }` — `u0,v0 = uvOf(x0,y0,e)`, `u1,v1 = uvOf(x0+size,y0+size,e)`; `sx = 1/|u1-u0|`, `sy = 1/|v1-v0|`, `su = sign(u1-u0)`, `sv = sign(v1-v0)`, `cu = (u0*sx) % 1`, `cv = (v0*sy) % 1`.
  - `C.tileQuads(road, x0, y0, size, margin) -> { {ax,ay,bx,by,dx,dy,cx,cy,v0,v1,w}, ... }` — `road = { L = {{x,y,z},...}, R = {...}, D = {dist,...}, tl = textureLength }`; quad i = (L[i], R[i], R[i+1], L[i+1]), `v = -D/tl`, `w` = mean of |R[i]-L[i]| and |R[i+1]-L[i+1]|; kept when its bbox overlaps the tile grown by `margin`.
  - `C.drawGroups(roads, highOnTop, maxQuads) -> { {mat, tl, quads = {...}, roadIdx = {...}}, ... }` — roads `{ id, mat, prio, tl, quads }`; sort: `highOnTop` → ascending prio (higher drawn later = on top), else descending; ties by `id` ascending; consecutive roads with the same `mat` and `tl` share a group; a group never exceeds `maxQuads` (64) quads (start a new group with the same mat); each quad keeps its road index (shader skips a road's second hit).
  - `C.signature(roads, params) -> string` — 8 hex chars, FNV-1a 32 over a canonical string of `params.version, params.size, params.highOnTop` and per road (in `drawGroups` order) `mat|prio|tl|` + quad coordinates rounded to 1 mm.
  - `C.cachePaths(level, key, sig) -> { dir, b, o, nm, r, m }` — `dir = '/deepnode_cache/roadbake/' .. level .. '/'`, files per Global Constraints.
  - `C.queueOrder(tiles, points, radius) -> { key, ... }` — `tiles = { [key] = {cx, cy} }`, `points = { {x,y}, ... }`; keep tiles within `radius` of any point, nearest first, ties by key.
  - `C.layerFields(activeLayers, files, map) -> list | nil` — nil when `activeLayers >= 4`; else `{ {field, layer, value}, ... }` for layer `L = activeLayers`: `activeLayers` (layer 0) = L+1; on L: `baseColorFactor '1 1 1 1'`, `opacityFactor '1'`, `roughnessFactor '1'`, `metallicFactor '1'`, `detailMap`=b, `detailBaseColorMapStrength '1'`, `opacityDetailMap`=o, `detailOpacityMapStrength '1'`, `detailNormalMap`=nm, `detailNormalMapStrength '1'`, `roughnessDetailMap`=r, `detailRoughnessMapStrength '1'`, `metallicDetailMap`=m, `detailMetallicMapStrength '1'`, `detailScale` = `('%.6f %.6f'):format(map.sx, map.sy)`.

- [ ] **Step 1: Write the failing tests** in `tests/roadBake_test.lua` (header and `expect` helper as in `tests/materials_test.lua`; `local C = dofile('lua/ge/extensions/deepnode/roadBakeCore.lua')`):

```lua
-- gridmap_v2 tile 9175179: uvOf base mode (ox,oy = -1023.5, size 2048, flipV); the spike measured cu 0, cv 0.6
local function uvOf(x, y) return (x + 1023.5) / 2048, 1 - (y + 1023.5) / 2048 end
local m = C.tileMapping(uvOf, 2, -328.5, -323.5, 5)
expect(math.abs(m.sx - 409.6) < 1e-6 and math.abs(m.sy - 409.6) < 1e-6, 'mapping_scale')
expect(m.su == 1 and m.sv == -1, 'mapping_signs')
expect(math.abs(m.cu - 0.0) < 1e-6 and math.abs(m.cv - 0.6) < 1e-6, 'mapping_offsets')

-- straight road along +y, 4 m wide, edges every 2 m, texLen 10
local road = { L = {}, R = {}, D = {}, tl = 10 }
for i = 0, 5 do road.L[i+1] = {x=-2, y=i*2, z=0}; road.R[i+1] = {x=2, y=i*2, z=0}; road.D[i+1] = i*2 end
local q = C.tileQuads(road, -1, 3, 5, 0.3)  -- tile y 3..8 (+0.3): quads 1..4 overlap
expect(#q == 4, 'quads_clip_count')
expect(q[1][9] == -0.2 and q[1][10] == -0.4 and q[1][11] == 4, 'quads_v_and_width')

-- draw order + grouping
local rs = { {id=1, mat='water', prio=19, tl=10, quads={1}}, {id=2, mat='large', prio=18, tl=10, quads={2}},
             {id=3, mat='furrow', prio=6, tl=10, quads={3}}, {id=4, mat='furrow', prio=8, tl=10, quads={4}} }
local g = C.drawGroups(rs, true, 64)
expect(g[1].mat == 'furrow' and #g[1].quads == 2 and g[#g].mat == 'water', 'groups_high_on_top')
g = C.drawGroups(rs, false, 64)
expect(g[1].mat == 'water' and g[#g].mat == 'furrow', 'groups_low_on_top')
local many = {}; for i = 1, 70 do many[i] = i end
g = C.drawGroups({ {id=1, mat='a', prio=1, tl=10, quads=many} }, true, 64)
expect(#g == 2 and #g[1].quads == 64 and #g[2].quads == 6, 'groups_split_at_64')

-- signature
local p = { version = 1, size = 512, highOnTop = true }
local s1 = C.signature(rs, p)
expect(#s1 == 8 and s1 == C.signature(rs, p), 'signature_stable')
rs[1].prio = 20
expect(C.signature(rs, p) ~= s1, 'signature_changes_with_roads')

-- cache paths
local cp = C.cachePaths('gridmap_v2', 9175179, 'a1b2c3d4')
expect(cp.b == '/deepnode_cache/roadbake/gridmap_v2/9175179_a1b2c3d4_b.color.png', 'cache_color_name')
expect(cp.nm == '/deepnode_cache/roadbake/gridmap_v2/9175179_a1b2c3d4_nm.normal.png', 'cache_normal_name')

-- queue
local qo = C.queueOrder({ [1] = {0, 0}, [2] = {50, 0}, [3] = {400, 0} }, { {45, 0} }, 300)
expect(#qo == 2 and qo[1] == 2 and qo[2] == 1, 'queue_nearest_first_within_radius')

-- layer fields
local lf = C.layerFields(2, cp, m)
local by = {}; for _, f in ipairs(lf) do by[f[1] .. '@' .. f[2]] = f[3] end
expect(by['activeLayers@0'] == '3' and by['detailMap@2'] == cp.b and by['detailScale@2'] == '409.600000 409.600000', 'layer_fields_layer2')
expect(C.layerFields(4, cp, m) == nil, 'layer_fields_full_material')

print(fails == 0 and 'ALL OK' or (fails .. ' FAILED')); os.exit(fails == 0 and 0 or 1)
```

- [ ] **Step 2: Run to verify it fails**
Run: `luajit tests/roadBake_test.lua` — Expected: error `cannot open lua/ge/extensions/deepnode/roadBakeCore.lua`.

- [ ] **Step 3: Implement `roadBakeCore.lua`** with the functions and contracts in Interfaces (pure Lua, `bit` library for FNV-1a, `string.format('%08x', ...)`; module ends with `M.onExtensionLoaded = function() setExtensionUnloadMode(M, 'manual') end` guarded by `if setExtensionUnloadMode` so offline loading works).

- [ ] **Step 4: Run tests** — `luajit tests/roadBake_test.lua` → `ALL OK`; `bash tools/dev/luacheck.sh` → no FAIL, no new global writes.

- [ ] **Step 5: Commit** — `git add lua/ge/extensions/deepnode/roadBakeCore.lua tests/roadBake_test.lua` → "Add pure core for baked road layers".

---

### Task 2: Bake and resolve shaders

**Files:**
- Create: `shaders/common/postFx/deepnode/roadBakeP.hlsl`, `shaders/common/postFx/deepnode/roadBakeResolveP.hlsl`
- Create: `tools/dev/shadercheck.sh` (dxc compile of every `shaders/common/postFx/deepnode/*.hlsl`, PS and VS, against a temp tree of the game's `shaders/common` + mod shaders; exit 1 on any error)

**Interfaces:**
- Consumes: spike shaders (session scratchpad `sh/bakeP.hlsl`, `sh/resolveP.hlsl`; logic summarised here, re-derive if gone).
- Produces (constants and slots Task 3 sets):
  - `roadBakeP.hlsl`: slots 0 colour map, 1 opacity map, 2 normal map, 3 roughness map, 4 previous accumulator (point). cbuffer: `dnTile` (x0, y0, size, bakeSize), `dnMap` (cu, su, cv, sv), `dnMat` (tint rgb, opacity factor), `dnMat2` (alphaRef or −1, normal strength, roughness factor, metallic factor), `dnMat3` (texel m, textureLength, flipTangent x sign, flipTangent y sign — calibration knobs, default 1, 1), `dnCtl` (quad count, output 0 = A / 1 = B, has opacity map, clear), `dnP0..63`, `dnQ0..63`, `dnV0..63` (left0 xy right0 xy; left1 xy right1 xy; v0, v1, road index, width).
  - Output A = premultiplied colour (linear) + accumulated opacity; output B = premultiplied (normal.xy·0.5+0.5, roughness, metallic). Both "over": `acc = c·a + acc·(1−a)`, alpha `a + A·(1−a)` (B carries metallic in alpha, weighted the same way; opacity lives only in A).
  - Pixel → world: `tc = (px + 0.5) / bakeSize`, `p = (x0, y0) + size · (frac((tc.x − cu)·su), frac((tc.y − cv)·sv))`; road normal → tile tangent frame: `w = n.x·right + n.y·(−forward)`, `nt = (w.x·su·dnMat3.z, w.y·sv·dnMat3.w)`; mip level `log2(max(texel·texW/width, texel·texH/textureLength))`.
  - `roadBakeResolveP.hlsl`: slots 0 = A, 1 = B; `dnCtl.x` mode 0 colour `sRGB(C/A/2)`, 1 opacity `A/2`, 2 normal (decode `(B.rg − 0.5A)/A·2`, encode x, −y, z), 3 roughness `B.b/A/2`, 4 metallic `B.a/A/2` (grey RGB, alpha 1).
  - A copy pass: reuse `rutCopyP.hlsl` (Load-copy slot 0) for ping-pong.

- [ ] **Step 1: Write `tools/dev/shadercheck.sh`** and run it on the existing shaders — Expected: all existing `deepnode/*.hlsl` OK (proves the script).
- [ ] **Step 2: Write both shaders** per Interfaces.
- [ ] **Step 3: Run `bash tools/dev/shadercheck.sh`** — Expected: roadBakeP and roadBakeResolveP PS/VS rc=0.
- [ ] **Step 4: Commit** — shaders + script → "Add road bake shaders and an offline shader check".

---

### Task 3: Engine module `roadBake.lua` (bake, cache, cook, clones)

**Files:**
- Create: `lua/ge/extensions/deepnode/roadBake.lua`
- Create: `tools/dev/roadbake_probe.lua` (MCP probe: bakes one given tile key and prints state transitions, file paths, ms)

**Interfaces:**
- Consumes: Task 1 `C.*`; Task 2 shaders; `roadCopy`: add `M.roadTiles() -> { [key] = { road, ... } }` and `M.roadEdges(road) -> {L, R, D, tl, mat, prio, id}` (roadCopy already reads edges in `addRoad`; keep the arrays on the road record); `main`: `tiles`, `matName(e)`, `uvOf(x,y,e)`, `mudLayerAt`, `getVehicleCenters()`, `cfg.roads`, `private.levelName`, `mod('tileMesh').reserveFrame / uploadsThisFrame`.
- Produces:
  - `M.start(main)`, `M.stop()`, `M.update(dtSim)` (called once per frame by main), `M.isEnabled()`.
  - `M.ready(key) -> bool` — baked, cooked, clones built.
  - `M.matFor(key, e) -> string | nil` — clone name `deepnode_rb_<key>_<e>` when ready.
  - `M.prioritize(key)` — move to the front of the queue (tile meshed while unbaked).
  - `M.onTileMesh(key, hasMesh)` — create clones when a ready tile gets a mesh; delete them when it loses it.
  - `M.stats() -> { queued, baking, baked, cooking, ready, fallback, bakeMs, lastError }`.
  - Callback to main when a tile becomes ready: `main.onRoadBakeReady(key)` (main marks the tile dirty).
- Per-tile state machine (one active tile at a time): `queued → steps (clear, then one material group per frame for outputs A and B, each followed by its copy-back pass) → resolve (5 targets) → saving (5 screenshots; done when all five PNGs exist via FS:fileExists) → cooking (poll `/temp` + path with `.png → .dds` for all five) → baked`; then `ready` once clones exist for a meshed tile. Cache hit at `start`/enqueue (all five files with current sig) jumps to `cooking`. Effects: per road material `dnrb_m<i>_A`, `dnrb_m<i>_B` (textures fixed at creation), copies `dnrb_cpA`, `dnrb_cpB`, resolves `dnrb_res0..4`; targets `#dnrb_A`, `#dnrb_At`, `#dnrb_B`, `#dnrb_Bt` (RGBA16F), `#dnrb_out0..4` (RGBA8), all `bakeSize²`, `renderTime PFXBeforeBin`, `renderBin ObjTranslucentBin`. Constants pushed from the `setShaderConsts` callback.
- Budget: at most one bake step per frame; no step when `tileMesh.uploadsThisFrame() > 0`; at most `bakeMaxPerSec` tiles started per second.

- [ ] **Step 1: Add `roadTiles()` / `roadEdges()` to roadCopy** (stage only these hunks). `luajit` compile via luacheck.
- [ ] **Step 2: Write `roadBake.lua`** per Interfaces (cache dir created by the screenshot writer; old files of a tile with another sig removed with `FS:removeFile` after the new five are saved).
- [ ] **Step 3: luacheck + offline tests** — all OK.
- [ ] **Step 4: Live, one tile** — game on gridmap_v2, mod running, `reload_lua`, then `python -I lua.py tools/dev/roadbake_probe.lua` with a pit tile key (e.g. 9175179). Expected: transitions queued → … → baked in < 2 s plus cook, five files under `deepnode_cache/roadbake/gridmap_v2/`, `/temp/...dds` present, no `dnrb` errors in beamng.log.
- [ ] **Step 5: Live, cache hit** — run the probe again: Expected: jumps to cooking/baked with no steps, bakeMs 0.
- [ ] **Step 6: Live, edge cases** — (a) `M.stop()` while a tile is in `steps`: no `dnrb_*` PostEffect or `deepnode_rb_*` material left (`scenetree.findClassObjects`); (b) probe a tile key with no roads: no effects created, state stays idle; (c) call `M.matFor` on a tile whose mud material reports 4 active layers (temporarily set on a clone in the probe): returns nil, stats.fallback increments.
- [ ] **Step 7: Commit** — roadBake.lua, probe, roadCopy hunks → "Bake decal roads per tile into PNG layers (roadBake)".

---

### Task 4: Wire `roads.mode 'bake'` into main, tileMesh and the GUI

**Files:**
- Modify: `lua/ge/extensions/deepnode/main.lua` (`P.roadMode` ~1722, `P.loadSubModules` ~7096 list, start ~7209 / stop ~7283, per-frame update, tile mesh release sites `P.dropTile` ~3333, ~4454–4583, ~4650, config defaults in `cfg.roads` ~141)
- Modify: `lua/ge/extensions/deepnode/tileMesh.lua` (4 `b:sub(main.matName(m), ...)` sites ~1007/1077/1138/1206; copy emission ~1290–1316)
- Modify: `lua/ge/extensions/deepnode/gui.lua` (decal-road mode selector gets "Bake"; Debug tab line with `roadBake.stats()`)
- Modify: `settings/deepnode/config.json` (bake keys), `docs/REFERENCE.md` (keys table rows from the spec)

**Interfaces:**
- Consumes: Task 3 `M.*`.
- Produces: `main.tileMatName(t, m) -> string` (`rb.matFor(t.key, m)` or `main.matName(m)`); `main.onRoadBakeReady(key)` (sets `t.dirty = true; t.decalForce = true` when the tile exists); `P.roadMode()` returns `'bake'` for `cfg.roads.mode == 'bake'` (roadCopy also starts in bake mode); `M.decalRoadsOn()` true for `'bake'`.
- tileMesh: at the copy emission, `if rb and rb.ready(t.key) then copyOut = {} else <existing copy path> end`; when a tile with roads builds a mesh while not ready, call `rb.prioritize(t.key)`.

- [ ] **Step 1: Implement main + tileMesh + gui + config/REFERENCE changes** (stage only own hunks).
- [ ] **Step 2: luacheck + offline tests** (`tests/gui_tabs_test.lua` must still pass with the new selector entry).
- [ ] **Step 3: Live, dig in bake mode** — `/settings/deepnode/gui.json` `roads.mode = 'bake'`, reload, spawn a test Percheron (not the user's vehicles) in the pit, drive 30 m south through the roads, park. Expected: copies on fresh tiles first, then within a few seconds those tiles rebuild with `deepnode_rb_*` materials and no copy submeshes (`stats.ready` grows, copy builds stop for them); screenshot shows roads on the ruts, no plain-mud rectangle at any time (screenshots every 0.5 s during the dig).
- [ ] **Step 4: Live, start-time pre-bake** — fresh level load in bake mode: Debug tab shows queued → baked counts rising, no frame over 25 ms attributable to bake (spike_install.lua), first load bake time and cached second load time recorded.
- [ ] **Step 5: Live, lifecycle** — `deepnode_main.stop()` (no sunk trucks) and `reload_lua`: no `dnrb_*` / `deepnode_rb_*` objects left; edit one road's `renderPriority` in the probe then restart: that tile rebakes (new sig), old files gone, others load from cache.
- [ ] **Step 6: Restore** `gui.json` to the user's previous `roads.mode`, delete the test vehicle.
- [ ] **Step 7: Commit** — "Add roads.mode 'bake': per-tile baked road layer with copy fallback".

---

### Task 5: Calibrate against the vanilla decal (draw order, sheen)

**Files:**
- Create: `tools/dev/roadbake_rig.lua` (MCP rig: for a given *undug* road tile, builds a test patch mesh from the terrain heights + 4 mm with the tile's clone material, toggles it hidden/shown, takes both screenshots at a given camera)
- Create: `tools/dev/roadbake_compare.py` (`python -I` — mean and std per channel of two screenshots inside a pixel box, prints ratio)
- Modify: `shaders/common/postFx/deepnode/roadBakeP.hlsl` and/or `roadBake.lua` constants as the measurements require; `settings/deepnode/config.json` `roads.bakeHighOnTop`; `docs/ENGINE_FINDINGS.md` (decal draw order, baked-layer calibration facts)

**Interfaces:**
- Consumes: Task 3/4 (`roadBake` bake of an arbitrary tile key via probe), `dnMat3.zw` tangent flips, `roads.bakeHighOnTop`.
- Produces: final `roads.bakeHighOnTop` default and any shader fix; numbers logged in ENGINE_FINDINGS.

- [ ] **Step 1: Draw order** — rig on an undug gridmap_v2 pit tile with stacked roads, bench camera (orbit yaw 160 / pitch 14 / 16 m) and a close camera (3 m): bake with `bakeHighOnTop` true and false. Expected: one order within 5 % of vanilla mean per channel; record both numbers; set the default.
- [ ] **Step 2: Sheen** — with the chosen order, compare std and look (spike: 51 vs vanilla-proxy 37). Try in order, re-measuring each: tangent flips (`dnMat3.z/w` ±1), normal strength 0.5, roughness/metallic as baked vs factors only. Expected: mean and std within 5 % of vanilla at both cameras; keep the first variant that meets it.
- [ ] **Step 3: Band edge** — dug tile next to undug terrain decal: no visible colour step at the mesh border in a close screenshot (compare 20 px strips either side: within 5 %).
- [ ] **Step 4: Commit** — rig, compare script, fixes, config default, ENGINE_FINDINGS → "Calibrate baked road layer against vanilla decals".

---

### Task 6: Bench, docs, decision

**Files:**
- Modify: `docs/BENCHMARK.md` (result log), `CHANGELOG.md`, `docs/OPEN_ISSUES.md`, `README.md` (open issues / roads section), `docs/ENGINE_FINDINGS.md` (cost facts)

- [ ] **Step 1: 4-truck bench** — `gridmap_spawn4.lua`, `bench2.py copyA 2 clear`, `bakeA`, `copyB` (mode switch via gui.json + reload between variants; bake cache warm before `bakeA`). Record fps mean/min, Lua ms, render/shadow ms.
- [ ] **Step 2: 8-truck bench** — `gridmap_setup.lua` list, same interleave. Also record texture/VRAM count (`deepnode_rb_*` materials alive, bake ms total).
- [ ] **Step 3: Look check at bench camera** — screenshots copy vs bake of the same pit view for the user.
- [ ] **Step 4: Decision + docs** — if bake beats copy on fps and Task 5 passed, propose switching the default (ask the user; do not switch unasked); write results to BENCHMARK, CHANGELOG (Unreleased), OPEN_ISSUES (what is left: far sectors, startEndFade, VRAM), README.
- [ ] **Step 5: Commit and push** — `git push origin test` → "Benchmark baked road layer vs copies".
