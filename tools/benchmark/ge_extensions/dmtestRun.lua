-- dmtestRun: deepmud benchmark helper (not part of the mod).
-- Every vehicle drives straight ahead from its spawn (captured once) at a set speed through
-- the pits, then all are reset to the spawn. Frame times are logged while driving.
-- dmtestRun.capture() / dmtestRun.start{runs=3, speed=13.41, dist=125, timeout=30}
-- dmtestRun.result() / dmtestRun.stop()
local M = {}
local FILE = '/settings/deepmud/bench_spawn.json'
local S = nil
local spawn = nil

local function mem()
  local m = Engine.Platform.getMemoryInfo()
  return m.processVirtUsed / 1048576, m.processPhysUsed / 1048576
end

function M.capture()
  local list = {}
  for i = 0, be:getObjectCount() - 1 do
    local v = be:getObject(i)
    local p, r, d = v:getPosition(), quat(v:getRotation()), v:getDirectionVector()
    list[#list + 1] = { id = v:getID(), p = { p.x, p.y, p.z }, r = { r.x, r.y, r.z, r.w }, d = { d.x, d.y } }
  end
  jsonWriteFile(FILE, { list = list }, true)
  spawn = list
  return #list
end

local function load()
  if spawn then return spawn end
  local d = jsonReadFile(FILE)
  spawn = d and d.list
  return spawn
end

local function input(veh, steer, thr, brake, park)
  veh:queueLuaCommand(string.format('input.event("steering",%.3f,1) input.event("throttle",%.3f,1) input.event("brake",%.3f,1) input.event("parkingbrake",%d,1)', steer, thr, brake, park and 1 or 0))
end
-- stop without reversing (arcade gearbox: brake held at standstill drives backwards)
local function halt(veh)
  local spd = veh:getVelocity():length()
  if spd > 1 then input(veh, 0, 0, 1) else input(veh, 0, 0, 0, true) end
end

local function resetAll()
  for _, e in ipairs(load() or {}) do
    local v = getObjectByID(e.id)
    if v then
      -- rotation from the captured heading (object rotation can be stale; dir = q * (0,-1))
      local th = -math.atan2(e.d[1], -e.d[2])
      v:setPositionRotation(e.p[1], e.p[2], e.p[3], 0, 0, math.sin(th / 2), math.cos(th / 2))
      v:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
      v:queueLuaCommand('ai.setMode("disabled")')
    end
  end
end

function M.start(o)
  o = o or {}
  if not load() then return 'no spawn captured' end
  S = { runs = o.runs or 3, speed = o.speed or 13.41, dist = o.dist or 125, timeout = o.timeout or 30,
    settle = o.settle or 3, run = 0, step = 'reset', t = 0, out = {}, label = o.label or '', clear = o.clear }
  return 'ok'
end

function M.stop()
  if S then
    for _, e in ipairs(load() or {}) do
      local v = getObjectByID(e.id)
      if v then input(v, 0, 0, 0, true) end
    end
  end
  S = nil
end

local function summary(R)
  local n = #R.dts
  if n == 0 then return end
  table.sort(R.dts)
  local sum = 0
  for i = 1, n do sum = sum + R.dts[i] end
  local p99 = R.dts[math.max(1, math.floor(n * 0.99))]
  local p95 = R.dts[math.max(1, math.floor(n * 0.95))]
  R.fps = n / sum
  R.low1 = 1 / p99
  R.low5 = 1 / p95
  R.minFps = 1 / R.dts[n]
  R.frames = n
  R.dts = nil
end

local function onUpdate(dtReal, dtSim)
  if not S then return end
  S.t = S.t + dtReal
  local list = load()
  if S.step == 'reset' then
    if not S.didReset then
      S.didReset = true; resetAll()
      if S.clear and deepmud_main and deepmud_main.isRunning() then deepmud_main.clearRuts() end
    end
    if S.t >= S.settle then
      S.run = S.run + 1
      local c, p = mem()
      S.cur = { run = S.run, dts = {}, c0 = c, p0 = p, t = 0, maxSpeed = 0, done = 0 }
      S.step, S.t, S.didReset = 'drive', 0, false
      if deepmud_main and deepmud_main.isRunning() and deepmud_main.perf then
        local pf = deepmud_main.perf()
        S.cur.ups0 = pf and pf.uploads
      end
    end
    return
  end
  if S.step == 'drive' then
    local R = S.cur
    R.dts[#R.dts + 1] = dtReal
    local done = 0
    local speeds = {}
    for _, e in ipairs(list) do
      local v = getObjectByID(e.id)
      if v then
        local p = v:getPosition()
        local f = v:getDirectionVector()
        local dx, dy = e.d[1], e.d[2]
        local along = (p.x - e.p[1]) * dx + (p.y - e.p[2]) * dy
        local side = (p.x - e.p[1]) * (-dy) + (p.y - e.p[2]) * dx
        local spd = v:getVelocity():length()
        speeds[#speeds + 1] = spd
        if along >= S.dist then
          done = done + 1
          halt(v)
        else
          -- aim 12 m ahead on the spawn line
          local tx, ty = dx * 12 - (-dy) * side, dy * 12 - dx * side
          local cross = f.x * ty - f.y * tx
          local dot = f.x * tx + f.y * ty
          local steer = math.max(-1, math.min(1, -math.atan2(cross, dot) * 2))
          local err = S.speed - spd
          local thr = math.max(0, math.min(1, 0.35 + err * 0.4))
          local brk = err < -1.5 and math.min(1, -err * 0.2) or 0
          if brk > 0 then thr = 0 end
          input(v, steer, thr, brk)
        end
        if spd > R.maxSpeed then R.maxSpeed = spd end
      end
    end
    R.t = R.t + dtReal
    if done >= #list or R.t >= S.timeout then
      R.done = done
      R.along = {}
      for _, e in ipairs(list) do
        local v = getObjectByID(e.id)
        if v then
          local p = v:getPosition()
          R.along[#R.along + 1] = math.floor(((p.x - e.p[1]) * e.d[1] + (p.y - e.p[2]) * e.d[2]) * 10) / 10
        end
      end
      R.avgEndSpeed = 0
      for _, s in ipairs(speeds) do R.avgEndSpeed = R.avgEndSpeed + s / #speeds end
      local c, p = mem()
      R.dCommit, R.dPhys = c - R.c0, p - R.p0
      R.c0, R.p0 = nil, nil
      summary(R)
      if deepmud_main and deepmud_main.isRunning() and deepmud_main.perf then
        local pf = deepmud_main.perf()
        R.modMs = pf and pf.frameAvg
      end
      S.out[#S.out + 1] = R
      S.cur = nil
      S.step, S.t = 'brake', 0
    end
    return
  end
  if S.step == 'brake' then
    for _, e in ipairs(list) do
      local v = getObjectByID(e.id)
      if v then halt(v) end
    end
    if S.t >= 1.5 then
      for _, e in ipairs(list) do
        local v = getObjectByID(e.id)
        if v then input(v, 0, 0, 0, true) end
      end
      if S.run >= S.runs then
        S.step = 'finished'
        local c = mem()
        S.commitEnd = c
      else
        S.step, S.t = 'reset', 0
      end
    end
  end
end

function M.result()
  if not S then return nil end
  return { step = S.step, run = S.run, out = S.out, label = S.label }
end

M.onUpdate = onUpdate
return M
