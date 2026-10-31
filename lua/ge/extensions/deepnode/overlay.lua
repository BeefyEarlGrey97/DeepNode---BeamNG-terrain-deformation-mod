-- DeepNode screen-space ground and tyre look (experimental, cfg.overlay.enabled).
--
-- Tyre prints go to a world-space map on the GPU, #deepnode_rut (RGBA16F, cfg.overlay.mapSize
-- texels over cfg.overlay.span m around the camera). PostEffects, shaders in
-- shaders/common/postFx/deepnode/:
--  * rutStampP.hlsl paints up to 16 queued print segments per frame: it reads the map and
--    writes all texels to #deepnode_rutTmp, rutCopyP.hlsl copies them back (a pass that draws
--    into a target loses its old content). Lua only sends the segments as shader constants;
--    both passes are skipped while nothing is queued, and the map keeps its content.
--    A print stores its surface kind (mud, sand, or mud / sand dust carried onto hard ground
--    by a coated tyre) and paints a berm band beside the tyre.
--  * rutOverlayP.hlsl runs after the opaque scene is lit (PFXBeforeBin ObjTranslucentBin)
--    and rewrites the scene colour ($backBuffer) where the map holds prints: print relief,
--    granular crumbs, wet churned colour and a sun highlight, relit with the sun direction,
--    and the engine's screen shadow mask (#sunShadowMask); colours change on the lit scene
--    colour (the light pre-pass G-buffer has no base colour).
--  * tyreWetP.hlsl (same slot, after the overlay) makes wet tyres darker and glossy, and can
--    draw the tyre mud coat itself (overlay.tyreCoat) for the wheels nearest the camera.
-- No mesh uploads: the rut shape still comes from the mud meshes.
-- The map follows the camera: when the camera nears its edge the window moves (8 m steps)
-- and the stamp pass reads the old content shifted, so prints stay while inside it.
--
-- Engine facts behind this (docs/ENGINE_FINDINGS.md "Custom shaders"): post effects cannot
-- write the G-buffer (#prepass), so the overlay relights by itself; a CustomMaterial on a
-- ProceduralMesh gets no constants or textures, so prints cannot displace the meshes.

local M = {}

local floor, min, max, sqrt, cos, sin, rad, exp = math.floor, math.min, math.max, math.sqrt, math.cos, math.sin,
  math.rad, math.exp
local atan2 = math.atan2
local sfmt = string.format
local tsort = table.sort

local FX_STAMP, FX_COPY, FX_OVER, FX_TYRE = 'deepnode_rutStampFX', 'deepnode_rutCopyFX', 'deepnode_rutOverlayFX',
  'deepnode_tyreWetFX'
local SH_STAMP, SH_COPY, SH_OVER, SH_TYRE = 'deepnode_rutStampShader', 'deepnode_rutCopyShader',
  'deepnode_rutOverlayShader', 'deepnode_tyreWetShader'
local SB_STAMP, SB_OVER = 'deepnode_rutStampSB', 'deepnode_rutOverlaySB'
local TARGET, TMP = '#deepnode_rut', '#deepnode_rutTmp'
local SHADER_DIR = 'shaders/common/postFx/deepnode/'
local STAMP_PATH = SHADER_DIR .. 'rutStampP.hlsl'
local COPY_PATH = SHADER_DIR .. 'rutCopyP.hlsl'
local OVER_PATH = SHADER_DIR .. 'rutOverlayP.hlsl'
local TYRE_PATH = SHADER_DIR .. 'tyreWetP.hlsl'
local COMMON_PATH = SHADER_DIR .. 'dnCommon.h.hlsl'
local MAX_SEG = 16
local MAX_WHEELS = 16
-- surface kinds stored in the map (rutStampP.hlsl)
local KIND_MUD, KIND_SAND, KIND_CARRY, KIND_DUST = 0, 1, 2, 3

local ctx, P, oc = nil, nil, nil
local active = false
local win = { x0 = 0, y0 = 0, span = 128, z = 0, set = false }
local queue, qHead, qTail = {}, 1, 0
local clearFrames = 0
local shift = nil             -- pending window move { texels x, texels y, z base change }
local clr, clrN = {}, 0       -- pending erase rects (rut tiles DeepNode reset), x0 y0 x1 y1 each
local anyPrint = false
local stampOn, overOn, tyreOn = nil, nil, nil
local vals = { [FX_STAMP] = {}, [FX_OVER] = {}, [FX_TYRE] = {} } -- [effect name][uniform] = formatted value
local sun = { x = 0, y = 0, z = 1, t = -1 }
local stats = { queued = 0, painted = 0, dropped = 0, recentres = 0, frames = 0, carried = 0, tyres = 0 }
-- arc length along each tyre path, keyed by the hub point where the next report starts
-- (main stores the stamped end point as the next start), so the print pattern continues
-- from one report to the next
local arcAt, arcCount = {}, 0
local ARC_MAX = 4096
-- per frame: camera, wheel time, wheels for the tyre pass (nearest first)
local camX, camY, camZ = 0, 0, 0
local wheelNow = 0
local cand, candD, candN = {}, {}, 0
local order = {}

local function find(name) return scenetree.findObject(name) end

local function kill(name)
  local o = find(name)
  if o then
    pcall(function() if o.disable then o:disable() end end)
    o:delete()
  end
end

-- Shader constants are stored here and pushed from the effect's setShaderConsts callback,
-- which the engine calls right before the effect renders, as '$name' (measured 2026-10-31:
-- '$name' set in the callback reaches the shader, the plain name did not). setShaderConst
-- parses the value string.
local function setConst(fxName, name, a, b, c, d)
  local v
  if b == nil then v = sfmt('%.6f', a)
  else v = sfmt('%.6f %.6f %.6f %.6f', a, b, c or 0, d or 0) end
  vals[fxName][name] = v
end

local function pushConsts(fxName)
  local fx = find(fxName)
  if not fx then return end
  for name, v in pairs(vals[fxName]) do fx:setShaderConst('$' .. name, v) end
end

-- PostEffect on/off without disable(): a disabled effect may drop its named target
local function setSkip(fx, skip)
  fx:setField('skip', 0, skip and '1' or '0')
end

-- source revision as a define: the engine caches compiled shaders (failed ones too) per
-- path + defines, so an edited file (or the shared include) needs a new define to be
-- compiled again
local function sourceRev(path)
  local sum = 0
  for _, p in ipairs({ path, COMMON_PATH }) do
    local st = FS and FS.stat and FS:stat('/' .. p)
    if st then sum = sum + (tonumber(st.modtime) or 0) + (tonumber(st.filesize) or 0) end
  end
  return floor(sum % 1000000)
end

-- Existing objects are updated in place: a deleted GFXStateBlockData / ShaderData can
-- survive (still referenced), and a stale one was silently reused (2026-10-31).
local function makeShader(name, path)
  local sh = find(name)
  local new = not sh
  if new then sh = createObject('ShaderData') end
  sh.DXVertexShaderFile = path
  sh.DXPixelShaderFile = path
  sh.pixVersion = 5.0
  sh:setField('defines', 0, 'DN_REV=' .. sourceRev(path))
  if new then sh:registerObject(name) end
  if sh.reload then sh:reload() end
end

-- sampler per slot: 'p' clamp point, 'l' clamp linear
local function makeStateBlock(name, samplers)
  local sb = find(name)
  local new = not sb
  if new then
    sb = createObject('GFXStateBlockData')
    local parent = find('PFX_DefaultStateBlock')
    if parent and sb.inheritParentFields then sb:inheritParentFields(parent) end
  end
  sb.zDefined = true
  sb.zEnable = false
  sb.zWriteEnable = false
  sb.samplersDefined = true
  for i = 1, #samplers do
    sb:setField('samplerStates', i - 1, samplers:sub(i, i) == 'l' and 'SamplerClampLinear' or 'SamplerClampPoint')
  end
  -- no blending: the passes read the scene and write the changed colour
  sb.blendDefined = true
  sb.blendEnable = false
  sb:setField('blendSrc', 0, 'GFXBlendOne')
  sb:setField('blendDest', 0, 'GFXBlendZero')
  if new then sb:registerObject(name) end
end

local function makeEffects()
  makeShader(SH_STAMP, STAMP_PATH)
  makeShader(SH_COPY, COPY_PATH)
  makeShader(SH_OVER, OVER_PATH)
  makeShader(SH_TYRE, TYRE_PATH)
  -- overlay slots: scene, normals, depth, rut map (linear), shadow mask; tyres: the same
  -- without the rut map
  makeStateBlock(SB_STAMP, 'pppp')
  makeStateBlock(SB_OVER, 'ppplp')
  -- constants are lost when the device resets: push them again
  for _, fx in ipairs({ FX_STAMP, FX_OVER, FX_TYRE }) do
    rawset(_G, fx .. 'Callbacks', { setShaderConsts = function() pushConsts(fx) end,
      onEnabled = function() return true end })
  end
  local size = floor(oc.mapSize)
  local function effect(name, fields, textures)
    local fx = find(name)
    local new = not fx
    if new then fx = createObject('PostEffect') end
    fx.allowReflectPass = false
    for i = 1, #fields do fx:setField(fields[i][1], 0, fields[i][2]) end
    for i = 0, 5 do fx:setField('texture', i, textures[i + 1] or '') end
    if new then
      fx.isEnabled = false
      fx:registerObject(name)
    elseif fx.reload then
      fx:reload()
    end
    return fx
  end
  -- higher renderPriority runs first: stamp (map -> tmp), copy (tmp -> map), overlay, tyres
  local function mapPass(name, shader, prio, src, dst)
    return effect(name, {
      { 'renderTime', 'PFXBeforeBin' }, { 'renderBin', 'ObjTranslucentBin' }, { 'renderPriority', prio },
      { 'shader', shader }, { 'stateBlock', SB_STAMP }, { 'target', dst },
      { 'targetSize', size .. ' ' .. size }, { 'targetFormat', 'GFXFormatR16G16B16A16F' },
      { 'targetClear', 'PFXTargetClear_None' } }, { src })
  end
  local st = mapPass(FX_STAMP, SH_STAMP, '60', TARGET, TMP)
  local cp = mapPass(FX_COPY, SH_COPY, '59', TMP, TARGET)
  -- scene colour in slot 0, as the engine's own post effects read $backBuffer
  local ov = effect(FX_OVER, {
    { 'renderTime', 'PFXBeforeBin' }, { 'renderBin', 'ObjTranslucentBin' }, { 'renderPriority', '50' },
    { 'shader', SH_OVER }, { 'stateBlock', SB_OVER }, { 'target', '$backBuffer' } },
    { '$backBuffer', '#prepass[RT0]', '#prepass[Depth]', TARGET, '#sunShadowMask' })
  local ty = effect(FX_TYRE, {
    { 'renderTime', 'PFXBeforeBin' }, { 'renderBin', 'ObjTranslucentBin' }, { 'renderPriority', '49' },
    { 'shader', SH_TYRE }, { 'stateBlock', SB_OVER }, { 'target', '$backBuffer' } },
    { '$backBuffer', '#prepass[RT0]', '#prepass[Depth]', '#sunShadowMask' })
  st:enable(); cp:enable(); ov:enable(); ty:enable()
  setSkip(st, false); setSkip(cp, false); setSkip(ov, true); setSkip(ty, true)
  stampOn, overOn, tyreOn = true, false, false
end

local function readCam()
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then camX, camY, camZ = p.x, p.y, p.z; return true end
  end
  return false
end

-- map window centred on (x, y), snapped to 8 m (whole texels). A moved window keeps its
-- prints: the next stamp pass reads the old map shifted; a new one is cleared.
local function recentre(x, y, z)
  local half = oc.span * 0.5
  local x0 = floor((x - half) / 8 + 0.5) * 8
  local y0 = floor((y - half) / 8 + 0.5) * 8
  local z0 = floor(z)
  if win.set and win.span == oc.span and clearFrames == 0 then
    local tex = oc.span / oc.mapSize
    local sx, sy = (x0 - win.x0) / tex, (y0 - win.y0) / tex
    local p = shift
    shift = { (p and p[1] or 0) + sx, (p and p[2] or 0) + sy, (p and p[3] or 0) + win.z - z0 }
  else
    clearFrames = max(clearFrames, 2)
    anyPrint = false
    qHead, qTail = 1, 0
  end
  win.x0, win.y0, win.z, win.span = x0, y0, z0, oc.span
  win.set = true
  stats.recentres = stats.recentres + 1
end

-- sun direction from the level's ScatterSky (azimuth from +y towards +x, elevation)
local function updateSun(now)
  if now - sun.t < 1 then return end
  sun.t = now
  local names = scenetree.findClassObjects and scenetree.findClassObjects('ScatterSky') or {}
  local o = names[1] and find(names[1])
  if not o then return end
  local az = tonumber(o:getField('azimuth', 0)) or 0
  local el = tonumber(o:getField('elevation', 0)) or 45
  local ce = cos(rad(el))
  sun.x, sun.y, sun.z = sin(rad(az)) * ce, cos(rad(az)) * ce, sin(rad(el))
end

local function arcKey(x, y, k)
  return (floor(x * 64 + 0.5) * 1048576 + floor(y * 64 + 0.5)) * 8 + k
end

-- one swept wheel print: hub path p0 -> p1, axle unit vector (xy), tyre radius, tyre list
-- { {o = offset along the axle, w = width} }, surface kind, strength 0..1, berm reach
-- (x half width, 1 = none)
local function stamp(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, R, tyres, kind, strength, berm)
  if not win.set then return end
  local dx, dy = p1x - p0x, p1y - p0y
  local L = sqrt(dx * dx + dy * dy)
  local heading
  if L > 1e-3 then heading = atan2(dy, dx) else heading = atan2(axx, -axy) end
  local z = (p0z + p1z) * 0.5 - R - win.z
  if arcCount > ARC_MAX then arcAt, arcCount = {}, 0 end
  for k = 1, #tyres do
    local ty = tyres[k]
    local ox, oy = axx * ty.o, axy * ty.o
    local k0, k1 = arcKey(p0x, p0y, k), arcKey(p1x, p1y, k)
    local s0 = arcAt[k0] or 0
    arcAt[k0] = nil
    if L > 1e-3 then
      arcAt[k1] = s0 + L
      arcCount = arcCount + 1
    else
      arcAt[k0] = s0
    end
    qTail = qTail + 1
    local e = queue[qTail]
    if not e then e = {}; queue[qTail] = e end
    e[1], e[2], e[3], e[4] = p0x + ox, p0y + oy, p1x + ox, p1y + oy
    -- the shader wraps the phase at 64: send the arc length modulo that period
    e[5], e[6], e[7], e[8] = ty.w * 0.5, z, heading, s0 % (64 / oc.phasePerMetre)
    e[9], e[10], e[11] = kind, strength, berm
    stats.queued = stats.queued + 1
  end
  if qTail - qHead + 1 > oc.queueMax then
    local drop = qTail - qHead + 1 - oc.queueMax
    qHead = qHead + drop
    stats.dropped = stats.dropped + drop
  end
end

-- print of a wheel in soft ground (P.stampWheel): kind from the soft layer under the hub
local function stampSoft(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, R, tyres)
  local kind = KIND_MUD
  if P.kindAtWorld and P.kindAtWorld((p0x + p1x) * 0.5, (p0y + p1y) * 0.5) == 'sand' then kind = KIND_SAND end
  local br = oc.bermReach
  stamp(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, R, tyres, kind, 1,
    kind == KIND_SAND and (br.sand or 1.8) or (br.mud or 1.6))
end

-- erase prints over a rut tile that DeepNode reset (idle reset, clear ruts)
local function clearRect(x0, y0, x1, y1)
  if not (win.set and anyPrint) then return end
  if x1 < win.x0 or y1 < win.y0 or x0 > win.x0 + win.span or y0 > win.y0 + win.span then return end
  if clrN >= 256 then return end
  clrN = clrN + 1
  local b = (clrN - 1) * 4
  clr[b + 1], clr[b + 2], clr[b + 3], clr[b + 4] = x0, y0, x1, y1
end

-- tyre wetness the tyre pass draws: water (puddles) or a fresh mud coat, drying after the
-- tyre left the mud (overlay.tyreMudDry s)
local function tyreWet(W)
  local w = max(W.wet or 0, W.water or 0)
  if (W.kind or 'mud') == 'mud' and (W.coat or 0) > 0 then
    local age = max(0, wheelNow - (W.mudT or -1e9))
    w = max(w, min(1, W.coat * 1.5) * exp(-age / max(1, oc.tyreMudDry)) * oc.tyreMudWet)
  end
  return w
end

-- per wheel and frame (wheelMud.eachWheel): mud carried onto hard ground, tyre pass candidates
local function onWheel(vid, W)
  local f = W.frame
  local cx, cy, cz = f[1], f[2], f[3]
  -- carried prints: a coated wheel off the soft ground leaves its coat in tread prints
  local cc = oc.carry
  local hard = wheelNow - (W.mudT or -1e9) > cc.afterSoft
  local coat = W.coat or 0
  if cc.enabled and hard and coat >= cc.minCoat and win.set then
    local q = W.ovCarry
    if not q then
      W.ovCarry = { cx, cy, cz }
    else
      local dx, dy = cx - q[1], cy - q[2]
      local d2 = dx * dx + dy * dy
      if d2 > 25 then
        q[1], q[2], q[3] = cx, cy, cz
      elseif d2 >= cc.step * cc.step then
        local axx, axy = f[4], f[5]
        local al = sqrt(axx * axx + axy * axy)
        if al > 0.3 then
          local kind = (W.kind == 'sand') and KIND_DUST or KIND_CARRY
          stamp(q[1], q[2], q[3], cx, cy, cz, axx / al, axy / al, W.R, W.tyres, kind, min(1, coat * cc.perCoat), 1)
          stats.carried = stats.carried + 1
        end
        q[1], q[2], q[3] = cx, cy, cz
      end
    end
  else
    W.ovCarry = nil
  end
  -- tyre pass candidates: wet or (screen-space coat) coated wheels near the camera
  local ssCoat = oc.tyreCoat and coat > 0.02
  local wet = oc.tyres and tyreWet(W) or 0
  if wet < 0.02 and not ssCoat then W.ssFrame = nil; return end
  local dx, dy, dz = cx - camX, cy - camY, cz - camZ
  local d2 = dx * dx + dy * dy + dz * dz
  if d2 > oc.tyreRange * oc.tyreRange then W.ssFrame = nil; return end
  W.ssFrame = true
  if ctx.pointInView and not ctx.pointInView(cx, cy, cz, W.R) then return end
  candN = candN + 1
  cand[candN] = W
  candD[W] = d2
  W.ovWet = wet
end

local function byDist(a, b) return candD[a] < candD[b] end

local function hw(W)
  local h = 0
  for i = 1, #W.tyres do
    local t = W.tyres[i]
    h = max(h, math.abs(t.o) + t.w * 0.5)
  end
  return h
end

-- coat colour packed for the shader (6 bits a channel)
local function q6(v) return floor(min(1, max(0, v)) * 63 + 0.5) end
local function packColor(r, g, b)
  return q6(r) + q6(g) * 64 + q6(b) * 4096
end

local function sendTyres(wm)
  for k = candN + 1, #order do order[k] = nil end
  for k = 1, candN do order[k] = cand[k] end
  tsort(order, byDist)
  local n = min(candN, MAX_WHEELS, oc.tyreMaxWheels)
  for i = 0, n - 1 do
    local W = order[i + 1]
    local f = W.frame
    setConst(FX_TYRE, 'dnWa' .. i, f[1], f[2], f[3], W.R)
    setConst(FX_TYRE, 'dnWb' .. i, f[4], f[5], f[6], hw(W))
    setConst(FX_TYRE, 'dnWc' .. i, f[7], f[8], f[9], W.rimR or W.R * 0.6)
    local cr, cg, cb = wm.coatAlbedo(W)
    setConst(FX_TYRE, 'dnWd' .. i, W.ovWet or 0, oc.tyreCoat and (W.coat or 0) or 0, packColor(cr, cg, cb),
      (W.seed or 0) % 97)
  end
  for k = 1, candN do candD[cand[k]] = nil; cand[k] = nil end
  candN = 0
  stats.tyres = n
  return n
end

function M.start(main)
  ctx = main
  P = main.private
  oc = main.cfg.overlay or {}
  active = false
  if not oc.enabled then return false end
  if not (createObject and scenetree) then return false end
  makeEffects()
  -- prints painted in the first frames after the effects are created were lost: warm up
  -- with clear passes (queued prints wait)
  clearFrames = 10
  if readCam() then recentre(camX, camY, camZ - 3) end
  queue, qHead, qTail = {}, 1, 0
  arcAt, arcCount = {}, 0
  shift = nil
  clr, clrN = {}, 0
  for k in pairs(stats) do stats[k] = 0 end
  sun.t = -1
  P.overlayStamp = stampSoft
  P.overlayClear = clearRect
  active = true
  log('I', 'deepnode', sfmt('rut overlay on: %d^2 map over %d m', floor(oc.mapSize), floor(oc.span)))
  return true
end

function M.stop()
  if P then P.overlayStamp, P.overlayClear = nil, nil end
  active = false
  for _, n in ipairs({ FX_STAMP, FX_COPY, FX_OVER, FX_TYRE, SH_STAMP, SH_COPY, SH_OVER, SH_TYRE, SB_STAMP, SB_OVER }) do
    kill(n)
  end
  for _, fx in ipairs({ FX_STAMP, FX_OVER, FX_TYRE }) do rawset(_G, fx .. 'Callbacks', nil) end
  vals = { [FX_STAMP] = {}, [FX_OVER] = {}, [FX_TYRE] = {} }
  win.set = false
  local wm = extensions and extensions.deepnode_wheelMud
  if wm and wm.eachWheel then wm.eachWheel(function(_, W) W.ssFrame, W.ovCarry = nil, nil end) end
end

-- recompile the overlay and tyre shaders in place, for shader work: a PostEffect keeps the
-- shader it compiled until it is reloaded itself (ShaderData:reload alone changed nothing,
-- 2026-10-31). The map passes are left alone, so the prints stay.
function M.reloadShaders()
  if not active then return false end
  makeShader(SH_OVER, OVER_PATH)
  makeShader(SH_TYRE, TYRE_PATH)
  for _, name in ipairs({ FX_OVER, FX_TYRE }) do
    local fx = find(name)
    if fx and fx.reload then fx:reload() end
  end
  return true
end

function M.isActive() return active end
function M.stats()
  return { queued = stats.queued, painted = stats.painted, dropped = stats.dropped, recentres = stats.recentres,
    carried = stats.carried, tyres = stats.tyres, pending = qTail - qHead + 1,
    window = { win.x0, win.y0, win.span, win.z } }
end

local function kindConsts(name, K)
  setConst(FX_OVER, name, K.darken, K.saturate, K.wet, K.bermCrumbs)
end

-- per frame, from deepnode_main after wheelMud read the wheel frames
function M.frame()
  if not active then return end
  local st, cp, ov, ty = find(FX_STAMP), find(FX_COPY), find(FX_OVER), find(FX_TYRE)
  if not (st and cp and ov and ty) then active = false; return end
  stats.frames = stats.frames + 1
  if readCam() then
    local m = oc.recentreMargin
    local x, y = camX, camY
    if not win.set or x < win.x0 + m or y < win.y0 + m or x > win.x0 + win.span - m or y > win.y0 + win.span - m then
      recentre(x, y, camZ - 3)
    end
  end

  -- wheels: carried prints (queued before this frame's paint) and tyre pass candidates
  local wm = extensions and extensions.deepnode_wheelMud
  if wm and wm.eachWheel then
    wheelNow = wm.time()
    wm.eachWheel(onWheel)
  end

  -- paint pass: clear, queued prints and/or a window move, or nothing
  setConst(FX_STAMP, 'dnWin', win.x0, win.y0, win.span, win.z)
  if shift then
    setConst(FX_STAMP, 'dnShift', shift[1], shift[2], shift[3], min(4, clrN))
  else
    setConst(FX_STAMP, 'dnShift', 0, 0, 0, min(4, clrN))
  end
  local moved = shift ~= nil
  shift = nil
  -- erase rects, 4 per frame
  local nc = min(4, clrN)
  for i = 0, nc - 1 do
    local b = i * 4
    setConst(FX_STAMP, 'dnClr' .. i, clr[b + 1], clr[b + 2], clr[b + 3], clr[b + 4])
  end
  if nc > 0 then
    for k = 1, (clrN - nc) * 4 do clr[k] = clr[k + nc * 4] end
    clrN = clrN - nc
  end
  local n = 0
  if clearFrames > 0 then
    clearFrames = clearFrames - 1
    setConst(FX_STAMP, 'dnCtl', 0, 1, oc.edge, oc.phasePerMetre)
    n = -1
  else
    n = min(min(oc.segmentsPerFrame, MAX_SEG), qTail - qHead + 1)
    for i = 0, n - 1 do
      local e = queue[qHead + i]
      setConst(FX_STAMP, 'dnA' .. i, e[1], e[2], e[3], e[4])
      setConst(FX_STAMP, 'dnB' .. i, e[5], e[6], e[7], e[8])
      setConst(FX_STAMP, 'dnC' .. i, e[9], e[10], e[11], 0)
    end
    qHead = qHead + n
    if qHead > qTail then qHead, qTail = 1, 0 end
    setConst(FX_STAMP, 'dnCtl', n, 0, oc.edge, oc.phasePerMetre)
    stats.painted = stats.painted + n
    if n > 0 then anyPrint = true end
  end
  local wantStamp = n ~= 0 or moved or nc > 0
  if wantStamp ~= stampOn then setSkip(st, not wantStamp); setSkip(cp, not wantStamp); stampOn = wantStamp end

  local dbg = oc.debug or 0
  updateSun(os.clock())
  local useSh = oc.useShadowMask and 1 or 0

  -- tyre pass: only while wet / coated wheels are in view
  local nt = (wm and wm.coatAlbedo) and sendTyres(wm) or 0
  local wantTyre = oc.tyres and nt > 0
  if wantTyre ~= tyreOn then setSkip(ty, not wantTyre); tyreOn = wantTyre end
  if wantTyre then
    setConst(FX_TYRE, 'dnSun', sun.x, sun.y, sun.z, oc.ambient)
    setConst(FX_TYRE, 'dnTy', nt, oc.tyreWetDarken, oc.tyreHighlight, dbg == 5 and 1 or 0)
    setConst(FX_TYRE, 'dnTyOpt', useSh, oc.tyreAlbedo, oc.tyreCoat and 1 or 0, oc.tyreCoatLump)
  end

  -- overlay pass: only while the map holds prints (or a debug view is on)
  local wantOver = anyPrint or (dbg > 0 and dbg ~= 5)
  if wantOver ~= overOn then setSkip(ov, not wantOver); overOn = wantOver end
  if not wantOver then return end
  setConst(FX_OVER, 'dnWin', win.x0, win.y0, win.span, win.z)
  setConst(FX_OVER, 'dnSun', sun.x, sun.y, sun.z, oc.ambient)
  setConst(FX_OVER, 'dnTread', oc.phasePerMetre, oc.streaks, oc.pressDepth, oc.lip)
  setConst(FX_OVER, 'dnLook', oc.strength, oc.fadeStart, oc.fadeLength, oc.highlight)
  setConst(FX_OVER, 'dnMask', oc.zTolerance, oc.minNormalZ, dbg, oc.mapSize)
  setConst(FX_OVER, 'dnOpt', useSh, oc.groundAlbedo, oc.grooveDark, oc.bermZTolerance)
  kindConsts('dnMud', oc.mud)
  kindConsts('dnSand', oc.sand)
  local c, d = oc.carry, oc.dust
  setConst(FX_OVER, 'dnCarry', c.color[1], c.color[2], c.color[3], c.opacity)
  setConst(FX_OVER, 'dnDust', d.color[1], d.color[2], d.color[3], d.opacity)
  setConst(FX_OVER, 'dnCarryG', c.gain, d.gain, 0, 0)
  local g = oc.grain
  setConst(FX_OVER, 'dnGrain', g.size, g.height, g.printDensity, g.churnSize)
end

-- test hook: paint a print without a vehicle (world xy path, ground z, width, kind 0..3)
function M.testPrint(x0, y0, x1, y1, z, width, kind)
  stamp(x0, y0, z + 0.4, x1, y1, z + 0.4, 0, 1, 0.4, { { o = 0, w = width or 0.3 } }, kind or 0, 1,
    (kind or 0) >= 2 and 1 or 1.6)
end

M.onExtensionLoaded = function() end
return M
