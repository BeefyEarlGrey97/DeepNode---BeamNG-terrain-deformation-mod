-- deepnode_roadCopy
-- Decal roads over the mud meshes (roads.mode 'copy', the default with terrain-first drawing).
--
-- The level's DecalRoads stay visible: on undug ground the terrain is the surface and the
-- engine draws them exactly as without the mod. Around ruts the terrain is lowered (heavy
-- rut floor) and a mud mesh draws the surface; that mesh carries a copy of every road over
-- it, so the road pattern continues over the untouched mud and drapes over rut walls and
-- berms. Engine limits that leave copies as the way (measured 2026-10-31 / 11-01, see
-- docs/ENGINE_FINDINGS.md "Decal roads"):
--  * a DecalRoad only clips terrain and collision meshes; a ProceduralMesh enters the
--    collision world through be:reloadCollision / reloadStaticCollision (~370 ms, all
--    objects): no live draping;
--  * a post effect cannot shade like the engine (no albedo buffer): the screen-space road
--    look was paler and flatter than the decal and needed vehicle mask boxes;
--  * a ProceduralMesh has one UV set: the road cannot be a layer of the mud material.
-- A copy uses a clone of the road's own material (all fields, castShadows off), the
-- engine's UV mapping (u 0..1 left to right, v = -distance / textureLength along the 3D
-- middle line) and its draw order (descending renderPriority: lower numbers on top, one
-- lift step each).
--
-- Cost. Copies are built on every mud build (no delay: a truck digging a tile showed a
-- plain-mud rectangle while copies waited for the tile to settle), from the quads the mesh
-- builder recorded (tileMesh rec): a square of cells that is still planar within
-- roads.copyFlat is one quad in the copies, so mostly the dug cells cost vertices. UVs
-- (u, d) per cell-grid vertex are cached per tile and road.

local M = {}

local ffi = require('ffi')
local floor, min, max, sqrt, abs, huge = math.floor, math.min, math.max, math.sqrt, math.abs, math.huge
local sfmt = string.format

local ctx = nil
local enabled = false
local roads = {}        -- road records
local byTile = {}       -- tile key -> { road, ... } in draw order
local cache = {}        -- tile key -> { [road.idx] = { u = float[], d = float[] } }
local matOf = {}        -- road material -> clone name (false: none)
local stats = { roads = 0, tiles = 0, builds = 0, ms = 0, verts = 0, clipped = 0, cacheTiles = 0 }

local function isFinite(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end
local function field(o, name)
  local ok, v = pcall(function() return o:getField(name, 0) end)
  if ok then return v end
  return nil
end

-------------------------------------------------------------------------------
-- materials: exact clones without shadow casting
-------------------------------------------------------------------------------
local function copyMaterial(name)
  local have = matOf[name]
  if have ~= nil then return have or nil end
  local src = scenetree.findObject(name)
  if not src then matOf[name] = false; return nil end
  local dst = 'deepnode_dec_' .. name
  local m = scenetree.findObject(dst)
  local fresh = m == nil
  if fresh then m = createObject('Material') end
  local ok = pcall(function() m:assignFieldsFromObject(src) end)
  if not ok then
    if fresh then pcall(function() m:delete() end) end
    -- fall back to the road's own material (draws the same, casts shadows)
    matOf[name] = name
    return name
  end
  pcall(function() m:setField('castShadows', 0, '0') end)
  if fresh then
    m.canSave = false
    m:registerObject(dst)
  else
    pcall(function() m:flush() end)
  end
  matOf[name] = dst
  return dst
end

-------------------------------------------------------------------------------
-- roads
-------------------------------------------------------------------------------
local function eachTile(x0, y0, x1, y1, f)
  local ter = ctx.ter
  local T = ctx.tileSize
  for ty = floor((y0 - ter.oy) / T), floor((y1 - ter.oy) / T) do
    for tx = floor((x0 - ter.ox) / T), floor((x1 - ter.ox) / T) do f(ty * ctx.KEY + tx) end
  end
end

local function addRoad(road, P)
  local cfgR = ctx.cfg.roads
  local mat = tostring(field(road, 'material') or '')
  if mat == '' then return end
  local lmat = mat:lower()
  for _, t in ipairs(cfgR.overSkipMatch or { 'invisible' }) do
    if t ~= '' and lmat:find(tostring(t):lower(), 1, true) then return end
  end
  local okC, ec = pcall(function() return road:getEdgeCount() end)
  ec = okC and tonumber(ec) or 0
  if ec < 2 then return end
  local L, R, Mx, My, Mz, D = {}, {}, {}, {}, {}, {}
  local n, soft, dist = 0, 0, 0
  for i = 0, ec - 1 do
    local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
    if okE and l and r and isFinite(l.x) and isFinite(l.y) and isFinite(r.x) and isFinite(r.y) then
      local mx, my, mz = (l.x + r.x) * 0.5, (l.y + r.y) * 0.5, (l.z + r.z) * 0.5
      local dd = 0
      if n > 0 then dd = sqrt((mx - Mx[n]) ^ 2 + (my - My[n]) ^ 2 + (mz - Mz[n]) ^ 2) end
      if n == 0 or dd >= 1e-3 then
        dist = dist + dd
        n = n + 1
        L[n], R[n] = { l.x, l.y }, { r.x, r.y }
        Mx[n], My[n], Mz[n], D[n] = mx, my, mz, dist
        if P.softAtWorld(mx, my) or P.softAtWorld(l.x, l.y) or P.softAtWorld(r.x, r.y) then soft = soft + 1 end
      end
    end
  end
  if n < 2 or soft == 0 then return end
  local cm = copyMaterial(mat)
  if not cm then return end
  local texLen = tonumber(field(road, 'textureLength')) or 5
  if texLen <= 0.01 then texLen = 5 end
  local fadeS, fadeE = 0, 0
  local a, b = tostring(field(road, 'startEndFade') or ''):match('([%d%.%-]+)%s+([%d%.%-]+)')
  if a then fadeS, fadeE = max(0, tonumber(a) or 0), max(0, tonumber(b) or 0) end
  local e = { obj = road, mat = cm, texLen = texLen, L = L, R = R, Mx = Mx, My = My, D = D, n = n, len = dist,
    fadeS = fadeS, fadeE = fadeE, prio = tonumber(field(road, 'renderPriority')) or 10, id = road:getId() }
  roads[#roads + 1] = e
  e.idx = #roads
  local seen = {}
  for i = 1, n - 1 do
    local x0 = min(L[i][1], R[i][1], L[i + 1][1], R[i + 1][1]) - 0.3
    local x1 = max(L[i][1], R[i][1], L[i + 1][1], R[i + 1][1]) + 0.3
    local y0 = min(L[i][2], R[i][2], L[i + 1][2], R[i + 1][2]) - 0.3
    local y1 = max(L[i][2], R[i][2], L[i + 1][2], R[i + 1][2]) + 0.3
    eachTile(x0, y0, x1, y1, function(k)
      local segs = seen[k]
      if not segs then
        segs = {}
        seen[k] = segs
        local list = byTile[k]
        if not list then list = {}; byTile[k] = list end
        list[#list + 1] = e
      end
      segs[#segs + 1] = i
    end)
  end
  e.segsByTile = seen
end

-- (u, d) of a point: u = 0 at the left edge, 1 at the right; d = distance along the middle
-- line (3D) from the road's start
local function mapPoint(e, segs, x, y)
  local L, R, Mx, My, D = e.L, e.R, e.Mx, e.My, e.D
  local bestU, bestD, bestScore = nil, nil, huge
  for k = 1, #segs do
    local i = segs[k]
    local ax, ay = Mx[i], My[i]
    local sx, sy = Mx[i + 1] - ax, My[i + 1] - ay
    local sl2 = sx * sx + sy * sy
    local t = ((x - ax) * sx + (y - ay) * sy) / sl2
    local tc = t < 0 and 0 or (t > 1 and 1 or t)
    local l1, l2, r1, r2 = L[i], L[i + 1], R[i], R[i + 1]
    local lx, ly = l1[1] + (l2[1] - l1[1]) * tc, l1[2] + (l2[2] - l1[2]) * tc
    local rx, ry = r1[1] + (r2[1] - r1[1]) * tc, r1[2] + (r2[2] - r1[2]) * tc
    local wx, wy = rx - lx, ry - ly
    local w2 = wx * wx + wy * wy
    if w2 > 1e-6 then
      local u = ((x - lx) * wx + (y - ly) * wy) / w2
      local score = abs(t - tc) * 4 + (u < 0 and -u or (u > 1 and u - 1 or 0))
      if score < bestScore then
        bestScore = score
        bestU = u
        bestD = D[i] + t * (D[i + 1] - D[i])
      end
    end
  end
  return bestU, bestD
end

-- (u, d) over the cell grid of tile k for road e (cached)
local function tileMap(k, e, N)
  local c = cache[k]
  if not c then c = {}; cache[k] = c; stats.cacheTiles = stats.cacheTiles + 1 end
  local m = c[e.idx]
  if m then return m end
  local W = N + 1
  local tx, ty = k % ctx.KEY, floor(k / ctx.KEY)
  local ter, cell = ctx.ter, ctx.cell
  local x0, y0 = ter.ox + tx * ctx.tileSize, ter.oy + ty * ctx.tileSize
  local us, ds = ffi.new('float[?]', W * W), ffi.new('float[?]', W * W)
  local segs = e.segsByTile[k]
  -- end fade by narrowing the strip (no vertex alpha in a ProceduralMesh)
  for j = 0, N do
    for i = 0, N do
      local u, d = mapPoint(e, segs, x0 + i * cell, y0 + j * cell)
      if u and (e.fadeS > 0 or e.fadeE > 0) then
        local w = 1
        if e.fadeS > 0 and d < e.fadeS then w = d / e.fadeS end
        if e.fadeE > 0 and e.len - d < e.fadeE then w = min(w, (e.len - d) / e.fadeE) end
        if w < 0.08 then w = 0.08 end
        u = 0.5 + (u - 0.5) / w
      end
      us[j * W + i] = u or -100
      ds[j * W + i] = d or -100
    end
  end
  m = { u = us, d = ds }
  c[e.idx] = m
  return m
end

-------------------------------------------------------------------------------
-- emission
-------------------------------------------------------------------------------
-- polygon clip buffers: x y z nx ny nz u d per vertex
local PA, PB = {}, {}
local function clipAxis(src, n, dst, comp, lim, keepAbove)
  if n == 0 then return 0 end
  local m = 0
  local px = (n - 1) * 8
  local pv = src[px + comp]
  local pin = keepAbove and pv >= lim or (not keepAbove and pv <= lim)
  for k = 0, n - 1 do
    local cx = k * 8
    local cv = src[cx + comp]
    local cin = keepAbove and cv >= lim or (not keepAbove and cv <= lim)
    if cin ~= pin then
      local t = (lim - pv) / (cv - pv)
      local o = m * 8
      for q = 1, 8 do dst[o + q] = src[px + q] + (src[cx + q] - src[px + q]) * t end
      m = m + 1
    end
    if cin then
      local o = m * 8
      for q = 1, 8 do dst[o + q] = src[cx + q] end
      m = m + 1
    end
    px, pv, pin = cx, cv, cin
  end
  return m
end

local vmap = {}      -- (submesh, vertex) -> copy vertex, per road and build
local pmap = {}      -- clip vertex position key -> copy vertex
local subId = {}     -- submesh table -> small id (per build)
local cU, cD, cI = {}, {}, {}
local polyIdx = {}
local dugQ = {}    -- recorded quad -> dug deeper than roads.copyCut (per emit)

-- triangle (corner slots p, q, r of quad k) of road e into `out`
local function emitTri(out, e, il, rec, k, p, q, r, sid)
  local u1, u2, u3 = cU[p], cU[q], cU[r]
  local d1, d2, d3 = cD[p], cD[q], cD[r]
  if (u1 < 0 and u2 < 0 and u3 < 0) or (u1 > 1 and u2 > 1 and u3 > 1)
      or (d1 < 0 and d2 < 0 and d3 < 0) or (d1 > e.len and d2 > e.len and d3 > e.len) then
    return
  end
  local s = rec.s[k]
  local verts, normals = s.verts, s.normals
  local base = 4 * k - 4
  if u1 >= 0 and u1 <= 1 and u2 >= 0 and u2 <= 1 and u3 >= 0 and u3 <= 1
      and d1 >= 0 and d2 >= 0 and d3 >= 0 and d1 <= e.len and d2 <= e.len and d3 <= e.len then
    -- inside: vertices shared with the neighbouring quads
    local ids = polyIdx
    for c = 1, 3 do
      local slot = c == 1 and p or (c == 2 and q or r)
      local vi = rec.v[base + slot]
      local key = sid * 65536 + vi
      local o = vmap[key]
      if not o then
        local V, Nn = verts[vi + 1], normals[vi + 1]
        o = out:vert(V.x, V.y, V.z + rec.d[base + slot] + e.lift, Nn.x, Nn.y, Nn.z, cU[slot], -cD[slot] * il)
        vmap[key] = o
      end
      ids[c] = o
    end
    out:tri(ids[1], ids[2], ids[3])
    return
  end
  -- across the strip edge or an end: clipped to u in [0, 1], d in [0, len]
  for c = 1, 3 do
    local slot = c == 1 and p or (c == 2 and q or r)
    local vi = rec.v[base + slot]
    local V, Nn = verts[vi + 1], normals[vi + 1]
    local o = (c - 1) * 8
    PA[o + 1], PA[o + 2], PA[o + 3] = V.x, V.y, V.z + rec.d[base + slot]
    PA[o + 4], PA[o + 5], PA[o + 6] = Nn.x, Nn.y, Nn.z
    PA[o + 7], PA[o + 8] = cU[slot], cD[slot]
  end
  local n = clipAxis(PA, 3, PB, 7, 0, true)
  n = clipAxis(PB, n, PA, 7, 1, false)
  n = clipAxis(PA, n, PB, 8, 0, true)
  n = clipAxis(PB, n, PA, 8, e.len, false)
  if n < 3 then return end
  local ox, oy = ctx.ter.ox, ctx.ter.oy
  for c = 0, n - 1 do
    local o = c * 8
    local key = floor((PA[o + 1] - ox) * 512 + 0.5) * 16777216 + floor((PA[o + 2] - oy) * 512 + 0.5)
    local id = pmap[key]
    if not id then
      local nx, ny, nz = PA[o + 4], PA[o + 5], PA[o + 6]
      local nl = sqrt(nx * nx + ny * ny + nz * nz)
      if nl < 1e-6 then nx, ny, nz, nl = 0, 0, 1, 1 end
      id = out:vert(PA[o + 1], PA[o + 2], PA[o + 3] + e.lift, nx / nl, ny / nl, nz / nl, PA[o + 7], -PA[o + 8] * il)
      pmap[key] = id
    end
    polyIdx[c + 1] = id
  end
  for c = 2, n - 1 do
    local a, b, cc = polyIdx[1], polyIdx[c], polyIdx[c + 1]
    if a ~= b and b ~= cc and a ~= cc then out:tri(a, b, cc) end
  end
  stats.clipped = stats.clipped + 1
end

-- Copies of every road over tile `key` for the quads recorded in tileMesh.rec (cell grid
-- N x N), appended to builder b.
function M.emit(b, key, N)
  if not enabled then return end
  local list = byTile[key]
  if not list then return end
  local tm = extensions.deepnode_tileMesh
  local rec = tm.rec
  local nq = rec.n
  if nq == 0 then return end
  local t0 = hptimer and hptimer()
  -- dug cells are left out (roads.copyCut): a copy draped into the rut painted it with the
  -- road pattern and the rut vanished behind a digging truck; the mud and the ground look
  -- (wet churned ruts) show there instead, berms keep the road
  local cut = ctx.cfg.roads.copyCut or 0.03
  local t = cut > 0 and ctx.tiles[key] or nil
  if t then
    local rest, dz = t.rest, ctx.decodeZ
    for k = 1, nq do
      local base = 4 * k - 4
      local dug = false
      for c = 1, 4 do
        local g = rec.g[base + c]
        if rest[g] - dz(t, g) > cut then dug = true; break end
      end
      dugQ[k] = dug
    end
  end
  for k in pairs(subId) do subId[k] = nil end
  local nsid = 0
  local v0 = b:vertexCount()
  for ri = 1, #list do
    local e = list[ri]
    local mp = tileMap(key, e, N)
    local us, ds = mp.u, mp.d
    local il = 1 / e.texLen
    local out = nil
    for kk in pairs(vmap) do vmap[kk] = nil end
    for kk in pairs(pmap) do pmap[kk] = nil end
    for k = 1, nq do
      local base = 4 * k - 4
      local g1, g2, g3, g4 = rec.g[base + 1], rec.g[base + 2], rec.g[base + 3], rec.g[base + 4]
      local u1, u2, u3, u4 = us[g1], us[g2], us[g3], us[g4]
      local d1, d2, d3, d4 = ds[g1], ds[g2], ds[g3], ds[g4]
      -- quick reject: dug, or the whole quad beside the strip or beyond an end
      if not (t and dugQ[k]) and not ((u1 < 0 and u2 < 0 and u3 < 0 and u4 < 0) or (u1 > 1 and u2 > 1 and u3 > 1 and u4 > 1)
          or (d1 < 0 and d2 < 0 and d3 < 0 and d4 < 0)
          or (d1 > e.len and d2 > e.len and d3 > e.len and d4 > e.len)) then
        if not out then out = b:sub(e.mat, 64) end
        local s = rec.s[k]
        local sid = subId[s]
        if not sid then nsid = nsid + 1; sid = nsid; subId[s] = sid end
        cU[1], cU[2], cU[3], cU[4] = u1, u2, u3, u4
        cD[1], cD[2], cD[3], cD[4] = d1, d2, d3, d4
        -- corners a=1 b=2 c=3 d=4; triangles (a, c, d) and (a, d, b) as the mud mesh
        emitTri(out, e, il, rec, k, 1, 3, 4, sid)
        emitTri(out, e, il, rec, k, 1, 4, 2, sid)
      end
    end
  end
  stats.builds = stats.builds + 1
  stats.verts = stats.verts + b:vertexCount() - v0
  if t0 then stats.ms = stats.ms + t0:stop() end
end

function M.hasRoads(k) return byTile[k] ~= nil end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------
function M.start(main)
  ctx = main
  roads, byTile, cache = {}, {}, {}
  for k in pairs(stats) do stats[k] = 0 end
  enabled = true
  local P = main.private
  local t0 = hptimer and hptimer()
  for _, name in ipairs(scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad') or {}) do
    local road = scenetree.findObject(name)
    if road then
      local okH, hid = pcall(function() return road:isHidden() end)
      if not (okH and hid) then
        local ok, err = pcall(addRoad, road, P)
        if not ok then log('W', 'deepnode', 'road copy: ' .. tostring(name) .. ': ' .. tostring(err)) end
      end
    end
  end
  -- draw order: the engine draws decal roads in descending renderPriority (lower numbers
  -- on top); copies are submeshes in that order, each priority level one lift step higher
  local R = main.cfg.roads
  local prios, seenP = {}, {}
  for _, e in ipairs(roads) do if not seenP[e.prio] then seenP[e.prio] = true; prios[#prios + 1] = e.prio end end
  table.sort(prios, function(a, b) return a > b end)
  local rankOf = {}
  for i, p in ipairs(prios) do rankOf[p] = i - 1 end
  local base, step = R.copyLift or 0.008, R.copyLiftStep or 0.002
  for _, e in ipairs(roads) do e.lift = base + rankOf[e.prio] * step + (e.idx % 3) * 0.0003 end
  for _, list in pairs(byTile) do
    table.sort(list, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end return a.idx < b.idx end)
    stats.tiles = stats.tiles + 1
  end
  stats.roads = #roads
  log('I', 'deepnode', sfmt('road copies: %d roads over soft ground, %d tiles, %.0f ms', #roads, stats.tiles,
    t0 and t0:stop() or 0))
  return #roads
end

function M.stop()
  roads, byTile, cache = {}, {}, {}
  enabled = false
end

function M.isEnabled() return enabled end
function M.stats() return stats end
function M.isMat(name)
  for _, n in pairs(matOf) do if n == name then return true end end
  return false
end

M.onExtensionLoaded = function() setExtensionUnloadMode(M, 'manual') end

return M
