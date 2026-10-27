-- deepmud_physics
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
-- (tileMesh.canUpload kind 'F').

local M = {}

local floor, min, max, huge = math.floor, math.min, math.max, math.huge
local sfmt = string.format

local KEYS = { 'staticFrictionCoefficient', 'slidingFrictionCoefficient', 'hydrodynamicFriction',
  'stribeckVelocity', 'strength', 'roughnessCoefficient', 'defaultDepth', 'fluidDensity',
  'flowConsistencyIndex', 'flowBehaviorIndex', 'dragAnisotropy', 'shearStrength' }
local KEYSET = {}
for _, k in ipairs(KEYS) do KEYSET[k] = true end

local ctx, P = nil, nil
local saved = {}     -- ground model name -> original values
local pending = {}   -- sink record number -> { gx, gy, lift }
local npend = 0
local acc = 0
local stats = { writes = 0, updates = 0, ms = 0, maxMs = 0, held = 0, lowered = 0, raised = 0, blocked = 0 }

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
  local kind = ctx.layerKindAt(gx, gy)
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
    local name = L.soft and L.gm and tostring(L.gm):upper() or ''
    local vals = h.groundModels and h.groundModels[L.kind]
    local e = gms[name]
    if name ~= '' and vals and e and e.cdata and not saved[name] then
      local o = {}
      for _, k in ipairs(KEYS) do o[k] = e.cdata[k] end
      saved[name] = o
      local list = {}
      for k, v in pairs(vals) do
        if KEYSET[k] and tonumber(v) then
          e.cdata[k] = tonumber(v)
          list[#list + 1] = sfmt('%s %g->%g', k, o[k], tonumber(v))
        end
      end
      be:setGroundModel(name, e.cdata)
      log('I', 'deepmud', sfmt('heavy physics: ground model %s (%s): %s', name, tostring(L.kind), table.concat(list, ', ')))
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
  if next(saved) then log('I', 'deepmud', 'ground models restored') end
  saved = {}
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
  local V = terrainZ(gx, gy) - P.sinkLift[k] -- full sink level
  local l = zmin - (h.floorMargin or 0.03) - V
  if l < 0 then return 0 end
  if l > lift0 then return lift0 end
  return l
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
  for key, e in pairs(P.floorTiles) do
    local gx0, gy0 = e.tx * TS, e.ty * TS
    local blocked = false
    for gy = max(0, gy0), min(S - 1, gy0 + TS) do
      for gx = max(0, gx0), min(S - 1, gx0 + TS) do
        local k = P.sinkFind(gy * S + gx)
        if k and P.sinkLift0[k] > 0 then
          local want = wantedLift(gx, gy, k, h)
          local cur = P.sinkLift[k]
          if want < cur - 0.005 then
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

-- write queued vertices: one updateGrid per frame, inside the upload budget
local function write(h)
  local tm = extensions and extensions.deepmud_tileMesh
  if tm and tm.canUpload and not tm.canUpload('F', 0) then
    stats.held = stats.held + 1
    return
  end
  local tb = ctx.ter.tb
  local maxV = h.floorMaxVerts or 600
  local n = 0
  local bx0, by0, bx1, by1 = huge, huge, -huge, -huge
  local timer = hptimer and hptimer()
  for k, w in pairs(pending) do
    if n >= maxV then break end
    local gx, gy, lift = w[1], w[2], w[3]
    local old = P.sinkLift[k]
    tb:setHeightGrid(gx, gy, tb:getHeightGrid(gx, gy) - old + lift)
    P.sinkLift[k] = lift
    if lift < old then stats.lowered = stats.lowered + 1 else stats.raised = stats.raised + 1 end
    if gx < bx0 then bx0 = gx end
    if gx > bx1 then bx1 = gx end
    if gy < by0 then by0 = gy end
    if gy > by1 then by1 = gy end
    pending[k] = nil
    npend = npend - 1
    n = n + 1
  end
  if n == 0 then return end
  tb:updateGrid(vec3(bx0, by0, 0), vec3(bx1, by1, 0))
  local ms = timer and timer:stop() or 1
  if ctx.onFloorChanged then ctx.onFloorChanged(bx0, by0, bx1, by1) end
  if tm and tm.recordUpload then tm.recordUpload('F', nil, ms) end
  stats.writes = stats.writes + n
  stats.updates = stats.updates + 1
  stats.ms = stats.ms + ms
  if ms > stats.maxMs then stats.maxMs = ms end
end

function M.update(dt)
  local h = heavy()
  if not h or not ctx.ter then return end
  acc = acc + (dt or 0)
  if acc >= 1 / max(0.5, h.floorHz or 5) then
    acc = 0
    collect(h)
  end
  if npend > 0 then write(h) end
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
  if heavy() then applyGroundModels(layers) end
end

function M.stop(objectsAlive)
  restoreGroundModels()
  pending, npend = {}, 0
end

-- switch mode: restarts the mod (new sink pass). Do it with no vehicle sunk in the mud:
-- the terrain under it changes.
function M.setMode(mode)
  if mode ~= 'heavy' then mode = 'vanilla' end
  local main = ctx or deepmud_main
  if not main then return end
  main.cfg.physics.mode = mode
  -- keep the other GUI values: merge into the GUI file (start reads it)
  local path = main.private and main.private.GUI_CFG or '/settings/deepmud/gui.json'
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
  s.mode = M.mode()
  s.groundModels = 0
  for _ in pairs(saved) do s.groundModels = s.groundModels + 1 end
  return s
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
