-- deepnode_vehicle (vehicle Lua VM)
-- Wheel/body reports and the vehicle's ground footprint (bounding box) to GE.
-- Physics is BeamNG's own: the mod applies no forces, except the heavy-physics rut guide
-- (physics.heavy.rutGuide, setGuide below: the lateral push of rut walls on the hubs).
-- The vehicle drives on the lowered terrain (the hard floor) and the mud surface is
-- drawn above it.
--
-- Engine API used (confirmed in the shipped 0.39 vehicle Lua):
--  * obj:getPosition() + obj:getNodePosition(cid) = world node position
--      lua/vehicle/extensions/tech/wheelForces.lua:233
--  * obj:getNodeVelocityVector(cid) world velocity, obj:getNodeMass(cid), obj:getID(),
--    obj:getDirectionVector(), obj:queueGameEngineLua(str)
--  * obj:getNodeCluster(cid): id of the rigid cluster a node belongs to; the cluster of
--    v.data.refNodes[0].ref is the main body, parts that broke loose get their own
--      lua/vehicle/bdebugImpl.lua:1177 ("mainCluster" debug mode)
--  * extension hook onBeamBroke(id, energy)              lua/vehicle/main.lua:366-374
--  * obj:inWater(cid) node under the water surface      lua/vehicle/wheels.lua:247, sounds.lua:434
--  * wheels.wheels[0..] (node1, node2, radius, tireWidth, wheelID, angularVelocity,
--    wheelSpeed, isBroken), v.data.wheels[id].treadNodes, v.data.nodes[cid] (cid, pos, wheelID)
--      lua/vehicle/wheels.lua:1179-1260, wheelForces.lua:243-365
--  * v.data.flexbodies[k].mesh / .pos (tyre meshes of a dual wheel sit side by side)
--  * vehicle extension hooks onReset / updateGFX       lua/vehicle/main.lua:441, :92

local M = {}

local floor, min, max, abs, sqrt = math.floor, math.min, math.max, math.abs, math.sqrt
local huge = math.huge
local sfmt = string.format

local ter = nil
local REP = nil
local DU = nil
local configured = false
local vid = -1

local tiles = {}
local tileCount = 0
local wheelList = {}
local hubSet = {}
local bodyNodes = {}
local cands, ncand = {}, 0
local found, foundS = {}, {}
local vehMass, wheelLoad = 0, 1000
local accCand, accReport, accWater, accStats, accBox = 0, 0, 0, 0, 0
-- LOD: 1 = full rates (vehicles in an active ring), 2+ = divided rates (far vehicles)
local lod = 1

-- Footprint: an oriented box round the main body. Parts that broke loose (their own node
-- cluster) are left out, so a wheel or bumper lying 20 m away does not stretch the box.
-- hullNodes: the main-body nodes that can be extreme in the ground plane (picked once per
-- cluster change from the jbeam positions), so the box costs a few hundred node reads.
local hullNodes = {}
local clustersDirty = true
local clusterAge = 0 -- s since the hull was last picked (re-picked at most every HULL_GAP s)
local HULL_GAP = 0.5
local lastBox = nil

local function isFinite(v) return type(v) == 'number' and v == v and v > -1e7 and v < 1e7 end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

-- rest-surface z and mud depth at a world point (bilinear over the tile grid), nil = no mud
local function sample(x, y)
  if tileCount == 0 then return nil end
  local fx, fy = (x - ter.ox) / ter.sq, (y - ter.oy) / ter.sq
  local gx, gy = floor(fx), floor(fy)
  local ts = ter.ts
  local tx, ty = floor(gx / ts), floor(gy / ts)
  local t = tiles[ty * ter.key + tx]
  if not t then return nil end
  local i, j = gx - tx * ts, gy - ty * ts
  local u, v = fx - gx, fy - gy
  local W = ts + 1
  local k = j * W + i + 1
  local d = t.d
  local dep = d[k] * (1 - u) * (1 - v) + d[k + 1] * u * (1 - v) + d[k + W] * (1 - u) * v + d[k + W + 1] * u * v
  if not (dep > 0.005) then return nil end
  local r = t.r
  local rest = r[k] * (1 - u) * (1 - v) + r[k + 1] * u * (1 - v) + r[k + W] * (1 - u) * v + r[k + W + 1] * u * v
  return rest, dep
end
M.sampleForTests = sample

local function nodeWorld(cid)
  local o = obj:getPosition()
  local p = obj:getNodePosition(cid)
  return o.x + p.x, o.y + p.y, o.z + p.z
end

-- jbeam-space position of a node (v.data.nodes is keyed by cid in 0.39)
local function nodeJbeamPos(cid)
  local n = v.data.nodes and v.data.nodes[cid]
  if n and n.cid == cid and n.pos then return n.pos end
  for _, m in pairs(v.data.nodes or {}) do
    if m.cid == cid then return m.pos end
  end
  return nil
end

-- Tyres of one wheel: { {o = offset along node1->node2 from the hub centre, w = width} }.
-- A dual wheel ("dually") is one physics wheel with two tyre meshes side by side: the
-- tyre flexbodies whose mesh position lies on this wheel's axle give the tyre centres.
-- Without usable flexbody positions a very wide, short wheel (width / radius above
-- dually.autoRatio) is split into two tyres with dually.gap between them.
-- Tyre meshes with a position: { p = pos, width = visual width (m) or nil }. The width
-- comes from the mesh name when it carries one (e.g. "tire_02c_315_22.5": 315 mm);
-- jbeam tireWidth is often narrower than the visible tyre.
local tyreMeshes = nil
local function meshWidth(name)
  for num in name:gmatch('%d+') do
    local n = tonumber(num)
    if #num == 3 and n and n >= 125 and n <= 455 then return n / 1000 end
  end
  return nil
end
local function collectTyreMeshes()
  tyreMeshes = {}
  for _, f in pairs(v.data.flexbodies or {}) do
    local m = tostring(f.mesh or ''):lower()
    local p = f.pos
    if p and (m:find('tire', 1, true) or m:find('tyre', 1, true)) and isFinite(p.x) and isFinite(p.y) and isFinite(p.z) then
      tyreMeshes[#tyreMeshes + 1] = { p = p, width = meshWidth(m) }
    end
  end
end

-- visual tyre width / tread node span of one tyre (tread nodes sit inside the shoulders;
-- us_semi: 0.214 m of tread nodes for a ~0.27 m tyre)
local TREAD_VIS = 1.25

-- tread node span along node1->node2, from the hub centre (jbeam positions): lo, hi or nil
local function treadSpan(w, a, b)
  if not (a and b) then return nil end
  local cx, cy, cz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
  local ax, ay, az = b.x - a.x, b.y - a.y, b.z - a.z
  local L = sqrt(ax * ax + ay * ay + az * az)
  if L < 1e-3 then return nil end
  ax, ay, az = ax / L, ay / L, az / L
  local lo, hi = math.huge, -math.huge
  for _, cid in ipairs(w.treadNodes or {}) do
    local p = nodeJbeamPos(cid)
    if p then
      local q = (p.x - cx) * ax + (p.y - cy) * ay + (p.z - cz) * az
      lo, hi = min(lo, q), max(hi, q)
    end
  end
  if not (hi - lo > 0.03 and hi - lo < 2) then return nil end
  return lo, hi
end

-- returns the tyre list; each tyre { o, w, vis = true when w is the visual width }.
-- A tyre is centred on its tread nodes, not on the hub nodes: rear hubs are often
-- off-centre (wheel offset, dual spacing).
local function tyreLayout(w)
  local a, b = nodeJbeamPos(w.n1), nodeJbeamPos(w.n2)
  local lo, hi = treadSpan(w, a, b)
  local single = { { o = lo and (lo + hi) * 0.5 or 0, w = lo and max(w.W, hi - lo) or w.W } }
  if not DU or DU.enabled == false then return single end
  if a and b and tyreMeshes then
    local cx, cy, cz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
    local ax, ay, az = b.x - a.x, b.y - a.y, b.z - a.z
    local L = sqrt(ax * ax + ay * ay + az * az)
    if L > 1e-3 then
      ax, ay, az = ax / L, ay / L, az / L
      local offs, widths = {}, {}
      for _, tmesh in ipairs(tyreMeshes) do
        local p = tmesh.p
        local rx, ry, rz = p.x - cx, p.y - cy, p.z - cz
        local q = rx * ax + ry * ay + rz * az
        local px, py, pz = rx - ax * q, ry - ay * q, rz - az * q
        if sqrt(px * px + py * py + pz * pz) < 0.35 * w.R and abs(q) < L * 0.5 + 0.2 then
          local dup = false
          for _, o in ipairs(offs) do if abs(o - q) < 0.05 then dup = true; break end end
          if not dup then offs[#offs + 1] = q; widths[q] = tmesh.width end
        end
      end
      if #offs >= 2 then
        table.sort(offs)
        offs = { offs[1], offs[#offs] }
        local span = offs[2] - offs[1]
        local named = widths[offs[1]]
        -- no width in the mesh name: from the tread nodes outside each tyre centre
        local fromTread = lo and 2 * min(offs[1] - lo, hi - offs[2]) * TREAD_VIS
        if fromTread and fromTread < 0.08 then fromTread = nil end
        local tw = clamp(min(span * 0.97, named or fromTread or w.W * 0.55), 0.08, 0.6)
        return { { o = offs[1], w = tw, vis = true }, { o = offs[2], w = tw, vis = true } }
      end
      if #offs == 1 then
        local named = widths[offs[1]]
        if named then return { { o = offs[1], w = named, vis = true } } end
        return single
      end
    end
  end
  local ratio = tonumber(DU.autoRatio) or 0
  if ratio > 0 and w.R > 0 and w.W / w.R > ratio then
    local gap = tonumber(DU.gap) or 0.04
    local tw = (w.W - gap) * 0.5
    local o = (tw + gap) * 0.5
    local oc = single[1].o
    return { { o = oc - o, w = tw }, { o = oc + o, w = tw } }
  end
  return single
end

local function collectWheels()
  wheelList = {}
  hubSet = {}
  if not wheels or not wheels.wheels then return end
  collectTyreMeshes()
  local i = 0
  while wheels.wheels[i] do
    local wd = wheels.wheels[i]
    local wdata = v.data.wheels and (v.data.wheels[wd.wheelID] or v.data.wheels[i])
    local tread = nil
    local treadList = {}
    if wdata and wdata.treadNodes then
      for _, cid in pairs(wdata.treadNodes) do
        if type(cid) == 'number' then
          treadList[#treadList + 1] = cid
          if not tread or cid < tread then tread = cid end
        end
      end
    end
    if wd.node1 and wd.node2 and tread then
      local w = { wd = wd, n1 = wd.node1, n2 = wd.node2, tread = tread,
        R = tonumber(wd.radius) or 0.3, W = tonumber(wd.tireWidth) or 0.2, treadNodes = treadList, water = 0,
        rimR = tonumber(wdata and wdata.hubRadius) or 0 }
      w.tyres = tyreLayout(w)
      wheelList[#wheelList + 1] = w
      hubSet[wd.node1], hubSet[wd.node2] = true, true
    end
    i = i + 1
  end
end

-- Chassis nodes that can carve dents: every non-wheel node with mass.
local function collectNodes()
  vehMass = 0
  bodyNodes = {}
  for _, n in pairs(v.data.nodes) do
    local cid = n.cid
    if cid then
      local m = obj:getNodeMass(cid) or 0
      vehMass = vehMass + m
      if n.pos and not n.wheelID and not hubSet[cid] and m > 0 then bodyNodes[#bodyNodes + 1] = cid end
    end
  end
  wheelLoad = vehMass * 9.81 / max(1, #wheelList)
end

-------------------------------------------------------------------------------
-- footprint box
-------------------------------------------------------------------------------
-- 16 directions in the ground plane; the BOX_PER_DIR most extreme main-body nodes along
-- each (by jbeam position) are read every box update. Deformation moves nodes by
-- centimetres to decimetres, so the extremes of the undeformed shape stay close.
local BOX_DIRS = 16
local BOX_PER_DIR = 10

local function mainCluster()
  local ref = v.data.refNodes and v.data.refNodes[0] and v.data.refNodes[0].ref
  if ref == nil or not obj.getNodeCluster then return nil end
  local ok, c = pcall(obj.getNodeCluster, obj, ref)
  if ok then return c end
  return nil
end

local function collectHull()
  hullNodes = {}
  local main = mainCluster()
  local list = {}
  for _, n in pairs(v.data.nodes) do
    local cid, p = n.cid, n.pos
    if cid and p and isFinite(p.x) and isFinite(p.y) then
      local keep = true
      if main ~= nil then
        local ok, c = pcall(obj.getNodeCluster, obj, cid)
        keep = ok and c == main
      end
      if keep then list[#list + 1] = { cid = cid, x = p.x, y = p.y } end
    end
  end
  if #list <= BOX_DIRS * BOX_PER_DIR then
    for k, e in ipairs(list) do hullNodes[k] = e.cid end
    return
  end
  -- top BOX_PER_DIR per direction by insertion into a short list (no full sorts: this
  -- runs again whenever parts break off)
  local seen = {}
  local topS, topC = {}, {}
  for d = 0, BOX_DIRS - 1 do
    local a = d / BOX_DIRS * 2 * math.pi
    local ca, sa = math.cos(a), math.sin(a)
    local n = 0
    for _, e in ipairs(list) do
      local s = e.x * ca + e.y * sa
      if n < BOX_PER_DIR or s > topS[n] then
        local k = n < BOX_PER_DIR and n + 1 or n
        while k > 1 and topS[k - 1] < s do
          topS[k], topC[k] = topS[k - 1], topC[k - 1]
          k = k - 1
        end
        topS[k], topC[k] = s, e.cid
        if n < BOX_PER_DIR then n = n + 1 end
      end
    end
    for k = 1, n do
      local cid = topC[k]
      if not seen[cid] then seen[cid] = true; hullNodes[#hullNodes + 1] = cid end
    end
  end
end

-- The box in the ground plane, aligned with the vehicle's heading: centre, forward unit
-- vector, half length, half width. nil when no node gives a valid position.
local function computeBox()
  if clustersDirty and (clusterAge >= HULL_GAP or #hullNodes == 0) then
    clustersDirty = false
    clusterAge = 0
    collectHull()
  end
  if #hullNodes == 0 then return nil end
  local op = obj:getPosition()
  local d = obj:getDirectionVector()
  local fx, fy = d.x, d.y
  local fl = sqrt(fx * fx + fy * fy)
  if not (fl > 1e-3) then fx, fy = 1, 0 else fx, fy = fx / fl, fy / fl end
  local rx, ry = -fy, fx
  local f0, f1, r0, r1 = huge, -huge, huge, -huge
  local n = 0
  for k = 1, #hullNodes do
    local p = obj:getNodePosition(hullNodes[k])
    local x, y = p.x, p.y
    if isFinite(x) and isFinite(y) then
      local f = x * fx + y * fy
      local r = x * rx + y * ry
      if f < f0 then f0 = f end
      if f > f1 then f1 = f end
      if r < r0 then r0 = r end
      if r > r1 then r1 = r end
      n = n + 1
    end
  end
  if n == 0 then return nil end
  local fc, rc = (f0 + f1) * 0.5, (r0 + r1) * 0.5
  local cx, cy = op.x + fx * fc + rx * rc, op.y + fy * fc + ry * rc
  local hl, hw = (f1 - f0) * 0.5, (r1 - r0) * 0.5
  -- a vehicle torn into a 300 m long "body" is broken: never send that
  if not (isFinite(cx) and isFinite(cy) and hl < 60 and hw < 60) then return nil end
  return cx, cy, fx, fy, hl, hw, op.x, op.y
end

local function sendBox(force)
  local cx, cy, fx, fy, hl, hw, px, py = computeBox()
  if not cx then return end
  local b = lastBox
  if b and not force and abs(b[1] - cx) < 0.05 and abs(b[2] - cy) < 0.05 and abs(b[3] - fx) < 0.01
    and abs(b[4] - fy) < 0.01 and abs(b[5] - hl) < 0.05 and abs(b[6] - hw) < 0.05 then
    return
  end
  lastBox = { cx, cy, fx, fy, hl, hw }
  -- with the vehicle position it was measured at: GE moves the box with the vehicle
  obj:queueGameEngineLua(sfmt('if deepnode_main then deepnode_main.onVehicleBox(%d,%.3f,%.3f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f) end',
    vid, cx, cy, fx, fy, hl, hw, px, py))
end

-------------------------------------------------------------------------------
-- wheels
-------------------------------------------------------------------------------
local function measureWheel(w)
  local ax, ay, az = nodeWorld(w.n1)
  local bx, by, bz = nodeWorld(w.n2)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  if not (l > 1e-4) then return w.R, w.W end
  dx, dy, dz = dx / l, dy / l, dz / l
  local tx, ty, tz = nodeWorld(w.tread)
  local rx, ry, rz = tx - ax, ty - ay, tz - az
  local p = rx * dx + ry * dy + rz * dz
  rx, ry, rz = rx - dx * p, ry - dy * p, rz - dz * p
  local r = sqrt(rx * rx + ry * ry + rz * rz)
  if not (r > 0.05 and r < 3) then r = w.R end
  local width = w.W
  if not (width > 0.05) then
    local lo, hi = math.huge, -math.huge
    for _, cid in ipairs(w.treadNodes or {}) do
      local x, y, z = nodeWorld(cid)
      local q = (x - ax) * dx + (y - ay) * dy + (z - az) * dz
      lo, hi = min(lo, q), max(hi, q)
    end
    width = (hi > lo) and (hi - lo) or 0.2
  end
  return r, width
end

-- wheel definitions to GE: array order index (pitfall 5), hub nodes, tread node, radius,
-- width, tyre count and up to two tyres (offset along node1->node2, width), rim radius
-- (jbeam hubRadius, 0 = unknown), 1 when the tyre widths are the visual widths
local function sendWheelDefs()
  local parts = {}
  for i, w in ipairs(wheelList) do
    local r, width = measureWheel(w)
    if isFinite(r) and isFinite(width) then
      local t1, t2 = w.tyres[1], w.tyres[2] or w.tyres[1]
      local rim = isFinite(w.rimR) and w.rimR or 0
      parts[#parts + 1] = sfmt('%d,%d,%d,%d,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%d', i, w.n1, w.n2, w.tread, r, width,
        #w.tyres, t1.o, t1.w, t2.o, t2.w, rim, t1.vis and 1 or 0)
    end
  end
  obj:queueGameEngineLua(sfmt('if deepnode_main then deepnode_main.onWheelDefs(%d,{%s}) end', vid, table.concat(parts, ',')))
end

-- wheel state for the reports; returns nil when not in mud
local function wheelState(w, op, vdx, vdy)
  local wd = w.wd
  if wd.isBroken then return nil end
  local p1 = obj:getNodePosition(w.n1)
  local p2 = obj:getNodePosition(w.n2)
  local hx, hy, hz = op.x + (p1.x + p2.x) * 0.5, op.y + (p1.y + p2.y) * 0.5, op.z + (p1.z + p2.z) * 0.5
  if not (isFinite(hx) and isFinite(hy) and isFinite(hz)) then return nil end
  local rest = sample(hx, hy)
  if not rest then return nil end
  local imm = rest - (hz - w.R)
  if not (imm > 0) then return nil end
  local ax, ay, az = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
  local al = sqrt(ax * ax + ay * ay + az * az)
  if not (al > 1e-4) then return nil end
  ax, ay, az = ax / al, ay / al, az / al
  local ah = sqrt(ax * ax + ay * ay)
  local ahx, ahy = 1, 0
  if ah > 1e-3 then ahx, ahy = ax / ah, ay / ah end
  local fx, fy = -ahy, ahx
  if fx * vdx + fy * vdy < 0 then fx, fy = -fx, -fy end
  local v1 = obj:getNodeVelocityVector(w.n1)
  local v2 = obj:getNodeVelocityVector(w.n2)
  local vx, vy, vz = (v1.x + v2.x) * 0.5, (v1.y + v2.y) * 0.5, (v1.z + v2.z) * 0.5
  if not (isFinite(vx) and isFinite(vy) and isFinite(vz)) then return nil end
  return hx, hy, hz, imm, ax, ay, az, ahx, ahy, fx, fy, vx, vy, vz
end

-- low-rate refresh of chassis nodes that may touch the mud (no tables made per call)
local function refreshCandidates()
  ncand = 0
  if tileCount == 0 then
    for k = 1, #cands do cands[k] = nil end
    return
  end
  local margin = REP.candidateMargin or 0.15
  local cap = REP.maxCandidates or 48
  local op = obj:getPosition()
  local nf = 0
  for _, cid in ipairs(bodyNodes) do
    local p = obj:getNodePosition(cid)
    local x, y, z = op.x + p.x, op.y + p.y, op.z + p.z
    if isFinite(x) and isFinite(y) and isFinite(z) then
      local rest = sample(x, y)
      if rest and z < rest + margin then
        nf = nf + 1
        found[nf] = cid
        foundS[cid] = rest - z
      end
    end
  end
  for k = nf + 1, #found do found[k] = nil end
  -- over the cap, the deepest nodes win (they cut the deepest dents)
  if nf > cap then table.sort(found, function(a, b) return foundS[a] > foundS[b] end) end
  for k = 1, min(nf, cap) do
    ncand = ncand + 1
    cands[ncand] = found[k]
  end
  for k = ncand + 1, #cands do cands[k] = nil end
end

local function fmtNum(x) return sfmt('%.3f', x) end

local deep = {}
local wheelsInMud = 0
local bodyTick = 0
local function sendReport()
  if tileCount == 0 then wheelsInMud = 0; return end
  local op = obj:getPosition()
  local vd = obj:getDirectionVector()
  local wparts = {}
  for i, w in ipairs(wheelList) do
    local hx, hy, hz, imm, ax, ay, az, ahx, ahy, fx, fy, vx, vy, vz = wheelState(w, op, vd.x, vd.y)
    if hx then
      local om = abs(tonumber(w.wd.angularVelocity) or 0)
      local vf = vx * fx + vy * fy
      local slip = om * w.R - abs(vf)
      local vals = { i, hx, hy, hz, ax, ay, az, fx, fy, wheelLoad, w.R, w.W, imm, slip, om }
      local ok = true
      for q = 1, #vals do if not isFinite(vals[q]) then ok = false; break end end
      if ok then
        wparts[#wparts + 1] = sfmt('%d,%s,%s,%s,%s,%s,%s,%s,%s,%.0f,%s,%s,%s,%s,%s', i,
          fmtNum(hx), fmtNum(hy), fmtNum(hz), fmtNum(ax), fmtNum(ay), fmtNum(az), fmtNum(fx), fmtNum(fy),
          wheelLoad, fmtNum(w.R), fmtNum(w.W), fmtNum(imm), fmtNum(slip), fmtNum(om))
      end
    end
  end
  wheelsInMud = #wparts
  local nparts = {}
  local nd = 0
  -- chassis dents change slowly and lie under the vehicle: every bodyEvery-th report
  -- (the GE sweeps each node from its last report, so the dents stay continuous)
  bodyTick = bodyTick + 1
  local ncandNow = (bodyTick % max(1, REP.bodyEvery or 1) == 0) and ncand or 0
  for k = 1, ncandNow do
    local cid = cands[k]
    local p = obj:getNodePosition(cid)
    local x, y, z = op.x + p.x, op.y + p.y, op.z + p.z
    if isFinite(x) and isFinite(y) and isFinite(z) then
      local rest = sample(x, y)
      if rest and z < rest then
        nd = nd + 1
        local d = deep[nd]
        if not d then d = {}; deep[nd] = d end
        d.cid, d.x, d.y, d.z, d.s = cid, x, y, z, rest - z
      end
    end
  end
  if nd > REP.maxBodyNodes then
    for k = nd + 1, #deep do deep[k].s = -math.huge end
    table.sort(deep, function(a, b) return a.s > b.s end)
  end
  for k = 1, min(nd, REP.maxBodyNodes) do
    local d = deep[k]
    nparts[#nparts + 1] = sfmt('%d,%s,%s,%s', d.cid, fmtNum(d.x), fmtNum(d.y), fmtNum(d.z))
  end
  if #wparts == 0 and #nparts == 0 then return end
  obj:queueGameEngineLua(sfmt('if deepnode_main then deepnode_main.onMudReport(%d,{%s},{%s}) end',
    vid, table.concat(wparts, ','), table.concat(nparts, ',')))
end

-- Water on the tyres: share of tread nodes under water (0..1), hub under water = 1.
-- Sent when a wheel's value changes by more than 0.1 (GE washes the mud off), and the
-- whole state again every waterResend checks while any wheel is wet or after a reset.
local waterTick, waterForce = 0, true
local function checkWater()
  local parts = nil
  waterTick = waterTick + 1
  local all = waterForce                -- after a reset: every wheel
  local resendWet = waterTick % 10 == 0 -- every 10th check: every wet wheel again
  waterForce = false
  for i, w in ipairs(wheelList) do
    local f = 0
    if not w.wd.isBroken then
      if obj:inWater(w.n1) or obj:inWater(w.n2) then
        f = 1
      else
        local n, wet = 0, 0
        local tn = w.treadNodes
        local step = max(1, floor(#tn / 8)) -- 8 samples around the tread are plenty
        for k = 1, #tn, step do
          n = n + 1
          if obj:inWater(tn[k]) then wet = wet + 1 end
        end
        if n > 0 then f = wet / n end
      end
    end
    if all or (resendWet and f > 0) or abs(f - (w.water or 0)) > 0.1 or (f == 0 and (w.water or 0) ~= 0) then
      w.water = f
      parts = parts or {}
      parts[#parts + 1] = sfmt('%d,%.2f', i, f)
    end
  end
  if parts then
    obj:queueGameEngineLua(sfmt('if deepnode_main then deepnode_main.onWheelWater(%d,{%s}) end', vid, table.concat(parts, ',')))
  end
end

local function sendStats()
  obj:queueGameEngineLua(sfmt('if deepnode_main then deepnode_main.onVehicleStats(%d,%d,%d,%d,%.0f,%d,%d) end',
    vid, wheelsInMud, ncand, tileCount, collectgarbage('count'), lod, #hullNodes))
end

-------------------------------------------------------------------------------
-- interface for GE
-------------------------------------------------------------------------------
function M.configure(p)
  if type(p) ~= 'table' or type(p.ter) ~= 'table' then return end
  ter = p.ter
  ter.key = ter.key or 65536
  REP = p.report or { rateHz = 30, maxBodyNodes = 24, boxHz = 10 }
  DU = p.dually or { enabled = true, autoRatio = 1.05, gap = 0.04 }
  lod = max(1, floor(tonumber(p.lod) or 1))
  vid = obj:getID()
  tiles = {}
  tileCount = 0
  ncand = 0
  collectWheels()
  collectNodes()
  clustersDirty, clusterAge = true, HULL_GAP
  lastBox = nil
  configured = true
  sendWheelDefs()
  sendBox(true)
end

function M.setTile(key, gx0, gy0, rest, depth)
  if not ter or type(rest) ~= 'table' or type(depth) ~= 'table' then return end
  local W = ter.ts + 1
  if #rest < W * W or #depth < W * W then return end
  if not tiles[key] then tileCount = tileCount + 1 end
  tiles[key] = { r = rest, d = depth, gx0 = gx0, gy0 = gy0 }
end

function M.dropTile(key)
  if tiles[key] then
    tiles[key] = nil
    tileCount = tileCount - 1
    if tileCount <= 0 then tileCount = 0; ncand = 0 end
  end
end
function M.dropAllTiles() tiles = {}; tileCount = 0; ncand = 0 end
function M.setLod(k) lod = max(1, floor(tonumber(k) or 1)) end

-- Heavy physics rut guide: lateral force per wheel from GE (N, along the axle node1 ->
-- node2), from the rut walls of the mud mesh under the tyre. Applied to the two hub
-- nodes, horizontal, for each frame until it is 0.35 s old.
local guide = {}   -- [wheel list index] = force
local guideT = -1
function M.setGuide(flat)
  for k in pairs(guide) do guide[k] = nil end
  if type(flat) == 'table' then
    for k = 1, #flat - 1, 2 do
      local i, f = flat[k], flat[k + 1]
      if isFinite(i) and isFinite(f) then guide[floor(i)] = f end
    end
  end
  guideT = 0
end

local gvec = nil
local function applyGuide(dt)
  if guideT < 0 then return end
  guideT = guideT + dt
  if guideT > 0.35 then guideT = -1; return end
  gvec = gvec or vec3()
  for i, f in pairs(guide) do
    local w = wheelList[i]
    if w and f ~= 0 and not w.wd.isBroken then
      local a, b = obj:getNodePosition(w.n1), obj:getNodePosition(w.n2)
      local ax, ay = b.x - a.x, b.y - a.y
      local l = sqrt(ax * ax + ay * ay)
      if l > 0.01 then
        local h = 0.5 * f / l
        gvec:set(ax * h, ay * h, 0)
        obj:applyForceVectorTime(w.n1, gvec, dt)
        obj:applyForceVectorTime(w.n2, gvec, dt)
      end
    end
  end
end

local function updateGFX(dt)
  if not configured then return end
  applyGuide(dt)
  accStats = accStats + dt
  if accStats >= 1 then
    accStats = 0
    sendStats()
  end
  -- the box is needed before the vehicle reaches the mud: GE activates tiles from it
  clusterAge = clusterAge + dt
  accBox = accBox + dt
  if accBox >= lod / (REP.boxHz or 10) then
    accBox = 0
    sendBox(false)
  end
  accWater = accWater + dt
  if accWater >= 1 / (REP.waterHz or 5) then
    accWater = 0
    checkWater()
  end
  if tileCount == 0 then wheelsInMud = 0; return end
  accCand = accCand + dt
  if accCand >= lod / (REP.candidateHz or 10) then
    accCand = 0
    refreshCandidates()
  end
  accReport = accReport + dt
  if accReport >= lod / REP.rateHz then
    accReport = 0
    sendReport()
  end
end

local function onBeamBroke()
  clustersDirty = true
end

local function onReset()
  ncand = 0
  guideT = -1
  accCand, accReport = 0, 0
  waterForce = true -- new wheel tables start dry: send the real state once
  if configured then
    collectWheels()
    collectNodes()
    clustersDirty, clusterAge = true, HULL_GAP
    lastBox = nil
    sendWheelDefs()
    sendBox(true)
  end
end

M.updateGFX = updateGFX
M.onReset = onReset
M.onBeamBroke = onBeamBroke

return M
