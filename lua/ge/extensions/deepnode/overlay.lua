-- DeepNode screen-space rut overlay (experimental, cfg.overlay.enabled).
--
-- Tyre prints go to a world-space map on the GPU, #deepnode_rut (RGBA16F, cfg.overlay.mapSize
-- texels over cfg.overlay.span m around the camera). Two PostEffects, shaders in
-- shaders/common/postFx/deepnode/:
--  * rutStampP.hlsl paints up to 16 queued print segments per frame: it reads the map and
--    writes all texels to #deepnode_rutTmp, rutCopyP.hlsl copies them back (a pass that draws
--    into a target loses its old content). Lua only sends the segments as shader constants;
--    both passes are skipped while nothing is queued, and the map keeps its content.
--  * rutOverlayP.hlsl runs after the opaque scene is lit (PFXBeforeBin ObjTranslucentBin)
--    and scales the scene colour ($backBuffer) where the map holds prints: tread relief relit with
--    the sun direction, and wet darkening. Fog and glass are drawn over it afterwards.
-- No mesh uploads: the rut shape still comes from the mud meshes.
-- The map follows the camera: when the camera nears its edge the window moves (8 m steps)
-- and the stamp pass reads the old content shifted, so prints stay while inside it.
--
-- Engine facts behind this (docs/ENGINE_FINDINGS.md "Custom shaders"): post effects cannot
-- write the G-buffer (#prepass), so the overlay relights by itself; a CustomMaterial on a
-- ProceduralMesh gets no constants or textures, so prints cannot displace the meshes.

local M = {}

local floor, min, max, sqrt, cos, sin, rad = math.floor, math.min, math.max, math.sqrt, math.cos, math.sin,
  math.rad
local atan2 = math.atan2
local sfmt = string.format

local FX_STAMP, FX_COPY, FX_OVER = 'deepnode_rutStampFX', 'deepnode_rutCopyFX', 'deepnode_rutOverlayFX'
local SH_STAMP, SH_COPY, SH_OVER = 'deepnode_rutStampShader', 'deepnode_rutCopyShader', 'deepnode_rutOverlayShader'
local SB_STAMP, SB_OVER = 'deepnode_rutStampSB', 'deepnode_rutOverlaySB'
local TARGET, TMP = '#deepnode_rut', '#deepnode_rutTmp'
local STAMP_PATH = 'shaders/common/postFx/deepnode/rutStampP.hlsl'
local COPY_PATH = 'shaders/common/postFx/deepnode/rutCopyP.hlsl'
local OVER_PATH = 'shaders/common/postFx/deepnode/rutOverlayP.hlsl'
local MAX_SEG = 16

local ctx, P, oc = nil, nil, nil
local active = false
local win = { x0 = 0, y0 = 0, span = 128, z = 0, set = false }
local queue, qHead, qTail = {}, 1, 0
local clearFrames = 0
local shift = nil             -- pending window move { texels x, texels y, z base change }
local clr, clrN = {}, 0       -- pending erase rects (rut tiles DeepNode reset), x0 y0 x1 y1 each
local anyPrint = false
local stampOn, overOn = nil, nil
local vals = { [FX_STAMP] = {}, [FX_OVER] = {} } -- [effect name][uniform] = formatted value
local sun = { x = 0, y = 0, z = 1, t = -1 }
local stats = { queued = 0, painted = 0, dropped = 0, recentres = 0, frames = 0 }
-- arc length along each tyre path, keyed by the hub point where the next report starts
-- (main stores the stamped end point as the next start), so lugs line up from one
-- report to the next
local arcAt, arcCount = {}, 0
local ARC_MAX = 4096

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
-- path + defines, so an edited file needs a new define to be compiled again
local function sourceRev(path)
  local st = FS and FS.stat and FS:stat('/' .. path)
  if not st then return 0 end
  return floor(((tonumber(st.modtime) or 0) + (tonumber(st.filesize) or 0)) % 1000000)
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

local function makeStateBlock(name)
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
  sb:setField('samplerStates', 0, 'SamplerClampPoint')
  sb:setField('samplerStates', 1, 'SamplerClampPoint')
  sb:setField('samplerStates', 2, 'SamplerClampPoint')
  sb:setField('samplerStates', 3, 'SamplerClampLinear')
  -- no blending: the overlay reads the scene colour and writes the scaled colour
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
  makeStateBlock(SB_STAMP)
  makeStateBlock(SB_OVER)
  -- constants are lost when the device resets: push them again
  rawset(_G, FX_STAMP .. 'Callbacks', { setShaderConsts = function() pushConsts(FX_STAMP) end,
    onEnabled = function() return true end })
  rawset(_G, FX_OVER .. 'Callbacks', { setShaderConsts = function() pushConsts(FX_OVER) end,
    onEnabled = function() return true end })
  local size = floor(oc.mapSize)
  local function effect(name, fields, textures)
    local fx = find(name)
    local new = not fx
    if new then fx = createObject('PostEffect') end
    fx.allowReflectPass = false
    for i = 1, #fields do fx:setField(fields[i][1], 0, fields[i][2]) end
    for i = 0, 3 do fx:setField('texture', i, textures[i + 1] or '') end
    if new then
      fx.isEnabled = false
      fx:registerObject(name)
    elseif fx.reload then
      fx:reload()
    end
    return fx
  end
  -- higher renderPriority runs first: stamp (map -> tmp), copy (tmp -> map), overlay
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
    { '$backBuffer', '#prepass[RT0]', '#prepass[Depth]', TARGET })
  st:enable(); cp:enable(); ov:enable()
  setSkip(st, false); setSkip(cp, false); setSkip(ov, true)
  stampOn, overOn = true, false
end

local function camPos()
  if core_camera and core_camera.getPosition then
    local p = core_camera.getPosition()
    if p then return p.x, p.y, p.z end
  end
  return nil
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

-- one swept wheel print, called from P.stampWheel (hub path p0 -> p1, axle unit vector,
-- tyre radius, tyre list { {o = offset along the axle, w = width} })
local function stamp(p0x, p0y, p0z, p1x, p1y, p1z, axx, axy, R, tyres)
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
    -- the shader wraps the phase at 64 lugs: send the arc length modulo that period
    e[5], e[6], e[7], e[8] = ty.w * 0.5, z, heading, s0 % (64 / oc.lugsPerMetre)
    stats.queued = stats.queued + 1
  end
  if qTail - qHead + 1 > oc.queueMax then
    local drop = qTail - qHead + 1 - oc.queueMax
    qHead = qHead + drop
    stats.dropped = stats.dropped + drop
  end
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
  local x, y, z = camPos()
  if x then recentre(x, y, z - 3) end
  queue, qHead, qTail = {}, 1, 0
  arcAt, arcCount = {}, 0
  shift = nil
  clr, clrN = {}, 0
  for k in pairs(stats) do stats[k] = 0 end
  sun.t = -1
  P.overlayStamp = stamp
  P.overlayClear = clearRect
  active = true
  log('I', 'deepnode', sfmt('rut overlay on: %d^2 map over %d m', floor(oc.mapSize), floor(oc.span)))
  return true
end

function M.stop()
  if P then P.overlayStamp, P.overlayClear = nil, nil end
  active = false
  for _, n in ipairs({ FX_STAMP, FX_COPY, FX_OVER, SH_STAMP, SH_COPY, SH_OVER, SB_STAMP, SB_OVER }) do kill(n) end
  rawset(_G, FX_STAMP .. 'Callbacks', nil)
  rawset(_G, FX_OVER .. 'Callbacks', nil)
  vals = { [FX_STAMP] = {}, [FX_OVER] = {} }
  win.set = false
end

function M.isActive() return active end
function M.stats()
  return { queued = stats.queued, painted = stats.painted, dropped = stats.dropped, recentres = stats.recentres,
    pending = qTail - qHead + 1, window = { win.x0, win.y0, win.span, win.z } }
end

function M.onPreRender()
  if not active then return end
  local st, cp, ov = find(FX_STAMP), find(FX_COPY), find(FX_OVER)
  if not (st and cp and ov) then active = false; return end
  stats.frames = stats.frames + 1
  local x, y, z = camPos()
  if x then
    local m = oc.recentreMargin
    if not win.set or x < win.x0 + m or y < win.y0 + m or x > win.x0 + win.span - m or y > win.y0 + win.span - m then
      recentre(x, y, z - 3)
    end
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
    setConst(FX_STAMP, 'dnCtl', 0, 1, oc.edge, oc.lugsPerMetre)
    n = -1
  else
    n = min(min(oc.segmentsPerFrame, MAX_SEG), qTail - qHead + 1)
    for i = 0, n - 1 do
      local e = queue[qHead + i]
      setConst(FX_STAMP, 'dnA' .. i, e[1], e[2], e[3], e[4])
      setConst(FX_STAMP, 'dnB' .. i, e[5], e[6], e[7], e[8])
    end
    qHead = qHead + n
    if qHead > qTail then qHead, qTail = 1, 0 end
    setConst(FX_STAMP, 'dnCtl', n, 0, oc.edge, oc.lugsPerMetre)
    stats.painted = stats.painted + n
    if n > 0 then anyPrint = true end
  end
  local wantStamp = n ~= 0 or moved or nc > 0
  if wantStamp ~= stampOn then setSkip(st, not wantStamp); setSkip(cp, not wantStamp); stampOn = wantStamp end

  -- overlay pass: only while the map holds prints (or a debug view is on)
  local dbg = oc.debug or 0
  local wantOver = anyPrint or dbg > 0
  if wantOver ~= overOn then setSkip(ov, not wantOver); overOn = wantOver end
  if not wantOver then return end
  updateSun(os.clock())
  setConst(FX_OVER, 'dnWin', win.x0, win.y0, win.span, win.z)
  setConst(FX_OVER, 'dnSun', sun.x, sun.y, sun.z, oc.ambient)
  setConst(FX_OVER, 'dnTread', oc.lugsPerMetre, oc.chevron, oc.relief, oc.lugWidth)
  setConst(FX_OVER, 'dnLook', oc.wetDarken, oc.strength, oc.fadeStart, oc.fadeLength)
  setConst(FX_OVER, 'dnMask', oc.zTolerance, oc.minNormalZ, dbg, oc.mapSize)
end

-- test hook: paint a print without a vehicle (world xy path, ground z, width)
function M.testPrint(x0, y0, x1, y1, z, width)
  stamp(x0, y0, z + 0.4, x1, y1, z + 0.4, 0, 1, 0.4, { { o = 0, w = width or 0.3 } })
end

M.onExtensionLoaded = function() end
return M
