-- dnSink: one-truck sink probe (not part of the mod).
-- dnSink.start{speed=5.5, stopY=-320, park=12, x=-320, y=-268}: teleport the player truck north of the
-- gridmap_v2 mud pit facing -y, drive at speed (m/s), stop at stopY, park `park` s.
-- Samples every 0.1 s: speed, sink below undisturbed surface, tyre below drawn rut, below terrain.
-- dnSink.result() -> table; dnSink.profile() -> drawn rut depth along the track.
local M = {}
local S = nil
local rep = {} -- vid -> last wheel array

local function wrap()
  local dm = deepnode_main
  if not dm then return end
  local orig = dm._dnSinkOrig or dm.onMudReport
  dm._dnSinkOrig = orig
  dm.onMudReport = function(vid, w, n, t)
    rep[vid] = w
    return orig(vid, w, n, t)
  end
  dm._dnSinkWrapped = true
end

local function input(veh, thr, brake, park)
  veh:queueLuaCommand(string.format('input.event("steering",0,1) input.event("throttle",%.3f,1) input.event("brake",%.3f,1) input.event("parkingbrake",%d,1)', thr, brake, park and 1 or 0))
end

function M.start(o)
  o = o or {}
  wrap()
  local veh = be:getPlayerVehicle(0)
  S = { o = o, speed = o.speed or 5.5, stopY = o.stopY or -320, park = o.park or 12, t = 0, phase = 'wait',
    rows = {}, vid = veh:getID(), trackX = {}, ystart = o.y or -268 }
  local rot = quatFromDir(vec3(0, -1, 0), vec3(0, 0, 1))
  map.safeTeleport(S.vid, o.x or -320, S.ystart, 101, rot.x, rot.y, rot.z, rot.w, nil, nil, nil, true, true)
  veh:queueLuaCommand('ai.setMode("disabled")')
  veh:queueLuaCommand('if controller.mainController.setGearboxMode then controller.mainController.setGearboxMode("arcade") end')
  if o.mode then veh:queueLuaCommand(o.mode) end
  if o.clear ~= false and deepnode_main.clearRuts then deepnode_main.clearRuts() end
  return 'ok'
end

local function sample(veh)
  local P = deepnode_main.private
  local w = rep[S.vid]
  local ter = scenetree.findClassObjects('TerrainBlock')
  local tb = ter and scenetree.findObject(ter[1])
  local n, sRest, sDraw, sTer, nr = 0, 0, 0, 0, 0
  local per = {}
  if w then
    local STR = P.REPORT_STRIDE
    for k = 1, #w - STR + 1, STR do
      local px, py, pz, R = w[k + 1], w[k + 2], w[k + 3], w[k + 10]
      local bot = pz - R
      local rest = P.restAt(px, py)
      local g = deepnode_main.groundAt(px, py)
      local th = tb and tb:getHeight(vec3(px, py, 0))
      if rest then
        n = n + 1
        sRest = sRest + (rest - bot)
        sDraw = sDraw + (g - bot)
        sTer = sTer + (th - bot)
        per[#per + 1] = string.format('%.3f', rest - bot)
      end
      S.trackX[w[k]] = px
      if k == 1 then
        local d = castRayStatic(vec3(px, py, pz), vec3(0, 0, -1), 3)
        S.ray = d and (pz - d) - (th or 0) or nil
        S.hub1 = pz
      end
    end
  end
  local v = veh:getVelocity():length()
  local p = veh:getPosition()
  S.rows[#S.rows + 1] = { t = S.t, ph = S.phase, v = v, y = p.y,
    sink = n > 0 and sRest / n or nil, belowDrawn = n > 0 and sDraw / n or nil,
    belowTer = n > 0 and sTer / n or nil, ray = S.ray, hub = S.hub1, vz = p.z, per = table.concat(per, ' ') }
end

function M.onUpdate(dtReal, dtSim)
  if not S or S.phase == 'done' then return end
  local veh = getObjectByID(S.vid)
  if not veh then return end
  S.t = S.t + dtSim
  S.acc = (S.acc or 0) + dtSim
  if S.phase == 'wait' then
    input(veh, 0, 0, true)
    if S.t > 2 then S.phase = 'drive' end
  elseif S.phase == 'drive' then
    local v = veh:getVelocity():length()
    local thr = math.max(0, math.min(1, 0.3 + (S.speed - v) * 0.4))
    input(veh, thr, 0, false)
    if veh:getPosition().y < S.stopY then S.phase = 'brake'; S.t0 = S.t end
    if S.t > 60 then S.phase = 'done' end
  elseif S.phase == 'brake' then
    local v = veh:getVelocity():length()
    if v > 0.5 then input(veh, 0, 1, false) else input(veh, 0, 0, true); S.phase = 'park'; S.tp = S.t end
  elseif S.phase == 'park' then
    input(veh, 0, 0, true)
    if S.t - S.tp > S.park then S.phase = 'done' end
  end
  if S.acc >= 0.1 then S.acc = 0; sample(veh) end
end

function M.result(every)
  if not S then return 'none' end
  local out = { 'phase ' .. S.phase }
  every = every or 5
  for i, r in ipairs(S.rows) do
    if i % every == 0 or (S.rows[i - 1] and S.rows[i - 1].ph ~= r.ph) then
      out[#out + 1] = string.format('%5.1f %-5s v%4.1f y%7.1f sink %s drawn %s ter %s | %s', r.t, r.ph, r.v, r.y,
        r.sink and string.format('%.3f', r.sink) or '-', r.belowDrawn and string.format('%.3f', r.belowDrawn) or '-',
        r.belowTer and string.format('%.3f', r.belowTer) or '-', r.per) .. string.format(' ray-ter %s hub %.3f vz %.3f', r.ray and string.format('%.3f', r.ray) or '-', r.hub or 0, r.vz or 0)
    end
  end
  return table.concat(out, '\n')
end

-- drawn rut depth (rest - surface) along y under each wheel x seen (unique x within 5 cm)
function M.profile(y0, y1, step)
  local P = deepnode_main.private
  local xs = {}
  for _, x in pairs(S.trackX) do
    local dup = false
    for _, e in ipairs(xs) do if math.abs(e - x) < 0.1 then dup = true end end
    if not dup then xs[#xs + 1] = x end
  end
  table.sort(xs)
  local out = {}
  for y = y0 or -275, y1 or -318, -(step or 2) do
    local parts = { string.format('y%6.1f', y) }
    for _, x in ipairs(xs) do
      local r, g = P.restAt(x, y), deepnode_main.groundAt(x, y)
      parts[#parts + 1] = r and string.format('%.3f', r - g) or '-'
    end
    out[#out + 1] = table.concat(parts, ' ')
  end
  return table.concat(out, '\n')
end

-- watch castRayStatic at (x, y) every frame for n frames after clearing the ruts
function M.rayWatch(x, y, n)
  local tb = scenetree.findObject(scenetree.findClassObjects('TerrainBlock')[1])
  M.RW = { x = x, y = y, n = n or 120, rows = {}, tb = tb, f = 0 }
  if deepnode_main.clearRuts then deepnode_main.clearRuts() end
  return 'ok'
end
local oldU = M.onUpdate
function M.onUpdate(a, b)
  oldU(a, b)
  local R = M.RW
  if R and R.f < R.n then
    R.f = R.f + 1
    local th = R.tb:getHeight(vec3(R.x, R.y, 0))
    local d = castRayStatic(vec3(R.x, R.y, th + 2), vec3(0, 0, -1), 5)
    local g = deepnode_main.groundAt(R.x, R.y)
    R.rows[#R.rows + 1] = string.format('%d %.2f ter %.3f ray %.3f drawn %.3f', R.f, os.clock(), th, d and th + 2 - d or -1, g or -1)
  end
end
function M.rayResult() return M.RW and table.concat(M.RW.rows, string.char(10)) end
-- terrain update latency: lower 7x11 squares round the parked player truck by dz, one
-- updateGrid (box mode 'real' or 'dummy'), then log vehicle z every frame
function M.latency(dz, mode, n)
  local tb = scenetree.findObject(scenetree.findClassObjects('TerrainBlock')[1])
  local veh = be:getPlayerVehicle(0)
  local p = veh:getPosition()
  local sq, tp = tb:getSquareSize(), tb:getPosition()
  local gx0, gy0 = math.floor((p.x - tp.x) / sq) - 3, math.floor((p.y - tp.y) / sq) - 5
  for gx = gx0, gx0 + 6 do for gy = gy0, gy0 + 10 do
    tb:setHeightGrid(gx, gy, tb:getHeightGrid(gx, gy) - dz)
  end end
  if mode == 'dummy' then tb:updateGrid(vec3(1, 1, 0), vec3(2, 2, 0)) else tb:updateGrid(vec3(gx0, gy0, 0), vec3(gx0 + 6, gy0 + 10, 0)) end
  M.LT = { n = n or 90, f = 0, t0 = os.clock(), z0 = p.z, rows = {}, veh = veh }
  return 'ok'
end
local oldU2 = M.onUpdate
function M.onUpdate(a, b)
  oldU2(a, b)
  local L = M.LT
  if L and L.f < L.n then
    L.f = L.f + 1
    L.rows[#L.rows + 1] = string.format('%d %.3f %.3f', L.f, os.clock() - L.t0, L.veh:getPosition().z - L.z0)
  end
end
function M.latResult() return M.LT and table.concat(M.LT.rows, string.char(10)) end
-- repeated updates: every `every` frames for `frames` frames lower by dz and updateGrid
function M.latency2(dz, every, frames, n)
  local tb = scenetree.findObject(scenetree.findClassObjects('TerrainBlock')[1])
  local veh = be:getPlayerVehicle(0)
  local p = veh:getPosition()
  local sq, tp = tb:getSquareSize(), tb:getPosition()
  M.L2 = { tb = tb, gx0 = math.floor((p.x - tp.x) / sq) - 3, gy0 = math.floor((p.y - tp.y) / sq) - 5,
    dz = dz, every = every, frames = frames, f = 0 }
  M.LT = { n = n or 240, f = 0, t0 = os.clock(), z0 = p.z, rows = {}, veh = veh }
  return 'ok'
end
local oldU3 = M.onUpdate
function M.onUpdate(a, b)
  local L = M.L2
  if L and L.f < L.frames then
    L.f = L.f + 1
    if L.f % L.every == 0 then
      for gx = L.gx0, L.gx0 + 6 do for gy = L.gy0, L.gy0 + 10 do
        L.tb:setHeightGrid(gx, gy, L.tb:getHeightGrid(gx, gy) - L.dz)
      end end
      L.tb:updateGrid(vec3(L.gx0, L.gy0, 0), vec3(L.gx0 + 6, L.gy0 + 10, 0))
    end
  end
  oldU3(a, b)
end
-- per-frame sum of deepnode_main.timings[*].last (each section's time in the frame before)
function M.timeWatch(on)
  M.TW = on and { n = 0, sum = {} } or M.TW
  if not on and M.TW then
    local out = { 'frames ' .. M.TW.n }
    local ks = {}
    for k in pairs(M.TW.sum) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return M.TW.sum[a] > M.TW.sum[b] end)
    for _, k in ipairs(ks) do out[#out + 1] = string.format('%s %.3f', k, M.TW.sum[k] / math.max(1, M.TW.n)) end
    M.TW.stop = true
    return table.concat(out, ' | ')
  end
  return 'ok'
end
local oldU4 = M.onUpdate
function M.onUpdate(a, b)
  oldU4(a, b)
  local W = M.TW
  if W and not W.stop and deepnode_main and deepnode_main.timings then
    W.n = W.n + 1
    for k, e in pairs(deepnode_main.timings) do W.sum[k] = (W.sum[k] or 0) + (e.last or 0) end
  end
end
return M
