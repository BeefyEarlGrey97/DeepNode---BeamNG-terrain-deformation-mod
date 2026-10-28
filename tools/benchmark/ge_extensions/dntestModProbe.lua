-- dntestModProbe: per-module DeepNode time averaged over driving frames of a dntestRun benchmark.
-- dntestModProbe.start(deep) (deep = also wrap mesh/stamp functions), dntestModProbe.result(), dntestModProbe.unwrap()
local M = {}
local acc = nil
local tmp = {}
local driving = false
local wraps = {}
local function wrap(tbl, name, label)
  if not tbl or type(tbl[name]) ~= 'function' then return end
  local f = tbl[name]
  wraps[#wraps + 1] = { tbl, name, f }
  tbl[name] = function(...)
    if not driving or not acc then return f(...) end
    local t = hptimer()
    local a, b, c, d = f(...)
    local ms = t:stop()
    acc.parts[label] = (acc.parts[label] or 0) + ms
    acc.parts['#' .. label] = (acc.parts['#' .. label] or 0) + 1
    return a, b, c, d
  end
end
function M.unwrap()
  for i = #wraps, 1, -1 do local w = wraps[i]; w[1][w[2]] = w[3] end
  wraps = {}
end
function M.start(deep)
  acc = { n = 0, parts = {}, eng = {} }
  M.unwrap()
  if deep then
    local P, tm, fm = deepnode_main.private, extensions.deepnode_tileMesh, extensions.deepnode_farMesh
    wrap(tm, 'buildTile', 'buildTile')
    wrap(tm, 'present', 'present')
    wrap(tm, 'canUpload', 'canUpload')
    wrap(tm, 'emitTileCells', 'emitCells')
    wrap(tm, 'emitTilePixels', 'emitPixels')
    wrap(extensions.deepnode_decals, 'overlay', 'decOverlay')
    wrap(extensions.deepnode_wheelMud, 'update', 'wmUpdate')
    wrap(extensions.deepnode_wheelMud, 'preRender', 'wmPre')
    wrap(P, 'borderRule', 'borderRule')
    wrap(P, 'dirtyHidden', 'dirtyHidden')
    wrap(P, 'tileMinDist2', 'tileMinDist2')
    wrap(P, 'camDist2', 'camDist2')
    wrap(P, 'markNeighboursDirty', 'markNb')
    wrap(P, 'tileInView', 'tileInView')
    wrap(P, 'updateViewCone', 'viewCone')
    wrap(fm, 'markDirty', 'fmMarkDirty')
    wrap(deepnode_main, 'onMudReport', 'report')
    wrap(P, 'stampWheel', 'stampWheel')
    wrap(P, 'slump', 'slump')
    wrap(P, 'stampBody', 'stampBody')
  end
end
function M.result()
  if not acc or acc.n == 0 then return 'none' end
  local t = {}
  for k, v in pairs(acc.parts) do
    if k:sub(1, 1) == '#' then t[#t + 1] = { k, v / acc.n, true } else t[#t + 1] = { k, v / acc.n } end
  end
  table.sort(t, function(a, b) return a[2] > b[2] end)
  local s = { string.format('frames %d', acc.n) }
  for _, e in ipairs(t) do if e[2] >= 0.01 then s[#s + 1] = string.format(e[3] and '%s %.2f/f' or '%s %.2f', e[1], e[2]) end end
  local e = {}
  for k, v in pairs(acc.eng) do e[#e + 1] = { k, v / acc.n } end
  table.sort(e, function(a, b) return a[2] > b[2] end)
  local s2 = {}
  for i = 1, math.min(8, #e) do s2[#s2 + 1] = string.format('%s %.2f', e[i][1], e[i][2]) end
  return table.concat(s, ' | ') .. '\nENG ' .. table.concat(s2, ' | ')
end
function M.onUpdate()
  if not acc or not deepnode_main or not dntestRun then return end
  local r = dntestRun.result and dntestRun.result()
  driving = r and r.step == 'drive'
  if not driving then return end
  acc.n = acc.n + 1
  for k, e in pairs(deepnode_main.timings or {}) do acc.parts[k] = (acc.parts[k] or 0) + (e.last or 0) end
  acc.parts._frame = (acc.parts._frame or 0) + (deepnode_main.private.stats.lastFrameMs or 0)
  Engine.Debug.getLastPerformanceMetrics(tmp)
  for _, k in ipairs({ 'Lua', 'LuaPre', 'RenderShadows', 'Render', 'RenderReflections', 'PhysicsNodes', 'PhysicsAndVLUA', 'FPSLimiter', 'Pool', 'LuaGC' }) do
    acc.eng[k] = (acc.eng[k] or 0) + (tmp[k] or 0)
  end
end
return M
