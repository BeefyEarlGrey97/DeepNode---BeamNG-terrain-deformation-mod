-- dmtestProf: wraps deepmud functions that are looked up per call and sums their time.
-- dmtestProf.install() / dmtestProf.report(frames) / dmtestProf.uninstall()
local M = {}
local acc, orig = {}, {}

local function wrap(tbl, name, label)
  if not tbl or type(tbl[name]) ~= 'function' then return end
  local f = tbl[name]
  orig[#orig + 1] = { tbl, name, f }
  local e = { ms = 0, n = 0, max = 0 }
  acc[label] = e
  tbl[name] = function(...)
    local t = hptimer()
    local a, b, c, d = f(...)
    local ms = t:stop()
    e.ms, e.n = e.ms + ms, e.n + 1
    if ms > e.max then e.max = ms end
    return a, b, c, d
  end
end

function M.install()
  M.uninstall()
  local m = deepmud_main
  local P = m.private
  wrap(m, 'onMudReport', 'report')
  wrap(m, 'onVehicleBox', 'box')
  wrap(m, 'onVehicleStats', 'vstats')
  wrap(P, 'stampWheel', 'stampWheel')
  wrap(P, 'stampBody', 'stampBody')
  wrap(P, 'slump', 'slump')
  wrap(P, 'distributeBerm', 'berm')
  wrap(P, 'updateRing', 'ring')
  wrap(P, 'relaxTiles', 'relax')
  wrap(P, 'rebuildTiles', 'tiles')
  wrap(P, 'streamTiles', 'stream')
  wrap(P, 'gatherCenters', 'centers')
  wrap(P, 'prepareTile', 'prepare')
  wrap(P, 'samplePerf', 'perf')
  wrap(P, 'updateFrozenOwn', 'frozenOwn')
  wrap(P, 'updateIdleReset', 'idleReset')
  wrap(P, 'updatePreload', 'preload')
  wrap(P, 'updateMudBounds', 'mudBounds')
  local tm = extensions.deepmud_tileMesh
  wrap(tm, 'buildTile', 'buildTile')
  wrap(tm, 'present', 'present')
  -- uploads by kind: count, verts, ms
  local pf = tm.present
  local orgPresent = orig[#orig][3]
  M.kinds = {}
  tm.present = function(chunk, meshes)
    local k = chunk.sx and (chunk.built and 'S' or 'Snew') or 'T'
    if k == 'T' and chunk.x0 then
      local cx, cy = core_camera.getPositionXYZ()
      local d = math.sqrt((chunk.x0 + 1.9 - cx) ^ 2 + (chunk.y0 + 1.9 - cy) ^ 2)
      k = d < 30 and 'T<30' or (d < 60 and 'T<60' or 'T>60')
      if chunk.rutted and chunk.lastStamp and deepmud_main.simTime() - chunk.lastStamp < 0.3 then k = k .. 'dig'
      elseif not chunk.rutted then k = k .. (chunk.obj and 'U-re' or 'U-first')
      else k = k .. (chunk.relaxing and 'R-relax' or 'R-other') .. (chunk.state == 'frozen' and 'F' or '') end
    end
    local nv, nc = 0, 0
    if meshes then for i = 1, #meshes do nv = nv + #meshes[i].verts; nc = nc + #meshes[i].faces end end
    local e = M.kinds[k] or { n = 0, v = 0, c = 0, sizes = {} }
    M.kinds[k] = e
    e.n, e.v, e.c = e.n + 1, e.v + nv, e.c + nc
    e.sizes[nc] = true
    return pf(chunk, meshes)
  end
  orig[#orig][3] = orgPresent
  wrap(tm, 'processDeferred', 'deferred')
  local fm = extensions.deepmud_farMesh
  wrap(fm, 'update', 'sectors')
  M.why = {}
  for _, fn in ipairs({ 'markDirty', 'handover' }) do
    local f0 = fm[fn]
    orig[#orig + 1] = { fm, fn, f0 }
    fm[fn] = function(sk, a, b)
      local info = debug.getinfo(2, 'l')
      local k = fn .. ':' .. (info and info.currentline or 0) .. (a == true and 'U' or '') .. ((fm.sectorState and fm.sectorState(sk)) or '-')
      M.why[k] = (M.why[k] or 0) + 1
      return f0(sk, a, b)
    end
  end
  local wm = extensions.deepmud_wheelMud
  wrap(wm, 'update', 'clods')
  wrap(wm, 'preRender', 'clodsPre')
  wrap(wm, 'onWheelMud', 'onWheelMud')
  return #orig
end

function M.uninstall()
  for i = #orig, 1, -1 do local o = orig[i]; o[1][o[2]] = o[3] end
  orig, acc = {}, {}
end

function M.reset() for _, e in pairs(acc) do e.ms, e.n, e.max = 0, 0, 0 end end

function M.report(frames)
  local out = {}
  for k, e in pairs(acc) do
    if e.n > 0 then out[#out + 1] = { k, e.ms / math.max(1, frames), e.n / math.max(1, frames), e.max } end
  end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  local s = {}
  for _, r in ipairs(out) do s[#s + 1] = string.format('%s %.3fms x%.2f max%.1f', r[1], r[2], r[3], r[4]) end
  for k, n in pairs(M.why or {}) do s[#s + 1] = 'WHY ' .. k .. ' ' .. n end
  for k, e in pairs(M.kinds or {}) do
    local ns = 0 for _ in pairs(e.sizes) do ns = ns + 1 end
    s[#s + 1] = string.format('UP %s n%d avgV %.0f avgCorners %.0f distinctSizes %d', k, e.n, e.v / math.max(1, e.n), e.c / math.max(1, e.n), ns)
  end
  return table.concat(s, ' | ')
end

return M
