-- deepnode_preRut
-- Decal roads on soft ground as real ruts from the start.
--
-- A level's mud decal roads (tyre tracks, furrows, puddles) only paint ruts on flat
-- ground. At mod start every such road becomes a procedural rut field and the mud
-- starts out in that shape: the tracks are carved into the undisturbed surface (`rest`),
-- the terrain under them is lowered so the mesh shows and the heavy physics floor follows.
--
-- The road's material is not used for the shape (its normal map gave clod blobs and
-- texture repeats). The profile is generated in metres from the road's own frame
-- (lateral offset from the centre line, distance along it), so it has no seams between
-- segments and no repeat: one to three passes per road (vehicles that drove it), each a
-- pair of tyre-wide ruts (0.28-0.48 m) with torn berms, its own gauge, offset and
-- wander; further passes fade in and out along the road; clumpy mud along the ruts. Puddle roads (material name
-- in roads.preBasinMatch) become a dish instead.
--
-- Rasterising: every road segment (left/right edge pair) is split into two triangles;
-- each 0.2 m cell vertex inside gets the offset roads.preDepth[kind] x profile, faded at
-- the road's ends and sides. Stacked roads blend in drawing order by their fades.
-- Output, per tile key: a float array of (N + 1)^2 cell offsets; per terrain vertex:
-- the offset at the vertex (main.vertexInfo adds it to rest) and the dip under it (the
-- sink pass lowers the terrain by it, so the squares are not flush any more).

local M = {}

local ffi = require('ffi')
local bit = require('bit')
local floor, ceil, min, max, abs, sqrt = math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt
local sfmt = string.format
local logTag = 'deepnode.preRut'

local function smooth(x) if x <= 0 then return 0 elseif x >= 1 then return 1 end return x * x * (3 - 2 * x) end
local function bump(x) if x <= 0 or x >= 1 then return 0 end local s = math.sin(math.pi * x) return s * s end

-------------------------------------------------------------------------------
-- procedural rut profile
-------------------------------------------------------------------------------
-- value noise in 0..1 (hash: tileMesh.hash01 of integer lattice points)
local hash
local function noise1(t, seed)
  local i = floor(t)
  local f = smooth(t - i)
  local a, b = hash(i, seed, 31), hash(i + 1, seed, 31)
  return a + (b - a) * f
end
local function noise2(x, y, seed)
  local i, j = floor(x), floor(y)
  local fx, fy = smooth(x - i), smooth(y - j)
  local a, b = hash(i, j, seed), hash(i + 1, j, seed)
  local c, d = hash(i, j + 1, seed), hash(i + 1, j + 1, seed)
  local l = a + (b - a) * fx
  return l + (c + (d - c) * fx - l) * fy
end

-- profile parameters (metres, shares of the depth) from roads.pre*
local function profileOf(rc)
  return {
    half = rc.preTrackHalf or { 0.75, 1.0 },  -- half the wheel gauge (range per pass)
    tyreW = rc.preTyreWidth or { 0.28, 0.48 }, -- rut width = a tyre's (range per pass)
    flat = rc.preRutFlat or 0.3,              -- share of the half width that is flat bottom
    berm = rc.preBerm or 0.3,                 -- berm height (x rut depth)
    bermW = rc.preBermWidth or 0.18,
    wander = rc.preWander or 0.25,            -- lateral wander amplitude of a pass
    wanderLen = rc.preWanderLen or { 6, 14 }, -- its wavelength range (m)
    depthVar = rc.preDepthVar or 0.35,        -- depth varies by +- this share along the rut
    fadeLen = rc.preFadeLen or 7,             -- m: passes fade in and out along the road
    passes = rc.prePasses or { 1, 3 },        -- passes per road (range)
    lumps = rc.preLumps or 0.15,              -- clump amplitude (x depth)
    lumpSize = rc.preLumpSize or 0.25,
    single = rc.preSingleMax or 1.4,          -- roads narrower than this carry one wheel line
  }
end

local function range(r, x) if type(r) ~= 'table' then return r end return r[1] + (r[2] - r[1]) * x end

-- one pass of a road (a vehicle that drove it): gauge, tyre width, offset, depth, wander
-- length, all from the road's seed, so every road looks different and the same on every load
local passCache = {}
local function passOf(F, seed, p, wid)
  -- cached per road width in 0.25 m steps (the width is interpolated per cell)
  local wq = min(63, floor(wid * 4 + 0.5))
  local key = (seed * 8 + p) * 64 + wq
  local q = passCache[key]
  if q then return q end
  wid = wq * 0.25
  q = {
    g = min(range(F.half, hash(seed, p, 41)), max(0.1, 0.5 * wid - 0.25)),
    w = 0.5 * range(F.tyreW, hash(seed, p, 43)),
    off = (hash(seed, p, 47) * 2 - 1) * max(0, 0.5 * wid - 1.1) * 0.6,
    depth = (p == 1) and 1 or (0.45 + 0.5 * hash(seed, p, 53)),
    wl = range(F.wanderLen, hash(seed, p, 59)),
    ps = seed + p * 101,
  }
  passCache[key] = q
  return q
end

-- height (x depth, about -1.3 .. 0.4) at lateral offset x (m from the centre line) and
-- distance s along a road of width wid
local function profile(F, x, s, wid, seed)
  local rutPart, bermPart, near = 0, 0, 0
  local twin = wid >= F.single
  local np = floor(range(F.passes, hash(seed, 0, 37)) + 0.5)
  for p = 1, max(1, np) do
    local q = passOf(F, seed, p, wid)
    local ps = q.ps
    -- the pass is faint or gone over some stretches (another line took over there)
    local env = p == 1 and 1 or smooth((noise1(s / F.fadeLen, ps + 3) - 0.3) / 0.35)
    if env > 0 then
      -- a vehicle's wheels wander together; a little of it is per wheel
      local wv = F.wander * ((noise1(s / q.wl, ps) * 2 - 1) + 0.3 * (noise1(s / (q.wl * 0.31), ps + 7) * 2 - 1))
      for side = twin and -1 or 1, 1, 2 do
        local c = (twin and side * q.g or 0) + q.off + wv + 0.03 * (noise1(s / 1.7, ps + side * 13) * 2 - 1)
        local w = q.w * (0.85 + 0.3 * noise1(s / 2.1, ps + side * 17))
        local dv = env * q.depth * (1 - F.depthVar + 2 * F.depthVar * noise1(s / 3.3, ps + side * 19))
        local d = abs(x - c)
        if d < w then
          local h = -dv * (1 - smooth((d / w - F.flat) / (1 - F.flat)))
          if h < rutPart then rutPart = h end
          near = 1
        else
          -- torn berm: its width and height break up along the rut
          local bw = F.bermW * (0.6 + 0.8 * noise1(s / 0.9, ps + side * 23))
          if d < w + bw then
            local h = F.berm * dv * (0.5 + noise1(s / 0.6, ps + side * 29)) * bump((d - w) / bw)
            if h > bermPart then bermPart = h end
            near = max(near, 1 - (d - w) / bw)
          end
        end
      end
    end
  end
  -- berms cut by a rut of another pass fade inside it
  local h = rutPart + bermPart * (1 + max(-1, rutPart))
  -- clumpy torn mud along the ruts, a little elsewhere
  local ls = F.lumpSize
  local n = noise2(x / ls, s / ls, seed + 3) * 0.6 + noise2(x / (ls * 0.4), s / (ls * 0.4), seed + 5) * 0.4
  n = n * n * 2.4 - 0.6
  return h + F.lumps * n * (0.2 + 0.8 * near)
end

-------------------------------------------------------------------------------
-- build
-------------------------------------------------------------------------------
-- main: the deepnode_main module (M), P: its private table. Returns the result table
-- { off = { [tileKey] = float[(N+1)^2] }, vOff = { [vertex] = z }, dip = { [vertex] = m },
--   tiles = n, cells = n, roads = n, prints = { x0, y0, x1, y1, width, ... } } or nil.
function M.build(main, P)
  local cfg = main.cfg
  local rc = cfg.roads or {}
  if rc.preRut ~= true then return nil end
  local ter = main.ter
  if not ter or (ter.K or 1) > 1 then return nil end
  hash = P.hash01
  passCache = {}
  local t0 = os.clock()
  local N, CPS, KEY = main.N, main.cps, main.KEY
  local CELL = main.cell
  local NW = N + 1
  local S = ter.size
  local ox, oy, invC = ter.ox, ter.oy, 1 / CELL
  local depthAt = main.depthAt
  local depthByKind = rc.preDepth or { mud = 0.3, sand = 0.17, snow = 0.1 }
  local skip, basins = {}, {}
  for _, t in ipairs(rc.preSkipMatch or { 'line', 'asphalt', 'invisible', 'skidmark' }) do skip[#skip + 1] = tostring(t):lower() end
  for _, t in ipairs(rc.preBasinMatch or { 'water', 'puddle' }) do basins[#basins + 1] = tostring(t):lower() end
  local softShare = rc.preSoftShare or 0.3
  local margin = rc.preMargin or 0.03
  local F = profileOf(rc)
  local basinDepth = rc.preBasin or 0.6

  local off, nTiles, nCells = {}, 0, 0
  local vdepth = {} -- vertex -> sink depth (cache)
  local function vDepth(gx, gy)
    local k = gy * S + gx
    local d = vdepth[k]
    if d == nil then
      local dd, mem = depthAt(gx, gy)
      d = (mem and dd > 0) and dd or 0
      vdepth[k] = d
    end
    return d
  end
  -- stacked roads blend like the decals do: a road drawn later lies over the earlier
  -- ones by its fade (keeping the deepest dip flattened a 25 m puddle decal's whole area)
  local function write(tx, ty, i, j, o, op)
    local key = ty * KEY + tx
    local a = off[key]
    if not a then
      a = ffi.new('float[?]', NW * NW)
      off[key] = a
      nTiles = nTiles + 1
    end
    local idx = j * NW + i
    a[idx] = a[idx] + (o - a[idx]) * op
  end
  local function setCell(gcx, gcy, o, op)
    local tx, ty = floor(gcx / N), floor(gcy / N)
    local i, j = gcx - tx * N, gcy - ty * N
    write(tx, ty, i, j, o, op)
    if i == 0 then write(tx - 1, ty, N, j, o, op) end
    if j == 0 then write(tx, ty - 1, i, N, o, op) end
    if i == 0 and j == 0 then write(tx - 1, ty - 1, N, N, o, op) end
  end

  -- one triangle with per-corner (u across 0..1, s along in m, road width): every cell
  -- vertex inside gets the offset; fades over endFade m at the road's ends and edgeFade
  -- of its width at the sides
  local endFade, edgeFade = rc.preEndFade or 1.5, rc.preEdgeFade or 0.1
  local roadLen, seed, basin = 0, 0, false
  local function tri(depth, ax, ay, au, as, aw, bx, by, bu, bs, bw, cx, cy, cu, cs, cw)
    local det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if abs(det) < 1e-9 then return end
    local id = 1 / det
    local gx0 = floor((min(ax, bx, cx) - ox) * invC)
    local gx1 = ceil((max(ax, bx, cx) - ox) * invC)
    local gy0 = floor((min(ay, by, cy) - oy) * invC)
    local gy1 = ceil((max(ay, by, cy) - oy) * invC)
    for gcy = gy0, gy1 do
      local py = oy + gcy * CELL
      for gcx = gx0, gx1 do
        local px = ox + gcx * CELL
        local l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) * id
        local l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) * id
        local l3 = 1 - l1 - l2
        if l1 >= -1e-6 and l2 >= -1e-6 and l3 >= -1e-6 then
          -- soft at the nearest terrain vertex (rounded cell / CPS)
          local gx, gy = floor(gcx / CPS + 0.5), floor(gcy / CPS + 0.5)
          local d = (gx >= 0 and gy >= 0 and gx < S and gy < S) and vDepth(gx, gy) or 0
          if d > 0 then
            local u = l1 * au + l2 * bu + l3 * cu
            local s = l1 * as + l2 * bs + l3 * cs
            local wid = l1 * aw + l2 * bw + l3 * cw
            local h
            if basin then
              h = -basinDepth * smooth(min(u, 1 - u) / 0.3)
            else
              h = profile(F, (u - 0.5) * wid, s, wid, seed)
            end
            local op = smooth(min(s, roadLen - s) / endFade) * smooth(min(u, 1 - u) / edgeFade)
            local o = depth * h
            if o < -(d - margin) then o = -(d - margin) end
            if op > 0.004 then
              setCell(gcx, gcy, o, op > 1 and 1 or op)
              nCells = nCells + 1
            end
          end
        end
      end
    end
  end

  local nRoads = 0
  local prints = {} -- wheel lines of the first pass: x0, y0, x1, y1, width (5 numbers each)
  -- in drawing order: DecalRoads are drawn in descending renderPriority (exe string),
  -- the last drawn lies on top
  local list = {}
  for _, r in ipairs(P.roadEdges()) do
    local okR, rp = pcall(function() return tonumber(r.road:getField('renderPriority', 0)) end)
    r.prio = okR and rp or 10
    list[#list + 1] = r
  end
  table.sort(list, function(a, b) return a.prio > b.prio end)
  for ri, r in ipairs(list) do
    if ri % 16 == 0 and P.coYield then P.coYield() end
    local mat = (r.mat or ''):lower()
    local use = mat ~= ''
    for _, t in ipairs(skip) do
      if use and t ~= '' and mat:find(t, 1, true) then use = false end
    end
    local e = r.e
    if use and #e >= 8 then
      -- share of the road's centre points on soft ground
      local soft, pts = 0, 0
      for i = 1, #e - 3, 4 do
        if e[i] then
          pts = pts + 1
          if P.softAtWorld(0.5 * (e[i] + e[i + 2]), 0.5 * (e[i + 1] + e[i + 3])) then soft = soft + 1 end
        end
      end
      if pts > 0 and soft / pts >= softShare then
        basin = false
        for _, t in ipairs(basins) do
          if t ~= '' and mat:find(t, 1, true) then basin = true end
        end
        -- kind of the ground under the road's middle point
        local mi = 4 * floor((#e / 4) / 2) + 1
        local mx, my = 0.5 * (e[mi] or e[1]) + 0.5 * (e[mi + 2] or e[3]), 0.5 * (e[mi + 1] or e[2]) + 0.5 * (e[mi + 3] or e[4])
        local kind = main.layerKindAt(floor((mx - ox) / ter.sq + 0.5), floor((my - oy) / ter.sq + 0.5)) or 'mud'
        local depth = (tonumber(depthByKind[kind]) or tonumber(depthByKind.mud) or 0.15) * (rc.preDepthScale or 1)
        nRoads = nRoads + 1
        -- same road, same ruts on every load: the seed comes from its first edge point
        seed = bit.band(bit.bxor(floor((e[1] or 0) * 8) * 92821, floor((e[2] or 0) * 8) * 68917), 0xfffff)
        roadLen = 0
        do
          local qx, qy = nil, nil
          for i = 1, #e - 3, 4 do
            if e[i] then
              local mx2, my2 = 0.5 * (e[i] + e[i + 2]), 0.5 * (e[i + 1] + e[i + 3])
              if qx then roadLen = roadLen + sqrt((mx2 - qx) ^ 2 + (my2 - qy) ^ 2) end
              qx, qy = mx2, my2
            else
              qx = nil
            end
          end
        end
        local s0, pl, w0 = 0, nil, 0
        for i = 1, #e - 3, 4 do
          local cur = nil
          if e[i] then cur = { e[i], e[i + 1], e[i + 2], e[i + 3] } end
          if cur then
            local w1 = sqrt((cur[3] - cur[1]) ^ 2 + (cur[4] - cur[2]) ^ 2)
            if pl then
              local cxp, cyp = 0.5 * (pl[1] + pl[3]), 0.5 * (pl[2] + pl[4])
              local cxn, cyn = 0.5 * (cur[1] + cur[3]), 0.5 * (cur[2] + cur[4])
              local s1 = s0 + sqrt((cxn - cxp) ^ 2 + (cyn - cyp) ^ 2)
              -- l0 (0, s0), r0 (1, s0), l1 (0, s1) / r0, r1 (1, s1), l1
              tri(depth, pl[1], pl[2], 0, s0, w0, pl[3], pl[4], 1, s0, w0, cur[1], cur[2], 0, s1, w1)
              tri(depth, pl[3], pl[4], 1, s0, w0, cur[3], cur[4], 1, s1, w1, cur[1], cur[2], 0, s1, w1)
              if not basin and w0 > 0.3 and w1 > 0.3 then
                -- the first pass's wheel lines at both segment ends (same wander as the profile)
                local twin = min(w0, w1) >= F.single
                for side = twin and -1 or 1, 1, 2 do
                  local n = #prints
                  local q = nil
                  for k = 0, 1 do
                    local s, w, a = k == 0 and s0 or s1, k == 0 and w0 or w1, k == 0 and pl or cur
                    q = passOf(F, seed, 1, w)
                    local wv = F.wander * ((noise1(s / q.wl, q.ps) * 2 - 1) + 0.3 * (noise1(s / (q.wl * 0.31), q.ps + 7) * 2 - 1))
                    local u = min(1, max(0, 0.5 + ((twin and side * q.g or 0) + q.off + wv) / w))
                    prints[n + 1 + 2 * k] = a[1] + (a[3] - a[1]) * u
                    prints[n + 2 + 2 * k] = a[2] + (a[4] - a[2]) * u
                  end
                  prints[n + 5] = max(0.2, 2 * q.w)
                end
              end
              s0 = s1
            end
            w0 = w1
          end
          pl = cur
        end
      end
    end
  end

  -- per vertex: offset at the vertex, dip under it (deepest dip within preReach)
  local vOff, dip = {}, {}
  local Rc = max(0, ceil((rc.preReach or 0.6) / CELL))
  local nV = 0
  for key, a in pairs(off) do
    local tx, ty = key % KEY, floor(key / KEY)
    local gcx0, gcy0 = tx * N, ty * N
    for j = 0, N do
      for i = 0, N do
        local o = a[j * NW + i]
        if o ~= 0 then
          local gcx, gcy = gcx0 + i, gcy0 + j
          if i % CPS == 0 and j % CPS == 0 then
            vOff[(gcy / CPS) * S + gcx / CPS] = o
          end
          if o < 0 then
            local need = -o + margin
            for gy = ceil((gcy - Rc) / CPS), floor((gcy + Rc) / CPS) do
              for gx = ceil((gcx - Rc) / CPS), floor((gcx + Rc) / CPS) do
                if gx >= 0 and gy >= 0 and gx < S and gy < S then
                  local vk = gy * S + gx
                  local cur = dip[vk]
                  if not cur then nV = nV + 1 end
                  if not cur or need > cur then dip[vk] = need end
                end
              end
            end
          end
        end
      end
    end
  end
  local ms = (os.clock() - t0) * 1000
  log('I', logTag, sfmt('pre-rutted %d road(s): %d cells in %d tiles, %d terrain vertices lowered, %d wheel lines, %.0f ms',
    nRoads, nCells, nTiles, nV, #prints / 5, ms))
  return { off = off, vOff = vOff, dip = dip, tiles = nTiles, cells = nCells, roads = nRoads, vertices = nV, ms = ms,
    prints = prints }
end

-- tests / tools: the profile (x depth) at lateral offset x, distance s, road width wid
function M.profileAt(x, s, wid, seed, rc)
  hash = hash or extensions.deepnode_tileMesh.hash01
  return profile(profileOf(rc or {}), x, s, wid, seed or 1)
end

return M
