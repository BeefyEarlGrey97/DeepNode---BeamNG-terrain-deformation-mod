-- deepnode_physics
-- Physics option 'heavy' (cfg.physics.mode). Everything stays BeamNG's own physics:
--  * ground models: the soft kinds' ground models get thicker values
--    (cfg.physics.heavy.groundModels, e.g. a deeper soft layer `defaultDepth` and a more
--    viscous `flowConsistencyIndex`), set live with be:setGroundModel and put back on stop
--    (ge/extensions/core/environment.lua submitGroundModel). Measured on gridmap_v2,
--    Percheron 8x8, 85 m from standstill: mud 56 -> 30 km/h, sand 55 -> 48 km/h;
--  * rut floor: the sink pass leaves the hard floor under undisturbed mud floorLift above
--    the full sink depth (main P.sinkPass, lift per vertex in P.sinkLift). Where ruts are
--    dug, the terrain vertices under them are lowered to the rut surface (minus
--    floorMargin, so the rut mesh still hides the terrain): the rut walls are terrain the
--    tyres have to climb, softened by the ground model's soft layer. A vertex is lowered
--    by the deepest rut cell within floorReach squares (terrain squares are 5 rut cells
--    wide, so the terrain groove is a bit wider than the rut). The floor never goes
--    below the full sink, so a wheel can sink at most sinkDepth + defaultDepth.
--    Terrain is raised back only when the ruts are reset (tile released / cleared) and
--    no vehicle is within raiseClear m.
-- Rut wall test (gridmap_v2, Percheron, in its own ruts at ~21 km/h, steering held at
-- 0.035): lateral drift at 55 m 1.12 m with floorLift 0.3 / reach 0.3, vanilla 1.75 m;
-- with floorLift 0.2 / reach 0.6 no difference (the 1 m grid merged both track lines
-- into one wide, shallow groove). The walls hold a light steering input for a while
-- and can be climbed.
-- Engine facts (measured): tb:setHeightGrid + tb:updateGrid take effect for physics at
-- once (a parked truck dropped with the terrain); updateGrid costs 1-2.5 ms whatever the
-- box size, so all writes of a frame go into one call, charged to the upload budget
-- (tileMesh.canUpload kind 'F'). Heights are rounded to maxHeight / 65536 per write
-- (1.5 mm on gridmap_v2): a read-modify-write lost ~1.7 mm per lower/raise cycle
-- (-3.4 cm after 20), so floor heights are written absolute from the sink pass's base.
-- core_environment.reset() / reloadGroundModels() rebuild groundModels with the level's
-- values (mission restart, environment reset, ground-model file change, the debug
-- panel's "Default"): the heavy values are checked once a second and put back.

local M = {}

local floor, ceil, min, max, abs, huge = math.floor, math.ceil, math.min, math.max, math.abs, math.huge
local sfmt = string.format

local KEYS = { 'staticFrictionCoefficient', 'slidingFrictionCoefficient', 'hydrodynamicFriction',
  'stribeckVelocity', 'strength', 'roughnessCoefficient', 'defaultDepth', 'fluidDensity',
  'flowConsistencyIndex', 'flowBehaviorIndex', 'dragAnisotropy', 'shearStrength' }
local KEYSET = {}
for _, k in ipairs(KEYS) do KEYSET[k] = true end

local ctx, P = nil, nil
local saved = {}     -- ground model name -> original values
local applied = {}   -- ground model name -> { e = engine entry, vals = heavy values }
local watchAcc = 0
local pending = {}   -- sink record number -> { gx, gy, lift }
local npend = 0
local acc = 0
local stats = { writes = 0, updates = 0, ms = 0, maxMs = 0, held = 0, lowered = 0, raised = 0, blocked = 0,
  grassHeld = 0, grassWrites = 0, physOnly = 0, flushHidden = 0, flushHold = 0 }

local function heavy()
  local ph = ctx and ctx.cfg.physics
  return ph and ph.mode == 'heavy' and ph.heavy or nil
end

function M.mode()
  local ph = ctx and ctx.cfg.physics
  return ph and ph.mode or 'vanilla'
end

-- rut floor wanted: heavy mode with a lift for some kind
function M.floorOn()
  local h = heavy()
  if not h then return false end
  for _, v in pairs(h.floorLift or {}) do
    if (tonumber(v) or 0) > 0 then return true end
  end
  return false
end

-- lift of a vertex at the sink pass (m above the full sink, never above the original)
function M.initialLift(gx, gy, d)
  local h = heavy()
  if not h then return 0 end
  local kind, vanilla = ctx.layerKindAt(gx, gy)
  if vanilla then return 0 end   -- ticked by hand in the Run tab: vanilla physics
  local l = tonumber(h.floorLift and h.floorLift[kind]) or 0
  if l <= 0 then return 0 end
  return min(l, d)
end

-------------------------------------------------------------------------------
-- ground models
-------------------------------------------------------------------------------
local function applyGroundModels(layers)
  local h = heavy()
  local gms = core_environment and core_environment.groundModels
  if not h or not gms or not be or not be.setGroundModel then return end
  for _, L in pairs(layers or {}) do
    -- layers ticked by hand (L.vanilla) keep the level's ground model
    local name = L.soft and not L.vanilla and L.gm and tostring(L.gm):upper() or ''
    local vals = h.groundModels and h.groundModels[L.kind]
    local e = gms[name]
    -- reapply when the entry was rebuilt (core_environment reload) or a value moved back
    local a = applied[name]
    local stale = a and (a.e ~= e or (e and e.cdata and not M.matches(e.cdata, vals)))
    if name ~= '' and vals and e and e.cdata and (not saved[name] or stale) then
      local o = {}
      for _, k in ipairs(KEYS) do o[k] = e.cdata[k] end
      -- the originals: the first time from the engine; after a reload the engine holds
      -- the level's values again, so they are the originals once more
      saved[name] = o
      applied[name] = { e = e, vals = vals }
      local list = {}
      for k, v in pairs(vals) do
        if KEYSET[k] and tonumber(v) then
          e.cdata[k] = tonumber(v)
          list[#list + 1] = sfmt('%s %g->%g', k, o[k], tonumber(v))
        end
      end
      be:setGroundModel(name, e.cdata)
      log('I', 'deepnode', sfmt('heavy physics: ground model %s (%s): %s', name, tostring(L.kind), table.concat(list, ', ')))
    end
  end
end

-- engine entry holds the heavy values (float rounding allowed)
function M.matches(cd, vals)
  for k, v in pairs(vals) do
    if KEYSET[k] and tonumber(v) and math.abs((tonumber(cd[k]) or 0) - tonumber(v)) > 1e-3 * math.max(1, math.abs(tonumber(v))) then
      return false
    end
  end
  return true
end

local layersSeen = nil
local reapplied = 0
local function watchGroundModels()
  local gms = core_environment and core_environment.groundModels
  if not gms or not layersSeen then return end
  for name, a in pairs(applied) do
    local e = gms[name]
    if e ~= a.e or (e and e.cdata and not M.matches(e.cdata, a.vals)) then
      log('I', 'deepnode', 'heavy physics: ground model ' .. name .. ' was reloaded by the game, applying again')
      reapplied = reapplied + 1
      applyGroundModels(layersSeen)
      return
    end
  end
end

local function restoreGroundModels()
  local gms = core_environment and core_environment.groundModels
  for name, o in pairs(saved) do
    local e = gms and gms[name]
    if e and e.cdata then
      for k, v in pairs(o) do e.cdata[k] = v end
      pcall(function() be:setGroundModel(name, e.cdata) end)
    end
  end
  if next(saved) then log('I', 'deepnode', 'ground models restored') end
  saved = {}
  applied = {}
end

-------------------------------------------------------------------------------
-- rut floor
-------------------------------------------------------------------------------
-- world z of the terrain at a vertex as it is now
local function terrainZ(gx, gy)
  local ter = ctx.ter
  local hgt = ter.tb:getHeightGrid(gx, gy)
  if ter.localZ then return hgt + ter.oz end
  return hgt
end

-- lift a vertex should have now: up to its rut surface (deepest rut cell within reach)
local function wantedLift(gx, gy, k, h)
  local lift0 = P.sinkLift0[k]
  local N, cps = ctx.N, ctx.cps
  local tiles = ctx.tiles
  local KEY = ctx.KEY
  local R = max(1, floor((h.floorReach or 0.3) * cps + 0.5))
  local cx0, cy0 = gx * cps, gy * cps
  local zmin = huge
  local decodeZ = ctx.decodeZ
  for cy = cy0 - R, cy0 + R do
    local ty = floor(cy / N)
    local rowBase = (cy - ty * N) * (N + 1)
    for cx = cx0 - R, cx0 + R do
      local tx = floor(cx / N)
      local t = tiles[ty * KEY + tx]
      if t and t.rut then
        local idx = rowBase + cx - tx * N
        -- only carved cells pull the floor down: untouched mud and berms keep it, so the
        -- terrain stays at the surface there (terrain-first drawing, main.squareFlush)
        if t.rut[idx] < 128 then
          local z = decodeZ(t, idx)
          if z < zmin then zmin = z end
        end
      end
    end
  end
  if zmin == huge then return lift0 end
  local ter = ctx.ter
  local V = P.sinkBase[k] + (ter.localZ and ter.oz or 0) -- full sink level (absolute)
  local l = zmin - (h.floorMargin or 0.03) - V
  if l < 0 then return 0 end
  if l > lift0 then return lift0 end
  return l
end

-- Stopped vehicles keep their floor. While a vehicle drives, the floor writes trail it
-- (floorHz, upload budget), so it rides on the undug terrain; once it stops they caught up
-- under its parked wheels and it sank (measured 2026-11-01, Percheron braking in fresh
-- gridmap_v2 mud: -22 cm in 6 s after standing still). The floor under the wheels of a
-- vehicle slower than holdSpeed is not lowered while they stand there; a wheel spinning
-- faster than holdSpin keeps digging itself in. Held vertices are tried again later.
local held, heldN, heldT = {}, 0, -huge
local function heldWheels(h)
  local now = ctx.simTime and ctx.simTime() or 0
  if now >= heldT and now - heldT < 0.1 then return heldN end
  heldT = now
  heldN = 0
  local vmax = h.holdSpeed or 0.8
  if vmax <= 0 then return 0 end
  local smax = h.holdSpin or 1.0
  local pad = (h.holdPad or 0.75) * ctx.ter.sq
  for vid, vs in pairs(P.vehs or {}) do
    local veh = getObjectByID(vid)
    local v = veh and veh:getVelocity()
    if v and v:length() < vmax and vs.lastWheel then
      for _, w in pairs(vs.lastWheel) do
        if w.ax and now - (w.at or -huge) < 1 and (w.spin or 0) < smax then
          heldN = heldN + 1
          local e = held[heldN]
          if not e then e = {}; held[heldN] = e end
          local r = (w.R or 0.5) * 0.8 + pad
          e[1], e[2], e[3] = w.ax, w.ay, r * r
        end
      end
    end
  end
  return heldN
end

local function isHeld(gx, gy)
  local ter = ctx.ter
  local x, y = ter.ox + gx * ter.sq, ter.oy + gy * ter.sq
  for i = 1, heldN do
    local e = held[i]
    if (e[1] - x) ^ 2 + (e[2] - y) ^ 2 < e[3] then return true end
  end
  return false
end

-- try the floor of the tile holding vertex (gx, gy) again at the next collect
local function remark(gx, gy)
  local TS, KEY = ctx.ts, ctx.KEY
  local tx, ty = floor(gx / TS), floor(gy / TS)
  local key = ty * KEY + tx
  if not P.floorTiles[key] then P.floorTiles[key] = { mode = 'lower', tx = tx, ty = ty } end
end

local function vehiclePositions()
  local list = {}
  for _, veh in ipairs(getAllVehicles and getAllVehicles() or {}) do
    local p = veh:getPosition()
    if p then list[#list + 1] = { p.x, p.y } end
  end
  return list
end

-- redo the floor under every marked tile: queue the vertices whose lift changes
local function collect(h)
  if not next(P.floorTiles) then return end
  local ter = ctx.ter
  local S, TS = ter.size, ctx.ts
  local clear2 = (h.raiseClear or 8) ^ 2
  local vpos = nil
  local keep = nil
  local nHeld = heldWheels(h)
  for key, e in pairs(P.floorTiles) do
    local gx0, gy0 = e.tx * TS, e.ty * TS
    local blocked = false
    for gy = max(0, gy0), min(S - 1, gy0 + TS) do
      for gx = max(0, gx0), min(S - 1, gx0 + TS) do
        local k = P.sinkFind(gy * S + gx)
        if k and P.sinkLift0[k] > 0 then
          local want = wantedLift(gx, gy, k, h)
          local cur = P.sinkLift[k]
          if want < cur - 0.005 and nHeld > 0 and isHeld(gx, gy) then
            blocked = true
            stats.wheelHeld = (stats.wheelHeld or 0) + 1
          elseif want < cur - 0.005 then
            if not pending[k] then npend = npend + 1 end
            pending[k] = { gx, gy, want }
          elseif e.mode == 'reset' and want > cur + 0.005 then
            -- raising under a tyre would wedge the vehicle: only with nobody near
            vpos = vpos or vehiclePositions()
            local x, y = ter.ox + gx * ter.sq, ter.oy + gy * ter.sq
            local free = true
            for _, v in ipairs(vpos) do
              if (v[1] - x) ^ 2 + (v[2] - y) ^ 2 < clear2 then free = false; break end
            end
            if free then
              if not pending[k] then npend = npend + 1 end
              pending[k] = { gx, gy, want }
            else
              blocked = true
            end
          end
        end
      end
    end
    if blocked then
      keep = keep or {}
      keep[key] = e
      stats.blocked = stats.blocked + 1
    end
  end
  P.floorTiles = keep or {}
end

-- Grass next to floor writes. Every tb:updateGrid makes the engine drop the GroundCover cells
-- over its box and build them again: the grass there is missing for a frame. Measured
-- 2026-10-31 on gridmap_v2: updateGrid every frame over a 6 x 100 m mud strip 12 m from a
-- grass strip hid 75 % of the grass in view, a 2 x 2 m box beside the grass 5-14 %; GPU and
-- CPU placement alike (CPU took several frames to come back), from every GE hook; there is no
-- physics-only terrain update (setHeightGrid alone: no change for the wheels). One merged box
-- per frame spanned all trucks, so grass anywhere between them blinked at floorHz.
-- Now the pending vertices are grouped in clusters of floorCluster squares. A frame writes,
-- in one call as before, every cluster whose joint box stays grassReach m (rounded up to
-- whole clusters) clear of grass layers; a cluster near grass is written on its own, at most
-- every grassHold s (the grass beside it blinks that often instead of at floorHz).
--
-- 2026-11-02: physics and render split. tb:updateGrid refreshes the physics terrain
-- everywhere whatever its box (a vertex lowered 0.5 m with a far 1 x 1 box: castRayStatic
-- hit the new height the next frame), but redraws the terrain and drops GroundCover cells
-- only inside the box (grass beside it stayed). So clusters near grass are written at once
-- with a far dummy box (vehicles sink without delay, no grass touched); their real box (the
-- terrain drawn lower, the rut mesh showing) waits until the grass cells over it are out of
-- view, at most grassHold s while they are in view (then one blink for that group).
local grassIdx = nil   -- terrain layer index -> true where a visible GroundCover grows; all = inverted cover
local blockGrass = {}  -- cluster key -> grass layer squares inside it (cached)
local clusterT = {}    -- cluster key -> clock of its last write
local clock = 0
local CKEY = 65536
local renderWait = {}  -- cluster key -> { gx0, gy0, gx1, gy1, since, need, ks }: written, terrain not redrawn
local nWait = 0
local drawn = {}       -- sink record -> lift the terrain is still drawn at (only while it differs)

local function collectGrassLayers()
  grassIdx = {}
  local byName = {}
  for idx, L in pairs(layersSeen or {}) do
    if type(L) == 'table' and L.name then byName[tostring(L.name):lower()] = idx end
  end
  local names = scenetree.findClassObjects and scenetree.findClassObjects('GroundCover') or {}
  for _, n in ipairs(names) do
    local gc = scenetree.findObject(n)
    if gc and not gc:isHidden() then
      for i = 0, 7 do
        local layer = tostring(gc:getField('layer', i) or '')
        local prob = tonumber(gc:getField('probability', i)) or 0
        -- main's lifted copies switch a type off with an unreachable minElevation
        local minE = tonumber(gc:getField('minElevation', i)) or 0
        if layer ~= '' and layer ~= '0' and prob > 0 and minE < 999999 then
          local inv = tostring(gc:getField('invertLayer', i) or '')
          if inv == '1' or inv == 'true' then
            grassIdx.all = true
          elseif byName[layer:lower()] then
            grassIdx[byName[layer:lower()]] = true
          end
        end
      end
    end
  end
end

-- grass layer squares inside cluster (bx, by) (every second square sampled)
local function blockHasGrass(bx, by, cs)
  local key = by * CKEY + bx
  local v = blockGrass[key]
  if v ~= nil then return v end
  v = false
  local S = ctx.ter.size
  local layerAt = ctx.layerAt
  for gy = max(0, by * cs), min(S - 1, by * cs + cs - 1), 2 do
    for gx = max(0, bx * cs), min(S - 1, bx * cs + cs - 1), 2 do
      if grassIdx[layerAt(gx, gy)] then v = true; break end
    end
    if v then break end
  end
  blockGrass[key] = v
  return v
end

-- grass within reach of the square box gx0..gx1 x gy0..gy1
local function nearGrass(gx0, gy0, gx1, gy1, cs, h)
  if not grassIdx then collectGrassLayers() end
  if grassIdx.all then return true end
  if not next(grassIdx) then return false end
  local r = ceil((h.grassReach or 16) / ctx.ter.sq)
  for by = floor((gy0 - r) / cs), floor((gy1 + r) / cs) do
    for bx = floor((gx0 - r) / cs), floor((gx1 + r) / cs) do
      if blockHasGrass(bx, by, cs) then return true end
    end
  end
  return false
end

-- the GroundCover cells over grid box gx0..gx1 x gy0..gy1 may be on screen: inside the
-- camera's view cone (main's P.view) and within reach of the covers (grassViewRange)
local vv = { 0, 0, 0, 0, 0 }
local function boxInView(gx0, gy0, gx1, gy1, h)
  local v = P and P.view
  if not v or not v.ok then return true end
  local ter = ctx.ter
  local cell = (ctx.cfg.grass and tonumber(ctx.cfg.grass.cellSize)) or 25
  if cell <= 0 then cell = 25 end
  local x0, y0 = ter.ox + gx0 * ter.sq - cell, ter.oy + gy0 * ter.sq - cell
  local x1, y1 = ter.ox + gx1 * ter.sq + cell, ter.oy + gy1 * ter.sq + cell
  local range = h.grassViewRange or 160
  local cx = v.x < x0 and x0 or (v.x > x1 and x1 or v.x)
  local cy = v.y < y0 and y0 or (v.y > y1 and y1 or v.y)
  local dx, dy = cx - v.x, cy - v.y
  if dx * dx + dy * dy > range * range then return false end
  if v.x >= x0 and v.x <= x1 and v.y >= y0 and v.y <= y1 then return true end
  local zc = core_terrain and core_terrain.getTerrainHeight(vec3((x0 + x1) * 0.5, (y0 + y1) * 0.5, 0)) or v.z
  vv[1], vv[2], vv[3], vv[4], vv[5] = x0, x1, (x0 + x1) * 0.5, y0, y1
  for zi = -1, 1, 2 do
    local z = zc + zi * 3 - v.z
    for xi = 1, 3 do
      for yi = 0, 2 do
        local px = vv[xi]
        local py = yi == 0 and y0 or (yi == 1 and y1 or (y0 + y1) * 0.5)
        local ex, ey = px - v.x, py - v.y
        local l = math.sqrt(ex * ex + ey * ey + z * z)
        if l < 1e-3 or (ex * v.fx + ey * v.fy + z * v.fz) / l > v.cosA then return true end
      end
    end
  end
  return false
end

-- 1 x 1 box at the terrain corner farthest from the camera: refreshes physics only
local dummyA, dummyB = nil, nil
local function dummyBox()
  local ter = ctx.ter
  local S = ter.size
  local v = P and P.view
  local cx, cy = v and v.x or 0, v and v.y or 0
  local gx = (cx - ter.ox) / ter.sq < S / 2 and S - 3 or 1
  local gy = (cy - ter.oy) / ter.sq < S / 2 and S - 3 or 1
  dummyA = dummyA or vec3(0, 0, 0)
  dummyB = dummyB or vec3(0, 0, 0)
  dummyA.x, dummyA.y, dummyB.x, dummyB.y = gx, gy, gx + 1, gy + 1
  return dummyA, dummyB
end

-- the oldest render-waiting group that may be redrawn now (hidden, or waited grassHold s):
-- it and the waiting clusters around it, one box
local function pickFlush(h)
  if nWait == 0 then return nil end
  local hold = h.grassHold or 1.0
  local best, bestT, why = nil, huge, nil
  for key, e in pairs(renderWait) do
    if e[5] < bestT then
      -- a group whose drawn terrain still hides no rut (lowered less than the rut's margin
      -- over it, or raised) waits for the camera to look away, however long
      local hidden = not boxInView(e[1], e[2], e[3], e[4], h)
      if hidden or (e[6] and clock - e[5] >= hold) then best, bestT, why = key, e[5], hidden end
    end
  end
  if not best then return nil end
  local ax, ay = best % CKEY, floor(best / CKEY)
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for key, e in pairs(renderWait) do
    local kx, ky = key % CKEY, floor(key / CKEY)
    if max(abs(kx - ax), abs(ky - ay)) <= 1 then
      x0, y0, x1, y1 = min(x0, e[1]), min(y0, e[2]), max(x1, e[3]), max(y1, e[4])
      for i = 1, #e[7] do drawn[e[7][i]] = nil end
      renderWait[key] = nil
      nWait = nWait - 1
    end
  end
  if why then stats.flushHidden = stats.flushHidden + 1 else stats.flushHold = stats.flushHold + 1 end
  return x0, y0, x1, y1
end

local function terrainUpdate(tb, x0, y0, x1, y1, tm)
  local timer = hptimer and hptimer()
  tb:updateGrid(vec3(x0, y0, 0), vec3(x1, y1, 0))
  local ms = timer and timer:stop() or 1
  if ctx.onFloorChanged then ctx.onFloorChanged(x0, y0, x1, y1) end
  if tm and tm.recordUpload then tm.recordUpload('F', nil, ms) end
  stats.updates = stats.updates + 1
  stats.ms = stats.ms + ms
  if ms > stats.maxMs then stats.maxMs = ms end
  return ms
end

-- write queued vertices: one updateGrid per frame, inside the upload budget
-- Slow terrains: tb:updateGrid costs more the bigger the terrain, not the box (hw550,
-- 8192 x 8192: 15-78 ms for a 3 x 3 square box, measured 2026-11-01, with every
-- GroundCover hidden too; gridmap_v2 2048 x 2048: 1-2.5 ms). Once the measured cost passes
-- slowUpdateMs, the floor is written at most every slowUpdateGap s, everything pending in
-- one update (one hitch instead of one per cluster); the rut shows that much later.
local cl, take = {}, {}
local updEma, lastUpd = nil, -huge
local function write(h)
  local tm = extensions and extensions.deepnode_tileMesh
  if tm and tm.canUpload and not tm.canUpload('F', 0) then
    stats.held = stats.held + 1
    return
  end
  local slow = updEma ~= nil and updEma > (h.slowUpdateMs or 8)
  if slow and clock - lastUpd < (h.slowUpdateGap or 2) then
    stats.slowHeld = (stats.slowHeld or 0) + 1
    return
  end
  local cs = max(2, floor(h.floorCluster or 16))
  local hold = h.grassHold or 1.0
  local needDrop = (h.floorMargin or 0.03) * (h.grassRedrawShare or 0.7)
  -- clusters of the pending vertices: key -> square box
  for k in pairs(cl) do cl[k] = nil end
  for k in pairs(take) do take[k] = nil end
  for _, w in pairs(pending) do
    local gx, gy = w[1], w[2]
    local key = floor(gy / cs) * CKEY + floor(gx / cs)
    local b = cl[key]
    if not b then
      cl[key] = { gx, gy, gx, gy }
    else
      if gx < b[1] then b[1] = gx end
      if gy < b[2] then b[2] = gy end
      if gx > b[3] then b[3] = gx end
      if gy > b[4] then b[4] = gy end
    end
  end
  local any, alone = slow, nil
  if slow then
    for key in pairs(cl) do take[key] = true; clusterT[key] = clock end
  end
  local split = h.grassSplit ~= false
  local grassAny = false
  local ux0, uy0, ux1, uy1 = huge, huge, -huge, -huge
  for key, b in pairs(slow and {} or cl) do
    if not nearGrass(b[1], b[2], b[3], b[4], cs, h) then
      local x0, y0, x1, y1 = min(ux0, b[1]), min(uy0, b[2]), max(ux1, b[3]), max(uy1, b[4])
      if not any or not nearGrass(x0, y0, x1, y1, cs, h) then
        take[key] = true
        any = true
        ux0, uy0, ux1, uy1 = x0, y0, x1, y1
      end
    elseif split then
      -- near grass: into the heightmap now (physics), its terrain redrawn later (renderWait)
      take[key] = 2
      grassAny = true
    elseif not alone and clock - (clusterT[key] or -huge) >= hold then
      alone = key
    end
  end
  if not any and not grassAny then
    if not alone then
      stats.grassHeld = stats.grassHeld + 1
      return
    end
    -- with it, the other clusters near grass next to it whose hold is over (one blink for all)
    local ax, ay = alone % CKEY, floor(alone / CKEY)
    for key in pairs(cl) do
      local kx, ky = key % CKEY, floor(key / CKEY)
      if max(abs(kx - ax), abs(ky - ay)) <= 1 and clock - (clusterT[key] or -huge) >= hold then
        take[key] = true
        clusterT[key] = clock
      end
    end
    stats.grassWrites = stats.grassWrites + 1
  end
  local tb = ctx.ter.tb
  local clampRaw = ctx.ter.clampRaw or 0
  local maxV = (h.floorMaxVerts or 600) * (slow and 4 or 1)
  local n = 0
  local bx0, by0, bx1, by1 = huge, huge, -huge, -huge
  local timer = hptimer and hptimer()
  local nHeld = heldWheels(h)
  for k, w in pairs(pending) do
    if n >= maxV then break end
    local gx, gy, lift = w[1], w[2], w[3]
    if nHeld > 0 and lift < P.sinkLift[k] and isHeld(gx, gy) then
      -- queued while the vehicle still drove: wait until its wheel leaves
      pending[k] = nil
      npend = npend - 1
      remark(gx, gy)
      stats.wheelHeld = (stats.wheelHeld or 0) + 1
    else
      local ck = floor(gy / cs) * CKEY + floor(gx / cs)
      local tk = take[ck]
      if tk then
        local old = P.sinkLift[k]
        -- absolute: full sink level + lift (the sink pass's clamp still holds)
        local hz = P.sinkBase[k] + lift
        if hz < clampRaw then hz = clampRaw end
        tb:setHeightGrid(gx, gy, hz)
        P.sinkLift[k] = lift
        if lift < old then stats.lowered = stats.lowered + 1 else stats.raised = stats.raised + 1 end
        if tk == 2 then
          -- the terrain stays drawn at its old height until the group's redraw: that hides
          -- the rut mesh only where it is now lower by more than the mesh's margin over it
          local dl = drawn[k]
          local fresh = dl == nil
          if fresh then dl = old; drawn[k] = old end
          local e = renderWait[ck]
          if not e then
            e = { gx, gy, gx, gy, clock, false, {} }
            renderWait[ck] = e
            nWait = nWait + 1
          else
            if gx < e[1] then e[1] = gx end
            if gy < e[2] then e[2] = gy end
            if gx > e[3] then e[3] = gx end
            if gy > e[4] then e[4] = gy end
          end
          if fresh then e[7][#e[7] + 1] = k end
          if dl - lift > needDrop then
            if not e[6] then e[6] = true; e[5] = clock end
          end
        else
          drawn[k] = nil
          if gx < bx0 then bx0 = gx end
          if gx > bx1 then bx1 = gx end
          if gy < by0 then by0 = gy end
          if gy > by1 then by1 = gy end
        end
        pending[k] = nil
        npend = npend - 1
        n = n + 1
      end
    end
  end
  if n == 0 then return end
  local ms
  if bx0 <= bx1 then
    -- clusters clear of grass: physics everywhere and this box redrawn
    ms = terrainUpdate(tb, bx0, by0, bx1, by1, tm)
  else
    local fx0, fy0, fx1, fy1 = pickFlush(h)
    if fx0 then
      ms = terrainUpdate(tb, fx0, fy0, fx1, fy1, tm)
    else
      -- only clusters near grass: physics now, nothing redrawn (no grass dropped)
      local da, db = dummyBox()
      tb:updateGrid(da, db)
      ms = timer and timer:stop() or 1
      if tm and tm.recordUpload then tm.recordUpload('F', nil, ms) end
      stats.physOnly = stats.physOnly + 1
      stats.ms = stats.ms + ms
    end
  end
  stats.writes = stats.writes + n
  updEma = updEma and updEma * 0.7 + ms * 0.3 or ms
  lastUpd = clock
end

-- no vertex pending: redraw a render-waiting group once it may be (one update per frame)
local function flushOnly(h)
  local tm = extensions and extensions.deepnode_tileMesh
  if tm and tm.canUpload and not tm.canUpload('F', 0) then return end
  local x0, y0, x1, y1 = pickFlush(h)
  if not x0 then return end
  local ms = terrainUpdate(ctx.ter.tb, x0, y0, x1, y1, tm)
  updEma = updEma and updEma * 0.7 + ms * 0.3 or ms
  lastUpd = clock
end

function M.update(dt)
  local h = heavy()
  if not h or not ctx.ter then return end
  acc = acc + (dt or 0)
  clock = clock + (dt or 0)
  watchAcc = watchAcc + (dt or 0)
  if watchAcc >= 1 then
    watchAcc = 0
    watchGroundModels()
  end
  -- coarse terrain (main's virtual grid): no rut floor, one real vertex spans many ruts
  if (ctx.ter.K or 1) > 1 then P.floorTiles = {}; return end
  if acc >= 1 / max(0.5, h.floorHz or 5) then
    acc = 0
    collect(h)
  end
  if npend > 0 then write(h) elseif nWait > 0 then flushOnly(h) end
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------
-- before the sink pass
function M.start(main, layers)
  ctx = main
  P = main.private
  pending, npend, acc = {}, 0, 0
  for k in pairs(stats) do stats[k] = 0 end
  layersSeen = layers
  -- grass layers are read on the first write (main lifts the groundcover after the sink pass)
  grassIdx, blockGrass, clusterT = nil, {}, {}
  renderWait, nWait, drawn = {}, 0, {}
  reapplied = 0
  if heavy() then applyGroundModels(layers) end
end

-- main's region shift renumbered the sink records: map[old] = new record, -1 = gone (the
-- vertex left the region or was sunk again: its queued write is void)
function M.remapRecords(map, n)
  local function nk(k) if k < n then return map[k] end return -1 end
  local np, c = {}, 0
  for k, w in pairs(pending) do
    local k2 = nk(k)
    if k2 >= 0 then np[k2] = w; c = c + 1 end
  end
  pending, npend = np, c
  local nd = {}
  for k, l in pairs(drawn) do
    local k2 = nk(k)
    if k2 >= 0 then nd[k2] = l end
  end
  drawn = nd
  for _, e in pairs(renderWait) do
    local ks = {}
    for i = 1, #e[7] do
      local k2 = nk(e[7][i])
      if k2 >= 0 then ks[#ks + 1] = k2 end
    end
    e[7] = ks
  end
  -- grass clusters were read with the old region's layers (hard outside it)
  blockGrass = {}
end

function M.stop(objectsAlive)
  restoreGroundModels()
  pending, npend = {}, 0
end

-- switch mode: restarts the mod (new sink pass). Do it with no vehicle sunk in the mud:
-- the terrain under it changes.
function M.setMode(mode)
  if mode ~= 'heavy' then mode = 'vanilla' end
  local main = ctx or deepnode_main
  if not main then return end
  main.cfg.physics.mode = mode
  -- keep the other GUI values: merge into the GUI file (start reads it)
  local path = main.private and main.private.GUI_CFG or '/settings/deepnode/gui.json'
  local g = (FS and FS:fileExists(path) and jsonReadFile(path)) or {}
  if type(g) ~= 'table' then g = {} end
  g.physics = type(g.physics) == 'table' and g.physics or {}
  g.physics.mode = mode
  jsonWriteFile(path, g, true)
  if main.isRunning() then main.reloadLevelData() end
end

function M.stats()
  local s = {}
  for k, v in pairs(stats) do s[k] = v end
  s.pending = npend
  s.redrawWaiting = nWait
  s.mode = M.mode()
  s.reapplied = reapplied
  s.groundModels = 0
  for _ in pairs(saved) do s.groundModels = s.groundModels + 1 end
  return s
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
