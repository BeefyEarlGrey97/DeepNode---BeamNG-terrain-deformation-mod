-- dmtestCircles: deepmud stress-test helper (not part of the mod).
-- Every vehicle drives its OWN circle (pure pursuit on the circle + speed hold).
-- dmtestCircles.start({ R = 100, kph = 40, cars = { { vid = 1, cx = 0, cy = 0 }, ... } })
-- dmtestCircles.place()  teleports each car onto its circle, heading clockwise
-- dmtestCircles.stop() / dmtestCircles.state()
local M = {}
local S = nil

local function vehicleInput(veh, steer, thr, brake)
  veh:queueLuaCommand(string.format('input.event("steering",%.3f,1) input.event("throttle",%.3f,1) input.event("brake",%.3f,1) input.event("parkingbrake",0,1)', steer, thr, brake))
end

local function placeCar(c, a)
  local veh = getObjectByID(c.vid)
  if not veh then return end
  a = a or c.a0 or 0
  local x, y = c.cx + S.R * math.cos(a), c.cy + S.R * math.sin(a)
  local z = core_terrain.getTerrainHeight(vec3(x, y, 0)) + 0.6
  -- clockwise: tangent = (sin a, -cos a)
  local dir = vec3(math.sin(a), -math.cos(a), 0)
  local rot = quat(0, 0, 1, 0) * quatFromDir(dir, vec3(0, 0, 1))
  spawn.safeTeleport(veh, vec3(x, y, z), rot, true, nil, false, nil, true)
  c.stuckT, c.lastPlace = 0, os.clock()
end

function M.start(spec)
  S = { R = spec.R or 100, v = (spec.kph or 40) / 3.6, cars = {}, t = 0, recover = 0, resetEvery = spec.resetEvery }
  for i, c in ipairs(spec.cars) do
    S.cars[i] = { vid = c.vid, cx = c.cx, cy = c.cy, a0 = c.a0 or 0, stuckT = 0, laps = 0, dist = 0,
      vSum = 0, vN = 0, errMax = 0, recovers = 0 }
    local veh = getObjectByID(c.vid)
    if veh then veh:queueLuaCommand('ai.setMode("disabled")') end
  end
  return #S.cars
end

function M.place()
  if not S then return 'no test' end
  for _, c in ipairs(S.cars) do placeCar(c) end
  return 'placed'
end

function M.stop()
  if S then
    for _, c in ipairs(S.cars) do
      local veh = getObjectByID(c.vid)
      if veh then vehicleInput(veh, 0, 0, 1) end
    end
  end
  S = nil
end

-- speed / radius stats since the last reset
function M.state(reset)
  if not S then return nil end
  local out = { recover = S.recover, cars = {} }
  for i, c in ipairs(S.cars) do
    out.cars[i] = { vid = c.vid, v = c.v, vAvg = c.vN > 0 and c.vSum / c.vN or 0, rad = c.rad, errMax = c.errMax,
      dist = c.dist, recovers = c.recovers }
    if reset then c.vSum, c.vN, c.errMax, c.dist = 0, 0, 0, 0 end
  end
  return out
end

local function onUpdate(dtReal, dtSim)
  if not S then return end
  local dt = dtSim or dtReal or 0
  -- full reset of every car each resetEvery s (user rule: 4 min)
  S.resetT = (S.resetT or 0) + (dtReal or 0)
  if S.resetEvery and S.resetT >= S.resetEvery then
    S.resetT = 0
    S.resets = (S.resets or 0) + 1
    for _, c in ipairs(S.cars) do placeCar(c) end
  end
  for _, c in ipairs(S.cars) do
    local veh = getObjectByID(c.vid)
    if veh then
      local p = veh:getPosition()
      local f = veh:getDirectionVector()
      local rx, ry = p.x - c.cx, p.y - c.cy
      local rl = math.sqrt(rx * rx + ry * ry)
      if rl > 1 then
        -- look-ahead point on the circle, clockwise (angle decreasing)
        local a = math.atan2(ry, rx) - 14 / S.R
        local tx, ty = c.cx + S.R * math.cos(a) - p.x, c.cy + S.R * math.sin(a) - p.y
        local cross = f.x * ty - f.y * tx
        local dot = f.x * tx + f.y * ty
        local err = math.atan2(cross, dot) -- > 0: target on the left
        local steer = math.max(-1, math.min(1, -err * 2.2))
        local v = veh:getVelocity():length()
        c.iv = math.max(-0.3, math.min(0.4, (c.iv or 0) + (S.v - v) * 0.05 * dt))
        local thr = math.max(0, math.min(1, 0.45 + (S.v - v) * 0.3 + c.iv))
        local brake = v > S.v + 1.5 and math.min(0.5, (v - S.v - 1.5) * 0.2) or 0
        vehicleInput(veh, steer, thr, brake)
        c.v, c.rad = v, rl
        if v < 40 then -- teleport frames report huge speeds
          c.vSum, c.vN = c.vSum + v, c.vN + 1
          c.dist = c.dist + v * dt
        end
        local re = math.abs(rl - S.R)
        if re > c.errMax then c.errMax = re end
        -- stuck or off the circle: put it back where it is on the circle
        if v < 1.5 and os.clock() - (c.lastPlace or 0) > 10 then c.stuckT = c.stuckT + dt else c.stuckT = 0 end
        local up = veh:getDirectionVectorUp()
        if c.stuckT > 6 or re > 25 or (up and up.z < 0.3 and os.clock() - (c.lastPlace or 0) > 5) then
          c.recovers = c.recovers + 1
          S.recover = S.recover + 1
          placeCar(c, math.atan2(ry, rx) - 0.2)
        end
      end
    end
  end
end

M.onUpdate = onUpdate
return M
