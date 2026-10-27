-- deepnode_farMesh
-- Sector meshes: 6x6 tiles each, one pooled mesh object per sector (swapped through
-- tileMesh.present, so the old mesh disappears one frame after the new one shows).
-- A sector draws its frozen (rutted) tiles at full resolution and every other mud
-- square at one quad per terrain square, so the lowered terrain
-- never shows a hole. It sits sectors.drop lower than active tiles (no z-fighting)
-- and leaves out tiles whose own mesh is shown.
--
-- Builds are coroutines that yield when the per-frame budget is used up.
-- Handover rule: a tile mesh given to a sector is released only after that sector
-- was rebuilt. The handover list is snapshotted when a build starts.

local M = {}

local floor, min, max, sqrt, huge = math.floor, math.min, math.max, math.sqrt, math.huge

local ctx = nil
local sectors = {}
local job = nil
local freeBuilders = {}
local refreshTimer = 0
local frameTimer = nil
local budget = 2
local pts = {}
local stats = { builds = 0, failed = 0, lastBuildMs = 0, maxBuildFrames = 0, byTier = {},
  urgentWaitLast = 0, urgentWaitMax = 0, urgentWaitSum = 0, urgentWaits = 0 }

local function tm() return extensions and extensions.deepnode_tileMesh or (ctx and ctx.tileMeshForTests) end

local function newTimer()
  if hptimer then return hptimer() end
  local t = { t0 = os.clock() }
  function t:stop() return (os.clock() - self.t0) * 1000 end
  return t
end

local function newSector(key)
  local KEY = ctx.KEY
  return { key = key, sx = key % KEY, sy = floor(key / KEY), obj = nil, dirty = true, urgent = false,
    handovers = {}, built = false, failures = 0 }
end

local function sectorSpan() return ctx.sec * ctx.tileSize end

local function sectorDist(sec, x, y)
  local span = sectorSpan()
  local x0, y0 = ctx.ter.ox + sec.sx * span, ctx.ter.oy + sec.sy * span
  local dx = max(x0 - x, 0, x - (x0 + span))
  local dy = max(y0 - y, 0, y - (y0 + span))
  return sqrt(dx * dx + dy * dy)
end

local function minDist(sec)
  local best = huge
  for i = 1, #pts, 2 do
    local d = sectorDist(sec, pts[i], pts[i + 1])
    if d < best then best = d end
  end
  return best
end

-- load radius of point i: the camera (first point when known) sees the mud around it,
-- the vehicle points only need the sectors next to their own tiles (sectors.vehLoadRadius)
local camPt = false
local function radiusOf(i)
  local cfg = ctx.cfg.sectors
  if i == 1 and camPt then return cfg.loadRadius end
  return min(cfg.loadRadius, cfg.vehLoadRadius or cfg.loadRadius)
end

-- smallest (distance - load radius) over all points
local function minExcess(sec)
  local best = huge
  for i = 1, #pts, 2 do
    local d = sectorDist(sec, pts[i], pts[i + 1]) - radiusOf(i)
    if d < best then best = d end
  end
  return best
end

local function setPoints(camx, camy, vehCenters)
  for i = #pts, 1, -1 do pts[i] = nil end
  local isFinite = ctx.isFinite
  camPt = isFinite(camx) and isFinite(camy)
  if camPt then pts[#pts + 1] = camx; pts[#pts + 1] = camy end
  if ctx.getCenterPoints then
    -- vehicles and their look-ahead points: sectors ahead load before the vehicle arrives
    local xs, ys, n = ctx.getCenterPoints()
    for i = 1, n do
      if isFinite(xs[i]) and isFinite(ys[i]) then pts[#pts + 1] = xs[i]; pts[#pts + 1] = ys[i] end
    end
  else
    for _, c in ipairs(vehCenters or {}) do
      if isFinite(c.x) and isFinite(c.y) then pts[#pts + 1] = c.x; pts[#pts + 1] = c.y end
    end
  end
end

local function hasContent(key)
  if ctx.frozenInSector(key) then return true end
  return ctx.loweredSector(key)
end

local function unload(sec)
  if sec.obj then tm().deferRelease(sec.obj); sec.obj = nil end
  tm().dropSpare(sec)
  sectors[sec.key] = nil
end

-- Sector cache (sectors.cacheMax): a built sector that leaves the load radius is only
-- hidden. Coming back into range shows it again without a rebuild unless it changed
-- meanwhile. Every mesh upload costs ~1 ms of createMesh plus render time (shadow and
-- reflection passes measured +0.5 ms each at ~50 uploads/s) and some engine memory;
-- re-entering sectors (driving back, circling) were rebuilt from scratch before.
-- Hidden objects cost no measurable frame time (hide test: 298 hidden objects deleted,
-- shadow pass -0.06 ms).
local nHidden = 0
local function hideSector(sec)
  if sec.hidden then return end
  sec.hidden = true
  sec.hiddenT = os.clock()
  nHidden = nHidden + 1
  tm().dropSpare(sec)
  if sec.obj then sec.obj:setHidden(true) end
  if ctx.onSectorShown then ctx.onSectorShown(sec.key, false) end
end
local function showSector(sec)
  if not sec.hidden then return end
  sec.hidden = false
  nHidden = nHidden - 1
  if sec.obj then sec.obj:setHidden(false) end
  if ctx.onSectorShown then ctx.onSectorShown(sec.key, true) end
  -- marks made while hidden wait from now (urgent wait readout)
  if sec.urgentSince then sec.urgentSince = os.clock() end
end

-- Load sectors with lowered mud or frozen tiles within the load radius of the
-- camera and the vehicles; unload the rest (with a margin, never during a build
-- or with pending handovers).
local function refreshLoaded()
  local cfg = ctx.cfg.sectors
  local span = sectorSpan()
  local KEY = ctx.KEY
  local ox, oy = ctx.ter.ox, ctx.ter.oy
  for i = 1, #pts, 2 do
    local x, y = pts[i], pts[i + 1]
    local R = radiusOf(i)
    local sx0, sx1 = floor((x - R - ox) / span), floor((x + R - ox) / span)
    local sy0, sy1 = floor((y - R - oy) / span), floor((y + R - oy) / span)
    if sx1 - sx0 <= 64 and sy1 - sy0 <= 64 then
      for sy = sy0, sy1 do
        for sx = sx0, sx1 do
          local key = sy * KEY + sx
          local sec = sectors[key]
          if sec then
            if sec.hidden and sectorDist(sec, x, y) <= R then showSector(sec) end
          elseif hasContent(key) then
            sec = newSector(key)
            if sectorDist(sec, x, y) <= R then sectors[key] = sec end
          end
        end
      end
    end
  end
  local drop, hide = nil, nil
  local cacheMax = cfg.cacheMax or 0
  for key, sec in pairs(sectors) do
    if #sec.handovers == 0 and not (job and job.sec == sec) then
      if not hasContent(key) then
        drop = drop or {}
        drop[#drop + 1] = sec
      elseif not sec.hidden and minExcess(sec) > cfg.unloadMargin then
        if cacheMax > 0 and sec.built and sec.obj then
          hide = hide or {}
          hide[#hide + 1] = sec
        else
          drop = drop or {}
          drop[#drop + 1] = sec
        end
      end
    end
  end
  if hide then for _, s in ipairs(hide) do hideSector(s) end end
  if nHidden > cacheMax then
    -- over the cap: unload the sectors hidden longest ago
    local list = {}
    for _, sec in pairs(sectors) do
      if sec.hidden and #sec.handovers == 0 and not (job and job.sec == sec) then list[#list + 1] = sec end
    end
    table.sort(list, function(a, b) return a.hiddenT < b.hiddenT end)
    for i = 1, min(#list, nHidden - cacheMax) do
      drop = drop or {}
      drop[#drop + 1] = list[i]
    end
  end
  if drop then
    for _, s in ipairs(drop) do
      if s.hidden then nHidden = nHidden - 1 end
      unload(s)
    end
  end
end

function M.markDirty(sk, urgent)
  local sec = sectors[sk]
  if not sec then return end
  sec.dirty = true
  if urgent then
    sec.urgent = true
    -- time until a build that started after this mark has been presented (hidden ruts)
    sec.urgentSince = sec.urgentSince or os.clock()
  end
end

function M.markAllDirty()
  for _, sec in pairs(sectors) do sec.dirty = true end
end

-- A tile mesh leaves the active ring. A handover to an unloaded sector loads it.
function M.handover(sk, obj, tileKey)
  local sec = sectors[sk]
  if not sec then
    sec = newSector(sk)
    sectors[sk] = sec
  end
  sec.handovers[#sec.handovers + 1] = { obj = obj, key = tileKey, cancelled = false }
  sec.dirty = true
end

-- A tile becomes active again before its sector was rebuilt: give its mesh back.
function M.reclaim(sk, tileKey)
  local sec = sectors[sk]
  if not sec then return nil end
  for i = #sec.handovers, 1, -1 do
    local h = sec.handovers[i]
    if h.key == tileKey and not h.cancelled then
      h.cancelled = true
      table.remove(sec.handovers, i)
      return h.obj
    end
  end
  if job and job.sec == sec then
    for _, h in ipairs(job.snapshot) do
      if h.key == tileKey and not h.cancelled then
        h.cancelled = true
        return h.obj
      end
    end
  end
  return nil
end

-- 'shown', 'hidden' (kept in the cache) or nil (not loaded)
function M.sectorState(sk)
  local sec = sectors[sk]
  if not sec then return nil end
  return sec.hidden and 'hidden' or 'shown'
end

function M.isLoaded(sk)
  local sec = sectors[sk]
  return sec ~= nil and sec.built
end

local function overBudget()
  return frameTimer:stop() > budget
end

local function buildBody(j)
  local main = ctx
  local sec = j.sec
  local b = j.builder
  local t_m = tm()
  b:reset()
  local drop = -main.cfg.sectors.drop
  -- terrain-first: the tile lift is a few mm over the terrain; a sector sits between the
  -- terrain and the tiles, so it never sinks under the (flush) terrain next to it
  if main.terrainFirst() then
    drop = -min(main.cfg.sectors.drop, 0.5 * (main.cfg.tiles.terrainFirstLift or 0.006))
  end
  local SEC, KEY = main.sec, main.KEY
  local dec = extensions and extensions.deepnode_decals
  local tx0, ty0 = sec.sx * SEC, sec.sy * SEC
  for ty = ty0, ty0 + SEC - 1 do
    for tx = tx0, tx0 + SEC - 1 do
      local key = ty * KEY + tx
      if not j.exclude[key] then
        local t = main.tiles[key]
        if t and (t.state == 'frozen' or t.rutted) then
          t_m.emitTileCells(b, t, drop, main.borderRule(t, true), main.cfg.sectors.frozenCellStride)
        else
          t_m.emitTerrainSquares(b, tx, ty, drop)
        end
        -- decal overlay of this tile's triangles, inside the build's time slices, on
        -- whole untouched squares only: a frozen tile here (beyond
        -- ring.frozenOwnMeshRadius from the camera, drawn at frozenCellStride) has
        -- none; decals on its cells doubled the sector uploads (550 -> 1200 vertices)
        if dec then dec.overlay(b, true, key) end
      end
      if j.check() then coroutine.yield() end
    end
  end
  return b:finish()
end

local function startBuild(sec, sync)
  local b = table.remove(freeBuilders) or tm().newBuilder()
  local j = { sec = sec, builder = b, snapshot = sec.handovers, exclude = {}, frames = 0, timer = newTimer(),
    urgentSince = sec.urgentSince }
  sec.urgentSince = nil
  sec.handovers = {}
  sec.dirty = false
  sec.urgent = false
  local SEC, KEY = ctx.sec, ctx.KEY
  for ty = sec.sy * SEC, sec.sy * SEC + SEC - 1 do
    for tx = sec.sx * SEC, sec.sx * SEC + SEC - 1 do
      local t = ctx.tiles[ty * KEY + tx]
      -- a rutted tile with its own mesh (active, or frozen near the camera) is left out;
      -- an untouched one is drawn here too (same surface, 1.5 cm lower, under its mesh)
      if t and t.obj and t.rutted then j.exclude[ty * KEY + tx] = true end
    end
  end
  if sync then j.check = function() return false end else j.check = overBudget end
  j.co = coroutine.create(function() return buildBody(j) end)
  job = j
end

local function finishBuild(j, meshes, failed)
  job = nil
  freeBuilders[#freeBuilders + 1] = j.builder
  local sec = j.sec
  local t_m = tm()
  if failed or meshes == nil then
    stats.failed = stats.failed + 1
    sec.failures = sec.failures + 1
    if sec.failures < 3 then
      -- keep the old mesh and the pending handovers; try again
      for _, h in ipairs(j.snapshot) do
        if not h.cancelled then sec.handovers[#sec.handovers + 1] = h end
      end
      sec.dirty = true
      if j.urgentSince then sec.urgent = true; sec.urgentSince = sec.urgentSince or j.urgentSince end
      return
    end
    log('W', 'deepnode', 'sector ' .. sec.sx .. ',' .. sec.sy .. ' failed to build 3 times, dropping its handovers')
  else
    sec.failures = 0
    t_m.present(sec, meshes)
    if sec.hidden and sec.obj then sec.obj:setHidden(true) end
    -- which tiles this sector now leaves out (main: ruts of a tile still drawn by its
    -- sector are hidden, see rebuildTiles)
    local SEC, KEY = ctx.sec, ctx.KEY
    for ty = sec.sy * SEC, sec.sy * SEC + SEC - 1 do
      for tx = sec.sx * SEC, sec.sx * SEC + SEC - 1 do
        local t = ctx.tiles[ty * KEY + tx]
        if t then t.secOut = j.exclude[ty * KEY + tx] == true end
      end
    end
    sec.built = true
    sec.lastBuildT = os.clock()
    if j.urgentSince then
      local w = sec.lastBuildT - j.urgentSince
      stats.urgentWaitLast = w
      stats.urgentWaitSum = stats.urgentWaitSum + w
      stats.urgentWaits = stats.urgentWaits + 1
      if w > stats.urgentWaitMax then stats.urgentWaitMax = w end
    end
  end
  stats.builds = stats.builds + 1
  -- builds per priority tier (see tierOf; 9 = level start / sync)
  local tk = j.tier or 9
  stats.byTier[tk] = (stats.byTier[tk] or 0) + 1
  stats.lastBuildMs = j.timer:stop()
  if j.frames > stats.maxBuildFrames then stats.maxBuildFrames = j.frames end
  -- handover callbacks run only after the sector was rebuilt
  for _, h in ipairs(j.snapshot) do
    if not h.cancelled then t_m.deferRelease(h.obj) end
  end
end

-- A built sector mesh waits for a frame whose upload budget (tileMesh.canUpload) has
-- room for it. After UPLOAD_WAIT frames it reserves the next frame, so it uploads alone:
-- a 2000-vertex sector is a 4-6 ms upload, and together with tile or tyre uploads in
-- the same frame it made the frame rate dip (measured: 8-9 ms of uploads in one frame).
local UPLOAD_WAIT = 4
local function uploadAllowed(j, meshes)
  local nv = 0
  for i = 1, #meshes do nv = nv + #meshes[i].verts end
  local t_m = tm()
  if t_m.canUpload('S', nv) then return true end
  j.uploadWait = (j.uploadWait or 0) + 1
  if j.uploadWait > UPLOAD_WAIT and t_m.reserveFrame then t_m.reserveFrame('S') end
  return false
end

-- resume the current build; returns true when it finished. force: upload at once
-- (level start)
local function stepBuild(force)
  local j = job
  j.frames = j.frames + 1
  if j.ready then
    if not force and not uploadAllowed(j, j.ready) then return false end
    local meshes = j.ready
    j.ready = nil
    finishBuild(j, meshes, false)
    return true
  end
  local ok, res = coroutine.resume(j.co)
  if not ok then
    log('E', 'deepnode', 'sector build error: ' .. tostring(debug.traceback(j.co, tostring(res))))
    finishBuild(j, nil, true)
    return true
  end
  if coroutine.status(j.co) == 'dead' then
    if res and #res > 0 and not force and not uploadAllowed(j, res) then
      j.ready = res
      return false
    end
    finishBuild(j, res, false)
    return true
  end
  return false
end

-- Distance within which a sector counts as "at the vehicle": its rebuild is visible now.
local function nearRadius()
  local cfg = ctx.cfg
  return cfg.sectors.nearRadius or 40
end

-- Rebuild priority tier (lower first):
--  0 urgent and near: a tile under or ahead of the wheels got its own mesh; until the
--    sector leaves it out, fresh ruts stay hidden under the sector surface (flat mud)
--  1 never built and near: visible hole in the lowered terrain
--  2 pending handovers: old tile meshes hold pool objects until this rebuild
--  3 urgent, far
--  4 never built, far (sectors entering the load radius; 100+ m away)
--  5 any other change
-- Before, every unbuilt sector in the whole load radius came first. At speed new
-- sectors enter the 300 m radius all the time, so the urgent sector under the wheels
-- waited until the vehicle slowed down, and handovers piled up in the pool.
local function tierOf(sec, d, near)
  local isNear = d <= near
  if sec.urgent and isNear then return 0 end
  if not sec.built and isNear then return 1 end
  if #sec.handovers > 0 then return 2 end
  if sec.urgent then return 3 end
  if not sec.built then return 4 end
  return 5
end
M.tierOfForTests = function(sec, d, near) return tierOf(sec, d, near) end

local function pickNext()
  local best, bestScore, bestTier = nil, huge, nil
  -- A built sector waits minRebuildGap before its next rebuild, so changes batch into
  -- one build (every mesh replace costs engine memory that is never given back; the
  -- tile meshes stay visible until the sector catches up).
  local now = os.clock()
  local gap = ctx.cfg.sectors.minRebuildGap or 0
  local near = nearRadius()
  -- urgent marks wait sectors.urgentBatch s so the tiles a truck digs one after the
  -- other in the same sector go in one rebuild (~4 urgent re-meshes/s with one truck)
  local batch = ctx.cfg.sectors.urgentBatch or 0
  for _, sec in pairs(sectors) do
    -- urgent: a tile just got its own mesh and must be left out now (else its ruts stay
    -- hidden under the sector surface), so the gap does not apply
    local ready
    if not sec.built then ready = true
    elseif sec.urgent then ready = now - (sec.urgentSince or now) >= batch
    else ready = now - (sec.lastBuildT or -huge) >= gap end
    if sec.dirty and ready and (not sec.hidden or #sec.handovers > 0) then
      local d = minDist(sec)
      local tier = tierOf(sec, d, near)
      local score = tier * 1e7 + min(d, 1e6)
      if score < bestScore then best, bestScore, bestTier = sec, score, tier end
    end
  end
  return best, bestTier
end

function M.update(dt, camx, camy, vehCenters)
  if not ctx then return end
  frameTimer = newTimer()
  budget = ctx.private and ctx.private.sectorBudget or ctx.cfg.sectors.buildBudgetMs
  setPoints(camx, camy, vehCenters)
  refreshTimer = refreshTimer - (dt or 0)
  if refreshTimer <= 0 then
    refreshTimer = ctx.cfg.sectors.refreshInterval
    refreshLoaded()
  end
  -- catch-up: a sector near a vehicle that is unbuilt (hole) or urgent (hidden ruts)
  -- gets a bigger time budget, also while an older job must finish first
  local catchUp = ctx.cfg.sectors.catchUpBudgetMs
  if catchUp and ctx.private and ctx.private.sectorBudget then
    catchUp = min(catchUp, 1.5 * ctx.private.sectorBudget)
  end
  if catchUp and catchUp > budget then
    local near = nearRadius()
    local hurry = false
    for _, sec in pairs(sectors) do
      if sec.dirty and (sec.urgent or not sec.built) and minDist(sec) <= near then hurry = true; break end
    end
    if not hurry and job and job.tier and job.tier <= 1 then hurry = true end
    if hurry then budget = catchUp end
  end
  local reserve = ctx.cfg.ring.prebuildReserve or 0
  local guard = 0
  while guard < 16 and not overBudget() do
    guard = guard + 1
    if not job then
      local s, tier = pickNext()
      if not s then break end
      -- shared mesh replace cap with the tiles (unbuilt and urgent sectors are never
      -- held back). Plain rebuilds also leave the tiles' reserve alone, so a tile being
      -- dug never waits for a sector refresh.
      -- (handovers neither: until the rebuild the old tile meshes hold pool objects)
      if s.built and not s.urgent and #s.handovers == 0 and ctx.takeBuildToken then
        local r = (tier == 5) and reserve or 0
        if not ctx.takeBuildToken(r) then break end
      end
      startBuild(s, false)
      job.tier = tier
    end
    if not stepBuild() then break end
  end
end

-- Level start: build every sector within `radius` synchronously, nearest first.
function M.buildSync(radius, camx, camy, vehCenters)
  setPoints(camx, camy, vehCenters)
  refreshLoaded()
  local list = {}
  for _, sec in pairs(sectors) do
    local d = minDist(sec)
    if d <= radius then list[#list + 1] = { sec = sec, d = d } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  for _, e in ipairs(list) do
    startBuild(e.sec, true)
    local guard = 0
    while job and guard < 1000 do
      guard = guard + 1
      stepBuild(true)
    end
  end
end

function M.start(main)
  ctx = main
  sectors = {}
  nHidden = 0
  job = nil
  refreshTimer = 0
  stats.builds, stats.failed = 0, 0
  stats.urgentWaitLast, stats.urgentWaitMax, stats.urgentWaitSum, stats.urgentWaits = 0, 0, 0, 0
end

-- Pooled objects are deleted by tileMesh.destroyAll; only drop references here.
function M.stop(objectsAlive)
  job = nil
  sectors = {}
  nHidden = 0
  freeBuilders = {}
end

-- Debug overlay: every loaded sector with its distance to the nearest vehicle or
-- look-ahead point and whether it counts as near (rebuild priority, see tierOf).
function M.debugSectors(out)
  local near = ctx and nearRadius() or 40
  local n = 0
  for _, sec in pairs(sectors) do
    n = n + 1
    local e = out[n] or {}
    out[n] = e
    e.key, e.sx, e.sy = sec.key, sec.sx, sec.sy
    e.built = sec.built and sec.obj ~= nil
    e.dist = minDist(sec)
    e.near = e.dist <= near
    e.urgent = sec.urgent
    e.building = job ~= nil and job.sec == sec
  end
  for k = n + 1, #out do out[k] = nil end
  return n
end

function M.stats()
  local loaded, built, pending = 0, 0, 0
  for _, sec in pairs(sectors) do
    loaded = loaded + 1
    if sec.built and sec.obj then built = built + 1 end
    pending = pending + #sec.handovers
  end
  return { loaded = loaded, hidden = nHidden, built = built, byTier = stats.byTier, pendingHandovers = pending, builds = stats.builds,
    failed = stats.failed, building = job ~= nil, lastBuildMs = stats.lastBuildMs, maxBuildFrames = stats.maxBuildFrames,
    urgentWaitLast = stats.urgentWaitLast, urgentWaitMax = stats.urgentWaitMax, urgentWaits = stats.urgentWaits,
    urgentWaitAvg = stats.urgentWaits > 0 and stats.urgentWaitSum / stats.urgentWaits or 0 }
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
