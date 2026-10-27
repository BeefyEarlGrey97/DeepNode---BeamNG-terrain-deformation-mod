-- deepnode_decals
-- Decal roads on the mud, drawn as part of the mud meshes (roads.mode = 'overlay';
-- GUI "Decal roads on mud", main.setDecalRoads switches it live).
--
-- A DecalRoad is a flat strip laid once onto whatever was below it. On the mud it either
-- lies on the lowered terrain (hidden under the mud) or, draped by a collision reload,
-- on the undisturbed mud surface, where it covers every rut dug later like a flat sheet.
-- Here every mud mesh (active tile, frozen tile, sector) gets, for each decal road over
-- it, a copy of its own triangles under the road strip, lifted (vertical) and textured
-- with the road's material and UVs (u across the strip, v = distance / textureLength):
--  * only on whole terrain squares no tyre or chassis touched (an untouched square is one
--    quad in every mesh): where the mud was dug the pattern is gone, so a decal never
--    lies over a rut and nothing switches while a tile is being dug;
--  * triangles are clipped exactly to the strip, clip vertices shared by position;
--  * materials: copies of the road materials, alpha-clipped (opaque pass, receives
--    shadows like the mud; translucent copies cost ~2.8 ms GPU and sorted badly),
--    castShadows 0, fixed roughness (the decal roughness maps sparkle on a mesh);
--    puddle decals (overlaySkipMatch 'water') are left out;
--  * overlapping roads are stacked by height (one overlayLiftStep per renderPriority
--    level), the whole stack under sectors.drop so a sector's decal never rises above a
--    tile mesh drawn over it;
--  * no vertex colours in ProceduralMesh (createMesh reads verts, uvs, normals, faces),
--    so startEndFade narrows the strip towards its ends: u' = 0.5 + (u - 0.5) / w;
--  * the engine keeps drawing the roads on the lowered terrain: hidden under a mud mesh,
--    still seen beyond the loaded mud sectors.
-- (u, d) per cell-grid vertex and road are cached per tile (ffi arrays), computed once.

local M = {}

local ffi = require('ffi')
local floor, min, max, sqrt, abs, huge = math.floor, math.min, math.max, math.sqrt, math.abs, math.huge
local sfmt = string.format

local ctx = nil
local roads = {}        -- road records
local byTile = {}       -- tile key -> { road, ... } (renderPriority order)
local cache = {}        -- tile key -> { [road.idx] = { u = float[], d = float[] } }
local hidden = {}       -- DecalRoad objects hidden by us
local matOf = {}        -- original material name -> overlay material name
local enabled = false
local stats = { coarseIn = 0, fineIn = 0, clipVerts = 0, roads = 0, hiddenRoads = 0, partial = 0, tiles = 0, tris = 0, clipped = 0, builds = 0, ms = 0, cacheTiles = 0 }

local function isFinite(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end

-------------------------------------------------------------------------------
-- materials
-------------------------------------------------------------------------------
local COPY = { 'baseColorMap', 'opacityMap', 'normalMap', 'roughnessMap', 'aoMap', 'metallicMap',
  'baseColorFactor', 'roughnessFactor', 'metallicFactor', 'normalMapStrength', 'opacityFactor',
  'alphaTest', 'alphaRef', 'translucentBlendOp', 'detailMap', 'detailScale', 'detailBaseColorMapStrength',
  'detailNormalMap', 'detailNormalMapStrength', 'clearCoatFactor', 'clearCoatRoughnessFactor' }

local function overlayMaterial(name)
  local have = matOf[name]
  if have ~= nil then return have or nil end
  local src = scenetree.findObject(name)
  if not src then matOf[name] = false; return nil end
  local dst = 'deepnode_dec_' .. name
  -- a copy left from an earlier session (GE Lua reload) would be reused with its old
  -- fields by createMaterial: delete it first
  local old = scenetree.findObject(dst)
  if old then old:delete() end
  local R = ctx.cfg.roads
  local fields = { { 'version', '1.5' }, { 'castShadows', '0' } }
  for _, f in ipairs(COPY) do
    local ok, v = pcall(function() return src:getField(f, 0) end)
    if ok and v ~= nil and v ~= '' then fields[#fields + 1] = { f, v } end
  end
  local rough = R.overlayRoughness or 0.85
  for k, v in pairs(R.overlayRoughnessByMatch or {}) do
    if name:lower():find(tostring(k):lower(), 1, true) then rough = tonumber(v) end
  end
  if rough and rough >= 0 then
    -- engine decals blend into the deferred buffers; a translucent mesh is lit forward
    -- with its own roughness (wet decals turned glossy): fixed roughness instead
    for i = #fields, 1, -1 do
      if fields[i][1] == 'roughnessMap' or fields[i][1] == 'roughnessFactor' then table.remove(fields, i) end
    end
    fields[#fields + 1] = { 'roughnessFactor', tostring(rough) }
  end
  if (R.overlayAlphaRef or 110) > 0 then
    -- alpha clip, drawn in the opaque (deferred) pass like the mud under it
    fields[#fields + 1] = { 'translucent', '0' }
    fields[#fields + 1] = { 'alphaTest', '1' }
    fields[#fields + 1] = { 'alphaRef', tostring(R.overlayAlphaRef or 110) }
  else
    fields[#fields + 1] = { 'translucent', '1' }
    fields[#fields + 1] = { 'translucentZWrite', '0' }
  end
  local m = ctx.createMaterial(dst, fields)
  matOf[name] = m and dst or false
  return m and dst or nil
end

-------------------------------------------------------------------------------
-- roads
-------------------------------------------------------------------------------
local function field(o, name)
  local ok, v = pcall(function() return o:getField(name, 0) end)
  if ok then return v end
  return nil
end

-- tiles touched by the box (x0,y0)-(x1,y1)
local function eachTile(x0, y0, x1, y1, f)
  local ter = ctx.ter
  local T = ctx.tileSize
  local tx0, tx1 = floor((x0 - ter.ox) / T), floor((x1 - ter.ox) / T)
  local ty0, ty1 = floor((y0 - ter.oy) / T), floor((y1 - ter.oy) / T)
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do f(ty * ctx.KEY + tx) end
  end
end

local function addRoad(road, P)
  local cfgR = ctx.cfg.roads
  local mat = tostring(field(road, 'material') or '')
  if mat == '' then return end
  local lmat = mat:lower()
  if cfgR.overlayOnly and cfgR.overlayOnly ~= '' and not lmat:find(cfgR.overlayOnly:lower(), 1, true) then return end
  for _, t in ipairs(cfgR.overSkipMatch or { 'invisible' }) do
    if t ~= '' and lmat:find(tostring(t):lower(), 1, true) then return end
  end
  -- puddle decals: lit forward as a mesh they turn into a flat light sheet (the engine
  -- draws them as a wet deferred decal); left out
  for _, t in ipairs(cfgR.overlaySkipMatch or { 'water' }) do
    if t ~= '' and lmat:find(tostring(t):lower(), 1, true) then return end
  end
  local okC, ec = pcall(function() return road:getEdgeCount() end)
  ec = okC and tonumber(ec) or 0
  if ec < 2 then return end
  local L, R, Mx, My, D = {}, {}, {}, {}, {}
  local n, soft, dist = 0, 0, 0
  for i = 0, ec - 1 do
    local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
    if okE and l and r and isFinite(l.x) and isFinite(l.y) and isFinite(r.x) and isFinite(r.y) then
      local mx, my = (l.x + r.x) * 0.5, (l.y + r.y) * 0.5
      if n > 0 then
        local dd = sqrt((mx - Mx[n]) ^ 2 + (my - My[n]) ^ 2)
        if dd < 1e-3 then goto continue end
        dist = dist + dd
      end
      n = n + 1
      L[n] = { l.x, l.y }
      R[n] = { r.x, r.y }
      Mx[n], My[n], D[n] = mx, my, dist
      if P.softAtWorld(mx, my) then soft = soft + 1 end
    end
    ::continue::
  end
  if n < 2 or soft == 0 then return end
  local omat = overlayMaterial(mat)
  if not omat then return end
  local texLen = tonumber(field(road, 'textureLength')) or 5
  if texLen <= 0.01 then texLen = 5 end
  local fadeS, fadeE = 0, 0
  local sef = tostring(field(road, 'startEndFade') or '')
  local a, b = sef:match('([%d%.%-]+)%s+([%d%.%-]+)')
  if a then fadeS, fadeE = max(0, tonumber(a) or 0), max(0, tonumber(b) or 0) end
  local e = { obj = road, id = road:getId(), mat = omat, texLen = texLen, L = L, R = R, Mx = Mx, My = My, D = D, n = n,
    len = dist, fadeS = fadeS, fadeE = fadeE, prio = tonumber(field(road, 'renderPriority')) or 10,
    inside = soft >= n * (cfgR.insideShare or 0.9) }
  roads[#roads + 1] = e
  e.idx = #roads
  -- tiles under each segment (bounding box plus a margin)
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

-------------------------------------------------------------------------------
-- (u, d) of a point on a road: d = distance along the middle line (m), u = 0 at the
-- left edge, 1 at the right edge
-------------------------------------------------------------------------------
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
      -- prefer the segment the point projects into, then the one nearest the strip
      local score = abs(t - tc) * 4 + (u < 0 and -u or (u > 1 and u - 1 or 0))
      if score < bestScore then
        bestScore = score
        bestU = u
        bestD = D[i] + t * sqrt(sl2)
      end
    end
  end
  return bestU, bestD
end

-- (u, d) arrays of a road over the cell grid of tile key k
local function tileMap(k, e)
  local c = cache[k]
  if not c then c = {}; cache[k] = c; stats.cacheTiles = stats.cacheTiles + 1 end
  local m = c[e.idx]
  if m then return m end
  local N = ctx.N
  local W = N + 1
  local KEY = ctx.KEY
  local tx, ty = k % KEY, floor(k / KEY)
  local ter = ctx.ter
  local cell = ctx.cell
  local x0 = ter.ox + tx * ctx.tileSize
  local y0 = ter.oy + ty * ctx.tileSize
  local us, ds = ffi.new('float[?]', W * W), ffi.new('float[?]', W * W)
  local segs = e.segsByTile[k]
  for j = 0, N do
    for i = 0, N do
      local u, d = mapPoint(e, segs, x0 + i * cell, y0 + j * cell)
      us[j * W + i] = u or -100
      ds[j * W + i] = d or -100
    end
  end
  m = { u = us, d = ds }
  c[e.idx] = m
  return m
end

-------------------------------------------------------------------------------
-- overlay emission (post pass over a builder's mud submeshes)
-------------------------------------------------------------------------------
-- width factor at distance d (startEndFade by narrowing)
local function widthAt(e, d)
  local w = 1
  if e.fadeS > 0 and d < e.fadeS then w = d / e.fadeS end
  if e.fadeE > 0 and e.len - d < e.fadeE then w = min(w, (e.len - d) / e.fadeE) end
  if w < 0.08 then w = 0.08 end
  return w
end

-- polygon clip buffers: x y z nx ny nz u d per vertex
local PA, PB = {}, {}
local function clipAxis(src, n, dst, comp, lim, keepAbove)
  local m = 0
  if n == 0 then return 0 end
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

-- cell-grid index (0..W*W-1) of a mud vertex inside tile (gx0, gy0)
local function loc(V, ox, oy, inv, gx0, gy0, N, W)
  local i = floor((V.x - ox) * inv + 0.5) - gx0
  local j = floor((V.y - oy) * inv + 0.5) - gy0
  if i < 0 then i = 0 elseif i > N then i = N end
  if j < 0 then j = 0 elseif j > N then j = N end
  return j * W + i
end

local polyIdx = {}
local stampGen = 0
local stampStep = 1
local stampA = nil
local stampV = nil
local stampN = 0
local function ensureStamp(n)
  if n > stampN then
    stampN = n
    stampA = ffi.new('int32_t[?]', n)
    stampV = ffi.new('int32_t[?]', n)
  end
end

local function ov(out, normals, key, lift, il, vi, V, u, d)
  -- lift: per road (layer order)
  if stampA[vi] == key then return stampV[vi] end
  local Nn = normals[vi + 1]
  local r = out:vert(V.x, V.y, V.z + lift, Nn.x, Nn.y, Nn.z, u, d * il)
  stampA[vi] = key
  stampV[vi] = r
  return r
end

-- Add the decal overlays for every mud submesh in builder b. zLift: vertical offset
-- above the mud surface of this mesh.
function M.overlay(b, squaresOnly, tileKey)
  if not enabled or #roads == 0 then return end
  -- a tile mesh under no road: nothing to do (most tiles)
  if tileKey and not byTile[tileKey] then
    for si = 1, b.nsub do local sb = b.subs[si]; sb.decalDone = sb.nf end
    return
  end
  local t0 = hptimer and hptimer()
  local ter = ctx.ter
  local N, KEY, cell = ctx.N, ctx.KEY, ctx.cell
  local W = N + 1
  local T = ctx.tileSize
  local ox, oy = ter.ox, ter.oy
  local inv = 1 / cell
  local tiles = ctx.tiles
  local coarse2 = (0.6 * ter.sq) ^ 2
  local um = ctx.cfg.roads.overlayCellMargin or 0.12
  local nsub = b.nsub
  local tris = 0
  local lastOut = {}
  local dedup = {}
  for si = 1, nsub do
    local s = b.subs[si]
    if s.nf > 0 and not s.material:find('^deepnode_dec_') then
      local verts, normals, faces = s.verts, s.normals, s.faces
      ensureStamp(s.nv)
      -- only the faces added since the last call (sector builds call this per tile)
      local f = (s.decalDone or 0) + 1
      s.decalDone = s.nf
      while f <= s.nf do
        local ia, ib, ic = faces[f].v, faces[f + 1].v, faces[f + 2].v
        local A, C = verts[ia + 1], verts[ic + 1]
        local e2 = (A.x - C.x) ^ 2 + (A.y - C.y) ^ 2
        local B, list, k, tx, ty = nil, nil, nil, nil, nil
        if not squaresOnly or e2 >= coarse2 then
          B = verts[ib + 1]
          local cx, cy = (A.x + B.x + C.x) / 3, (A.y + B.y + C.y) / 3
          tx, ty = floor((cx - ox) / T), floor((cy - oy) / T)
          k = ty * KEY + tx
          list = byTile[k]
        end
        -- coarse = triangle of a whole terrain square (clipped exactly to the strip);
        -- rut cells (0.2 m) are taken whole or left out: no clipping, vertices shared
        -- with the neighbours (the strip's soft edge texels are alpha-clipped anyway)
        local coarse = e2 >= coarse2
        -- decals only on whole untouched terrain squares (one quad each): a square a tyre
        -- touched shows bare mud. Cells would be finer at the rut edge, but cost ~2x the
        -- upload of every rutted tile (measured: 780 vs 420 vertices)
        if not coarse and squaresOnly then list = nil end
        local la, lb, lc
        if list then
          local gx0, gy0 = tx * N, ty * N
          la = loc(A, ox, oy, inv, gx0, gy0, N, W)
          lb = loc(B, ox, oy, inv, gx0, gy0, N, W)
          lc = loc(C, ox, oy, inv, gx0, gy0, N, W)
          -- no decal where a tyre or the chassis touched the mud (rut, berm, track):
          -- the decal pattern is churned away there, and a decal never lies over a rut
          local t = tiles[k]
          if t and t.rutted then
            local rut, track = t.rut, t.track
            if rut[la] ~= 128 or rut[lb] ~= 128 or rut[lc] ~= 128 or track[la] ~= 0 or track[lb] ~= 0 or track[lc] ~= 0 then
              list = nil
            end
          end
        end
        if list then
          for ri = 1, #list do
            local e = list[ri]
            local mp = tileMap(k, e)
            local us, ds = mp.u, mp.d
            local ua, ub, uc = us[la], us[lb], us[lc]
            local da, db, dc = ds[la], ds[lb], ds[lc]
            -- quick reject: all on one side of the strip or beyond an end
            if not ((ua < -0.05 and ub < -0.05 and uc < -0.05) or (ua > 1.05 and ub > 1.05 and uc > 1.05)
                or (da < 0 and db < 0 and dc < 0) or (da > e.len and db > e.len and dc > e.len)) then
              -- narrowed u (end fade)
              if e.fadeS > 0 or e.fadeE > 0 then
                ua, ub, uc = 0.5 + (ua - 0.5) / widthAt(e, da), 0.5 + (ub - 0.5) / widthAt(e, db), 0.5 + (uc - 0.5) / widthAt(e, dc)
              end
              local out = b:sub(e.mat, 6)
              -- a new submesh for this material: the shared-vertex stamps are void
              if out ~= lastOut[e.idx] then lastOut[e.idx] = out; stampGen = stampGen + stampStep end
              local inside
              if coarse then
                inside = ua >= 0 and ua <= 1 and ub >= 0 and ub <= 1 and uc >= 0 and uc <= 1
                  and da >= 0 and db >= 0 and dc >= 0 and da <= e.len and db <= e.len and dc <= e.len
              else
                inside = ua >= -um and ua <= 1 + um and ub >= -um and ub <= 1 + um and uc >= -um and uc <= 1 + um
                  and da >= -0.3 and db >= -0.3 and dc >= -0.3 and da <= e.len + 0.3 and db <= e.len + 0.3 and dc <= e.len + 0.3
              end
              local il = 1 / e.texLen
              if not coarse and not inside then
                -- rut cell over the strip edge: left out
              elseif inside then
                -- shared vertices: one overlay vertex per mud vertex and road
                local key = stampGen + e.idx
                local a = ov(out, normals, key, e.lift, il, ia, A, ua, da)
                local bb = ov(out, normals, key, e.lift, il, ib, B, ub, db)
                local c = ov(out, normals, key, e.lift, il, ic, C, uc, dc)
                out:tri(a, bb, c)
                tris = tris + 1
                if coarse then stats.coarseIn = stats.coarseIn + 1 else stats.fineIn = stats.fineIn + 1 end
              else
                local NA, NB, NC = normals[ia + 1], normals[ib + 1], normals[ic + 1]
                PA[1], PA[2], PA[3], PA[4], PA[5], PA[6], PA[7], PA[8] = A.x, A.y, A.z, NA.x, NA.y, NA.z, ua, da
                PA[9], PA[10], PA[11], PA[12], PA[13], PA[14], PA[15], PA[16] = B.x, B.y, B.z, NB.x, NB.y, NB.z, ub, db
                PA[17], PA[18], PA[19], PA[20], PA[21], PA[22], PA[23], PA[24] = C.x, C.y, C.z, NC.x, NC.y, NC.z, uc, dc
                local n = clipAxis(PA, 3, PB, 7, 0, true)
                n = clipAxis(PB, n, PA, 7, 1, false)
                n = clipAxis(PA, n, PB, 8, 0, true)
                n = clipAxis(PB, n, PA, 8, e.len, false)
                if n >= 3 then
                  -- clip vertices shared by position (per road and submesh): a clipped
                  -- strip edge runs through both triangles of a square and its neighbours
                  local dd = dedup[e.idx]
                  if not dd or dd.out ~= out then dd = { out = out }; dedup[e.idx] = dd end
                  for q = 0, n - 1 do
                    local o = q * 8
                    local key = floor((PA[o + 1] - ox) * 512 + 0.5) * 16777216 + floor((PA[o + 2] - oy) * 512 + 0.5)
                    local r = dd[key]
                    if not r then
                      local nx, ny, nz = PA[o + 4], PA[o + 5], PA[o + 6]
                      local nl = sqrt(nx * nx + ny * ny + nz * nz)
                      if nl < 1e-6 then nx, ny, nz, nl = 0, 0, 1, 1 end
                      r = out:vert(PA[o + 1], PA[o + 2], PA[o + 3] + e.lift, nx / nl, ny / nl, nz / nl, PA[o + 7], PA[o + 8] * il)
                      dd[key] = r
                      stats.clipVerts = stats.clipVerts + 1
                    end
                    polyIdx[q + 1] = r
                  end
                  for q = 2, n - 1 do
                    local a, bq, cq = polyIdx[1], polyIdx[q], polyIdx[q + 1]
                    if a ~= bq and bq ~= cq and a ~= cq then out:tri(a, bq, cq) end
                  end
                  tris = tris + n - 2
                  stats.clipped = stats.clipped + 1
                end
              end
            end
          end
        end
        f = f + 3
      end
      stampGen = stampGen + stampStep
    end
  end
  stats.tris = stats.tris + tris
  stats.builds = stats.builds + 1
  if t0 then stats.ms = stats.ms + t0:stop() end
end

-- tiles of sector sk that carry decal overlays (sector builds skip nothing; for stats)
function M.hasRoads(k) return byTile[k] ~= nil end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------
function M.start(main)
  ctx = main
  roads, byTile, cache, hidden, matOf = {}, {}, {}, {}, {}
  for k in pairs(stats) do stats[k] = 0 end
  local cfgR = main.cfg.roads or {}
  enabled = cfgR.enabled ~= false and (cfgR.mode or 'overlay') == 'overlay'
  if not enabled then return 0 end
  local P = main.private
  local names = scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad') or {}
  local t0 = hptimer and hptimer()
  for _, name in ipairs(names) do
    local road = scenetree.findObject(name)
    if road then
      local okH, hid = pcall(function() return road:isHidden() end)
      if not (okH and hid) then
        local ok, err = pcall(addRoad, road, P)
        if not ok then log('W', 'deepnode', 'decal overlay: road ' .. tostring(name) .. ': ' .. tostring(err)) end
      end
    end
  end
  -- layer lift: alpha-clipped overlays are opaque, so overlapping roads are stacked by
  -- height: lower renderPriority numbers on top (one step per distinct priority), and a
  -- sub-step per road so roads of the same priority do not z-fight
  local R = main.cfg.roads
  local prios, seenP = {}, {}
  for _, e in ipairs(roads) do if not seenP[e.prio] then seenP[e.prio] = true; prios[#prios + 1] = e.prio end end
  table.sort(prios, function(a, b) return a > b end)
  local rankOf = {}
  for i, p in ipairs(prios) do rankOf[p] = i - 1 end
  -- the whole stack stays under the sector drop: a sector's decal must never rise above
  -- the surface of a tile mesh drawn over it
  local top = (main.cfg.sectors.drop or 0.015) - 0.002
  local step = R.overlayLiftStep or 0.001
  if #prios > 1 then step = min(step, (top - (R.overlayLift or 0.004) - 0.0006) / (#prios - 1)) end
  for _, e in ipairs(roads) do
    e.lift = (R.overlayLift or 0.004) + rankOf[e.prio] * step + (e.idx % 3) * 0.0003
  end
  -- draw order: high renderPriority first (lower numbers end up on top)
  for _, list in pairs(byTile) do
    table.sort(list, function(a, b) if a.prio ~= b.prio then return a.prio > b.prio end return a.idx < b.idx end)
    stats.tiles = stats.tiles + 1
  end
  -- The engine's own decals stay (roads.hideInside false): they lie on the lowered
  -- terrain under the mud, so they only show where no mud mesh is loaded (far away),
  -- which keeps the distant look.
  local hide = ctx.cfg.roads.hideInside == true
  for _, e in ipairs(roads) do
    if e.inside and hide then
      pcall(function() e.obj:setHidden(true) end)
      hidden[#hidden + 1] = e.obj
    else
      stats.partial = stats.partial + 1
    end
  end
  stats.roads, stats.hiddenRoads = #roads, #hidden
  stampStep = #roads + 1
  log('I', 'deepnode', sfmt('decal overlay: %d roads on the mud (%d hidden, %d also off the mud), %d tiles, %.0f ms',
    #roads, #hidden, stats.partial, stats.tiles, t0 and t0:stop() or 0))
  return #roads
end

function M.stop(objectsAlive)
  if objectsAlive ~= false then
    for _, o in ipairs(hidden) do pcall(function() o:setHidden(false) end) end
  end
  roads, byTile, cache, hidden = {}, {}, {}, {}
  matOf = {}
  enabled = false
end

function M.isEnabled() return enabled end
function M.materialNames()
  local list = {}
  for _, n in pairs(matOf) do if n then list[#list + 1] = n end end
  return list
end
function M.stats() return stats end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
