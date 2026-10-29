-- deepnode_wheelMud
-- Mud on the tyres, and chunks that drop off them.
--
-- Rewrite (2026-10-24). The old skin re-uploaded a 36-segment mesh whenever the coat
-- changed (10 uploads/s of ~2.8 ms with 6 trucks, engine memory kept per upload) and
-- switched whole quads on and off (blocky edges). Now:
--  * every wheel owns ONE mesh, built once per wheel definition (spawn, config change):
--    the tyre cross-section (rim, sidewall, rounded shoulder, tread) swept round the
--    axle at ~6 cm steps, lifted off the tyre by a cake thickness that follows the mud
--    blobs of the texture (thick where mud sticks first);
--  * which part of that skin shows is decided per pixel by the material's alpha clip:
--    art/deepnode/t_tyremud_o.data.png holds a coverage order (tread first, then
--    shoulders, then blotches over the sidewalls; histogram-equalised, see
--    art/deepnode/bake_tyremud.py), so alphaRef = 255 - 254 x coverage shows exactly
--    that share. Each wheel has its own material; a change is setField + flush
--    (~0.4-0.8 ms measured, no lasting engine memory over 600 flushes), at most
--    clods.flushPerFrame per frame inside the shared upload budget;
--  * a coat thicker than 1 grows the skin outwards with the wheel transform's scale;
--  * chunks: a fixed pool of small lump meshes (uploaded once) moved with setTransform:
--    they drop off a tyre that loses its loose mud or flings it, fall, lie on the ground
--    and sink away after clods.chunkLife seconds. No mesh upload while driving.
-- Wheel frame (MatrixF columns: 0 = axle, 1/2 = spin frame, position = wheel centre) as in
-- ge/extensions/core/vehicles.lua; node positions from veh:getNodeAbsPositionXYZ.
--
-- Coat model (per wheel, 0..coatMax; 0..1 = covered share, above 1 = thicker cake):
--  * in mud the tread picks mud up per metre it rolls (spin churns more on), more in
--    deep mud, saturating towards the kind's coatMax; x clods.buildRate;
--  * the outer layer is loose (looseShare of the coat): out of the mud it falls off over
--    the first metres (this is what drops the chunks), the rest packs down (packTime)
--    and wears off slowly with distance; a fast spinning tyre flings mud off (chunks
--    too); water washes it off (no chunks); all losses x clods.wearRate.

local M = {}

local floor, min, max, sqrt, abs, huge = math.floor, math.min, math.max, math.sqrt, math.abs, math.huge
local sin, cos, atan2 = math.sin, math.cos, math.atan2 or math.atan
local sfmt = string.format

local TEX_B = '/art/deepnode/t_tyremud_b.color.png'
local TEX_O = '/art/deepnode/t_tyremud_o.data.png'
local ORDER_FILE = '/art/deepnode/tyremud_order.json'
local MAT = 'deepnode_clod'

local ctx = nil
local vehs = {}
local session = 0
local enabled = true
local now = 0
local objCounter, matCounter = 0, 0
local camX, camY, camZ = 0, 0, 0
local builder = nil
local order = nil           -- { w, h, data } coverage order lookup (0..255), u fastest
local matFree = {}          -- released tyre materials { name, mat } for reuse
local filmFree = {}         -- released water film materials
local chunkPools = {}       -- kind -> { free = {objects}, n = created }
local chunks = {}           -- active chunks
local chunkFree = {}        -- spare chunk state tables
local geoVerts, geoCorners = 0, 0
local counters = { flushes = 0, meshes = 0, chunks = 0, washed = 0, flushMs = 0, meshMs = 0 }
local lumpVariants = nil

local function isFinite(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function tm() return extensions and extensions.deepnode_tileMesh end

local function hash01(a, b, c)
  local t = tm()
  if t then return t.hash01(a, b, c) end
  return ((a * 92821 + b * 68917 + (c or 0) * 1237) % 1000) / 1000
end

-- per-kind settings, unknown kinds use mud
local function kindCfg(kind)
  local ks = ctx and ctx.cfg.clods.kinds
  return (ks and (ks[kind] or ks.mud)) or { stick = 1, coatMax = 3, shed = 1, color = { 0.5, 0.475, 0.44 }, roughness = 0.5 }
end

local function matOf(kind)
  if kind == nil or kind == 'mud' then return MAT end
  local ks = ctx and ctx.cfg.clods.kinds
  if ks and ks[kind] then return MAT .. '_' .. kind end
  return MAT
end

local function newObject(tag)
  objCounter = objCounter + 1
  local o = createObject('ProceduralMesh')
  if not o then return nil end
  o.canSave = false
  o:registerObject(sfmt('deepnode_tyre_%d_%s_%d', session, tag, objCounter))
  local t = tm()
  local grp = t and t.getGroup and t.getGroup() or scenetree.MissionGroup
  if grp then
    if grp.addObject then grp:addObject(o.obj) elseif grp.add then grp:add(o.obj) end
  end
  o:setHidden(true)
  return o
end

-- createMesh, timed and charged to the shared upload budget
local function upload(o, meshes, kind)
  local nv, nc = 0, 0
  for i = 1, #meshes do nv = nv + #meshes[i].verts; nc = nc + #meshes[i].faces end
  local timer = hptimer and hptimer()
  o:createMesh({ meshes })
  local ms = timer and timer:stop() or 1
  local t_m = tm()
  if t_m and t_m.recordUpload then t_m.recordUpload(kind, nv, ms) end
  return nv, nc, ms
end

-------------------------------------------------------------------------------
-- coverage order lookup (the low-resolution copy of the texture's alpha)
-------------------------------------------------------------------------------
local function loadOrder()
  local d = jsonReadFile and jsonReadFile(ORDER_FILE)
  if type(d) == 'table' and type(d.data) == 'table' and d.w and d.h and #d.data >= d.w * d.h then
    order = d
  else
    order = nil
    log('W', 'deepnode', 'tyre mud: ' .. ORDER_FILE .. ' missing, flat cake')
  end
end

-- coverage order at texture (u, v) in 0..1 (1 = covered first); v wraps
local function orderAt(u, v)
  if not order then return 0.5 end
  local w, h, d = order.w, order.h, order.data
  local x = clamp(u, 0, 1) * w - 0.5
  local y = (v - floor(v)) * h - 0.5
  local x0, y0 = floor(x), floor(y)
  local fx, fy = x - x0, y - y0
  local x1 = min(w - 1, x0 + 1)
  x0 = max(0, x0)
  local y1 = (y0 + 1) % h
  y0 = y0 % h
  local a = d[y0 * w + x0 + 1] * (1 - fx) + d[y0 * w + x1 + 1] * fx
  local b = d[y1 * w + x0 + 1] * (1 - fx) + d[y1 * w + x1 + 1] * fx
  return (a * (1 - fy) + b * fy) / 255
end

-------------------------------------------------------------------------------
-- tyre materials (one per wheel, reused when wheels go)
-------------------------------------------------------------------------------
local function colorString(col)
  local b = ctx.cfg.clods.tyreBrightness or 1
  return sfmt('%g %g %g 1', (col[1] or 1) * b, (col[2] or 1) * b, (col[3] or 1) * b)
end

-- kind colour times the kind's own brightness (sand is much lighter than the mud the
-- global clods.tyreBrightness is tuned for)
local function kindColor(K)
  local c = K.color or { 0.5, 0.475, 0.44 }
  local b = K.brightness or 1
  if b == 1 then return c end
  return { (c[1] or 1) * b, (c[2] or 1) * b, (c[3] or 1) * b }
end

local function tyreColor(K)
  return colorString(kindColor(K))
end

-- mean linear value of each kind's tyre base texture (measured at start): the coat
-- colour factor is the ground colour divided by it, so coat and ground match
local texMean = {}
local function texMeanOf(kind)
  return texMean[kind] or texMean.mud or 0.5
end

-- colour the coat takes from the ground under wheel W (nil: unknown, use the kind
-- colour); in colorString's space (it multiplies by clods.tyreBrightness). groundGain
-- defaults to the kind's `wet` factor (mud on a tyre is wetter, darker than the ground);
-- groundDesat moves it towards grey: dry dust on rubber reads paler than the ground
-- (and a sidewall misses the blue sky light the ground gets, so it renders warmer)
-- (three numbers, no table: called per wheel and coat tick)
local function groundColor(W, K)
  if not W.gr or ctx.cfg.clods.groundColor == false then return nil end
  local k = (K.groundGain or K.wet or 1) / (texMeanOf(W.kind) * max(0.05, ctx.cfg.clods.tyreBrightness or 1))
  local r, g, b = W.gr, W.gg, W.gb
  local ds = K.groundDesat or 0
  if ds > 0 then
    local l = 0.2126 * r + 0.7152 * g + 0.0722 * b
    r, g, b = r + (l - r) * ds, g + (l - g) * ds, b + (l - b) * ds
  end
  return r * k, g * k, b * k
end

-- kind the tyre is drawn with (textures, coverage, cake thickness): follows the coat's
-- kind with the look delay (updateLook)
local function lookKind(W)
  return W.dkind or W.kind
end

-- colour the wheel's coat is drawn with: the coat's colour (mixed by mass, see
-- updateCoat) through the look delay (updateLook); nil = clean tyre
local function wheelColor(W)
  return W.dcol or W.col or kindColor(kindCfg(lookKind(W)))
end

local function colorDiff(a, b)
  if not a or not b then return huge end
  return max(abs(a[1] - b[1]), abs(a[2] - b[2]), abs(a[3] - b[3]))
end

-- textures of a soft-ground kind: base (monochrome, coverage order in alpha), coverage
-- order (opacity map), normal map. Sand has its own fine-grain set (bake_tyresand.py):
-- it packs into the tread and dusts the sidewalls instead of caking in blobs.
local function kindTextures(kind)
  local K = kindCfg(kind)
  local c = ctx.cfg.clods
  return K.texB or TEX_B, K.texO or TEX_O, K.texN or (c.texDir .. c.texBase .. '_nm.normal.dds')
end

-- wet look of the coat: roughness towards clods.wetRoughness, colour darker
local function wetRoughness(W, K)
  local r = K.roughness or 0.5
  local w = W.wet or 0
  if w <= 0 then return r end
  local wr = ctx.cfg.clods.wetRoughness or 0.22
  return r + (wr - r) * w
end
local function wetColor(W, col)
  local w = W.wet or 0
  if w <= 0 then return col end
  local k = 1 - (ctx.cfg.clods.wetDarken or 0.25) * w
  return { col[1] * k, col[2] * k, col[3] * k }
end

local function acquireMaterial(W)
  local K = kindCfg(lookKind(W))
  local e = table.remove(matFree)
  local col = wheelColor(W)
  local tb, to, tn = kindTextures(lookKind(W))
  local rough = wetRoughness(W, K)
  if e then
    if e.texB ~= tb then
      e.mat:setField('baseColorMap', 0, tb)
      e.mat:setField('opacityMap', 0, to)
      e.mat:setField('normalMap', 0, tn)
    end
    e.mat:setField('baseColorFactor', 0, colorString(wetColor(W, col)))
    e.mat:setField('roughnessFactor', 0, sfmt('%g', rough))
    e.mat:setField('alphaRef', 0, '255')
    e.mat:flush()
    W.matName, W.mat = e.name, e.mat
  else
    matCounter = matCounter + 1
    local name = sfmt('deepnode_tyremat_%d_%d', session, matCounter)
    local m = ctx.createMaterial(name, {
      { 'version', '1.5' }, { 'castShadows', '0' },
      { 'baseColorMap', tb }, { 'opacityMap', to },
      { 'normalMap', tn },
      { 'baseColorFactor', colorString(wetColor(W, col)) }, { 'roughnessFactor', sfmt('%g', rough) },
      { 'alphaTest', '1' }, { 'alphaRef', '255' },
    })
    W.matName, W.mat = name, m
  end
  W.matTex = tb
  W.ref, W.matKind = 255, lookKind(W)
  W.matCol = { col[1], col[2], col[3] }
  W.matWet = W.wet or 0
end

local function releaseMaterial(W)
  if W.film then filmFree[#filmFree + 1] = { name = W.filmName, mat = W.film } end
  W.film, W.filmName = nil, nil
  if W.mat then matFree[#matFree + 1] = { name = W.matName, mat = W.mat, texB = W.matTex } end
  W.mat, W.matName = nil, nil
end

-------------------------------------------------------------------------------
-- wet tyres: water film
-------------------------------------------------------------------------------
-- The vehicle's own tyre materials cannot be swapped per vehicle at runtime (measured:
-- vehicle:switchMaterial and setFlexmeshMaterial render the tyre chrome, even with its
-- own material, until a reset), so a wet tyre gets a water film from the mod: every
-- tyre skin mesh carries a second layer (all of the tyre, filmLift over it, under the
-- mud cake) with its own translucent material per wheel: dark, glossy (filmRoughness),
-- opacity filmOpacity x wetness, alpha-clipped away when dry. Updated in wetStep steps
-- through the material flush queue.
-- (opacity is opacityFactor: the base colour alpha is ignored, measured)
-- The film is muddy water, not clear (reference: trucks out of brown flood water): its
-- colour is the ground colour of the wheel's last soft ground x filmMud, else filmColor
-- grey; the texture (art/deepnode/bake_tyrefilm.py) streaks it where the water runs off.
local FILM_B = '/art/deepnode/t_tyrefilm_b.color.png'
local FILM_O = '/art/deepnode/t_tyrefilm_o.data.png'
local function filmFields(W)
  local c = ctx.cfg.clods
  local w = W.wet or 0
  local a = (c.filmOpacity or 0.2) * w
  return sfmt('%g', a), w > 0.01 and '1' or '255'
end

local function filmColor(W)
  local c = ctx.cfg.clods
  local m = c.filmMud or 0
  if W.gr and m > 0 and c.groundColor ~= false then
    return W.gr * m, W.gg * m, W.gb * m
  end
  local g = c.filmColor or 0.03
  return g, g, g
end

local function setFilmColor(W)
  local r, g, b = filmColor(W)
  W.film:setField('baseColorFactor', 0, sfmt('%g %g %g 1', r, g, b))
  W.filmCol = W.filmCol or {}
  W.filmCol[1], W.filmCol[2], W.filmCol[3] = r, g, b
end

local function acquireFilm(W)
  local op, ref = filmFields(W)
  local e = table.remove(filmFree)
  if e then
    W.filmName, W.film = e.name, e.mat
    e.mat:setField('opacityFactor', 0, op)
    e.mat:setField('alphaRef', 0, ref)
    setFilmColor(W)
    e.mat:flush()
  else
    matCounter = matCounter + 1
    local name = sfmt('deepnode_tyrefilm_%d_%d', session, matCounter)
    W.film = ctx.createMaterial(name, {
      { 'version', '1.5' }, { 'castShadows', '0' }, { 'translucent', '1' }, { 'translucentZWrite', '0' },
      { 'translucentBlendOp', 'LerpAlpha' }, { 'opacityFactor', op },
      { 'baseColorMap', FILM_B }, { 'opacityMap', FILM_O },
      { 'baseColorFactor', sfmt('%g %g %g 1', filmColor(W)) },
      { 'roughnessFactor', sfmt('%g', ctx.cfg.clods.filmRoughness or 0.08) },
      { 'alphaTest', '1' }, { 'alphaRef', ref },
    })
    W.filmName = name
  end
  W.filmWet = W.wet or 0
end

-------------------------------------------------------------------------------
-- tyre skin mesh
-------------------------------------------------------------------------------
-- cross-section of one tyre, both sidewalls: points { x, r, nx, nr, s (arc length) };
-- nSide = points per sidewall (to leave out the inner faces of a dual pair)
local function tyreProfile(w, Rv, rimR)
  local hw = w * 0.5
  local rs = clamp(min(hw * 0.45, (Rv - rimR) * 0.35), 0.01, 0.2)
  local top = Rv - rs
  local rim = min(rimR + 0.005, top - 0.01)
  local pts = {}
  local function add(x, r, nx, nr)
    local l = sqrt(nx * nx + nr * nr)
    pts[#pts + 1] = { x = x, r = r, nx = nx / l, nr = nr / l }
  end
  local sideT = { 0, 0.35, 0.7 }
  local phis = { 0, 25, 50, 75 }
  for _, t in ipairs(sideT) do
    add(hw * (0.9 + 0.1 * sin(math.pi * 0.5 * t)), rim + (top - rim) * t, 1, -0.05)
  end
  for _, ph in ipairs(phis) do
    local a = math.rad(ph)
    add(hw - rs + rs * cos(a), top + rs * sin(a), cos(a), sin(a))
  end
  for _, f in ipairs({ 1, 0.5, 0, -0.5, -1 }) do add((hw - rs) * f, Rv, 0, 1) end
  for q = #phis, 1, -1 do
    local a = math.rad(phis[q])
    add(-(hw - rs + rs * cos(a)), top + rs * sin(a), -cos(a), sin(a))
  end
  for q = #sideT, 1, -1 do
    local t = sideT[q]
    add(-hw * (0.9 + 0.1 * sin(math.pi * 0.5 * t)), rim + (top - rim) * t, -1, -0.05)
  end
  local s = 0
  for k = 1, #pts do
    if k > 1 then s = s + sqrt((pts[k].x - pts[k - 1].x) ^ 2 + (pts[k].r - pts[k - 1].r) ^ 2) end
    pts[k].s = s
  end
  return pts, #sideT, s
end

-- The mesh is rebuilt only when the wheel's shape really changes. Radius and widths
-- are measured from the nodes at every reset and move with the tyre load (measured:
-- 0.505 -> 0.518 m on a sunk Percheron), so the radius may move 4 %, the rest 2 cm.
local function shapeOf(W)
  local s = { R = W.R, rim = W.rimR or 0, w = W.width or 0, n = #W.tyres }
  for i, ty in ipairs(W.tyres) do s[i] = { ty.o, ty.w, ty.vis } end
  return s
end
local function sameShape(a, b)
  if not a or not b or a.n ~= b.n then return false end
  if abs(a.R - b.R) > 0.04 * b.R or abs(a.rim - b.rim) > 0.02 or abs(a.w - b.w) > 0.02 then return false end
  for i = 1, a.n do
    if abs(a[i][1] - b[i][1]) > 0.02 or abs(a[i][2] - b[i][2]) > 0.02 or a[i][3] ~= b[i][3] then return false end
  end
  return true
end

-- the per-kind values a skin mesh is built with, as one number (a wheel entering a kind
-- with other values rebuilds its skin)
local function meshSig(K, c)
  return (K.thickness or c.thickness or 0.012) + (K.treadInset or 0) * 1000 + (K.texO and 0 or 1e6)
end

local function buildMesh(W)
  local c = ctx.cfg.clods
  local Rv = W.R * (1 + (c.surfaceOffset or 0.04))
  local rimR = clamp(W.rimR or Rv * 0.58, Rv * 0.3, Rv * 0.85)
  local circ = 2 * math.pi * Rv
  local nC = clamp(floor(circ / (c.segLen or 0.06) + 0.5), 32, c.maxSegments or 112)
  -- cake thickness of the kind the wheel is in (sand: a thin film); a kind with its own
  -- textures gets an even skin (the blob relief follows the mud texture's order)
  local K = kindCfg(lookKind(W))
  local th0 = K.thickness or c.thickness or 0.012
  local blobs = not K.texO
  local lift = c.lift or 0.003
  -- treadInset: the skin sits this far below the tread surface (scaled by how much the
  -- profile point faces outwards), between groove bottom and lug top: the tyre's own
  -- lugs show through and the sand stays in the grooves (a skin over the lugs read as
  -- a smooth cake). Sidewalls keep the plain lift.
  local inset = K.treadInset or 0
  local ct, st = {}, {}
  for q = 0, nC do
    local a = q / nC * 2 * math.pi
    ct[q], st[q] = cos(a), sin(a)
  end
  local tyres = W.tyres
  local nt = #tyres
  local sorted = {}
  for k = 1, nt do sorted[k] = tyres[k] end
  table.sort(sorted, function(a, b) return a.o < b.o end)
  builder = builder or tm().newBuilder()
  builder:reset()
  local flip = nil
  local seed = W.seed or 1
  for rank, ty in ipairs(sorted) do
    local width = ty.w
    if not ty.vis then width = width * (c.widthScale or 1.12) end
    local prof, nSide, sTot = tyreProfile(width, Rv, rimR)
    local nP = #prof
    -- a dual pair leaves out the sidewalls that face each other. The profile starts on
    -- the +x sidewall; tyres are sorted by offset, so the +x sidewall of every tyre but
    -- the last faces its neighbour, and the -x sidewall of every tyre but the first
    local k0 = (nt > 1 and rank < nt) and nSide + 1 or 1
    local k1 = (nt > 1 and rank > 1) and nP - nSide or nP
    -- texture: u across the profile, v round the tyre, square texels (texture 1:2)
    local rep = max(1, floor(circ / (2 * sTot) + 0.5))
    local vOff = hash01(seed, rank, 11)
    local s = builder:sub(W.matName, (k1 - k0 + 1) * (nC + 1))
    local base = nil
    for k = k0, k1 do
      local P = prof[k]
      local u = P.s / sTot
      for col = 0, nC do
        local v = col / nC * rep + vOff
        local o = blobs and orderAt(u, v) or 1
        local lump = hash01(seed * 7 + rank, k * 131 + col % nC, 5)
        local d = th0 * (0.15 + 0.85 * o * o) * (0.85 + 0.3 * lump) + lift - inset * max(0, P.nr) ^ 2
        local x = ty.o + P.x + P.nx * d
        local r = P.r + P.nr * d
        local vi = s:vert(x, r * ct[col], r * st[col], P.nx, P.nr * ct[col], P.nr * st[col], u, v)
        if not base then base = vi end
      end
    end
    if flip == nil then
      -- front faces are clockwise seen from outside: test one tread quad of the profile
      local km = floor((k0 + k1) / 2)
      local P0, P1 = prof[km], prof[km + 1]
      local ax, ay, az = P0.x, P0.r * ct[0], P0.r * st[0]
      local bx, by, bz = P1.x, P1.r * ct[0], P1.r * st[0]
      local cx, cy, cz = P1.x, P1.r * ct[1], P1.r * st[1]
      local ux, uy, uz = bx - ax, by - ay, bz - az
      local vx, vy, vz = cx - ax, cy - ay, cz - az
      local rnx, rny, rnz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      flip = (rnx * P0.nx + rny * P0.nr * ct[0] + rnz * P0.nr * st[0]) > 0
    end
    local row = nC + 1
    for k = 0, k1 - k0 - 1 do
      for col = 0, nC - 1 do
        local i1 = base + k * row + col
        local i2, i3, i4 = i1 + row, i1 + row + 1, i1 + 1
        if flip then
          s:tri(i1, i3, i2); s:tri(i1, i4, i3)
        else
          s:tri(i1, i2, i3); s:tri(i1, i3, i4)
        end
      end
    end
    -- water film: the whole tyre surface just over it (under the mud cake), coarser
    -- round the tyre (every 2nd skin step)
    if W.filmName then
      local fl = c.filmLift or 0.0015
      local step = 2
      local nF = floor(nC / step)
      local fs = builder:sub(W.filmName, (k1 - k0 + 1) * (nF + 1))
      local fbase = nil
      for k = k0, k1 do
        local P = prof[k]
        local u = P.s / sTot
        for q = 0, nF do
          local col = q == nF and nC or q * step
          local x = ty.o + P.x + P.nx * fl
          local r = P.r + P.nr * fl
          local vi = fs:vert(x, r * ct[col], r * st[col], P.nx, P.nr * ct[col], P.nr * st[col], u, col / nC)
          if not fbase then fbase = vi end
        end
      end
      local frow = nF + 1
      for k = 0, k1 - k0 - 1 do
        for q = 0, nF - 1 do
          local i1 = fbase + k * frow + q
          local i2, i3, i4 = i1 + frow, i1 + frow + 1, i1 + 1
          if flip then
            fs:tri(i1, i3, i2); fs:tri(i1, i4, i3)
          else
            fs:tri(i1, i2, i3); fs:tri(i1, i3, i4)
          end
        end
      end
    end
  end
  local meshes = builder:finish()
  if not meshes or #meshes == 0 then return false end
  if not W.obj then W.obj = newObject(W.tag) end
  if not W.obj then return false end
  -- a skin that is drawn (rebuild for another kind) is replaced in place: hiding it for
  -- the upload made the coat blink at every mud/sand switch
  if not W.visible then W.obj:setHidden(true) end
  local nv, nc, ms = upload(W.obj, meshes, 'C')
  geoVerts, geoCorners = geoVerts - (W.gv or 0) + nv, geoCorners - (W.gc or 0) + nc
  W.gv, W.gc = nv, nc
  W.Rv = Rv
  W.shape = shapeOf(W)
  W.meshSig = meshSig(K, c)
  W.needMesh = false
  counters.meshes = counters.meshes + 1
  counters.meshMs = counters.meshMs + ms
  return true
end

-------------------------------------------------------------------------------
-- wheel transform
-------------------------------------------------------------------------------
local function hideWheel(W)
  if W.obj and W.visible then W.obj:setHidden(true) end
  W.visible = false
end

-- frame columns into vec3s kept per wheel (no garbage per frame); scale grows the cake
local function applyTransform(W)
  local f = W.frame
  if not f or not W.obj then return false end
  for i = 1, 12 do if not isFinite(f[i]) then return false end end
  local m = W.mat4 or MatrixF(true)
  W.mat4 = m
  local cols = W.cols
  if not cols then cols = { vec3(), vec3(), vec3(), vec3() }; W.cols = cols end
  local sa, sr = W.sa or 1, W.sr or 1
  cols[1]:set(f[4] * sa, f[5] * sa, f[6] * sa); m:setColumn(0, cols[1])
  cols[2]:set(f[7] * sr, f[8] * sr, f[9] * sr); m:setColumn(1, cols[2])
  cols[3]:set(f[10] * sr, f[11] * sr, f[12] * sr); m:setColumn(2, cols[3])
  cols[4]:set(f[1], f[2], f[3]); m:setPosition(cols[4])
  W.obj:setTransform(m)
  return true
end

-- wheel frame from nodes: axle = hub2 - hub1, spin angle = tread node projected onto the
-- wheel plane. false for broken wheels.
local function readFrame(veh, W)
  local ax, ay, az = veh:getNodeAbsPositionXYZ(W.n1)
  local bx, by, bz = veh:getNodeAbsPositionXYZ(W.n2)
  local tx, ty, tz = veh:getNodeAbsPositionXYZ(W.tread)
  if not (isFinite(ax) and isFinite(ay) and isFinite(az) and isFinite(bx) and isFinite(by) and isFinite(bz)
      and isFinite(tx) and isFinite(ty) and isFinite(tz)) then return false end
  local axx, axy, axz = bx - ax, by - ay, bz - az
  local al = sqrt(axx * axx + axy * axy + axz * axz)
  if al < 0.01 or al > 3 then return false end
  axx, axy, axz = axx / al, axy / al, axz / al
  local cx, cy, cz = (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5
  local rx, ry, rz = tx - cx, ty - cy, tz - cz
  local p = rx * axx + ry * axy + rz * axz
  rx, ry, rz = rx - axx * p, ry - axy * p, rz - axz * p
  local rl = sqrt(rx * rx + ry * ry + rz * rz)
  if rl < 0.3 * W.R or rl > 2.5 * W.R then return false end
  rx, ry, rz = rx / rl, ry / rl, rz / rl
  local ex, ey, ez = axy * rz - axz * ry, axz * rx - axx * rz, axx * ry - axy * rx
  local f = W.frame or {}
  f[1], f[2], f[3] = cx, cy, cz
  f[4], f[5], f[6] = axx, axy, axz
  f[7], f[8], f[9] = rx, ry, rz
  f[10], f[11], f[12] = ex, ey, ez
  W.frame = f
  return true
end

-------------------------------------------------------------------------------
-- chunks
-------------------------------------------------------------------------------
-- unit lump variants: icosphere (1 subdivision, 42 vertices), jittered and flattened
local function makeLumps()
  local p = (1 + sqrt(5)) / 2
  local V = {
    { -1, p, 0 }, { 1, p, 0 }, { -1, -p, 0 }, { 1, -p, 0 }, { 0, -1, p }, { 0, 1, p },
    { 0, -1, -p }, { 0, 1, -p }, { p, 0, -1 }, { p, 0, 1 }, { -p, 0, -1 }, { -p, 0, 1 },
  }
  local F = {
    { 0, 11, 5 }, { 0, 5, 1 }, { 0, 1, 7 }, { 0, 7, 10 }, { 0, 10, 11 }, { 1, 5, 9 }, { 5, 11, 4 },
    { 11, 10, 2 }, { 10, 7, 6 }, { 7, 1, 8 }, { 3, 9, 4 }, { 3, 4, 2 }, { 3, 2, 6 }, { 3, 6, 8 },
    { 3, 8, 9 }, { 4, 9, 5 }, { 2, 4, 11 }, { 6, 2, 10 }, { 8, 6, 7 }, { 9, 8, 1 },
  }
  for _, v in ipairs(V) do
    local l = sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2)
    v[1], v[2], v[3] = v[1] / l, v[2] / l, v[3] / l
  end
  local mid = {}
  local function midpoint(a, b)
    local key = a < b and a * 64 + b or b * 64 + a
    local i = mid[key]
    if i then return i end
    local A, B = V[a + 1], V[b + 1]
    local x, y, z = A[1] + B[1], A[2] + B[2], A[3] + B[3]
    local l = sqrt(x * x + y * y + z * z)
    V[#V + 1] = { x / l, y / l, z / l }
    i = #V - 1
    mid[key] = i
    return i
  end
  local F2 = {}
  for _, f in ipairs(F) do
    local a, b, c = f[1], f[2], f[3]
    local ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
    F2[#F2 + 1] = { a, ab, ca }; F2[#F2 + 1] = { ab, b, bc }
    F2[#F2 + 1] = { ca, bc, c }; F2[#F2 + 1] = { ab, bc, ca }
  end
  -- clockwise seen from outside: check the first face, flip all if needed
  local A, B, C = V[F2[1][1] + 1], V[F2[1][2] + 1], V[F2[1][3] + 1]
  local ux, uy, uz = B[1] - A[1], B[2] - A[2], B[3] - A[3]
  local vx, vy, vz = C[1] - A[1], C[2] - A[2], C[3] - A[3]
  local out = (uy * vz - uz * vy) * A[1] + (uz * vx - ux * vz) * A[2] + (ux * vy - uy * vx) * A[3]
  local swap = out > 0
  local variants = {}
  for vi = 1, 4 do
    local pts = {}
    for i, v in ipairs(V) do
      local j = 1 + (hash01(vi * 97, i, 3) - 0.5) * 0.55
      pts[i] = { v[1] * j, v[2] * j * 0.75, v[3] * j, v[1], v[2], v[3] }
    end
    variants[vi] = { pts = pts, faces = F2, swap = swap }
  end
  return variants
end

local function newChunkObject(kind)
  lumpVariants = lumpVariants or makeLumps()
  local pool = chunkPools[kind]
  local L = lumpVariants[pool.n % #lumpVariants + 1]
  builder = builder or tm().newBuilder()
  builder:reset()
  local s = builder:sub(matOf(kind), #L.pts)
  local base = nil
  for _, p in ipairs(L.pts) do
    local vi = s:vert(p[1], p[2], p[3], p[4], p[5], p[6], p[4] * 0.12 + 0.5, p[6] * 0.12 + 0.5)
    if not base then base = vi end
  end
  for _, f in ipairs(L.faces) do
    if L.swap then s:tri(base + f[1], base + f[3], base + f[2]) else s:tri(base + f[1], base + f[2], base + f[3]) end
  end
  local meshes = builder:finish()
  if not meshes then return nil end
  local o = newObject('chunk_' .. kind)
  if not o then return nil end
  local nv, nc = upload(o, meshes, 'C')
  geoVerts, geoCorners = geoVerts + nv, geoCorners + nc
  pool.n = pool.n + 1
  return o
end

local function takeChunkObject(kind)
  local pool = chunkPools[kind]
  if not pool then pool = { free = {}, n = 0 }; chunkPools[kind] = pool end
  local o = table.remove(pool.free)
  if o then return o end
  if pool.n >= (ctx.cfg.clods.chunkMax or 24) then return nil end
  return newChunkObject(kind)
end

local function freeChunk(i)
  local ch = chunks[i]
  ch.o:setHidden(true)
  local pool = chunkPools[ch.kind]
  if pool then pool.free[#pool.free + 1] = ch.o end
  ch.o = nil
  chunkFree[#chunkFree + 1] = ch
  chunks[i] = chunks[#chunks]
  chunks[#chunks] = nil
end

local chunkMat, chunkCols = nil, nil
local function placeChunk(ch, scale)
  chunkMat = chunkMat or MatrixF(true)
  chunkCols = chunkCols or { vec3(), vec3(), vec3(), vec3() }
  local ax, ay, az = ch.ax, ch.ay, ch.az
  local c, s = cos(ch.ang), sin(ch.ang)
  local t = 1 - c
  local k = ch.size * scale
  chunkCols[1]:set((t * ax * ax + c) * k, (t * ax * ay + s * az) * k, (t * ax * az - s * ay) * k)
  chunkCols[2]:set((t * ax * ay - s * az) * k, (t * ay * ay + c) * k, (t * ay * az + s * ax) * k)
  chunkCols[3]:set((t * ax * az + s * ay) * k, (t * ay * az - s * ax) * k, (t * az * az + c) * k)
  chunkCols[4]:set(ch.x, ch.y, ch.z)
  chunkMat:setColumn(0, chunkCols[1]); chunkMat:setColumn(1, chunkCols[2]); chunkMat:setColumn(2, chunkCols[3])
  chunkMat:setPosition(chunkCols[4])
  ch.o:setTransform(chunkMat)
end

-- one chunk off wheel W from a random spot of its tread
local function spawnChunk(W, q)
  local c = ctx.cfg.clods
  if #chunks >= (c.chunkMax or 24) then return end
  local f = W.frame
  if not f then return end
  local o = takeChunkObject(W.kind)
  if not o then return end
  local seed = W.index * 977 + floor(now * 61) + q * 13
  local ang = hash01(seed, 1, 21) * 2 * math.pi
  local off = (hash01(seed, 2, 21) - 0.5) * (W.width or 0.3) * 0.8
  local r = (W.Rv or W.R) * (W.sr or 1) + 0.01
  local ca, sa = cos(ang), sin(ang)
  local rx = (f[7] * ca + f[10] * sa)
  local ry = (f[8] * ca + f[11] * sa)
  local rz = (f[9] * ca + f[12] * sa)
  local om = W.omega
  -- tyre surface velocity omega x r (omega about the axle), plus a little outward push
  local tx = om * (f[5] * rz - f[6] * ry) * r
  local ty = om * (f[6] * rx - f[4] * rz) * r
  local tz = om * (f[4] * ry - f[5] * rx) * r
  local fling = c.chunkFling or 0.5
  local ch = table.remove(chunkFree) or {}
  ch.o, ch.kind = o, W.kind
  ch.x = f[1] + f[4] * off + rx * r
  ch.y = f[2] + f[5] * off + ry * r
  ch.z = f[3] + f[6] * off + rz * r
  ch.vx = W.vel[1] + tx * fling + rx * 0.6
  ch.vy = W.vel[2] + ty * fling + ry * 0.6
  ch.vz = W.vel[3] + tz * fling + rz * 0.6 + 0.4
  local sp = sqrt(ch.vx * ch.vx + ch.vy * ch.vy + ch.vz * ch.vz)
  if sp > 12 then ch.vx, ch.vy, ch.vz = ch.vx * 12 / sp, ch.vy * 12 / sp, ch.vz * 12 / sp end
  local K = kindCfg(W.kind)
  ch.size = ((c.chunkSize or 0.035) + (W.thickNow or 0) * 1.2) * (0.6 + 0.8 * hash01(seed, 3, 21)) * (K.size or 1)
  local axx, axy, axz = hash01(seed, 4, 21) - 0.5, hash01(seed, 5, 21) - 0.5, hash01(seed, 6, 21) - 0.5
  local al = sqrt(axx * axx + axy * axy + axz * axz)
  if al < 1e-3 then axx, axy, axz, al = 0, 0, 1, 1 end
  ch.ax, ch.ay, ch.az = axx / al, axy / al, axz / al
  ch.ang = hash01(seed, 7, 21) * 6.28
  ch.spin = (hash01(seed, 8, 21) - 0.5) * 20
  ch.t, ch.landT = now, nil
  if not (isFinite(ch.x) and isFinite(ch.y) and isFinite(ch.z) and isFinite(ch.vx) and isFinite(ch.vy) and isFinite(ch.vz)) then
    o:setHidden(true)
    chunkPools[W.kind].free[#chunkPools[W.kind].free + 1] = o
    ch.o = nil
    chunkFree[#chunkFree + 1] = ch
    return
  end
  chunks[#chunks + 1] = ch
  placeChunk(ch, 1)
  o:setHidden(false)
  counters.chunks = counters.chunks + 1
end

local function updateChunks(dt)
  local c = ctx.cfg.clods
  local life = max(0.2, c.chunkLife or 3)
  local fade = life * 0.4
  local far2 = (c.drawDist or 150) ^ 2
  local i = 1
  while i <= #chunks do
    local ch = chunks[i]
    local remove = false
    if not ch.landT then
      ch.vz = ch.vz - 9.81 * dt
      ch.x, ch.y, ch.z = ch.x + ch.vx * dt, ch.y + ch.vy * dt, ch.z + ch.vz * dt
      ch.ang = ch.ang + ch.spin * dt
      local gz = ctx.groundAt(ch.x, ch.y)
      if isFinite(gz) and ch.z - ch.size * 0.5 <= gz then
        ch.z = gz + ch.size * 0.25
        ch.landT = now
      elseif now - ch.t > 4 or not isFinite(ch.z) then
        remove = true
      end
    end
    local scale = 1
    if ch.landT then
      local age = now - ch.landT
      if age >= life then
        remove = true
      elseif age > life - fade then
        -- sinks into the ground and shrinks away
        local k = (age - (life - fade)) / fade
        scale = 1 - 0.7 * k
        ch.z = ch.z - ch.size * 0.6 * dt / fade
      end
    end
    if not remove and (ch.x - camX) ^ 2 + (ch.y - camY) ^ 2 > far2 then remove = true end
    if remove then
      freeChunk(i)
    else
      if dt > 0 then placeChunk(ch, scale) end
      i = i + 1
    end
  end
end

-------------------------------------------------------------------------------
-- coat model
-------------------------------------------------------------------------------
local function resetCoat(W)
  W.coat, W.loose = 0, 0
  W.water = 0
  W.wet = 0
  W.prevE1, W.prevC = nil, nil
  W.omega = 0
  W.chunkAcc = 0
  W.wantRef = 255
  W.col = nil
  W.newShare = 0
  W.dcol, W.dkind, W.lookKey, W.lookFrom, W.dC = nil, nil, nil, nil, 0
end

-- coat change over dt; returns the coat that dropped off as chunks (loose shed + fling)
local function updateCoat(W, c, dt)
  local K = kindCfg(W.kind)
  local cap = min(c.coatMax, K.coatMax or c.coatMax)
  W.cap = cap
  local build, wear = c.buildRate or 1, c.wearRate or 1
  local surf = abs(W.omega) * W.R
  local inMud = now - W.mudT < 0.25
  local shed = (K.shed or 1) * wear
  local dropped = 0
  if inMud then
    local rolled = surf * dt
    local spinF = 1 + min(2, (c.buildSpinGain or 0.5) * W.lastSpin)
    local depthF = clamp(W.lastDepth / 0.1, 0.2, 1.5)
    local room = max(0, 1 - W.coat / max(0.05, cap))
    -- the ground's kind (what is picked up) can differ from the coat's (what is drawn)
    local GK = W.groundKind or W.kind
    local KG = GK == W.kind and K or kindCfg(GK)
    local picked = (c.buildPerMeter or 0.03) * build * (KG.stick or 1) * depthF * spinF * rolled
    local gain = picked * room
    -- coat kind: a (nearly) clean tyre takes the ground's kind at once; a coated one only
    -- once the new material makes up most of the coat, by the same mass share the colour
    -- mixes with. Switching at the boundary made a mud-caked tyre look like a thin sand
    -- film the moment it rolled into sand (and the other way round).
    if GK ~= W.kind then
      if W.coat < 0.05 then
        W.kind, W.kindT, W.newShare = GK, now, 0
        K = KG
      elseif picked > 0 then
        local f = min(1, (c.colorMix or 3) * picked / clamp(W.coat, 0.1, 1.5))
        W.newShare = (W.newShare or 0) + (1 - (W.newShare or 0)) * f
        if W.newShare >= 0.5 then W.kind, W.kindT, W.newShare = GK, now, 0; K = KG end
      end
    else
      W.newShare = 0
    end
    -- colour: the new mud mixes in by the share it brings (also on a full tyre, where
    -- it replaces the loose outer layer)
    local kr, kg, kb = groundColor(W, KG)
    if not kr then
      local kc = kindColor(KG)
      kr, kg, kb = kc[1], kc[2], kc[3]
    end
    if not W.col or W.coat < 0.005 then
      local col = W.col or {}
      col[1], col[2], col[3] = kr, kg, kb
      W.col = col
    elseif picked > 0 then
      local f = min(1, (c.colorMix or 3) * picked / clamp(W.coat, 0.1, 1.5))
      local col = W.col
      col[1], col[2], col[3] = col[1] + (kr - col[1]) * f, col[2] + (kg - col[2]) * f, col[3] + (kb - col[3]) * f
    end
    W.coat = W.coat + gain
    W.loose = min(W.loose + gain, W.coat * (K.looseShare or c.looseShare or 0.55))
  else
    if now - W.mudT > (c.cleanDelay or 2) then
      local m = W.moved
      local l = min(W.loose, (c.looseShedPerMeter or 0.03) * shed * m)
      W.loose = W.loose - l
      dropped = dropped + l
      W.coat = W.coat - l - (c.cleanPerMeter or 0.002) * shed * m * min(1, W.coat)
    end
    if W.loose > 0 then W.loose = W.loose - W.loose * min(1, dt / max(0.1, c.packTime or 6)) end
  end
  W.moved = 0
  -- Fling (in and out of the mud): wet loose mud leaves a fast tyre within a few turns
  -- (at 13 m/s a 0.5 m tyre pulls ~35 g); a time constant 1 / (flingRate x excess
  -- speed), so at 30 mph the loose layer is gone in about a second and in deep mud the
  -- tyre keeps a packed tread plus a thin loose layer that sprays off as chunks. The
  -- packed layer only goes above flingPackedSpeed, slowly.
  local fs = c.flingSpeed or 6
  if surf > fs and W.loose > 0 then
    local f = W.loose * min(1, (c.flingRate or 0.12) * (surf - fs) * dt * shed)
    W.coat = W.coat - f
    W.loose = W.loose - f
    dropped = dropped + f
  end
  local fp = c.flingPackedSpeed or 18
  if surf > fp and W.coat > W.loose then
    local f = min(W.coat - W.loose, (c.flingPackedRate or 0.01) * (surf - fp) * dt * shed * min(1, W.coat))
    W.coat = W.coat - f
    dropped = dropped + f
  end
  -- water washes the loose layer first (washLooseFactor x faster), then the packed one
  local water = W.water or 0
  if water > 0 and W.coat > 0 then
    local w = ((c.washRate or 0.2) + (c.washSpeedGain or 0.05) * surf) * water * dt * wear
    local wl = min(W.loose, w * (c.washLooseFactor or 3))
    W.loose = W.loose - wl
    local wp = min(W.coat - wl, w)
    W.coat = W.coat - wl - wp
    counters.washed = counters.washed + wl + wp
    dropped = dropped * (1 - water)
  end
  -- wetness of the coat and the tyre: up to the water share at once (wetRate per s),
  -- drying over clods.dryTime s (faster with speed: airflow)
  local wet = W.wet or 0
  if water > wet then
    wet = min(water, wet + (c.wetRate or 3) * dt)
  elseif wet > 0 then
    wet = max(0, wet - dt / max(1, c.dryTime or 45) * (1 + surf / (c.drySpeedRef or 8)))
  end
  W.wet = wet
  if W.coat > cap then W.coat = W.coat - (W.coat - cap) * min(1, dt * 2) end
  W.coat = clamp(W.coat, 0, c.coatMax)
  if W.loose > W.coat then W.loose = W.coat end
  return dropped
end

-------------------------------------------------------------------------------
-- wheel definitions and reports
-------------------------------------------------------------------------------
local function deleteWheel(W)
  if W.obj then W.obj:delete(); W.obj = nil end
  geoVerts, geoCorners = geoVerts - (W.gv or 0), geoCorners - (W.gc or 0)
  W.gv, W.gc = 0, 0
  releaseMaterial(W)
  W.dead = true
end

function M.setWheelDefs(vid, defs)
  if not ctx or not enabled or not ctx.cfg.clods.enabled then return end
  local V = vehs[vid]
  if not V then
    V = { wheels = {} }
    vehs[vid] = V
  end
  local seen = {}
  for _, d in ipairs(defs) do
    local W = V.wheels[d.index]
    if not W then
      W = { index = d.index, coat = 0, loose = 0, mudT = -huge, lastDepth = 0, lastSpin = 0, omega = 0,
        vel = { 0, 0, 0 }, moved = 0, valid = false, visible = false, kind = 'mud', water = 0, far = false,
        cap = 3, ref = 255, wantRef = 255, chunkAcc = 0, flushT = -huge }
      W.tag = vid .. '_' .. d.index
      W.seed = vid % 9973 * 17 + d.index
      V.wheels[d.index] = W
    end
    W.n1, W.n2, W.tread, W.R, W.width = d.n1, d.n2, d.tread, d.R, d.W
    W.tyres = d.tyres or { { o = 0, w = d.W } }
    W.rimR = d.rimR
    if not W.mat then acquireMaterial(W) end
    if not W.film and ctx.cfg.clods.wetFilm ~= false then acquireFilm(W) end
    -- the mesh is kept over resets; only a new shape needs a new one
    if not sameShape(shapeOf(W), W.shape) then W.needMesh = true; W.needT = now end
    resetCoat(W)
    hideWheel(W)
    seen[d.index] = true
  end
  for idx, W in pairs(V.wheels) do
    if not seen[idx] then
      deleteWheel(W)
      V.wheels[idx] = nil
    end
  end
end

function M.onWheelMud(vid, wi, depth, slip, omega, R, t, kind, layer, x, y)
  local V = vehs[vid]
  if not V then return end
  local W = V.wheels[wi]
  if not W then return end
  W.mudT = t
  W.lastDepth = depth
  W.lastSpin = max(0, slip)
  -- the ground's kind; the coat's own kind (W.kind) follows it in updateCoat once the new
  -- material makes up most of the coat
  if kind then W.groundKind = kind end
  -- ground colour of the soft ground under the wheel; kept where it is unknown (a
  -- zone without a layer texture), so the coat never changes colour out of the mud
  if x and ctx.groundColorAt then
    local r, g, b = ctx.groundColorAt(x, y, layer)
    if r then W.gr, W.gg, W.gb = r, g, b end
  end
end

function M.onWheelWater(vid, wi, f)
  local V = vehs[vid]
  if not V then return end
  local W = V.wheels[wi]
  if W then W.water = f end
end

function M.onVehicleReset(vid)
  local V = vehs[vid]
  if not V then return end
  for _, W in pairs(V.wheels) do
    resetCoat(W)
    hideWheel(W)
  end
end

function M.onVehicleRemoved(vid)
  local V = vehs[vid]
  if not V then return end
  for _, W in pairs(V.wheels) do deleteWheel(W) end
  vehs[vid] = nil
end

function M.cleanWheels()
  for _, V in pairs(vehs) do
    for _, W in pairs(V.wheels) do
      local water = W.water
      resetCoat(W)
      W.water = water
      hideWheel(W)
    end
  end
end

local function clearChunks()
  for i = #chunks, 1, -1 do freeChunk(i) end
end

function M.setEnabled(on)
  enabled = on and true or false
  if not enabled then
    M.cleanWheels()
    clearChunks()
  end
end

-- memory flush: nothing grows here any more; drop the chunks in flight
function M.flush()
  clearChunks()
  return 0
end

function M.geometry() return geoVerts, geoCorners end

-------------------------------------------------------------------------------
-- per frame
-------------------------------------------------------------------------------
local function wheelActive(W)
  return W.visible or W.coat > 0 or now - W.mudT < 1 or (W.wet or 0) > 0 or (W.water or 0) > 0
end

function M.preRender(dt)
  if not ctx or not enabled then return end
  local c = ctx.cfg.clods
  local cx, cy, cz = core_camera.getPositionXYZ()
  if isFinite(cx) then camX, camY, camZ = cx, cy, cz end
  local far2 = (c.drawDist or 150) ^ 2
  for vid, V in pairs(vehs) do
    local veh = getObjectByID(vid)
    if veh then
      local p = veh:getPosition()
      local d2 = (p and isFinite(p.x)) and ((p.x - camX) ^ 2 + (p.y - camY) ^ 2 + (p.z - camZ) ^ 2) or 0
      local far = d2 > far2
      V.camD = sqrt(d2)
      -- beyond drawDist nothing is drawn: wheel frames (spin, speed for wear and fling)
      -- every 4th frame only, with the time summed up (56 wheels with 7 trucks)
      local wdt = dt
      local skip = false
      if far then
        V.farAcc = (V.farAcc or 0) + dt
        V.farN = (V.farN or 0) + 1
        if V.farN < 4 then skip = true else wdt = V.farAcc; V.farAcc, V.farN = 0, 0 end
      else
        V.farAcc, V.farN = 0, 0
      end
      local pgap = 1 / max(1, c.coatHz or 20)
      -- a vehicle outside the camera view: its drawn mud follows the wheel at coatHz too
      -- (8 trucks x 8 wheels of node reads + setTransform every frame cost ~0.7 ms)
      local vin = far or not ctx.pointInView or (p and ctx.pointInView(p.x, p.y, p.z, 7))
      for _, W in pairs(V.wheels) do
        W.far = far
        -- a wheel whose mud is not drawn needs its frame only for spin and speed (coat
        -- bookkeeping): at coatHz with the summed time; a drawn one every frame
        local wskip = false
        local wdt2 = wdt
        if not skip and (not W.visible or not vin) then
          W.preAcc = (W.preAcc or 0) + wdt
          if W.preAcc < pgap and W.prevE1 then wskip = true else wdt2 = W.preAcc; W.preAcc = 0 end
        else
          W.preAcc = 0
        end
        if skip or wskip then
          -- next update with the summed time
        elseif wheelActive(W) and readFrame(veh, W) then
          local f = W.frame
          local dt = wdt2
          if dt > 0 then
            if W.prevE1 then
              local q = W.prevE1
              local cxv = (q[2] * f[9] - q[3] * f[8]) * f[4] + (q[3] * f[7] - q[1] * f[9]) * f[5] + (q[1] * f[8] - q[2] * f[7]) * f[6]
              local dot = q[1] * f[7] + q[2] * f[8] + q[3] * f[9]
              local om = atan2(cxv, dot) / dt
              if isFinite(om) then W.omega = W.omega + (om - W.omega) * min(1, dt * 20) end
            end
            if W.prevC then
              local q = W.prevC
              local dx, dy, dz = f[1] - q[1], f[2] - q[2], f[3] - q[3]
              local d = sqrt(dx * dx + dy * dy + dz * dz)
              if d < 5 then
                W.vel[1], W.vel[2], W.vel[3] = dx / dt, dy / dt, dz / dt
                W.moved = W.moved + d
              end
            end
            W.prevE1 = W.prevE1 or {}
            W.prevE1[1], W.prevE1[2], W.prevE1[3] = f[7], f[8], f[9]
            W.prevC = W.prevC or {}
            W.prevC[1], W.prevC[2], W.prevC[3] = f[1], f[2], f[3]
          end
          W.valid = true
          if W.visible and not applyTransform(W) then hideWheel(W) end
        elseif wheelActive(W) then
          -- broken wheel: hide its mud and reset its coat
          W.valid = false
          resetCoat(W)
          hideWheel(W)
        else
          W.prevE1, W.prevC = nil, nil
          W.omega = 0
        end
      end
    end
  end
end

-- coverage share shown for a coat: like the old skin (coat 0.3 ~ a quarter of the tyre,
-- coat 1 ~ 85 %: tread, shoulders and most of the sidewalls); the rest comes with a
-- thicker cake (coat above 1)
local function coverage(W, c)
  if W.coat < 0.005 then return 0 end
  local cm = kindCfg(lookKind(W)).coverMax or c.coverMax or 0.92
  local C = cm * min(1, W.coat) ^ (c.coverExp or 1.1)
  if (W.cap or 1) > 1 and W.coat > 1 then
    C = C + (1 - cm) * clamp((W.coat - 1) / ((W.cap or 1) - 1), 0, 1)
  end
  return C
end

-- Drawn look (colour, kind) of a coat. The coat model switches its colour and kind
-- within a fraction of a second at a mud/sand/off boundary, which read as a snap. The
-- drawn look holds for clods.lookDelay s after the wheel's state (ground kind under it
-- or off the soft ground, coat kind) changed, then blends to the coat's look over
-- clods.lookFade s (a linear fade towards a target that may still move); the texture
-- set (kind) changes half way through. A clean tyre takes the look at once.
local function updateLook(W, c)
  local col = W.col
  if not col then W.dcol, W.dkind = nil, nil; return end
  local inMud = now - W.mudT < 0.25
  local key = inMud and (W.groundKind or W.kind) or 'off'
  local d = W.dcol
  if not d or (W.ref == 255 and (W.dC or 0) <= 0) then
    d = d or {}
    d[1], d[2], d[3] = col[1], col[2], col[3]
    W.dcol = d
    if W.dkind ~= W.kind then W.dkind, W.dkindT = W.kind, now end
    W.lookKey, W.lookT = key, -huge
    return
  end
  local delay, fade = c.lookDelay or 1, max(0.05, c.lookFade or 1)
  -- a new state starts a transition; so does a coat kind switch that comes after the
  -- last transition ended (one inside a running transition joins it: no second delay)
  if key ~= W.lookKey or (W.dkind ~= W.kind and now - W.lookT >= delay + fade) then
    W.lookKey, W.lookT = key, now
    local f = W.lookFrom or {}
    f[1], f[2], f[3] = d[1], d[2], d[3]
    W.lookFrom = f
  end
  local age = now - W.lookT
  if age < delay then return end
  local s = (age - delay) / fade
  if s >= 1 then
    d[1], d[2], d[3] = col[1], col[2], col[3]
  else
    local f = W.lookFrom
    d[1], d[2], d[3] = f[1] + (col[1] - f[1]) * s, f[2] + (col[2] - f[2]) * s, f[3] + (col[3] - f[3]) * s
  end
  if s >= 0.5 and W.dkind ~= W.kind then W.dkind, W.dkindT = W.kind, now end
end

local flushList = {}
local updN = 0
function M.update(dt)
  if not ctx or not enabled or not ctx.cfg.clods.enabled then return end
  updN = updN + 1
  now = ctx.simTime()
  local c = ctx.cfg.clods
  local t_m = tm()
  local nFlush = 0
  local meshW = nil
  for vid, V in pairs(vehs) do
    local veh = getObjectByID(vid)
    if not veh then
      M.onVehicleRemoved(vid)
    else
      local nearCam = (V.camD or 0) <= (c.lodNearDist or 20)
      local step = nearCam and (c.refStepNear or 4) or (c.refStepFar or 16)
      -- material updates only for vehicles in the camera view: every flush also costs the
      -- engine a refresh of the frame's shadow pass; a wheel out of view catches up in one
      -- step when it comes back into view (its coat bookkeeping goes on regardless)
      local vp = veh:getPosition()
      local inView = not ctx.pointInView or ctx.pointInView(vp.x, vp.y, vp.z, 7)
      -- coat bookkeeping (and material/visibility decisions) at clods.coatHz with the
      -- summed time, each vehicle on its own phase; beyond drawDist every 4th frame or
      -- slower. The coat changes over seconds: every frame cost ~0.3 ms with 8 trucks.
      local vdt, skipV = dt, false
      V.updAcc = (V.updAcc or 0) + dt
      V.updN = (V.updN or 0) + 1
      local gap = 1 / max(1, c.coatHz or 20)
      if (V.camD or 0) > (c.drawDist or 150) then
        if V.updN < 4 or V.updAcc < gap then skipV = true end
      elseif V.updAcc < gap then
        skipV = true
      end
      if not skipV then vdt = V.updAcc; V.updAcc, V.updN = 0, 0 end
      if not skipV then for _, W in pairs(V.wheels) do
        if W.valid and (W.coat > 0 or (W.dC or 0) > 0 or now - W.mudT < 0.5 or (W.wet or 0) > 0 or (W.water or 0) > 0) then
          local dropped = updateCoat(W, c, vdt)
          updateLook(W, c)
          -- drawn coverage follows the coat's at most coverUpRate / coverDownRate per s
          -- (a mud/sand switch changes coverMax: the coat no longer jumps)
          local C = coverage(W, c)
          local dC = W.dC or 0
          if C > dC then dC = min(C, dC + (c.coverUpRate or 0.5) * vdt)
          else dC = max(C, dC - (c.coverDownRate or 1) * vdt) end
          if C <= 0 and dC < 0.01 then dC = 0 end
          W.dC = dC
          W.wantRef = dC <= 0 and 255 or clamp(floor(255.5 - 254 * dC), 1, 254)
          -- coat above 1: thicker cake through the transform scale
          local over = 0
          if (W.cap or 1) > 1 then over = clamp((W.coat - 1) / max(0.01, (W.cap or 1) - 1), 0, 1) end
          local K = kindCfg(lookKind(W))
          local extra = (c.thicknessMax or 0.035) * over * (K.size or 1)
          W.thickNow = (K.thickness or c.thickness or 0.012) * min(1, W.coat) + extra
          local Rv = W.Rv or W.R
          W.sr = 1 + extra / max(0.1, Rv)
          W.sa = 1 + extra / max(0.1, (W.width or 0.3) * 0.5 + 0.05)
          -- chunks from the mud that dropped off (only where the tyre is drawn)
          if dropped > 0 and W.visible and not W.far then
            W.chunkAcc = (W.chunkAcc or 0) + dropped * (c.chunkRate or 10)
            local n = min(3, floor(W.chunkAcc))
            if n > 0 then
              W.chunkAcc = W.chunkAcc - n
              for q = 1, n do spawnChunk(W, q) end
            end
          elseif W.chunkAcc and W.chunkAcc > 3 then
            W.chunkAcc = 3
          end
        end
        -- a kind of another cake thickness (sand film / mud cake): rebuild once the wheel
        -- stayed in it for a second (boundaries between kinds would rebuild every frame)
        if W.meshSig and not W.needMesh and now - (W.dkindT or W.kindT or -huge) > 1
          and abs(meshSig(kindCfg(lookKind(W)), c) - W.meshSig) > 1e-5 then
          W.needMesh = true; W.needT = now
        end
        -- mesh needed: first the wheels that carry mud
        if W.needMesh and not W.far then
          if not meshW or (W.coat > 0 and meshW.coat <= 0) or (W.needT or 0) < (meshW.needT or 0) then meshW = W end
        end
        -- material threshold to apply
        if W.mat and not W.needMesh and not W.far and inView then
          local diff = abs(W.wantRef - W.ref)
          -- colour steps of a look fade: at most one per colorFlushGap s per wheel
          local kindChange = W.coat > 0 and (W.matKind ~= lookKind(W)
            or (colorDiff(wheelColor(W), W.matCol) >= (c.colorStep or 0.03)
              and now - W.flushT >= (c.colorFlushGap or 0.1))
            or abs((W.wet or 0) - (W.matWet or 0)) >= (c.wetStep or 0.1)
            or ((W.wet or 0) == 0 and (W.matWet or 0) > 0))
          -- per wheel at most one update every flushGap s (the coat jitters at its cap)
          local due = now - W.flushT >= (nearCam and (c.flushGap or 0.4) or (c.flushGap or 0.4) * 3)
          if kindChange or (due and (diff >= step or (diff > 0 and (W.wantRef == 255 or W.wantRef <= 2)))) then
            if W.wantRef ~= 255 or W.visible then
              nFlush = nFlush + 1
              flushList[nFlush] = W
              W.listN = updN
              W.prio = diff + (now - W.flushT) * 20 + (kindChange and 120 or 0) + (W.ref == 255 and 300 or 0)
            end
          end
        end
        -- water film: one update per wetStep of wetness change (and when dry again)
        if W.film and not W.needMesh and not W.far and inView then
          local wet, fw = W.wet or 0, W.filmWet or 0
          if abs(wet - fw) >= (c.wetStep or 0.1) or (wet == 0 and fw > 0) or (fw == 0 and wet > 0.02) then
            W.filmDue = true
            if W.listN ~= updN then
              nFlush = nFlush + 1
              flushList[nFlush] = W
              W.listN = updN
              W.prio = 150 + abs(wet - fw) * 100
            end
          end
        end
        -- visibility: drawn while it carries mud and its material has been set once; a
        -- material lagging behind the coat keeps showing (hiding it made wheels pop);
        -- or while its water film shows
        -- a wheel waiting for a skin rebuild (other kind: thickness, inset) keeps drawing
        -- its current skin; hiding it made the coat vanish for a moment at every mud/sand
        -- switch. Only a wheel without any skin yet waits hidden.
        local show = W.valid and not W.far and (not W.needMesh or (W.gv or 0) > 0) and W.obj
          and ((W.wantRef < 255 and W.ref < 255) or (W.filmWet or 0) > 0)
        if show and not W.visible then
          if applyTransform(W) then W.obj:setHidden(false); W.visible = true end
        elseif not show and W.visible then
          hideWheel(W)
        end
      end end
    end
  end
  for k = nFlush + 1, #flushList do flushList[k] = nil end

  -- material flushes inside the upload budget, biggest change first; one per frame goes
  -- ahead anyway once its wheel waited flushWait s (tile uploads can hold the budget
  -- for seconds while digging: measured, the coverage then froze)
  if nFlush > 1 then table.sort(flushList, function(a, b) return a.prio > b.prio end) end
  local done = 0
  for k = 1, nFlush do
    if done >= (c.flushPerFrame or 2) then break end
    local W = flushList[k]
    local room = not (t_m and t_m.canUpload) or t_m.canUpload('M', 200)
    if not room and not (done == 0 and now - W.flushT >= (c.flushWait or 0.25)) then break end
    local timer = hptimer and hptimer()
    if W.filmDue then
      -- water film update (may come with a coat update of the same wheel)
      W.filmDue = nil
      local op, ref = filmFields(W)
      W.film:setField('opacityFactor', 0, op)
      W.film:setField('alphaRef', 0, ref)
      setFilmColor(W)
      W.film:flush()
      W.filmWet = W.wet or 0
      counters.filmFlushes = (counters.filmFlushes or 0) + 1
    end
    if W.matKind ~= lookKind(W) or colorDiff(wheelColor(W), W.matCol) > 0 or abs((W.wet or 0) - (W.matWet or 0)) > 0 then
      local K = kindCfg(lookKind(W))
      local col = wheelColor(W)
      local tb, to, tn = kindTextures(lookKind(W))
      if W.matTex ~= tb then
        W.mat:setField('baseColorMap', 0, tb)
        W.mat:setField('opacityMap', 0, to)
        W.mat:setField('normalMap', 0, tn)
        W.matTex = tb
      end
      W.mat:setField('baseColorFactor', 0, colorString(wetColor(W, col)))
      W.mat:setField('roughnessFactor', 0, sfmt('%g', wetRoughness(W, K)))
      W.matKind = lookKind(W)
      W.matCol = W.matCol or {}
      W.matCol[1], W.matCol[2], W.matCol[3] = col[1], col[2], col[3]
      W.matWet = W.wet or 0
      W.matDirty = true
    end
    if W.wantRef ~= W.ref or W.matDirty then
      W.mat:setField('alphaRef', 0, tostring(W.wantRef))
      W.mat:flush()
      W.matDirty = nil
    end
    local ms = timer and timer:stop() or 0.5
    if t_m and t_m.recordUpload then t_m.recordUpload('M', nil, ms) end
    W.ref = W.wantRef
    W.flushT = now
    counters.flushes = counters.flushes + 1
    counters.flushMs = counters.flushMs + ms
    done = done + 1
  end

  -- one tyre mesh per frame at most (spawn / config change), inside the budget; a tyre
  -- with mud that waited 0.5 s reserves the next frame
  if meshW then
    local est = (meshW.gv and meshW.gv > 0) and meshW.gv or 2500
    if not t_m or not t_m.canUpload or t_m.canUpload('C', est) then
      buildMesh(meshW)
    elseif meshW.coat > 0 and now - (meshW.needT or now) > 0.5 and t_m.reserveFrame then
      t_m.reserveFrame('C')
    end
  end

  updateChunks(dt)
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------
function M.materialNames()
  local list = { MAT }
  local ks = ctx and ctx.cfg.clods.kinds or {}
  for k in pairs(ks) do if k ~= 'mud' then list[#list + 1] = MAT .. '_' .. k end end
  return list
end

-- chunk material per kind: the same monochrome mud texture as the tyres, times the
-- kind's colour
local function createKindMaterial(main, name, K)
  local c = main.cfg.clods
  local p = c.texDir .. c.texBase
  main.createMaterial(name, {
    { 'version', '1.5' },
    { 'castShadows', '0' },
    { 'baseColorMap', K.texB or TEX_B },
    { 'normalMap', K.texN or (p .. '_nm.normal.dds') },
    { 'baseColorFactor', tyreColor(K) },
    { 'roughnessFactor', sfmt('%g', K.roughness or c.roughness or 0.5) },
  })
end

-- re-apply every kind colour (GUI "Mud brightness")
function M.refreshColors()
  local ks = ctx and ctx.cfg.clods.kinds or {}
  for kind, K in pairs(ks) do
    local col = K.color or { 1, 1, 1 }
    M.setKindColor(kind, col[1] or 1, col[2] or 1, col[3] or 1)
  end
end

-- colour of a soft-ground kind (GUI colour pickers): tyre materials of that kind are
-- updated through the flush queue, the chunk material at once
function M.setKindColor(kind, r, g, b)
  if not ctx then return end
  local ks = ctx.cfg.clods.kinds
  local K = ks and ks[kind]
  if not K or not (isFinite(r) and isFinite(g) and isFinite(b)) then return end
  K.color = { r, g, b }
  for _, V in pairs(vehs) do
    for _, W in pairs(V.wheels) do
      if W.kind == kind then
        W.matKind = nil
        if W.col and not groundColor(W, K) then W.col = { r, g, b }; W.dcol = nil end
      end
    end
  end
  local m = scenetree.findObject(matOf(kind))
  if m then
    m:setField('baseColorFactor', 0, tyreColor(K))
    m:flush()
  end
end

function M.start(main)
  ctx = main
  session = session + 1
  vehs, chunks, chunkFree, chunkPools, matFree = {}, {}, {}, {}, {}
  filmFree = {}
  geoVerts, geoCorners = 0, 0
  objCounter, matCounter = 0, 0
  for k in pairs(counters) do counters[k] = 0 end
  enabled = main.cfg.clods.enabled ~= false
  filmFree = {}
  loadOrder()
  local c = main.cfg.clods
  local ks = c.kinds or {}
  createKindMaterial(main, MAT, ks.mud or { color = { 0.5, 0.475, 0.44 }, roughness = 0.5 })
  for k, K in pairs(ks) do
    if k ~= 'mud' then createKindMaterial(main, MAT .. '_' .. k, K) end
  end
  -- tyre texture means (ground colour / mean = colour factor, see groundColor)
  texMean = {}
  if c.groundColor ~= false and main.textureMean then
    for k, K in pairs(ks) do
      local m = main.textureMean(K.texB or TEX_B, true)
      if m then texMean[k] = max(0.05, (m[1] + m[2] + m[3]) / 3) end
    end
  end
end

function M.stop(objectsAlive)
  if objectsAlive then
    for _, V in pairs(vehs) do
      for _, W in pairs(V.wheels) do if W.obj then W.obj:delete(); W.obj = nil end end
    end
    for _, ch in ipairs(chunks) do if ch.o then ch.o:delete() end end
    for _, pool in pairs(chunkPools) do
      for _, o in ipairs(pool.free) do o:delete() end
    end
  end
  -- tyre and chunk materials are owned by main and deleted with its materials
  vehs, chunks, chunkFree, chunkPools, matFree = {}, {}, {}, {}, {}
  filmFree = {}
  builder = nil
  geoVerts, geoCorners = 0, 0
end

function M.stats()
  local wheels, coatSum, active, wet, dual, vis, pend = 0, 0, 0, 0, 0, 0, 0
  for _, V in pairs(vehs) do
    for _, W in pairs(V.wheels) do
      wheels = wheels + 1
      coatSum = coatSum + W.coat
      if wheelActive(W) then active = active + 1 end
      if (W.water or 0) > 0 then wet = wet + 1 end
      if W.tyres and #W.tyres > 1 then dual = dual + 1 end
      if W.visible then vis = vis + 1 end
      if W.needMesh then pend = pend + 1 end
    end
  end
  local pooled = 0
  for _, pool in pairs(chunkPools) do pooled = pooled + pool.n end
  local wetVeh = 0
  for _, V in pairs(vehs) do
    for _, W in pairs(V.wheels) do if (W.filmWet or 0) > 0 then wetVeh = wetVeh + 1; break end end
  end
  return { wheels = wheels, avgCoat = wheels > 0 and coatSum / wheels or 0, activeWheels = active, wetWheels = wet,
    dualWheels = dual, visibleWheels = vis, chunks = #chunks, chunkObjects = pooled, flushes = counters.flushes,
    wetVehicles = wetVeh, filmFlushes = counters.filmFlushes or 0,
    flushMs = counters.flushMs, meshes = counters.meshes, meshMs = counters.meshMs, pendingMeshes = pend,
    chunksSpawned = counters.chunks, washed = counters.washed, materials = matCounter, enabled = enabled,
    -- old names still read by the GUI / tools
    flying = #chunks, landed = 0, onTyres = vis, rebuilds = counters.meshes, detached = counters.chunks }
end

-- per-wheel state for the debug tab
function M.wheelStates()
  local out = {}
  for vid, V in pairs(vehs) do
    local list = {}
    for idx, W in pairs(V.wheels) do
      list[#list + 1] = { index = idx, coat = W.coat, loose = W.loose, kind = W.kind, drawnKind = W.dkind, groundKind = W.groundKind,
        newShare = W.newShare, water = W.water or 0, wet = W.wet or 0,
        tyres = W.tyres and #W.tyres or 1, shown = W.visible and 1 or 0, far = W.far, ref = W.ref,
        surf = abs(W.omega) * W.R, mudAge = now - W.mudT,
        col = W.col and { W.col[1], W.col[2], W.col[3] } or nil,
        dcol = W.dcol and { W.dcol[1], W.dcol[2], W.dcol[3] } or nil, cover = W.dC or 0 }
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    out[vid] = list
  end
  return out
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
