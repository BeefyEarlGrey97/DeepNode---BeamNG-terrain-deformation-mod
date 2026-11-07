-- deepnode_roadBake
-- Decal roads baked into the mud (roads.mode 'bake'). Every road over a soft-ground tile is
-- rendered once, top-down, into five small images per tile (colour, opacity, normal,
-- roughness, metallic); the tile's mud material gets one detail-only layer that reads them
-- (roadBakeCore.layerFields). The road then lies in the mud surface itself: it follows every rut,
-- is lit like the ground and needs no copy submeshes (deepnode_roadCopy stays the fallback for
-- tiles whose bake is not loaded yet, see main.tileMatName / tileMesh).
--
-- Bake (GPU, one tile at a time, one road material per frame): roadBakeP.hlsl composites the
-- material's quads over the accumulators #deepnode_rbA / #deepnode_rbB (ping-pong through
-- rutCopyP.hlsl: several post effects cannot share one named target, so one effect pair is used
-- and its road maps are switched per step with PostEffect:setTexture). roadBakeResolveP.hlsl writes
-- the five images; named-buffer screenshots save them as PNG in the cache
-- (deepnode_cache/roadbake/<level>/, roadBakeCore.cachePaths). The engine cooks each PNG to
-- /temp/<path>.dds when a material first uses it; the clone is reloaded once the cooks exist, and
-- only then the tile counts as ready (main.onRoadBakeReady rebuilds it).
--
-- Clones (deepnode_rb_<tile>_<layer>) are never deleted during a session: the tile mesh pool keeps
-- ProceduralMesh objects that still reference them.

local M = {}

local floor, min, max, sqrt, huge = math.floor, math.min, math.max, math.sqrt, math.huge
local sfmt = string.format

local C = nil           -- deepnode_roadBakeCore
local ctx = nil         -- deepnode_main
local enabled = false
local VERSION = 1       -- bake shader / layout version (part of the signature)
local MAXQ = 64         -- quads per bake step (roadBakeP.hlsl constant slots)
local SHADER_DIR = 'shaders/common/postFx/deepnode/'
local BAKE_PATH, RES_PATH, COPY_PATH = SHADER_DIR .. 'roadBakeP.hlsl', SHADER_DIR .. 'roadBakeResolveP.hlsl', SHADER_DIR .. 'rutCopyP.hlsl'
local FX_A, FX_B, FX_CA, FX_CB = 'deepnode_rbFxA', 'deepnode_rbFxB', 'deepnode_rbCopyA', 'deepnode_rbCopyB'
local FX_RES = 'deepnode_rbRes'      -- .. 0..4
local SB = 'deepnode_rbSB'
local T_A, T_AT, T_B, T_BT, T_OUT = '#deepnode_rbA', '#deepnode_rbAt', '#deepnode_rbB', '#deepnode_rbBt', '#deepnode_rbOut'

local roads = {}        -- { id, mat, prio, tl, L, R, D, info }
local byTile = {}       -- tile key -> { road, ... }
local matInfo = {}      -- road material -> { col, opa, nrm, rgh, tint, opacity, aref, nstr, rough, metal } | false
local recs = {}         -- tile key -> { state, sig, files, map, groups, step, clones, t0 }
local front = {}        -- tile keys moved to the front of the queue (meshed while unbaked)
local queue, queuePos, queueT = {}, 1, -huge
local job = nil         -- tile record being baked
local fxReady = false
local shaderNames = {}
local consts = { a = {}, b = {}, res = {} }
local startedT = {}     -- start times of the tiles of the last second (bakeMaxPerSec)
local stats = { roads = 0, tiles = 0, queued = 0, baked = 0, ready = 0, fallback = 0, failed = 0, cached = 0, bakeMs = 0, lastError = '' }

local function find(n) return scenetree.findObject(n) end
local function field(o, name, st)
  local ok, v = pcall(function() return o:getField(name, st or 0) end)
  if ok then return v end
  return nil
end
local function num(o, name, d) return tonumber(field(o, name)) or d end
local function isFinite(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end
local function now() return ctx.simTime() end

-------------------------------------------------------------------------------
-- roads over soft ground
-------------------------------------------------------------------------------
local function readMat(name)
  local have = matInfo[name]
  if have ~= nil then return have or nil end
  local mo = find(name)
  local col = mo and tostring(field(mo, 'baseColorMap') or '') or ''
  if col == '' then matInfo[name] = false; return nil end
  local tint = {}
  for v in tostring(field(mo, 'baseColorFactor') or ''):gmatch('[%d%.%-]+') do tint[#tint + 1] = tonumber(v) end
  if #tint < 3 then tint = { 1, 1, 1 } end
  local aref = -1
  if tonumber(field(mo, 'alphaTest')) == 1 then aref = num(mo, 'alphaRef', 0) / 255 end
  local nrm = tostring(field(mo, 'normalMap') or '')
  local e = { col = col, opa = tostring(field(mo, 'opacityMap') or ''), nrm = nrm, rgh = tostring(field(mo, 'roughnessMap') or ''),
    tint = tint, opacity = num(mo, 'opacityFactor', 1), aref = aref,
    nstr = nrm ~= '' and num(mo, 'normalMapStrength', 1) or 0, rough = num(mo, 'roughnessFactor', 1), metal = num(mo, 'metallicFactor', 0) }
  matInfo[name] = e
  return e
end

local function addRoad(road, P)
  local mat = tostring(field(road, 'material') or '')
  if mat == '' then return end
  local lmat = mat:lower()
  for _, t in ipairs(ctx.cfg.roads.overSkipMatch or { 'invisible' }) do
    if t ~= '' and lmat:find(tostring(t):lower(), 1, true) then return end
  end
  if not readMat(mat) then return end
  local okC, ec = pcall(function() return road:getEdgeCount() end)
  ec = okC and tonumber(ec) or 0
  if ec < 2 then return end
  -- same edge rules as deepnode_roadCopy: distance along the 3D middle of the two edges
  local L, R, D = {}, {}, {}
  local n, soft, dist, px, py, pz = 0, 0, 0, 0, 0, 0
  for i = 0, ec - 1 do
    local okE, l, r = pcall(function() return road:getLeftEdgePosition(i), road:getRightEdgePosition(i) end)
    if okE and l and r and isFinite(l.x) and isFinite(l.y) and isFinite(r.x) and isFinite(r.y) then
      local mx, my, mz = (l.x + r.x) * 0.5, (l.y + r.y) * 0.5, (l.z + r.z) * 0.5
      local dd = n > 0 and sqrt((mx - px) ^ 2 + (my - py) ^ 2 + (mz - pz) ^ 2) or 0
      if n == 0 or dd >= 1e-3 then
        dist = dist + dd
        n = n + 1
        L[n], R[n], D[n] = { x = l.x, y = l.y }, { x = r.x, y = r.y }, dist
        px, py, pz = mx, my, mz
        if P.softAtWorld(mx, my) or P.softAtWorld(l.x, l.y) or P.softAtWorld(r.x, r.y) then soft = soft + 1 end
      end
    end
  end
  if n < 2 or soft == 0 then return end
  local tl = tonumber(field(road, 'textureLength')) or 5
  if tl <= 0.01 then tl = 5 end
  local e = { id = road:getId(), mat = mat, prio = tonumber(field(road, 'renderPriority')) or 10, tl = tl, L = L, R = R, D = D }
  roads[#roads + 1] = e
  local ter, T, KEY = ctx.ter, ctx.tileSize, ctx.KEY
  local seen = {}
  for i = 1, n - 1 do
    local x0 = min(L[i].x, R[i].x, L[i + 1].x, R[i + 1].x) - 0.3
    local x1 = max(L[i].x, R[i].x, L[i + 1].x, R[i + 1].x) + 0.3
    local y0 = min(L[i].y, R[i].y, L[i + 1].y, R[i + 1].y) - 0.3
    local y1 = max(L[i].y, R[i].y, L[i + 1].y, R[i + 1].y) + 0.3
    for ty = floor((y0 - ter.oy) / T), floor((y1 - ter.oy) / T) do
      for tx = floor((x0 - ter.ox) / T), floor((x1 - ter.ox) / T) do
        local k = ty * KEY + tx
        if not seen[k] then
          seen[k] = true
          local list = byTile[k]
          if not list then list = {}; byTile[k] = list end
          list[#list + 1] = e
        end
      end
    end
  end
end

local function tileOrigin(k)
  local KEY = ctx.KEY
  local tx, ty = k % KEY, floor(k / KEY)
  return ctx.ter.ox + tx * ctx.tileSize, ctx.ter.oy + ty * ctx.tileSize
end

-------------------------------------------------------------------------------
-- post effects
-------------------------------------------------------------------------------
local function sourceRev(path)
  local st = FS and FS.stat and FS:stat('/' .. path)
  return st and floor(((tonumber(st.modtime) or 0) + (tonumber(st.filesize) or 0)) % 1000000) or 0
end

local function makeShader(base, path)
  local name = base .. '_' .. sourceRev(path)
  local sh = find(name)
  if not sh then
    sh = createObject('ShaderData')
    sh.DXVertexShaderFile = path
    sh.DXPixelShaderFile = path
    sh.pixVersion = 5.0
    sh:registerObject(name)
  end
  shaderNames[#shaderNames + 1] = name
  return name
end

local function setSkip(name, skip)
  local fx = find(name)
  if fx then fx:setField('skip', 0, skip and '1' or '0') end
end

local function effect(name, prio, shader, target, fmt, size, textures, cvals)
  local fx = find(name)
  local new = not fx
  if new then fx = createObject('PostEffect') end
  fx.allowReflectPass = false
  for _, f in ipairs({ { 'renderTime', 'PFXBeforeBin' }, { 'renderBin', 'ObjTranslucentBin' }, { 'renderPriority', tostring(prio) },
    { 'shader', shader }, { 'stateBlock', SB }, { 'target', target }, { 'targetSize', size .. ' ' .. size },
    { 'targetFormat', fmt }, { 'targetClear', 'PFXTargetClear_None' } }) do
    fx:setField(f[1], 0, f[2])
  end
  for i = 0, 5 do fx:setField('texture', i, textures[i + 1] or '') end
  if cvals then
    rawset(_G, name .. 'Callbacks', { onEnabled = function() return true end, setShaderConsts = function()
      for k, v in pairs(cvals) do fx:setShaderConst(k, v) end
    end })
  end
  if new then
    fx.isEnabled = false
    fx:registerObject(name)
  elseif fx.reload then
    fx:reload()
  end
  fx:enable()
  fx:setField('skip', 0, '1')
end

local function makeEffects()
  if fxReady then return end
  local size = floor(ctx.cfg.roads.bakeSize or 512)
  local shBake = makeShader('deepnode_rbBakeSh', BAKE_PATH)
  local shRes = makeShader('deepnode_rbResSh', RES_PATH)
  local shCopy = makeShader('deepnode_rbCopySh', COPY_PATH)
  local sb = find(SB)
  if not sb then
    sb = createObject('GFXStateBlockData')
    local parent = find('PFX_DefaultStateBlock')
    if parent and sb.inheritParentFields then sb:inheritParentFields(parent) end
    sb.zDefined = true; sb.zEnable = false; sb.zWriteEnable = false
    sb.blendDefined = true; sb.blendEnable = false
    sb.samplersDefined = true
    for i, s in ipairs({ 'SamplerWrapLinear', 'SamplerWrapLinear', 'SamplerWrapLinear', 'SamplerWrapLinear', 'SamplerClampPoint', 'SamplerClampPoint' }) do
      sb:setField('samplerStates', i - 1, s)
    end
    sb:registerObject(SB)
  end
  local F16, F8 = 'GFXFormatR16G16B16A16F', 'GFXFormatR8G8B8A8'
  -- higher renderPriority runs first: bake A, copy A, bake B, copy B, resolves
  effect(FX_A, 140, shBake, T_AT, F16, size, { '', '', '', '', T_A }, consts.a)
  effect(FX_CA, 139, shCopy, T_A, F16, size, { T_AT }, {})
  effect(FX_B, 138, shBake, T_BT, F16, size, { '', '', '', '', T_B }, consts.b)
  effect(FX_CB, 137, shCopy, T_B, F16, size, { T_BT }, {})
  for i = 0, 4 do
    consts.res[i] = { ['$dnCtl'] = sfmt('%d 0 0 0', i) }
    effect(FX_RES .. i, 130 - i, shRes, T_OUT .. i, F8, size, { T_A, T_B }, consts.res[i])
  end
  fxReady = true
end

local function killEffects()
  for _, n in ipairs({ FX_A, FX_CA, FX_B, FX_CB, FX_RES .. 0, FX_RES .. 1, FX_RES .. 2, FX_RES .. 3, FX_RES .. 4 }) do
    local o = find(n)
    if o then
      pcall(function() if o.disable then o:disable() end end)
      o:delete()
    end
    rawset(_G, n .. 'Callbacks', nil)
  end
  local sb = find(SB)
  if sb then sb:delete() end
  for _, n in ipairs(shaderNames) do local o = find(n); if o then o:delete() end end
  shaderNames = {}
  fxReady = false
end

-------------------------------------------------------------------------------
-- one tile
-------------------------------------------------------------------------------
local function f4(a, b, c, d) return sfmt('%.6f %.6f %.6f %.6f', a, b, c, d) end

-- roads over tile k as roadBakeCore wants them (quads clipped to the tile)
local function tileRoads(k)
  local x0, y0 = tileOrigin(k)
  local T = ctx.tileSize
  local out = {}
  for _, r in ipairs(byTile[k] or {}) do
    local q = C.tileQuads(r, x0, y0, T, 0.3)
    if #q > 0 then out[#out + 1] = { id = r.id, mat = r.mat, prio = r.prio, tl = r.tl, quads = q } end
  end
  return out, x0, y0
end

local function highOnTop() return ctx.cfg.roads.bakeHighOnTop == true end

-- the record of tile k with signature, files and bake groups (nil: no roads over it)
local function prepare(k)
  local rs, x0, y0 = tileRoads(k)
  if #rs == 0 then return nil end
  local T = ctx.tileSize
  local e = ctx.mudLayerAt(x0 + T * 0.5, y0 + T * 0.5)
  local map = C.tileMapping(ctx.uvOf, e, x0, y0, T)
  local size = floor(ctx.cfg.roads.bakeSize or 512)
  local sig = C.signature(rs, { version = sfmt('%d|%.6f|%.6f|%.6f|%.6f|%d|%d', VERSION, map.sx, map.sy, map.cu, map.cv, map.su, map.sv),
    size = size, highOnTop = highOnTop() })
  local files = C.cachePaths(ctx.private.levelName, k, sig)
  return { key = k, x0 = x0, y0 = y0, e = e, map = map, sig = sig, files = files, size = size,
    groups = C.drawGroups(rs, highOnTop(), MAXQ), clones = {} }
end

local function filesExist(files)
  for _, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
    if not FS:fileExists(files[n]) then return false end
  end
  return true
end
-- all five written: the screenshot writer creates a file before it finishes it, and a cook that
-- starts then reads a partial PNG ("TextureCooker: Could not open ..."), so the sizes must be
-- non-zero and unchanged since the previous frame
local function filesDone(rec)
  if not filesExist(rec.files) then return false end
  local same = rec.sizes ~= nil
  rec.sizes = rec.sizes or {}
  for _, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
    local st = FS:stat(rec.files[n])
    local sz = st and tonumber(st.filesize) or 0
    if sz <= 0 or rec.sizes[n] ~= sz then same = false end
    rec.sizes[n] = sz
  end
  return same
end
local function cookPath(f) return '/temp' .. f:gsub('%.png$', '.dds') end
local function cooked(files)
  for _, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
    if not FS:fileExists(cookPath(files[n])) then return false end
  end
  return true
end
-- the engine cooks a PNG to /temp/<path>.dds only when its texture manager loads it (a material
-- that is merely created or reloaded does not); an ImGui texture handle loads it at once
-- (~10 ms each, measured 2026-11-07). One image per call; true once all five are cooked.
local function cookOne(files)
  for _, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
    if not FS:fileExists(cookPath(files[n])) then
      local im = rawget(_G, 'ui_imgui')
      if im and im.ImTextureHandler and FS:fileExists(files[n]) then pcall(im.ImTextureHandler, files[n]) end
      return false
    end
  end
  return true
end

-- constants of one bake step: group g (nil: clear) for output 0 (A) or 1 (B)
local function stepConsts(dst, rec, g, out)
  for k in pairs(dst) do dst[k] = nil end
  local map, T = rec.map, ctx.tileSize
  dst['$dnTile'] = f4(rec.x0, rec.y0, T, rec.size)
  dst['$dnMap'] = f4(map.cu, map.su, map.cv, map.sv)
  local tangent = ctx.cfg.roads.bakeTangent or { 1, 1 }
  if not g then
    dst['$dnCtl'] = f4(0, out, 0, 1)
    return
  end
  local mi = matInfo[g.mat]
  dst['$dnMat'] = f4(mi.tint[1], mi.tint[2], mi.tint[3], mi.opacity)
  dst['$dnMat2'] = f4(mi.aref, mi.nstr, mi.rough, mi.metal)
  dst['$dnMat3'] = f4(T / rec.size, g.tl, tangent[1] or 1, tangent[2] or 1)
  dst['$dnCtl'] = f4(#g.quads, out, (mi.opa ~= '' and 1 or 0) + (mi.rgh ~= '' and 2 or 0), 0)
  for i, q in ipairs(g.quads) do
    dst['$dnP' .. (i - 1)] = f4(q[1], q[2], q[3], q[4])
    dst['$dnQ' .. (i - 1)] = f4(q[5], q[6], q[7], q[8])
    dst['$dnV' .. (i - 1)] = f4(q[9], q[10], g.roadIdx[i], q[11])
  end
end

local function setRoadMaps(g)
  local mi = matInfo[g.mat]
  for _, n in ipairs({ FX_A, FX_B }) do
    local fx = find(n)
    if fx then
      fx:setTexture(0, mi.col); fx:setTexture(1, mi.opa); fx:setTexture(2, mi.nrm); fx:setTexture(3, mi.rgh)
    end
  end
end

local function bakeOff()
  for _, n in ipairs({ FX_A, FX_CA, FX_B, FX_CB }) do setSkip(n, true) end
  for i = 0, 4 do setSkip(FX_RES .. i, true) end
end

local function fail(rec, why)
  rec.state = 'failed'
  stats.failed = stats.failed + 1
  stats.lastError = sfmt('tile %d: %s', rec.key, why)
  log('W', 'deepnode', 'road bake ' .. stats.lastError)
end

-- one frame of the job; returns true while the job continues
local function stepJob(rec)
  if rec.state == 'bake' then
    local s = rec.step
    if s == 0 then
      stepConsts(consts.a, rec, nil, 0); stepConsts(consts.b, rec, nil, 1)
    else
      local g = rec.groups[s]
      setRoadMaps(g)
      stepConsts(consts.a, rec, g, 0); stepConsts(consts.b, rec, g, 1)
    end
    for _, n in ipairs({ FX_A, FX_CA, FX_B, FX_CB }) do setSkip(n, false) end
    rec.step = s + 1
    if rec.step > #rec.groups then rec.state = 'resolve' end
    return true
  elseif rec.state == 'resolve' then
    -- the last group step ran in the previous frame: accumulators are final
    for _, n in ipairs({ FX_A, FX_CA, FX_B, FX_CB }) do setSkip(n, true) end
    for i = 0, 4 do setSkip(FX_RES .. i, false) end
    rec.state = 'shoot'
    return true
  elseif rec.state == 'shoot' then
    local ss = require('screenshot')
    for i, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
      local fname = rec.files[n]:sub(2):gsub('%.png$', '')
      ss.createScreenshotTracked({ filename = fname, bufferType = T_OUT:sub(2) .. (i - 1), superSampling = 1 })
    end
    rec.state = 'save'
    rec.t0 = now()
    return true
  elseif rec.state == 'save' then
    if filesDone(rec) then
      bakeOff()
      -- the screenshot module keeps every job and re-sends the whole list to the UI on each
      -- callback: hundreds of bake jobs made every frame ~16 ms slower (measured 2026-11-07)
      local ss = require('screenshot')
      if ss.clearScreenshotJobs then ss.clearScreenshotJobs() end
      -- older images of this tile stay until the next start (sweepCache): a material may still
      -- reference them, and a file deleted under a live material made the engine re-cook it and
      -- crash (2026-11-07)
      rec.state = 'precook'
      rec.t0 = now()
      return true
    end
    if now() - rec.t0 > 10 then bakeOff(); fail(rec, 'screenshots not saved'); return false end
    return true
  elseif rec.state == 'precook' then
    if cookOne(rec.files) then
      rec.state = 'baked'
      stats.baked = stats.baked + 1
      return false
    end
    if now() - rec.t0 > 10 then fail(rec, 'textures not cooked'); return false end
    return true
  end
  return false
end

-------------------------------------------------------------------------------
-- materials
-------------------------------------------------------------------------------
local function sameMap(a, b)
  return math.abs(a.sx - b.sx) < 1e-6 and math.abs(a.sy - b.sy) < 1e-6 and math.abs(a.cu - b.cu) < 1e-6
    and math.abs(a.cv - b.cv) < 1e-6 and a.su == b.su and a.sv == b.sv
end

-- clone of layer e's mud material with the baked layer (nil: not possible)
local function makeClone(rec, e)
  local have = rec.clones[e]
  if have ~= nil then return have or nil end
  local map = C.tileMapping(ctx.uvOf, e, rec.x0, rec.y0, ctx.tileSize)
  local src = find(ctx.matName(e))
  local fields = src and sameMap(map, rec.map) and C.layerFields(num(src, 'activeLayers', 1), rec.files, rec.map)
  if not fields then rec.clones[e] = false; return nil end
  local name = sfmt('deepnode_rb_%d_%d', rec.key, e)
  local m = find(name)
  local fresh = m == nil
  if fresh then m = createObject('Material') end
  local ok = pcall(function() m:assignFieldsFromObject(src) end)
  if not ok then
    if fresh then pcall(function() m:delete() end) end
    rec.clones[e] = false
    return nil
  end
  m:setField('mapTo', 0, name)
  for _, f in ipairs(fields) do m:setField(f[1], f[2], f[3]) end
  if fresh then
    m.canSave = false
    m:registerObject(name)
  else
    pcall(function() m:reload() end)
  end
  rec.clones[e] = name
  return name
end

local function reloadClones(rec)
  for _, name in pairs(rec.clones) do
    local m = name and find(name)
    if m then pcall(function() m:reload() end) end
  end
end

-- a baked tile that has a mesh: clones for its layers, then wait for the cooks
local function attach(rec, t)
  local okAll = true
  for _, e in ipairs(t.matList or { rec.e }) do
    if not makeClone(rec, e) then okAll = false end
  end
  if not okAll then
    rec.state = 'fallback'
    stats.fallback = stats.fallback + 1
    return
  end
  rec.state = 'cook'
  rec.t0 = now()
end

-------------------------------------------------------------------------------
-- scheduling
-------------------------------------------------------------------------------
local function points()
  local pts = {}
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then pts[#pts + 1] = { p.x, p.y } end
  end
  for i = 0, (be and be:getObjectCount() or 0) - 1 do
    local v = be:getObject(i)
    local p = v and v:getPosition()
    if p then pts[#pts + 1] = { p.x, p.y } end
  end
  return pts
end

local function rebuildQueue()
  local T = ctx.tileSize
  local cand = {}
  for k in pairs(byTile) do
    if not recs[k] then
      local x0, y0 = tileOrigin(k)
      cand[k] = { x0 + T * 0.5, y0 + T * 0.5 }
    end
  end
  queue = C.queueOrder(cand, points(), ctx.cfg.roads.bakeRadius or 80)
  queuePos = 1
  stats.queued = #queue
end

local function nextKey()
  while #front > 0 do
    local k = table.remove(front, 1)
    if not recs[k] and byTile[k] then return k end
  end
  while queuePos <= #queue do
    local k = queue[queuePos]
    queuePos = queuePos + 1
    if not recs[k] then return k end
  end
  return nil
end

local function mayStart()
  local t = now()
  local keep = {}
  for _, s in ipairs(startedT) do if t - s < 1 then keep[#keep + 1] = s end end
  startedT = keep
  return #startedT < (ctx.cfg.roads.bakeMaxPerSec or 3)
end

-- start the next tile: cache hit (files with the current signature) or a GPU job
local function startNext()
  local k = nextKey()
  if not k then return end
  local rec = prepare(k)
  if not rec then recs[k] = { key = k, state = 'none', clones = {} }; return end
  recs[k] = rec
  startedT[#startedT + 1] = now()
  if ctx.cfg.roads.bakeCache ~= false and filesExist(rec.files) then
    rec.state = 'baked'
    stats.cached = stats.cached + 1
    stats.baked = stats.baked + 1
    return
  end
  makeEffects()
  rec.state = 'bake'
  rec.step = 0
  rec.tStart = os.clock()
  job = rec
end

function M.onUpdate()
  if not enabled then return end
  local tm = ctx.private and ctx.private.mod and ctx.private.mod('tileMesh')
  -- the job: one step a frame, never in a frame that uploaded a mesh
  if job then
    if job.state == 'bake' and tm and tm.uploadsThisFrame and tm.uploadsThisFrame() > 0 then
      -- a step that is not advanced must not run again (it would composite its group twice)
      for _, n in ipairs({ FX_A, FX_CA, FX_B, FX_CB }) do setSkip(n, true) end
    else
      local ok, cont = pcall(stepJob, job)
      if not ok then bakeOff(); fail(job, tostring(cont)); cont = false end
      if not cont then
        stats.bakeMs = stats.bakeMs + (os.clock() - (job.tStart or os.clock())) * 1000
        job = nil
      end
    end
  elseif mayStart() then
    if now() - queueT > 1 then rebuildQueue(); queueT = now() end
    startNext()
  end
  -- baked tiles: clones once they have a mesh, ready once the cooks exist (at most one image
  -- cooked a frame: cache hits from an earlier session whose /temp was cleared)
  local tiles = ctx.tiles
  local cookBudget = 1
  for k, rec in pairs(recs) do
    if rec.state == 'baked' then
      local t = tiles[k]
      if t and t.obj then attach(rec, t) end
    elseif rec.state == 'cook' then
      local done = cooked(rec.files)
      if not done and cookBudget > 0 then cookBudget = cookBudget - 1; done = cookOne(rec.files) end
      if done then
        reloadClones(rec)
        rec.state = 'ready'
        stats.ready = stats.ready + 1
        if ctx.onRoadBakeReady then ctx.onRoadBakeReady(k) end
      elseif now() - rec.t0 > 30 then
        fail(rec, 'textures not cooked')
      end
    end
  end
end

-------------------------------------------------------------------------------
-- interface
-------------------------------------------------------------------------------
function M.ready(k)
  local rec = recs[k]
  return enabled and rec ~= nil and rec.state == 'ready'
end

-- baked material of layer e on tile k (nil: plain mud material and the copies)
function M.matFor(k, e)
  local rec = recs[k]
  if not (enabled and rec and rec.state == 'ready') then return nil end
  local name = rec.clones[e]
  if name == nil then
    -- a layer the tile did not have when it was attached (dug into another soil): its cooks exist
    name = makeClone(rec, e)
    if name then
      local m = find(name)
      if m then pcall(function() m:reload() end) end
    else
      rec.state = 'fallback'
      stats.ready = stats.ready - 1
      stats.fallback = stats.fallback + 1
      if ctx.onRoadBakeReady then ctx.onRoadBakeReady(k) end
    end
  end
  return name or nil
end

function M.prioritize(k)
  if enabled and byTile[k] and not recs[k] then front[#front + 1] = k end
end

function M.hasRoads(k) return byTile[k] ~= nil end
function M.isEnabled() return enabled end
function M.stats() return stats end
function M.state(k) local r = recs[k]; return r and r.state or nil, r and r.files or nil end
function M.jobState() return job and job.state or nil end

-- stale images (a tile baked again under another signature): per tile only the newest
-- signature's files are kept, and only for tiles without a clone material in the scene (a live
-- material must never lose its files, see the save step)
local function sweepCache()
  local dir = C.cachePaths(ctx.private.levelName, 0, 'x').dir
  local byKey = {}
  for _, f in ipairs(FS:findFiles(dir, '*.png', 0, true, false) or {}) do
    local key, sig = f:match('/(%d+)_(%x+)_%a+%.%a+%.png$')
    if key then
      local e = byKey[key] or {}
      byKey[key] = e
      local st = FS:stat(f)
      local t = st and tonumber(st.modtime) or 0
      e[sig] = e[sig] or { t = 0, files = {} }
      e[sig].t = max(e[sig].t, t)
      table.insert(e[sig].files, f)
    end
  end
  local cloned = {}
  for _, n in ipairs(scenetree.findClassObjects and scenetree.findClassObjects('Material') or {}) do
    local key = n:match('^deepnode_rb_(%d+)_')
    if key then cloned[key] = true end
  end
  local removed = 0
  for key, sigs in pairs(byKey) do
    if not cloned[key] then
      local newest, nt = nil, -1
      for sig, e in pairs(sigs) do if e.t > nt then newest, nt = sig, e.t end end
      for sig, e in pairs(sigs) do
        if sig ~= newest then
          for _, f in ipairs(e.files) do FS:removeFile(f); removed = removed + 1 end
        end
      end
    end
  end
  return removed
end

function M.start(main)
  ctx = main
  C = (extensions and extensions.deepnode_roadBakeCore) or require('ge/extensions/deepnode/roadBakeCore')
  roads, byTile, matInfo, recs, front, queue, queuePos, queueT, job = {}, {}, {}, {}, {}, {}, 1, -huge, nil
  for k in pairs(stats) do stats[k] = type(stats[k]) == 'number' and 0 or '' end
  local P = main.private
  local t0 = hptimer and hptimer()
  for _, name in ipairs(scenetree.findClassObjects and scenetree.findClassObjects('DecalRoad') or {}) do
    local road = find(name)
    if road then
      local okH, hid = pcall(function() return road:isHidden() end)
      if not (okH and hid) then
        local ok, err = pcall(addRoad, road, P)
        if not ok then log('W', 'deepnode', 'road bake: ' .. tostring(name) .. ': ' .. tostring(err)) end
      end
    end
  end
  for _ in pairs(byTile) do stats.tiles = stats.tiles + 1 end
  stats.roads = #roads
  local okS, removed = pcall(sweepCache)
  if okS and removed > 0 then log('I', 'deepnode', 'road bake: removed ' .. removed .. ' stale cache images') end
  enabled = true
  log('I', 'deepnode', sfmt('road bake: %d roads over soft ground, %d tiles, %.0f ms', #roads, stats.tiles, t0 and t0:stop() or 0))
  return #roads
end

function M.stop()
  enabled = false
  job = nil
  killEffects()
  roads, byTile, recs, front, queue = {}, {}, {}, {}, {}
end

M.onExtensionLoaded = function() setExtensionUnloadMode(M, 'manual') end

return M
