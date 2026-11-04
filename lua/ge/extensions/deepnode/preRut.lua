-- deepnode_preRut
-- Decal roads on soft ground as real ruts from the start.
--
-- A level's mud decal roads (tyre tracks, furrows, puddles) only paint ruts on flat
-- ground. At mod start their normal maps become height maps and the mud starts out in
-- that shape: the tracks are carved into the undisturbed surface (`rest`), the terrain
-- under them is lowered so the mesh shows and the heavy physics floor follows them.
--
-- Height from a normal map: the textures are BC5 (two BC4 channels, x and y of the
-- tangent normal) with mips. A small mip (about roads.preTexWidth pixels across the road)
-- is decoded here in Lua; each row is integrated across the road (dh/du = -nx / nz) and
-- detrended so both road edges sit at 0 (the decal fades into the terrain there), rows are
-- smoothed along the road, and the result is scaled so its 5th percentile (weighted by the
-- opacity map) is -1. The opacity map (BC4) fades it out. Measured offline on the stock
-- textures: mud_tiretracks and tread_marks_clean give two low wheel strips, the dirt road
-- variation a dish (road edges high).
--
-- Rasterising: every road segment (left/right edge pair) is split into two triangles;
-- each 0.2 m cell vertex inside gets (u across 0..1, distance along), v = -distance /
-- textureLength (DecalRoad UV, see ENGINE_FINDINGS), and the offset
-- roads.preDepth[kind] x height(u, v) x opacity. Stacked roads keep the deepest dip.
-- Output, per tile key: a float array of (N + 1)^2 cell offsets; per terrain vertex:
-- the offset at the vertex (main.vertexInfo adds it to rest) and the dip under it (the
-- sink pass lowers the terrain by it, so the squares are not flush any more).

local M = {}

local ffi = require('ffi')
local floor, ceil, min, max, abs, sqrt, huge = math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt, math.huge
local sfmt = string.format
local logTag = 'deepnode.preRut'

local texCache = {}

-------------------------------------------------------------------------------
-- DDS (BC4 / BC5) decoding of one mip
-------------------------------------------------------------------------------
local pal = ffi.new('int32_t[8]')
local function bc4Palette(a0, a1)
  pal[0], pal[1] = a0, a1
  if a0 > a1 then
    for k = 1, 6 do pal[k + 1] = floor(((7 - k) * a0 + k * a1) / 7 + 0.5) end
  else
    for k = 1, 4 do pal[k + 1] = floor(((5 - k) * a0 + k * a1) / 5 + 0.5) end
    pal[6], pal[7] = 0, 255
  end
end

-- decode a BC4 block at byte offset o (0-based) of the string p into out (float 0..1,
-- row stride w) at x0, y0. ffi.cast of a string is not available in the GE VM (returns
-- the string): bytes are read with string.byte.
local byte = string.byte
local function bc4Block(p, o, out, w, h, x0, y0, stride, comp)
  local a0, a1, b2, b3, b4, b5, b6, b7 = byte(p, o + 1, o + 8)
  bc4Palette(a0, a1)
  -- 48 index bits, little endian: two 24-bit halves (8 pixels each)
  local lo = b2 + b3 * 256 + b4 * 65536
  local hi = b5 + b6 * 256 + b7 * 65536
  for k = 0, 15 do
    local bits
    if k < 8 then bits = floor(lo / 2 ^ (3 * k)) % 8 else bits = floor(hi / 2 ^ (3 * (k - 8))) % 8 end
    local x, y = x0 + k % 4, y0 + floor(k / 4)
    if x < w and y < h then out[(y * w + x) * stride + comp] = pal[bits] / 255 end
  end
end

local function u32(p, o)
  local a, b, c, d = byte(p, o + 1, o + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

-- returns { w, h, ch (1 or 2), data = float[w*h*ch] } of the smallest mip at least
-- minW wide, or nil, reason
local function decodeDDS(path, minW)
  local s = readFile and readFile(path)
  if type(s) ~= 'string' or #s < 128 then return nil, 'unreadable' end
  local p = s
  if s:sub(1, 4) ~= 'DDS ' then return nil, 'not a DDS' end
  local h, w = u32(p, 12), u32(p, 16)
  local mips = max(1, u32(p, 28))
  local four = s:sub(85, 88)
  local off = 128
  local ch
  if four == 'BC5U' or four == 'ATI2' then ch = 2
  elseif four == 'BC4U' or four == 'ATI1' then ch = 1
  elseif four == 'DX10' then
    local dx = u32(p, 128)
    off = 148
    if dx == 83 then ch = 2 elseif dx == 80 then ch = 1 else return nil, 'dxgi format ' .. dx end
  else
    return nil, 'format ' .. four
  end
  local bsize = ch == 2 and 16 or 8
  local level = 0
  local mw, mh = w, h
  while level < mips - 1 and floor(mw / 2) >= minW do
    off = off + max(1, ceil(mw / 4)) * max(1, ceil(mh / 4)) * bsize
    mw, mh = max(1, floor(mw / 2)), max(1, floor(mh / 2))
    level = level + 1
  end
  local bw, bh = max(1, ceil(mw / 4)), max(1, ceil(mh / 4))
  if off + bw * bh * bsize > #s then return nil, 'truncated' end
  local data = ffi.new('float[?]', mw * mh * ch)
  local o = off
  for by = 0, bh - 1 do
    for bx = 0, bw - 1 do
      bc4Block(p, o, data, mw, mh, bx * 4, by * 4, ch, 0)
      if ch == 2 then bc4Block(p, o + 8, data, mw, mh, bx * 4, by * 4, ch, 1) end
      o = o + bsize
    end
  end
  return { w = mw, h = mh, ch = ch, data = data, level = level }
end

local function ddsPath(p)
  if type(p) ~= 'string' or p == '' then return nil end
  if p:sub(1, 1) ~= '/' then p = '/' .. p end
  local d = p:gsub('%.[%w]+$', '.dds')
  if FS and FS.fileExists and FS:fileExists(d) then return d end
  if FS and FS.fileExists and FS:fileExists(p) then return p end
  return d
end

-------------------------------------------------------------------------------
-- FFT (radix 2, in place) for the height integration
-------------------------------------------------------------------------------
local function isPow2(n) return n >= 1 and floor(n) == n and 2 ^ floor(math.log(n) / math.log(2) + 0.5) == n end

-- 1D FFT over n complex values re/im at off + k * stride
local function fft1(re, im, off, stride, n, inv)
  local j = 0
  for i = 0, n - 2 do
    if i < j then
      local a, b = off + i * stride, off + j * stride
      re[a], re[b] = re[b], re[a]
      im[a], im[b] = im[b], im[a]
    end
    local m = n / 2
    while m >= 1 and j >= m do j = j - m; m = m / 2 end
    j = j + m
  end
  local len = 2
  while len <= n do
    local ang = (inv and 2 or -2) * math.pi / len
    local wr, wi = math.cos(ang), math.sin(ang)
    local half = len / 2
    for i = 0, n - 1, len do
      local cr, ci = 1, 0
      for k = 0, half - 1 do
        local a = off + (i + k) * stride
        local b = a + half * stride
        local tr = re[b] * cr - im[b] * ci
        local ti = re[b] * ci + im[b] * cr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    len = len * 2
  end
end

-- 2D FFT of a w x h grid (row major); the inverse is scaled by 1 / (w h)
local function fft2(re, im, w, h, inv)
  for y = 0, h - 1 do fft1(re, im, y * w, 1, w, inv) end
  for x = 0, w - 1 do fft1(re, im, x, w, h, inv) end
  if inv then
    local k = 1 / (w * h)
    for i = 0, w * h - 1 do re[i] = re[i] * k; im[i] = im[i] * k end
  end
end

-------------------------------------------------------------------------------
-- height field of a decal material
-------------------------------------------------------------------------------
-- { w, h, hgt = float[w*h] (about -1 .. 0.6), op = float[w*h] } or nil, reason
local function heightOf(mat, rc)
  local nmPath = ddsPath(mat:getField('normalMap', 0))
  if not nmPath then return nil, 'no normal map' end
  local opPath = ddsPath(mat:getField('opacityMap', 0))
  local key = nmPath .. '|' .. tostring(opPath)
  local c = texCache[key]
  if c ~= nil then return c or nil, 'cached failure' end
  local minW = rc.preTexWidth or 64
  local nm, why = decodeDDS(nmPath, minW)
  if not nm or nm.ch ~= 2 then
    texCache[key] = false
    return nil, 'normal map ' .. nmPath .. ': ' .. tostring(why or 'not BC5')
  end
  local W, H = nm.w, nm.h
  if not isPow2(W) or not isPow2(H) then
    texCache[key] = false
    return nil, sfmt('mip %dx%d is not a power of two', W, H)
  end
  -- slopes (dh/du, dh/dv in pixels); green is flipped (DirectX normal maps: the
  -- integrability residual is lower that way on every stock decal, measured offline)
  local W2 = 2 * W
  local n2 = W2 * H
  local gxr, gxi = ffi.new('double[?]', n2), ffi.new('double[?]', n2)
  local gyr, gyi = ffi.new('double[?]', n2), ffi.new('double[?]', n2)
  local d = nm.data
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local i = (y * W + x) * 2
      local nx, ny = d[i] * 2 - 1, d[i + 1] * 2 - 1
      local nz = sqrt(max(0.05, 1 - nx * nx - ny * ny))
      local gx, gy = -nx / nz, ny / nz
      -- mirrored across the road (u is not periodic): gx odd, gy even
      gxr[y * W2 + x], gxr[y * W2 + W2 - 1 - x] = gx, -gx
      gyr[y * W2 + x], gyr[y * W2 + W2 - 1 - x] = gy, gy
    end
  end
  fft2(gxr, gxi, W2, H, false)
  fft2(gyr, gyi, W2, H, false)
  -- least squares height: H = -j 2pi (fx GX + fy GY) / (2pi)^2 (fx^2 + fy^2)
  local tp = 2 * math.pi
  for y = 0, H - 1 do
    local fy = (y <= H / 2) and y / H or (y - H) / H
    for x = 0, W2 - 1 do
      local fx = (x <= W2 / 2) and x / W2 or (x - W2) / W2
      local i = y * W2 + x
      local den = tp * tp * (fx * fx + fy * fy)
      if den == 0 then
        gxr[i], gxi[i] = 0, 0
      else
        -- a = fx GX + fy GY; H = -j tp a / den: (ar + j ai) * -j = ai - j ar
        local ar = fx * gxr[i] + fy * gyr[i]
        local ai = fx * gxi[i] + fy * gyi[i]
        gxr[i], gxi[i] = tp * ai / den, -tp * ar / den
      end
    end
  end
  fft2(gxr, gxi, W2, H, true)
  local hg = ffi.new('float[?]', W * H)
  for y = 0, H - 1 do
    for x = 0, W - 1 do hg[y * W + x] = gxr[y * W2 + x] end
  end
  -- high pass: minus a wide box blur (twice, periodic in v, clamped in u). The normal
  -- maps carry a low-frequency bias that the integration turns into a bowl over the road.
  local sm = ffi.new('float[?]', W * H)
  local tmp = ffi.new('float[?]', W * H)
  local Rb = max(2, floor(W * (rc.preHighPass or (1 / 6))))
  local function boxV(src, dst, r)
    for x = 0, W - 1 do
      local s = 0
      for k = -r, r do s = s + src[(k % H) * W + x] end
      for y = 0, H - 1 do
        dst[y * W + x] = s / (2 * r + 1)
        s = s - src[((y - r) % H) * W + x] + src[((y + r + 1) % H) * W + x]
      end
    end
  end
  local function boxU(src, dst, r)
    for y = 0, H - 1 do
      local b = y * W
      for x = 0, W - 1 do
        local s, n = 0, 0
        for k = max(0, x - r), min(W - 1, x + r) do s = s + src[b + k]; n = n + 1 end
        dst[b + x] = s / n
      end
    end
  end
  boxV(hg, tmp, Rb); boxU(tmp, sm, Rb); boxV(sm, tmp, Rb); boxU(tmp, sm, Rb)
  for i = 0, W * H - 1 do sm[i] = hg[i] - sm[i] end
  -- light smoothing against cell-size speckle of the lumpy mud maps
  local Rs = max(0, floor(rc.preSmoothRows or 1))
  if Rs > 0 then boxV(sm, tmp, Rs); boxU(tmp, sm, max(0, floor(rc.preSmoothCols or 1))) end
  -- opacity on the same grid (nearest)
  local op = ffi.new('float[?]', W * H)
  local om = opPath and decodeDDS(opPath, minW) or nil
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local v = 1
      if om and om.ch == 1 then
        local ox = min(om.w - 1, floor((x + 0.5) * om.w / W))
        local oy = min(om.h - 1, floor((y + 0.5) * om.h / H))
        v = om.data[oy * om.w + ox]
      end
      op[y * W + x] = v
    end
  end
  -- level: median of the visible part -> 0; scale: its 5th percentile -> -1
  local vals = {}
  for i = 0, W * H - 1, 3 do
    if op[i] > 0.5 then vals[#vals + 1] = sm[i] end
  end
  if #vals < 16 then
    texCache[key] = false
    return nil, 'no opaque texels'
  end
  table.sort(vals)
  local med = vals[max(1, floor(#vals * 0.5))]
  local p5 = vals[max(1, floor(#vals * 0.05))] - med
  local basin = false
  if p5 > -(rc.preFlatRelief or 0.1) then
    -- next to no relief (water puddles: flat normals): the decal is a basin, deepest
    -- where it is most opaque
    basin = true
    for i = 0, W * H - 1 do sm[i] = -(rc.preBasin or 0.6) end
  else
    local k = -1 / p5
    local lo, hi = -(rc.preClampLow or 1.5), rc.preClampHigh or 0.6
    for i = 0, W * H - 1 do
      local v = (sm[i] - med) * k
      if v < lo then v = lo elseif v > hi then v = hi end
      sm[i] = v
    end
  end
  local res = { w = W, h = H, hgt = sm, op = op, path = nmPath, level = nm.level, basin = basin }
  texCache[key] = res
  return res
end

local function sampleTex(T, u, v)
  local W, H = T.w, T.h
  local x = u * W - 0.5
  if x < 0 then x = 0 elseif x > W - 1 then x = W - 1 end
  local y = (v % 1) * H - 0.5
  local x0, y0 = floor(x), floor(y)
  local fx, fy = x - x0, y - y0
  local x1 = min(W - 1, x0 + 1)
  local ya, yb = y0 % H, (y0 + 1) % H
  local a, b = ya * W, yb * W
  local hg, op = T.hgt, T.op
  local h = (hg[a + x0] * (1 - fx) + hg[a + x1] * fx) * (1 - fy) + (hg[b + x0] * (1 - fx) + hg[b + x1] * fx) * fy
  local o = (op[a + x0] * (1 - fx) + op[a + x1] * fx) * (1 - fy) + (op[b + x0] * (1 - fx) + op[b + x1] * fx) * fy
  return h, o
end

-------------------------------------------------------------------------------
-- build
-------------------------------------------------------------------------------
-- main: the deepnode_main module (M), P: its private table. Returns the result table
-- { off = { [tileKey] = float[(N+1)^2] }, vOff = { [vertex] = z }, dip = { [vertex] = m },
--   tiles = n, cells = n, roads = n } or nil.
function M.build(main, P)
  local cfg = main.cfg
  local rc = cfg.roads or {}
  if rc.preRut == false then return nil end
  local ter = main.ter
  if not ter or (ter.K or 1) > 1 then return nil end
  local t0 = os.clock()
  local N, CPS, KEY = main.N, main.cps, main.KEY
  local CELL = main.cell
  local NW = N + 1
  local S = ter.size
  local ox, oy, invC = ter.ox, ter.oy, 1 / CELL
  local depthAt = main.depthAt
  local depthByKind = rc.preDepth or { mud = 0.15, sand = 0.08, snow = 0.1 }
  local skip = {}
  for _, t in ipairs(rc.preSkipMatch or { 'line', 'asphalt', 'invisible', 'skidmark' }) do skip[#skip + 1] = tostring(t):lower() end
  local softShare = rc.preSoftShare or 0.3
  local margin = rc.preMargin or 0.03

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
  -- ones by its opacity (keeping the deepest dip flattened a 25 m puddle decal's whole
  -- area to one level: every furrow on it was lost)
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

  -- one triangle with per-corner (u, s): every cell vertex inside gets the offset
  -- fades: over endFade m at the road's ends and edgeFade of its width at the sides (the
  -- ends had no fade: a hard step across the mud)
  local endFade, edgeFade = rc.preEndFade or 1.5, rc.preEdgeFade or 0.1
  local roadLen = 0
  local function smooth(x) if x <= 0 then return 0 elseif x >= 1 then return 1 end return x * x * (3 - 2 * x) end
  local function tri(T, len, depth, ax, ay, au, as, bx, by, bu, bs, cx, cy, cu, cs)
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
            local h, op = sampleTex(T, u, -s / len)
            op = op * smooth(min(s, roadLen - s) / endFade) * smooth(min(u, 1 - u) / edgeFade)
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

  local nRoads, failed = 0, {}
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
    local use = r.mat ~= ''
    for _, t in ipairs(skip) do
      if use and t ~= '' and r.mat:find(t, 1, true) then use = false end
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
        local road = r.road
        local okM, matName = pcall(function() return road:getField('material', 0) end)
        local mat = okM and matName and scenetree.findObject(matName)
        local len = tonumber(road:getField('textureLength', 0)) or 5
        if len <= 0.01 then len = 5 end
        local T, why = nil, 'no material'
        if mat then T, why = heightOf(mat, rc) end
        if T then
          -- kind of the ground under the road's middle point
          local mi = 4 * floor((#e / 4) / 2) + 1
          local mx, my = 0.5 * (e[mi] or e[1]) + 0.5 * (e[mi + 2] or e[3]), 0.5 * (e[mi + 1] or e[2]) + 0.5 * (e[mi + 3] or e[4])
          local kind = main.layerKindAt(floor((mx - ox) / ter.sq + 0.5), floor((my - oy) / ter.sq + 0.5)) or 'mud'
          local depth = (tonumber(depthByKind[kind]) or tonumber(depthByKind.mud) or 0.15) * (rc.preDepthScale or 1)
          nRoads = nRoads + 1
          local s0 = 0
          local pl = nil
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
          for i = 1, #e - 3, 4 do
            local cur = nil
            if e[i] then cur = { e[i], e[i + 1], e[i + 2], e[i + 3] } end
            if cur and pl then
              local cxp, cyp = 0.5 * (pl[1] + pl[3]), 0.5 * (pl[2] + pl[4])
              local cxn, cyn = 0.5 * (cur[1] + cur[3]), 0.5 * (cur[2] + cur[4])
              local s1 = s0 + sqrt((cxn - cxp) ^ 2 + (cyn - cyp) ^ 2)
              -- l0 (0, s0), r0 (1, s0), l1 (0, s1) / r0, r1 (1, s1), l1
              tri(T, len, depth, pl[1], pl[2], 0, s0, pl[3], pl[4], 1, s0, cur[1], cur[2], 0, s1)
              tri(T, len, depth, pl[3], pl[4], 1, s0, cur[3], cur[4], 1, s1, cur[1], cur[2], 0, s1)
              s0 = s1
            end
            pl = cur
          end
        else
          failed[r.mat] = why
        end
      end
    end
  end
  for m, why in pairs(failed) do log('W', logTag, sfmt('road material %s skipped: %s', m, tostring(why))) end

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
  log('I', logTag, sfmt('pre-rutted %d road(s): %d cells in %d tiles, %d terrain vertices lowered, %.0f ms',
    nRoads, nCells, nTiles, nV, ms))
  return { off = off, vOff = vOff, dip = dip, tiles = nTiles, cells = nCells, roads = nRoads, vertices = nV, ms = ms }
end

-- tests / tools: decode a texture and return its height field
function M.heightField(matName, rc)
  local mat = scenetree.findObject(matName)
  if not mat then return nil, 'no material' end
  return heightOf(mat, rc or {})
end

function M.clearCache() texCache = {} end

return M
