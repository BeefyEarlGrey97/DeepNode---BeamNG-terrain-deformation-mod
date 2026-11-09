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
--    art/deepnode/t_tyremud_o.data.dds holds a coverage order (tread first, then
--    shoulders, then blotches over the sidewalls; histogram-equalised, see
--    tools/tyre_textures/bake_tyremud.py), so alphaRef = 255 - 254 x coverage shows exactly
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

local TEX_B = '/art/deepnode/tyre/t_tyremud_b.color.dds'
local TEX_O = '/art/deepnode/tyre/t_tyremud_o.data.dds'
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
local rubber = {}           -- tyre rubber materials of the vehicles: name -> state (wet look)
local rubberT = -huge       -- last rubber wetness pass
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
  if W.sec then
    for _, S in ipairs(W.sec) do
      if S.mat then matFree[#matFree + 1] = { name = S.matName, mat = S.mat, texB = S.matTex } end
      S.mat, S.matName, S.matTex = false, false, false
    end
  end
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
-- grey; the texture (tools/tyre_textures/bake_tyrefilm.py) streaks it where the water runs off.
local FILM_B = '/art/deepnode/tyre/t_tyrefilm_b.color.dds'
local FILM_O = '/art/deepnode/tyre/t_tyrefilm_o.data.dds'
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
  -- sectors: every arc gets the same whole number of columns
  local nsec = W.sec and #W.sec or 0
  if nsec > 0 then nC = math.ceil(nC / nsec) * nsec end
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
    -- one submesh per sector arc (columns c0..c1 with its own material), else one in all
    local parts = {}
    if nsec > 0 then
      local per = nC / nsec
      for q = 1, nsec do parts[q] = { W.sec[q].matName, (q - 1) * per, q * per } end
    else
      parts[1] = { W.matName, 0, nC }
    end
    for _, part in ipairs(parts) do
    local c0, c1 = part[2], part[3]
    local row = c1 - c0 + 1
    local s = builder:sub(part[1], (k1 - k0 + 1) * row)
    local base = nil
    for k = k0, k1 do
      local P = prof[k]
      local u = P.s / sTot
      for col = c0, c1 do
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
    for k = 0, k1 - k0 - 1 do
      for col = 0, c1 - c0 - 1 do
        local i1 = base + k * row + col
        local i2, i3, i4 = i1 + row, i1 + row + 1, i1 + 1
        if flip then
          s:tri(i1, i3, i2); s:tri(i1, i4, i3)
        else
          s:tri(i1, i2, i3); s:tri(i1, i3, i4)
        end
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
-- a tyre sector's coat (see the tyre sectors section)
local function resetSector(S, W)
  S.coat, S.loose, S.wet, S.newShare, S.dC = 0, 0, 0, 0, 0
  S.kind, S.kindT, S.col = W.kind, -huge, false
  S.wantRef = 255
end

local function resetCoat(W)
  W.coat, W.loose = 0, 0
  W.water = 0
  W.wet = 0
  W.rw = 0
  W.prevE1, W.prevC = nil, nil
  W.omega = 0
  W.chunkAcc = 0
  W.wantRef = 255
  W.col = nil
  W.newShare = 0
  W.dcol, W.dkind, W.lookKey, W.lookFrom, W.dC = nil, nil, nil, nil, 0
  W.cang, W.cacc = nil, 0
  if W.sec then for _, S in ipairs(W.sec) do resetSector(S, W) end end
end

-- coat change over dt; returns the coat that dropped off as chunks (loose shed + fling).
-- Sector coats (clods.sectors) pass their pick-up weight, water share and the wheel's
-- distance rolled; a whole wheel passes nothing.
local function updateCoat(W, c, dt, pickW, wat, moved)
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
    local picked = (c.buildPerMeter or 0.03) * build * (KG.stick or 1) * depthF * spinF * rolled * (pickW or 1)
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
      local m = moved or W.moved
      local l = min(W.loose, (c.looseShedPerMeter or 0.03) * shed * m)
      W.loose = W.loose - l
      dropped = dropped + l
      W.coat = W.coat - l - (c.cleanPerMeter or 0.002) * shed * m * min(1, W.coat)
    end
    if W.loose > 0 then W.loose = W.loose - W.loose * min(1, dt / max(0.1, c.packTime or 6)) end
  end
  if not moved then W.moved = 0 end
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
  local water = wat or W.water or 0
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
-- tyre sectors (clods.sectors, MudRunner / SnowRunner style)
-------------------------------------------------------------------------------
-- The tyre's perimeter is split into N arcs, each with its own coat, kind, colour and
-- wetness. Only the arcs that touch the ground pick mud up, by the distance they roll
-- through it: half a turn in mud leaves half the tyre clean, a parked tyre is muddy
-- only at the bottom, a spinning one gets covered all round. Water wets and washes the
-- arcs under the water line only. Each arc is one submesh of the skin with its own
-- material (coverage = alphaRef, kind textures, colour, wetness).
-- A sector reads the wheel's shared state (spin, depth, ground kind and colour) through
-- its metatable; everything it writes (coat, loose, kind, col, wet, material) is its own.
local TWO_PI = 2 * math.pi
local function nSectors()
  local n = ctx and ctx.cfg.clods.sectors or 0
  return n >= 2 and floor(n) or 0
end

local function wrapAngle(a)
  a = a % TWO_PI
  if a > math.pi then a = a - TWO_PI end
  return a
end

local function makeSectors(W, n)
  local sec = {}
  local mt = { __index = W }
  for s = 1, n do
    -- false (not nil) shadows the wheel's own fields a sector must never use
    local S = setmetatable({ s = s, dkind = false, dcol = false, film = false, filmDue = false,
      ref = 255, flushT = -huge, cap = W.cap or 3, mat = false, matName = false, matTex = false,
      matKind = false, matCol = false, matWet = 0, pend = false, matDirty = false, near = false }, mt)
    resetSector(S, W)
    sec[s] = S
  end
  W.sec = sec
end

-- pick-up weights of the arcs: the contact patch (half angle from the sinking depth) swept
-- over the rotation since the last tick, sampled; the weights sum to N (mean 1, so the
-- tyre as a whole picks up what the single-coat model did)
local wts = {}
local function contactWeights(W, n)
  for s = 1, n do wts[s] = 0 end
  local a1 = W.cang
  if not a1 then
    for s = 1, n do wts[s] = 1 end
    return wts
  end
  local R = max(0.1, W.R or 0.4)
  local dep = max(0, W.lastDepth or 0) + 0.04
  local half = math.acos(clamp(1 - dep / R, -1, 1))
  local a0 = a1 - (W.cacc or 0)
  local lo, hi = min(a0, a1) - half, max(a0, a1) + half
  if hi - lo >= TWO_PI then
    for s = 1, n do wts[s] = 1 end
    return wts
  end
  local ns = 24
  local step = n / TWO_PI
  for q = 0, ns - 1 do
    local a = (lo + (hi - lo) * (q + 0.5) / ns) % TWO_PI
    local s = floor(a * step) + 1
    if s > n then s = n end
    wts[s] = wts[s] + n / ns
  end
  return wts
end

-- one coat tick of a sectored wheel; the wheel's own coat fields become the sectors'
-- mean (chunks, tyre layer, cake scale, visibility use them); returns the dropped coat
local function updateSectors(W, c, dt)
  local sec = W.sec
  local n = #sec
  local w = contactWeights(W, n)
  W.cacc = 0
  local p = W.water or 0
  local a1 = W.cang or 0
  local dropped = 0
  local coat, loose, wet, ccoat = 0, 0, 0, 0
  local cr, cg, cb = 0, 0, 0
  local best = nil
  for s = 1, n do
    local S = sec[s]
    -- water share of the arc: the tread nodes under water lie round the bottom
    local wat = 0
    if p >= 0.99 then
      wat = 1
    elseif p > 0 then
      local d = abs(wrapAngle((s - 0.5) * TWO_PI / n - a1))
      wat = clamp((math.pi * p - d) / (TWO_PI / n) + 0.5, 0, 1)
    end
    dropped = dropped + updateCoat(S, c, dt, w[s], wat, W.moved)
    coat, loose, wet = coat + S.coat, loose + S.loose, wet + S.wet
    if S.col and S.coat > 0 then
      cr, cg, cb = cr + S.col[1] * S.coat, cg + S.col[2] * S.coat, cb + S.col[3] * S.coat
      ccoat = ccoat + S.coat
    end
    if not best or S.coat > best.coat then best = S end
  end
  W.moved = 0
  W.coat, W.loose, W.wet = coat / n, loose / n, wet / n
  W.cap = sec[1].cap
  if best and best.coat > 0 then
    if W.kind ~= best.kind then W.kind, W.kindT = best.kind, now end
  end
  if ccoat > 0 then
    local col = W.col or {}
    col[1], col[2], col[3] = cr / ccoat, cg / ccoat, cb / ccoat
    W.col = col
  end
  return dropped / n
end

-------------------------------------------------------------------------------
-- wet rubber: the vehicle's own tyre material
-------------------------------------------------------------------------------
-- A wet tyre is darker and glossy (satin highlights on the lugs and the sidewall).
-- The look comes from the vehicle's own tyre Material: roughnessFactor (x the roughness
-- map) drops by clods.rubberGloss x wetness, the base colour by clods.rubberDarken x
-- wetness. Edits reach the vehicle only with Material:reload() (~2 ms; flush() changes
-- nothing on vehicle meshes, measured), so a material is re-applied per rubberStep of
-- wetness change, one per pass inside the shared upload budget.
-- Materials are shared: every vehicle with the same tyre material shows the wettest
-- in-range tyre that uses it (no per-vehicle instance of a vehicle material exists;
-- swapping in an own copy rendered the tyre chrome, see ENGINE_FINDINGS).
local NAMED_COLORS = { White = { 1, 1, 1, 1 }, Black = { 0, 0, 0, 1 } }
local function parseColor(s)
  if type(s) ~= 'string' or s == '' then return nil end
  if NAMED_COLORS[s] then local n = NAMED_COLORS[s]; return { n[1], n[2], n[3], n[4] } end
  local t = {}
  for v in s:gmatch('[%-%d%.eE]+') do t[#t + 1] = tonumber(v) end
  if #t < 3 or not t[1] or not t[2] or not t[3] then return nil end
  return { t[1], t[2], t[3], t[4] or 1 }
end

-- Tyre layer (clods.tyreLayer, SnowRunner-style): the coat is drawn as one more layer of
-- the vehicle's own tyre material instead of the skin mesh: a layer of dirt on the rubber,
-- the tyre's own normal and AO maps under it (the tread relief stays, grooves stay dark).
-- Its opacity map is one of LAYER_K coverage masks (tools/tyre_textures/bake_tyrelayer.py,
-- mask k covers 0.12 k of the tyre: tread first, then shoulders, then sidewall blotches; an
-- opacity map is not alpha-clipped in a layer, so the share needs its own mask). The masks
-- assume the common tyre strip layout (U around, V across, tread in the middle). Same
-- reload path and sharing as the wet rubber: one material per tyre name.
local LAYER_B = '/art/deepnode/tyre/t_tyrelayer_b.color.dds'
local LAYER_O = '/art/deepnode/tyre/t_tyrelayer_o%d.data.dds'
local LAYER_N = '/art/deepnode/tyre/t_tyrelayer_nm.normal.dds'
local LAYER_K = 7
local LAYER_SHARE = 0.12

local function layerLevel(dC)
  return clamp(floor(dC / LAYER_SHARE + 0.5), 0, LAYER_K)
end

local function isRubberName(nm)
  local l = nm:lower()
  if l:find('deepnode', 1, true) then return false end
  return (l:find('tire', 1, true) or l:find('tyre', 1, true)) ~= nil
end

-- the tyre materials of a vehicle (names), registered with their original values
local function rubberOf(veh)
  local list = {}
  local ok, names = pcall(function() return veh:getMaterialNames() end)
  if not ok or type(names) ~= 'table' then return list end
  for _, nm in ipairs(names) do
    if type(nm) == 'string' and isRubberName(nm) then
      local R = rubber[nm]
      if not R then
        local m = scenetree.findObject(nm)
        if m and m.getField then
          local layers = {}
          local nl = clamp(tonumber(m:getField('activeLayers', 0)) or 1, 1, 4)
          for l = 0, nl - 1 do
            layers[#layers + 1] = { rough = tonumber(m:getField('roughnessFactor', l)) or 1,
              col = parseColor(m:getField('baseColorFactor', l)) }
          end
          -- the layer goes on top of the material's own layers (at most 4 in all)
          R = { name = nm, layers = layers, applied = 0, target = 0, t = -huge, nl = nl,
            mudIdx = nl < 4 and nl or nil,
            nrm = m:getField('normalMap', 0) or '', ao = m:getField('ambientOcclusionMap', 0) or '' }
          rubber[nm] = R
        end
      end
      if R then list[#list + 1] = nm end
    end
  end
  return list
end

-- mud: nil = no tyre layer, else { k = mask level 0..LAYER_K, col = colour string,
-- rough = roughness } (k 0 = layer off)
local function applyRubber(R, w, mud)
  local m = scenetree.findObject(R.name)
  if not m then rubber[R.name] = nil; return false end
  local c = ctx.cfg.clods
  local gloss, dark = c.rubberGloss or 0.7, c.rubberDarken or 0.3
  for i, L in ipairs(R.layers) do
    local l = i - 1
    m:setField('roughnessFactor', l, sfmt('%g', max(0.04, L.rough * (1 - gloss * w))))
    if L.col then
      local k = 1 - dark * w
      m:setField('baseColorFactor', l, sfmt('%g %g %g %g', L.col[1] * k, L.col[2] * k, L.col[3] * k, L.col[4]))
    end
  end
  local li = R.mudIdx
  if li then
    if mud and mud.k > 0 then
      if not R.mudOn then
        -- maps set once per material (a layer count change compiles a new permutation)
        m:setField('baseColorMap', li, LAYER_B)
        m:setField('normalMap', li, R.nrm)
        m:setField('ambientOcclusionMap', li, R.ao)
        -- the tyre's AO as colour detail: lug tops lighter, grooves darker
        m:setField('detailMap', li, R.ao)
        m:setField('detailScale', li, '1 1')
        m:setField('detailBaseColorMapStrength', li, sfmt('%g', R.ao ~= '' and (c.layerAoTint or 0.1) or 0))
        -- the dirt's own clods and grit over the tyre's relief
        m:setField('detailNormalMap', li, LAYER_N)
        m:setField('detailNormalMapStrength', li, sfmt('%g', c.layerRelief or 0.8))
        m:setField('metallicFactor', li, '0')
        m:setField('opacityFactor', li, '1')
        m:setField('activeLayers', 0, tostring(li + 1))
      end
      m:setField('opacityMap', li, sfmt(LAYER_O, mud.k))
      m:setField('baseColorFactor', li, mud.col)
      m:setField('roughnessFactor', li, sfmt('%g', mud.rough))
      R.mudOn = true
    elseif R.mudOn then
      m:setField('activeLayers', 0, tostring(R.nl))
      R.mudOn = false
    end
    R.mud = mud and mud.k > 0 and mud or nil
  end
  m:reload()
  R.applied, R.t = w, now
  counters.rubberReloads = (counters.rubberReloads or 0) + 1
  return true
end

-- original look back on every touched material; keep = leave them registered (toggle)
local function restoreRubber(keep)
  for _, R in pairs(rubber) do
    if R.applied > 0 or R.mudOn then pcall(applyRubber, R, 0, nil) end
  end
  if not keep then rubber = {} end
end

-- GUI / tests: wet rubber on or off live
function M.setRubberWet(on)
  if not ctx then return end
  ctx.cfg.clods.rubberWet = on and true or false
  if not on then restoreRubber(true) end
  rubberT = -huge
end

-- wetness of the rubber itself (W.rw): rises to the water share or the wet ground's
-- kind rubberWet at rubberWetRate per s, dries over rubberDryTime s (faster with speed)
local function updateRubberWet(W, c, dt)
  local src = W.water or 0
  if now - W.mudT < 0.3 then
    local K = kindCfg(W.groundKind or W.kind)
    src = max(src, K.rubberWet or 0)
  end
  local rw = W.rw or 0
  if src > rw then
    rw = min(src, rw + (c.rubberWetRate or 1.5) * dt)
  elseif rw > 0 then
    local surf = abs(W.omega or 0) * (W.R or 0.4)
    rw = max(0, rw - dt / max(1, c.rubberDryTime or 90) * (1 + surf / (c.drySpeedRef or 8)))
  end
  W.rw = rw
end

-- one pass every rubberGap s: target per material = wettest tyre of the vehicles in range
-- that use it; the biggest change past rubberStep is applied (one reload per pass)
local function rubberPass(c, t_m)
  local wetOn = c.rubberWet ~= false
  if not (wetOn or c.tyreLayer ~= false) or now - rubberT < (c.rubberGap or 0.25) then return end
  rubberT = now
  for _, R in pairs(rubber) do R.target, R.mudW = 0, nil end
  local range = c.drawDist or 150
  for _, V in pairs(vehs) do
    if V.rubber and (V.camD or 0) <= range then
      local w, mw = 0, nil
      for _, W in pairs(V.wheels) do
        if wetOn and (W.rw or 0) > w then w = W.rw end
        -- tyre layer: the muddiest wheel of the vehicle shows on its tyre material
        if V.layer and W.valid and (W.dC or 0) > (mw and mw.dC or 0) then mw = W end
      end
      for _, nm in ipairs(V.rubber) do
        local R = rubber[nm]
        if R then
          if w > R.target then R.target = w end
          if mw and (not R.mudW or mw.dC > R.mudW.dC) then R.mudW = mw end
        end
      end
    end
  end
  local best, bestD, bestMud = nil, 0, nil
  local step = c.rubberStep or 0.12
  for _, R in pairs(rubber) do
    local d = abs(R.target - R.applied)
    local score = 0
    if d >= step or (R.target < 0.03 and R.applied > 0) or (R.applied == 0 and R.target > 0.03) then score = d end
    -- the layer: mask level, colour or wetness of its muddiest wheel changed
    local mud = nil
    local W = R.mudW
    if R.mudIdx and W then
      local K = kindCfg(lookKind(W))
      local col = wetColor(W, wheelColor(W))
      -- with sectored skins the layer is only the dirt on the rubber under them
      local kmax = W.sec and (c.layerMaxSectors or 3) or LAYER_K
      -- with sectors the layer is on (kmax) or off: each reload of a shared tyre material
      -- took 18-21 ms with 8 trucks (the sectors carry the coat's level and colour)
      local k = layerLevel(W.dC)
      if W.sec then k = k > 0 and kmax or 0 end
      mud = { k = min(k, kmax), col = colorString(col), rough = wetRoughness(W, K), c3 = col, wet = W.wet or 0 }
      local a = R.mud
      -- a reload of a tyre material costs ~8 ms (every mesh of every vehicle using it,
      -- 4 Percherons): layer changes at most once per layerGap s, the first coat at once
      local due = now - R.t >= (c.layerGap or 1.5)
      if not a then
        if mud.k > 0 then score = max(score, 2) end
      elseif not due then
        -- wait
      elseif mud.k ~= a.k then
        score = max(score, 1 + abs(mud.k - a.k) * 0.1)
      elseif not W.sec and (colorDiff(mud.c3, a.c3) >= (c.colorStep or 0.03) or abs(mud.wet - a.wet) >= (c.wetStep or 0.1)) then
        score = max(score, 0.5)
      end
    elseif R.mudOn then
      score = max(score, 1)
    end
    if score > bestD then best, bestD, bestMud = R, score, mud end
  end
  if not best then return end
  -- a wetness-only update keeps the layer as it is
  if not bestMud and best.mudOn and best.mudW then bestMud = best.mud end
  -- the reload runs in a frame of its own (tileMesh reserveFrame: no tile uploads in it);
  -- after flushWait x 2 without one it runs anyway
  if t_m and t_m.reservedFor and t_m.reservedFor() ~= 'M' then
    if not best.askT then best.askT = now end
    if now - best.askT < (c.flushWait or 0.5) * 2 then t_m.reserveFrame('M'); return end
  end
  best.askT = nil
  local timer = hptimer and hptimer()
  applyRubber(best, best.target < 0.03 and 0 or best.target, bestMud)
  local ms = timer and timer:stop() or 2
  if t_m and t_m.recordUpload then t_m.recordUpload('M', nil, ms) end
  counters.rubberMs = (counters.rubberMs or 0) + ms
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
  local cl = ctx.cfg.clods
  if cl.rubberWet ~= false or cl.tyreLayer ~= false then
    local veh = getObjectByID(vid)
    if veh then V.rubber = rubberOf(veh) end
  end
  -- tyre layer instead of the skin mesh: only when every tyre material takes one more layer
  V.layer = false
  if cl.tyreLayer ~= false and V.rubber and #V.rubber > 0 then
    V.layer = true
    for _, nm in ipairs(V.rubber) do
      if not (rubber[nm] and rubber[nm].mudIdx) then V.layer = false end
    end
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
    local ns = nSectors()
    if V.layer and ns == 0 then
      -- no skin: no mesh, skin material or film
      if W.obj then hideWheel(W); W.obj:delete(); W.obj = nil end
      releaseMaterial(W)
      W.needMesh, W.shape = false, nil
    else
      if ns > 0 then
        -- sectored skin: one material per arc, none for the whole wheel
        if not W.sec or #W.sec ~= ns then
          releaseMaterial(W)
          makeSectors(W, ns)
          W.shape = nil
        end
        for _, S in ipairs(W.sec) do if not S.mat then acquireMaterial(S) end end
      elseif not W.mat then
        if W.sec then releaseMaterial(W); W.sec = nil; W.shape = nil end
        acquireMaterial(W)
      end
      if not W.film and ctx.cfg.clods.wetFilm ~= false then acquireFilm(W) end
      -- the mesh is kept over resets; only a new shape needs a new one
      if not sameShape(shapeOf(W), W.shape) then W.needMesh = true; W.needT = now end
    end
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
    restoreRubber(true)
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
  return W.visible or W.coat > 0 or now - W.mudT < 1 or (W.wet or 0) > 0 or (W.water or 0) > 0 or (W.rw or 0) > 0
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
        if not skip and (not (W.visible or W.ssFrame) or not vin) then
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
            -- sectors: where "down" points in the tyre's own frame (the skin's column
            -- angle of the contact patch) and how far it turned since the last coat tick
            if W.sec then
              local a = atan2(-f[12], -f[9])
              if W.cang then W.cacc = (W.cacc or 0) + wrapAngle(a - W.cang) end
              W.cang = a
            end
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

-- drawn coverage of a coat (wheel or sector) towards its coat's, rate limited
local function followCover(T, c, dt)
  local C = coverage(T, c)
  local dC = T.dC or 0
  if C > dC then dC = min(C, dC + (c.coverUpRate or 0.5) * dt)
  else dC = max(C, dC - (c.coverDownRate or 1) * dt) end
  if C <= 0 and dC < 0.01 then dC = 0 end
  T.dC = dC
  T.wantRef = dC <= 0 and 255 or clamp(floor(255.5 - 254 * dC), 1, 254)
  return dC
end

local flushList = {}
local one = {}
local flushTokens = 0
local lastFlushW = nil -- wheel of the last sector flush: its other arcs go next
local updN = 0
function M.update(dt)
  if not ctx or not enabled or not ctx.cfg.clods.enabled then return end
  updN = updN + 1
  now = ctx.simTime()
  local c = ctx.cfg.clods
  local t_m = tm()
  -- the flush queue persists between frames (entries are added on coat ticks, flushed on
  -- any frame); T.pend marks a queued wheel or sector
  local nFlush = #flushList
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
        if W.valid and (W.coat > 0 or (W.dC or 0) > 0 or now - W.mudT < 0.5 or (W.wet or 0) > 0 or (W.water or 0) > 0
          or (W.rw or 0) > 0) then
          local dropped = W.sec and updateSectors(W, c, vdt) or updateCoat(W, c, vdt)
          updateRubberWet(W, c, vdt)
          updateLook(W, c)
          -- drawn coverage follows the coat's at most coverUpRate / coverDownRate per s
          -- (a mud/sand switch changes coverMax: the coat no longer jumps)
          if W.sec then
            -- per arc; the wheel shows the mean coverage and the lowest threshold
            local sum, wr, rr = 0, 255, 255
            local q = c.sectorRefStep or 16
            for _, S in ipairs(W.sec) do
              local dC = followCover(S, c, vdt)
              -- shared threshold levels: arcs with the same coat change level together
              if S.wantRef < 255 then S.wantRef = clamp(floor(S.wantRef / q + 0.5) * q, 1, 254) end
              sum = sum + dC
              if S.wantRef < wr then wr = S.wantRef end
              if S.ref < rr then rr = S.ref end
            end
            W.dC, W.wantRef, W.ref = sum / #W.sec, wr, rr
          else
            followCover(W, c, vdt)
          end
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
          if dropped > 0 and (W.visible or V.layer) and not W.far then
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
        if (not V.layer or W.sec) and W.meshSig and not W.needMesh and now - (W.dkindT or W.kindT or -huge) > 1
          and abs(meshSig(kindCfg(lookKind(W)), c) - W.meshSig) > 1e-5 then
          W.needMesh = true; W.needT = now
        end
        -- mesh needed: first the wheels that carry mud
        if W.needMesh and not W.far then
          if not meshW or (W.coat > 0 and meshW.coat <= 0) or (W.needT or 0) < (meshW.needT or 0) then meshW = W end
        end
        -- material threshold to apply (the wheel's, or each sector's)
        local targets = W.sec
        if not targets then one[1] = W; targets = one end
        -- a sector steps coarser (8 materials per wheel share the flush rate)
        local tstep = W.sec and max(step, c.sectorRefStep or 16) or step
        -- sectors: colour / wetness drift rides along with the coverage steps (8 materials
        -- per wheel flushing for every colour step took ~0.9 ms each, 700 per run)
        local cstep = W.sec and (c.sectorColorStep or 0.08) or (c.colorStep or 0.03)
        local wstep = W.sec and (c.sectorWetStep or 0.25) or (c.wetStep or 0.1)
        for _, T in ipairs(targets) do
        if T.mat and not W.needMesh and not W.far and inView then
          local diff = abs(T.wantRef - T.ref)
          -- colour steps of a look fade: at most one per colorFlushGap s per wheel
          local kindChange = T.coat > 0 and (T.matKind ~= lookKind(T)
            or (colorDiff(wheelColor(T), T.matCol) >= cstep
              and now - T.flushT >= (c.colorFlushGap or 0.1))
            or abs((T.wet or 0) - (T.matWet or 0)) >= wstep
            or ((T.wet or 0) == 0 and (T.matWet or 0) > 0))
          -- per wheel at most one update every flushGap s (the coat jitters at its cap)
          local due = now - T.flushT >= (nearCam and (c.flushGap or 0.4) or (c.flushGap or 0.4) * 3)
          if kindChange or (due and (diff >= tstep or (diff > 0 and (T.wantRef == 255 or T.wantRef <= 2)))) then
            if T.wantRef ~= 255 or T.visible then
              if not T.pend then
                nFlush = nFlush + 1
                flushList[nFlush] = T
                T.pend = true
              end
              T.prio = diff + (now - T.flushT) * 20 + (kindChange and 120 or 0) + (T.ref == 255 and 300 or 0)
                + (W == lastFlushW and 200 or 0) + (nearCam and 100 or 0)
              T.near = nearCam
            end
          end
        end
        end
        -- water film: one update per wetStep of wetness change (and when dry again)
        if W.film and not W.needMesh and not W.far and inView then
          local wet, fw = W.wet or 0, W.filmWet or 0
          if abs(wet - fw) >= (c.wetStep or 0.1) or (wet == 0 and fw > 0) or (fw == 0 and wet > 0.02) then
            W.filmDue = true
            if not W.pend then
              nFlush = nFlush + 1
              flushList[nFlush] = W
              W.pend = true
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
  -- drop entries of wheels / sectors that lost their material (removed vehicles)
  do
    local n = 0
    for k = 1, nFlush do
      local T = flushList[k]
      if T.mat or rawget(T, 'film') then n = n + 1; flushList[n] = T else T.pend = false end
    end
    for k = n + 1, nFlush do flushList[k] = nil end
    nFlush = n
  end

  -- material flushes inside the upload budget, biggest change first; one per frame goes
  -- ahead anyway once its wheel waited flushWait s (tile uploads can hold the budget
  -- for seconds while digging: measured, the coverage then froze)
  if nFlush > 1 then table.sort(flushList, function(a, b) return a.prio > b.prio end) end
  -- no budget: the one that waited longest goes ahead after flushWait (with 8 sectors per
  -- wheel the top one had often just been flushed and the rest froze for seconds)
  -- flush rate cap (clods.maxFlushPerSec): with sectors the queue never empties (512 arc
  -- materials with 8 trucks) and a flush every frame cost ~0.8 ms plus ~1.5 ms of engine
  -- ticking; the arcs of a wheel still go together (sibling priority). Wheels within
  -- lodNearDist of the camera (the truck being watched) are not capped.
  local fr = c.maxFlushPerSec or 0
  local first, last = 1, nFlush
  if fr > 0 then
    flushTokens = min(2, flushTokens + fr * dt)
    if flushTokens < 1 then
      first, last = 1, 0
      for k = 1, nFlush do
        if flushList[k].near then first, last = k, k; break end
      end
    end
  end
  if last >= first and t_m and t_m.canUpload and not t_m.canUpload('M', 200) then
    local old = nil
    for k = first, last do
      local T = flushList[k]
      if now - T.flushT >= (c.flushWait or 0.25) and (not old or T.flushT < flushList[old].flushT) then old = k end
    end
    first, last = old or 1, old or 0
  end
  local done = 0
  for k = first, last do
    if done >= (c.flushPerFrame or 2) then break end
    if done > 0 and t_m and t_m.canUpload and not t_m.canUpload('M', 200) then break end
    local W = flushList[k]
    W.pend = false
    W.flushed = true
    lastFlushW = rawget(W, 's') and getmetatable(W).__index or nil
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
    if W.mat and (W.matKind ~= lookKind(W) or colorDiff(wheelColor(W), W.matCol) > 0 or abs((W.wet or 0) - (W.matWet or 0)) > 0) then
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
    if W.mat and (W.wantRef ~= W.ref or W.matDirty) then
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
    if fr > 0 and not W.near then flushTokens = flushTokens - 1 end
  end
  if done > 0 then
    local n = 0
    for k = 1, nFlush do
      local T = flushList[k]
      if rawget(T, 'flushed') then T.flushed = nil else n = n + 1; flushList[n] = T end
    end
    for k = n + 1, nFlush do flushList[k] = nil end
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

  rubberPass(c, t_m)
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
  restoreRubber()
  rubberT = -huge
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
  -- tyre texture means (ground colour / mean = colour factor, see groundColor): the kind's
  -- texMean (linear mean of the base texture weighted by its coverage order, measured from
  -- the source PNG: the shipped BC7 DDS has no alpha and GBitmap may not decode it), else
  -- measured from the texture file
  texMean = {}
  if c.groundColor ~= false then
    for k, K in pairs(ks) do
      if tonumber(K.texMean) then
        texMean[k] = max(0.05, tonumber(K.texMean))
      elseif main.textureMean then
        local m = main.textureMean(K.texB or TEX_B, true)
        if m then texMean[k] = max(0.05, (m[1] + m[2] + m[3]) / 3) end
      end
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
  -- tyre and chunk materials are owned by main and deleted with its materials; the
  -- vehicles' own tyre materials get their original roughness and colour back
  restoreRubber()
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
    rubberMaterials = (function() local n = 0 for _ in pairs(rubber) do n = n + 1 end return n end)(),
    rubberReloads = counters.rubberReloads or 0, rubberMs = counters.rubberMs or 0,
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
      if W.sec then
        local sc = {}
        for s, S in ipairs(W.sec) do
          sc[s] = sfmt('%s %.2f/%d w%.2f', S.kind, S.coat, S.ref, S.wet)
        end
        list[#list].sectors = sc
        list[#list].contact = W.cang
      end
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    out[vid] = list
  end
  return out
end

-- wheels for the screen-space overlay (deepnode_overlay): fn(vid, W) for every wheel with
-- a current frame (W.frame: hub centre, axle, e1 turning with the wheel, e2; W.R, W.rimR,
-- W.tyres, W.coat, W.wet, W.water, W.mudT, W.kind). A wheel the overlay marks W.ssFrame gets
-- its frame read every frame while in view (like a drawn coat).
function M.eachWheel(fn)
  for vid, V in pairs(vehs) do
    for _, W in pairs(V.wheels) do
      if W.valid and W.frame and not W.dead then fn(vid, W) end
    end
  end
end

-- albedo of the coat as drawn (kind colour or ground colour x brightness x texture mean)
function M.coatAlbedo(W)
  local col = wheelColor(W)
  local b = (ctx and ctx.cfg.clods.tyreBrightness) or 1
  local m = texMeanOf(lookKind(W))
  return clamp(col[1] * b * m, 0, 1), clamp(col[2] * b * m, 0, 1), clamp(col[3] * b * m, 0, 1)
end

function M.time() return now end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
