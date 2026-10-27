-- deepmud_tileMesh
-- Patch mesh building and the shared pool of pre-created ProceduralMesh objects.
--
-- Engine facts used here (confirmed in the shipped 0.39 Lua):
--  * ProceduralMesh:createMesh(lods): lods = { { submesh, submesh, ... } } (one LOD).
--    submesh = { verts = {{x,y,z}}, normals = {{x,y,z}}, uvs = {{u,v}},
--                faces = {{v=,n=,u=}} with 0-based indices, material = name }.
--    lua/ge/extensions/editor/tech/roadArchitect/roadMesh.lua:146-151 and :351,
--    lua/ge/extensions/util/trackBuilder/proceduralPrimitives.lua:650-669.
--  * createMesh can be called again on the same object to replace the geometry:
--    lua/ge/extensions/util/trackBuilder/segmentToProceduralMesh.lua:42.
--  * Front faces are clockwise seen from outside. The shipped icosphere triangle
--    {0,4,1} (proceduralPrimitives.lua:626-631) has its right-hand normal pointing
--    inward, and roadMesh.lua:111 builds normals as -(b-a)x(c-a). For a ground
--    patch, "outside" is above, so every triangle here is clockwise seen from above.
--    The offline test checks this; verify once in game (patch visible from above).
--  * Objects are created with createObject + registerObject and added to a group
--    with addObject(obj.obj): roadMesh.lua:347-350, techCore.lua:292-296.
--  * scene objects hide with :setHidden(bool) (gameplay drag lights, setHidden(true)).

local M = {}

local ffi = require('ffi')
local bit = require('bit')

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local sfmt = string.format

-- Split a submesh before it reaches this many vertices. The engine uses 16-bit
-- indices for small meshes; 60k keeps a safe margin (pitfall 10).
local MAX_SUB_VERTS = 60000
-- The engine also expands every face corner (3 per triangle) with a 16-bit counter:
-- a submesh with more than 65535 corners hangs the game forever (measured in game:
-- main thread spinning in a uint16 loop with 66000 corners from a rutted sector).
-- Split before MAX_SUB_CORNERS; reserve assumes at most 6 corners per vertex
-- (2 triangles per grid vertex). A submesh still over HARD_CORNERS is dropped.
local MAX_SUB_CORNERS = 60000
local HARD_CORNERS = 65000

local ctx = nil -- deepmud_main, set by setContext

local stats = { created = 0, inUse = 0, builds = 0, rejected = 0, peakInUse = 0 }

-- Geometry held per object (a hidden pooled object keeps its last mesh until it gets a
-- new one), for the debug memory estimate: vertices and triangle corners.
local geo = setmetatable({}, { __mode = 'k' })
local geoVerts, geoCorners = 0, 0
local function setGeometry(o, meshes)
  local nv, nc = 0, 0
  for i = 1, #meshes do
    nv = nv + #meshes[i].verts
    nc = nc + #meshes[i].faces
  end
  local g = geo[o]
  if g then
    geoVerts, geoCorners = geoVerts - g[1], geoCorners - g[2]
    g[1], g[2] = nv, nc
  else
    geo[o] = { nv, nc }
  end
  geoVerts, geoCorners = geoVerts + nv, geoCorners + nc
  return nv
end
M.setGeometry = setGeometry
-- vertices, corners held by every mesh object the mod tracks
function M.geometry() return geoVerts, geoCorners end
function M.forgetGeometry(o)
  local g = geo[o]
  if g then geoVerts, geoCorners = geoVerts - g[1], geoCorners - g[2]; geo[o] = nil end
end

local function isFinite(v)
  return v == v and v > -1e7 and v < 1e7
end
M.isFinite = isFinite

-------------------------------------------------------------------------------
-- deterministic hash in [0,1] from integer grid coordinates (world-space jitter)
-------------------------------------------------------------------------------
local bxor, rshift, band, tobit = bit.bxor, bit.rshift, bit.band, bit.tobit
local function hash01(ix, iy, salt)
  local h = bxor(tobit(ix * 374761393), tobit(iy * 668265263), salt or 0)
  h = tobit(bxor(h, rshift(h, 13)) * 1274126177)
  h = bxor(h, rshift(h, 16))
  return band(h, 0xffff) / 65535
end
M.hash01 = hash01

-------------------------------------------------------------------------------
-- object pool
-------------------------------------------------------------------------------
local pool = { free = {}, all = {}, count = 0, group = nil, session = 0 }
local deferred, deferredFrame = {}, {}
local frameNo = 0
local identity = nil

local function addToGroup(o)
  local grp = pool.group or scenetree.MissionGroup
  if grp then
    if grp.addObject then grp:addObject(o.obj) elseif grp.add then grp:add(o.obj) end
  end
end

local function createPooledObject()
  local o = createObject('ProceduralMesh')
  if not o then return nil end
  pool.count = pool.count + 1
  pool.serial = (pool.serial or 0) + 1 -- names never repeat, even after trimPool
  o.canSave = false
  o:registerObject(sfmt('deepmud_pm_%d_%d', pool.session, pool.serial))
  addToGroup(o)
  o:setPosition(vec3(0, 0, 0))
  o:setHidden(true)
  pool.all[#pool.all + 1] = o
  stats.created = stats.created + 1
  return o
end

-- Create the object group and `n` pooled objects. Called once at level start.
function M.initPool(n, session)
  pool.session = session or 0
  if not pool.group then
    local g = createObject('SimGroup')
    if g then
      g.canSave = false
      g:registerObject(sfmt('deepmud_objects_%d', pool.session))
      if scenetree.MissionGroup then scenetree.MissionGroup:addObject(g.obj) end
      pool.group = g
    end
  end
  identity = MatrixF(true)
  for _ = 1, n do
    local o = createPooledObject()
    if not o then break end
    pool.free[#pool.free + 1] = o
  end
end

function M.getGroup() return pool.group end

local growStep = 16
function M.setGrowStep(n) growStep = max(1, n or 16) end

local function acquire()
  local o = table.remove(pool.free)
  if not o then
    -- pool exhausted: grow in a small batch (logged, should not happen with a sized pool)
    log('W', 'deepmud', 'mesh pool exhausted, growing by ' .. growStep)
    for _ = 1, growStep do
      local p = createPooledObject()
      if p then pool.free[#pool.free + 1] = p end
    end
    o = table.remove(pool.free)
    if not o then return nil end
  end
  stats.inUse = stats.inUse + 1
  if stats.inUse > stats.peakInUse then stats.peakInUse = stats.inUse end
  return o
end
M.acquire = acquire

local function release(o)
  if not o then return end
  o:setHidden(true)
  -- pitfall 12: never let a recycled object carry a transform into a world-space mesh
  if identity then o:setTransform(identity) end
  pool.free[#pool.free + 1] = o
  stats.inUse = stats.inUse - 1
end
M.release = release

-- Queue an object to be hidden and returned to the pool on the next frame, so the
-- replacement mesh is already visible when the old one disappears (no flicker).
local deferredChunk = {}
local function deferRelease(o)
  if not o then return end
  deferred[#deferred + 1] = o
  deferredFrame[#deferredFrame + 1] = frameNo
  deferredChunk[#deferred] = false
end
M.deferRelease = deferRelease

-- Paired buffers (pool.mode = 'pair'): the replaced object is hidden on the next frame
-- and kept by its chunk as the spare for the chunk's next upload, instead of going back
-- to the shared pool. Each chunk alternates between the same two objects.
local function deferSpare(o, chunk)
  deferred[#deferred + 1] = o
  deferredFrame[#deferredFrame + 1] = frameNo
  deferredChunk[#deferred] = chunk
end

-- a chunk gives up its meshes (released, handed over, unloaded): its spare goes back
function M.dropSpare(chunk)
  if chunk and chunk.spare then
    release(chunk.spare)
    chunk.spare = nil
  end
end

-- mesh uploads (createMesh) this frame, shared with the tyre mud so one frame does not
-- take several big uploads at once
local frameUploads = 0
function M.uploadsThisFrame() return frameUploads end
function M.frame() return frameNo end
function M.noteUpload() frameUploads = frameUploads + 1 end

-- Upload budget, shared by tiles (T), sectors (S) and tyre mud (C): on average no more
-- than `uploadBudget` ms of createMesh per frame. Measured in game with 6 trucks
-- digging: a createMesh costs about 0.1 ms + 2.9 us per vertex for tiles, 2.0 us for
-- sectors; frames that took two tile uploads, a sector and a tyre skin ran 15-20 ms of
-- uploads and dropped to 45 fps. The cost per vertex is learned from every upload.
-- An account gains the budget every frame (it holds at most two frames' worth); an
-- upload goes ahead while the account is positive and its estimate fits, or while
-- nothing was uploaded this frame and the account is positive; it is charged the
-- measured time. A 6 ms sector upload so leaves the next frames without uploads
-- until it is paid back. main adapts the budget to the frame rate (perf.*).
local frameUploadMs = 0
local uploadBudget = 3
local account = 0
local COST_BASE = 0.1
local costPerVert = { T = 0.0029, S = 0.0020, C = 0.0025 }
function M.setUploadBudget(ms) uploadBudget = ms end
function M.uploadBudget() return uploadBudget end
function M.uploadAccount() return account end
function M.uploadMsThisFrame() return frameUploadMs end
function M.estimateUpload(kind, verts) return COST_BASE + (costPerVert[kind] or 0.003) * (verts or 0) end
-- An upload that waited too long reserves the next frame for itself: then nothing else
-- uploads before it, and it runs alone, whatever the account says (it is still charged).
local reserved, reserveNext = nil, nil
function M.reserveFrame(kind) reserveNext = reserveNext or kind end
-- Uploads only every uploadEvery-th frame (perf.uploadEvery), with the budget of the
-- frames between: tested because every mesh upload also costs engine time outside
-- createMesh (shadow/reflection passes, measured +0.5 ms each while uploads run).
local uploadEvery = 1
function M.setUploadEvery(n) uploadEvery = max(1, floor(n or 1)) end
function M.canUpload(kind, verts)
  if uploadEvery > 1 and frameNo % uploadEvery ~= 0 then return false end
  if reserved then return reserved == kind and frameUploads == 0 end
  if account <= 0 then return false end
  if frameUploads == 0 then return true end
  return M.estimateUpload(kind, verts) <= account
end
function M.recordUpload(kind, verts, ms)
  if reserved == kind then reserved = nil end
  frameUploads = frameUploads + 1
  frameUploadMs = frameUploadMs + ms
  account = account - ms
  if verts and verts > 50 and ms > 0 and ms < 50 then
    local k = max(0, ms - COST_BASE) / verts
    costPerVert[kind] = (costPerVert[kind] or k) * 0.9 + k * 0.1
  end
end
function M.uploadCosts() return costPerVert end

-- Call once at the start of every frame.
function M.processDeferred()
  frameNo = frameNo + 1
  frameUploads = 0
  frameUploadMs = 0
  account = math.min(account + uploadBudget, (uploadEvery + 1) * uploadBudget)
  -- a reservation holds for one frame; an unused one is dropped
  reserved, reserveNext = reserveNext, nil
  local w = 0
  local n = #deferred
  for i = 1, n do
    local o, f, ch = deferred[i], deferredFrame[i], deferredChunk[i]
    if f < frameNo then
      if ch and ch.obj and ch.obj ~= o and not ch.spare then
        -- still in use by its chunk: keep as the spare (hidden, geometry kept)
        o:setHidden(true)
        ch.spare = o
      else
        release(o)
      end
    else
      w = w + 1
      deferred[w], deferredFrame[w], deferredChunk[w] = o, f, ch
    end
  end
  for i = w + 1, n do deferred[i], deferredFrame[i], deferredChunk[i] = nil, nil, nil end
end

-- Size classes. Engine memory grows with every DIFFERENT mesh size uploaded: measured
-- in game (2 objects, alternating uploads, physics paused): one fixed size 0.4-1 KB per
-- upload, sizes spread over 100-3700 vertices 22-31 KB per upload and still growing,
-- the same sizes rounded up to powers of two 9 KB. So every submesh is padded before
-- createMesh: a tile to one of three tile size classes, a sector to the next power
-- of two. Padding = copies of the first vertex and degenerate
-- triangles on vertex 0 (nothing drawn, bounds unchanged); removed again after upload.
local PAD_N = { x = 0, y = 0, z = 1 }
local PAD_UV = { u = 0, v = 0 }
local PAD_F = { v = 0, n = 0, u = 0 }
local function pow2(n, lo)
  local c = lo
  while c < n do c = c * 2 end
  return c
end
local padLen = {}
local function padMeshes(chunk, meshes)
  local tileN = not chunk.sx and chunk.N
  for i = 1, #meshes do
    local m = meshes[i]
    local nv, nc = #m.verts, #m.faces
    padLen[2 * i - 1], padLen[2 * i] = nv, nc
    local capV, capC
    local maxV, maxC = tileN and (tileN + 1) * (tileN + 1), tileN and 6 * tileN * tileN
    if m.material:sub(1, 12) == 'deepmud_dec_' then
      -- decal overlay (deepmud_decals): small, own power-of-two classes
      capC = pow2(max(nc, 4 * nv), 384)
      capV = capC / 4
    elseif tileN and nv <= maxV and nc <= maxC then
      -- three tile classes (1/3, 2/3, all of the largest tile): createMesh costs ~0.3 ms
      -- + 0.3 us per corner, padding every tile to the largest one cost +35 %
      local k = max(math.ceil(3 * nv / maxV), math.ceil(3 * nc / maxC), 1)
      capV, capC = math.ceil(maxV * k / 3), math.ceil(maxC * k / 3)
    else
      -- one (verts, corners) pair per class: corners 3072 * 2^k, verts a quarter of that
      -- (a grid mesh has ~5 corners per vertex), so sizes do not combine freely
      capC = pow2(max(nc, 4 * nv), 3072)
      capV = capC / 4
    end
    if nv > 0 and (capV > nv or capC > nc) then
      local v1 = m.verts[1]
      local pv = { x = v1.x, y = v1.y, z = v1.z }
      local verts, normals, uvs, faces = m.verts, m.normals, m.uvs, m.faces
      for k = nv + 1, capV do verts[k] = pv; normals[k] = PAD_N; uvs[k] = PAD_UV end
      for k = nc + 1, capC do faces[k] = PAD_F end
    end
  end
end
local function unpadMeshes(meshes)
  for i = 1, #meshes do
    local m = meshes[i]
    local nv, nc = padLen[2 * i - 1], padLen[2 * i]
    local verts, normals, uvs, faces = m.verts, m.normals, m.uvs, m.faces
    for k = #verts, nv + 1, -1 do verts[k] = nil; normals[k] = nil; uvs[k] = nil end
    for k = #faces, nc + 1, -1 do faces[k] = nil end
  end
end

-- Show `meshes` (array of submeshes) for a chunk that owns at most one pooled
-- object in chunk.obj. nil = rejected build (keep the old mesh), {} = nothing to draw.
function M.present(chunk, meshes)
  if meshes == nil then
    stats.rejected = stats.rejected + 1
    return false
  end
  if #meshes == 0 then
    if chunk.obj then deferRelease(chunk.obj); chunk.obj = nil end
    M.dropSpare(chunk)
    return true
  end
  -- The new mesh always goes to a hidden object and is shown at once; the replaced one
  -- is hidden on the next frame. Replacing the geometry of the visible object in place
  -- left the chunk undrawn for a frame (measured in game: the rut tile vanished in every
  -- other frame while rebuilding, i.e. flicker).
  local mode = ctx and ctx.cfg.pool and ctx.cfg.pool.mode or 'pair'
  local o = nil
  if mode == 'pair' and chunk.spare then o = chunk.spare; chunk.spare = nil end
  o = o or acquire()
  if not o then return false end
  local timer = hptimer and hptimer()
  local nv = setGeometry(o, meshes)
  padMeshes(chunk, meshes)
  o:createMesh({ meshes })
  unpadMeshes(meshes)
  M.recordUpload(chunk.sx and 'S' or 'T', nv, timer and timer:stop() or 1)
  chunk.lastVerts = nv
  o:setHidden(false)
  if chunk.obj then
    if mode == 'pair' then deferSpare(chunk.obj, chunk) else deferRelease(chunk.obj) end
  end
  chunk.obj = o
  stats.builds = stats.builds + 1
  return true
end

-- Delete every pooled object. `objectsAlive` = false after the level was unloaded
-- (onClientEndMission): the engine already deleted them, only drop references.
function M.destroyAll(objectsAlive)
  if objectsAlive then
    for _, o in ipairs(pool.all) do o:delete() end
    if pool.group then pool.group:delete() end
  end
  pool.free, pool.all, pool.count, pool.group = {}, {}, 0, nil
  deferred, deferredFrame, deferredChunk = {}, {}, {}
  geo = setmetatable({}, { __mode = 'k' })
  geoVerts, geoCorners = 0, 0
  stats.inUse, stats.created, stats.peakInUse = 0, 0, 0
end

function M.stats()
  return stats.created, stats.inUse, #pool.free, stats.builds, stats.rejected, stats.peakInUse
end

-- Memory flush: free pooled objects keep the geometry of their last use while hidden;
-- give them an empty mesh, and delete the free objects beyond `keep` in total.
-- Returns cleared, deleted.
function M.trimPool(keep)
  local cleared, deleted = 0, 0
  local free = pool.free
  for i = #free, 1, -1 do
    local o = free[i]
    if pool.count - deleted > (keep or 0) then
      table.remove(free, i)
      for j = #pool.all, 1, -1 do
        if pool.all[j] == o then table.remove(pool.all, j); break end
      end
      M.forgetGeometry(o)
      o:delete()
      deleted = deleted + 1
    elseif geo[o] then
      o:createMesh({})
      M.forgetGeometry(o)
      cleared = cleared + 1
    end
  end
  pool.count = pool.count - deleted
  stats.created = stats.created - deleted
  return cleared, deleted
end

-------------------------------------------------------------------------------
-- submesh accumulator with table reuse (keeps GC pressure low)
-------------------------------------------------------------------------------
local Sub = {}
Sub.__index = Sub

local function trunc(arr, n, stash)
  for i = #arr, n + 1, -1 do
    stash[#stash + 1] = arr[i]
    arr[i] = nil
  end
end

local function restore(arr, stash)
  for i = #stash, 1, -1 do
    arr[#arr + 1] = stash[i]
    stash[i] = nil
  end
end

local function newSub()
  return setmetatable({ verts = {}, normals = {}, uvs = {}, faces = {},
    sv = {}, sn = {}, su = {}, sf = {}, nv = 0, nf = 0, bad = false, material = '' }, Sub)
end

function Sub:reset(material)
  self.material = material
  restore(self.verts, self.sv); restore(self.normals, self.sn)
  restore(self.uvs, self.su); restore(self.faces, self.sf)
  self.nv, self.nf, self.bad = 0, 0, false
  self.decalDone = 0 -- faces already given their decal overlay (deepmud_decals)
end

-- Add a vertex; returns its 0-based index. Non-finite input marks the whole build
-- as bad: it is dropped instead of reaching the engine (pitfall 2).
function Sub:vert(x, y, z, nx, ny, nz, u, v)
  if not (isFinite(x) and isFinite(y) and isFinite(z) and isFinite(nx) and isFinite(ny)
      and isFinite(nz) and isFinite(u) and isFinite(v)) then
    self.bad = true
    x, y, z, nx, ny, nz, u, v = 0, 0, 0, 0, 0, 1, 0, 0
  end
  local n = self.nv + 1
  self.nv = n
  local t = self.verts[n]
  if t then t.x, t.y, t.z = x, y, z else self.verts[n] = { x = x, y = y, z = z } end
  t = self.normals[n]
  if t then t.x, t.y, t.z = nx, ny, nz else self.normals[n] = { x = nx, y = ny, z = nz } end
  t = self.uvs[n]
  if t then t.u, t.v = u, v else self.uvs[n] = { u = u, v = v } end
  return n - 1
end

-- Triangle from 0-based vertex indices, already in front-face (clockwise) order.
function Sub:tri(a, b, c)
  local f = self.faces
  local n = self.nf
  local t = f[n + 1]
  if t then t.v, t.n, t.u = a, a, a else f[n + 1] = { v = a, n = a, u = a } end
  t = f[n + 2]
  if t then t.v, t.n, t.u = b, b, b else f[n + 2] = { v = b, n = b, u = b } end
  t = f[n + 3]
  if t then t.v, t.n, t.u = c, c, c else f[n + 3] = { v = c, n = c, u = c } end
  self.nf = n + 3
end

function Sub:finish()
  trunc(self.verts, self.nv, self.sv); trunc(self.normals, self.nv, self.sn)
  trunc(self.uvs, self.nv, self.su); trunc(self.faces, self.nf, self.sf)
  return { verts = self.verts, normals = self.normals, uvs = self.uvs, faces = self.faces, material = self.material }
end

local Builder = {}
Builder.__index = Builder

function M.newBuilder()
  return setmetatable({ subs = {}, nsub = 0, byMat = {}, freeSubs = {} }, Builder)
end

function Builder:reset()
  for i = 1, self.nsub do
    self.freeSubs[#self.freeSubs + 1] = self.subs[i]
    self.subs[i] = nil
  end
  self.nsub = 0
  for k in pairs(self.byMat) do self.byMat[k] = nil end
end

-- Submesh for `material` with room for `reserve` more vertices.
function Builder:sub(material, reserve)
  local s = self.byMat[material]
  local r = reserve or 0
  if s and s.nv + r <= MAX_SUB_VERTS and s.nf + 6 * r <= MAX_SUB_CORNERS then return s end
  s = table.remove(self.freeSubs) or newSub()
  s:reset(material)
  self.nsub = self.nsub + 1
  self.subs[self.nsub] = s
  self.byMat[material] = s
  return s
end

function Builder:vertexCount()
  local n = 0
  for i = 1, self.nsub do n = n + self.subs[i].nv end
  return n
end

-- Array of submesh tables, {} when empty, nil when any vertex was invalid.
function Builder:finish()
  for i = 1, self.nsub do
    local s = self.subs[i]
    if s.bad then return nil end
    if s.nf > HARD_CORNERS or s.nv > HARD_CORNERS then
      log('E', 'deepmud', sfmt('submesh %s too big (%d verts, %d corners): dropped', s.material, s.nv, s.nf))
      return nil
    end
  end
  local out = {}
  for i = 1, self.nsub do
    local s = self.subs[i]
    if s.nf > 0 then out[#out + 1] = s:finish() end
  end
  return out
end

-------------------------------------------------------------------------------
-- patch emitters
-------------------------------------------------------------------------------
local bufN = 0
local zbuf, vidx = nil, nil
local function ensure(n)
  if n > bufN then
    bufN = n
    zbuf = ffi.new('float[?]', n)
    vidx = ffi.new('int32_t[?]', n)
  end
end

local terrN = 0
local tRest, tPatched, tMat = nil, nil, nil
local function ensureTerrain(ts)
  local n = (ts + 1) * (ts + 1)
  if n > terrN then
    terrN = n
    tRest = ffi.new('float[?]', n)
    tPatched = ffi.new('uint8_t[?]', n)
    tMat = ffi.new('uint8_t[?]', n)
  end
end

-- Smooth normal from a height grid zb (W x H, row-major), spacing h.
local function gridNormal(zb, W, H, i, j, h)
  local il = i > 0 and i - 1 or i
  local ir = i < W - 1 and i + 1 or i
  local jd = j > 0 and j - 1 or j
  local ju = j < H - 1 and j + 1 or j
  local dzdx = (zb[j * W + ir] - zb[j * W + il]) / ((ir - il) * h)
  local dzdy = (zb[ju * W + i] - zb[jd * W + i]) / ((ju - jd) * h)
  local l = 1 / sqrt(dzdx * dzdx + dzdy * dzdy + 1)
  return -dzdx * l, -dzdy * l, l
end
M.gridNormal = gridNormal

-- Border rule: rule[1..8] = codes for neighbours L,R,B,T,BL,BR,TL,TR.
-- 0 = keep, 1 = lower by the sector drop.
local function borderCode(rule, i, j, n)
  if not rule then return 0 end
  local c = 0
  if i == 0 then c = max(c, rule[1]) end
  if i == n then c = max(c, rule[2]) end
  if j == 0 then c = max(c, rule[3]) end
  if j == n then c = max(c, rule[4]) end
  if i == 0 and j == 0 then c = max(c, rule[5]) end
  if i == n and j == 0 then c = max(c, rule[6]) end
  if i == 0 and j == n then c = max(c, rule[7]) end
  if i == n and j == n then c = max(c, rule[8]) end
  return c
end
M.borderCode = borderCode

local sqPlain = nil

-- Full-resolution cells of a tile (rutted tiles; frozen tiles inside sectors).
-- stride > 1 (sector copy of a frozen tile): only every stride-th cell line is drawn,
-- plus the tile edge, so a left-behind rut costs far fewer vertices.
function M.emitTileCells(b, t, zOff, rule, stride)
  local main = ctx
  local N = t.N
  local W = N + 1
  ensure(W * W)
  local cell = t.cell
  local st = main.cfg.stamp
  local jz, jxy = st.jitterZ, st.jitterXY
  local drop = main.cfg.sectors.drop
  local gcx0, gcy0 = t.gx0 * t.cps, t.gy0 * t.cps
  local rut, track, rest, flo = t.rut, t.track, t.rest, t.floor
  local decodeZ = main.decodeZ
  -- terrain-first (main.squareFlush): untouched flush squares are left to the terrain,
  -- which lies exactly at the rest surface; everything drawn floats tfLift above it so the
  -- untouched cells of a dug square do not z-fight with the terrain under them
  local tfLift = main.terrainFirst() and (main.cfg.tiles.terrainFirstLift or 0.006) or 0
  local flush = t.anyFlush and t.sqFlush or nil

  for j = 0, N do
    for i = 0, N do
      local idx = j * W + i
      local z = decodeZ(t, idx)
      local tr = track[idx]
      if tr > 0 then z = z + (hash01(gcx0 + i, gcy0 + j, 7) * 2 - 1) * jz * tr / 255 end
      if borderCode(rule, i, j, N) == 1 then z = z - drop end
      zbuf[idx] = z + zOff + tfLift
    end
  end

  local x0, y0 = t.x0, t.y0
  local cps, ts = t.cps, t.ts
  local soft, sqMat = t.soft, t.sqMat
  local uvOf = main.uvOf
  local s, curM = nil, nil

  local function vtx(i, j)
    local idx = j * W + i
    local vi = vidx[idx]
    if vi >= 0 then return vi end
    local x, y = x0 + i * cell, y0 + j * cell
    local tr = track[idx]
    if tr > 0 then
      local k = jxy * tr / 255
      x = x + (hash01(gcx0 + i, gcy0 + j, 11) * 2 - 1) * k
      y = y + (hash01(gcx0 + i, gcy0 + j, 13) * 2 - 1) * k
    end
    local nx, ny, nz = gridNormal(zbuf, W, W, i, j, cell)
    local u, v = uvOf(x, y, curM)
    vi = s:vert(x, y, zbuf[idx], nx, ny, nz, u, v)
    vidx[idx] = vi
    return vi
  end

  -- grid lines: every stride-th cell line, always ending on the tile edge N
  stride = max(1, floor(stride or 1))
  local lines = {}
  for k = 0, N - 1, stride do lines[#lines + 1] = k end
  lines[#lines + 1] = N
  local L = #lines

  -- Full-resolution tile: a terrain square that no tyre touched (every vertex at the
  -- rest surface, no track jitter) is drawn as one quad instead of cps x cps cells.
  -- Its edge vertices lie on the straight line between its corners (rest heights are
  -- bilinear per square), so the fine cells next to it meet it without cracks. A
  -- rebuild uploads far fewer vertices (createMesh costs ~1.3 ms per 700 in game).
  local plain = nil
  if (stride == 1 and main.cfg.tiles.mergePlain ~= false) or flush then
    plain = sqPlain
    if not plain or #plain < ts * ts then plain = {}; sqPlain = plain end
    for sj = 0, ts - 1 do
      for si = 0, ts - 1 do
        local ok = true
        for j = sj * cps, sj * cps + cps do
          local row = j * W
          for i = si * cps, si * cps + cps do
            local idx = row + i
            if rut[idx] ~= 128 or track[idx] ~= 0 then ok = false; break end
          end
          if not ok then break end
        end
        plain[sj * ts + si + 1] = ok
      end
    end
  end
  if stride == 1 and main.cfg.tiles.mergePlain ~= false then
    for mi = 1, #t.matList do
      local m = t.matList[mi]
      s = b:sub(main.matName(m), W * W)
      curM = m
      for k = 0, W * W - 1 do vidx[k] = -1 end
      for sj = 0, ts - 1 do
        for si = 0, ts - 1 do
          local q = sj * ts + si
          if sqMat[q] == m and soft[(sj * cps) * N + si * cps] ~= 0 then
            local i0, j0 = si * cps, sj * cps
            if plain[q + 1] then
              if not (flush and flush[q] ~= 0) then
                local a, bb = vtx(i0, j0), vtx(i0 + cps, j0)
                local c, d = vtx(i0, j0 + cps), vtx(i0 + cps, j0 + cps)
                s:tri(a, c, d)
                s:tri(a, d, bb)
              end
            else
              -- terrain-first: in a dug square whose corners are still flush (the rut floor
              -- did not lower them) the untouched cells are left to the terrain too, so its
              -- decal roads reach the rut edge instead of stopping at the square grid
              local sqF = flush and flush[q] ~= 0
              for cj = j0, j0 + cps - 1 do
                local r0, r1 = cj * W, (cj + 1) * W
                for ci = i0, i0 + cps - 1 do
                  if soft[cj * N + ci] ~= 0 and not (sqF
                      and rut[r0 + ci] == 128 and rut[r0 + ci + 1] == 128 and rut[r1 + ci] == 128 and rut[r1 + ci + 1] == 128
                      and track[r0 + ci] == 0 and track[r0 + ci + 1] == 0 and track[r1 + ci] == 0 and track[r1 + ci + 1] == 0) then
                    local a, bb = vtx(ci, cj), vtx(ci + 1, cj)
                    local c, d = vtx(ci, cj + 1), vtx(ci + 1, cj + 1)
                    s:tri(a, c, d)
                    s:tri(a, d, bb)
                  end
                end
              end
            end
          end
        end
      end
    end
    return
  end

  for mi = 1, #t.matList do
    local m = t.matList[mi]
    s = b:sub(main.matName(m), W * W)
    curM = m
    for k = 0, W * W - 1 do vidx[k] = -1 end
    for lj = 1, L - 1 do
      local cj0, cj1 = lines[lj], lines[lj + 1]
      local cjm = floor((cj0 + cj1 - 1) / 2)
      local sqRow = floor(cjm / cps) * ts
      for li = 1, L - 1 do
        local ci0, ci1 = lines[li], lines[li + 1]
        local cim = floor((ci0 + ci1 - 1) / 2)
        local q = sqRow + floor(cim / cps)
        if soft[cjm * N + cim] ~= 0 and sqMat[q] == m and not (flush and flush[q] ~= 0 and plain[q + 1]) then
          local a, bb = vtx(ci0, cj0), vtx(ci1, cj0)
          local c, d = vtx(ci0, cj1), vtx(ci1, cj1)
          -- (0,0)->(0,1)->(1,1) and (0,0)->(1,1)->(1,0): clockwise seen from above
          s:tri(a, c, d)
          s:tri(a, d, bb)
        end
      end
    end
  end
end

-- One quad per terrain square of an untouched tile (uses the tile's vertex data).
function M.emitTilePixels(b, t, zOff, rule)
  local main = ctx
  local ts = t.ts
  local W = ts + 1
  ensure(W * W)
  local sq = main.ter.sq
  local drop = main.cfg.sectors.drop
  local vRest, vFloor = t.vRest, t.vFloor
  local tfLift = main.terrainFirst() and (main.cfg.tiles.terrainFirstLift or 0.006) or 0
  local flush = t.anyFlush and t.sqFlush or nil
  for j = 0, ts do
    for i = 0, ts do
      local idx = j * W + i
      local z = vRest[idx]
      if borderCode(rule, i, j, ts) == 1 then z = z - drop end
      zbuf[idx] = z + zOff + tfLift
    end
  end
  local x0, y0 = t.x0, t.y0
  local uvOf = main.uvOf
  local sqPatched, sqMat = t.sqPatched, t.sqMat
  local s, curM = nil, nil
  local function vtx(i, j)
    local idx = j * W + i
    local vi = vidx[idx]
    if vi >= 0 then return vi end
    local x, y = x0 + i * sq, y0 + j * sq
    local nx, ny, nz = gridNormal(zbuf, W, W, i, j, sq)
    local u, v = uvOf(x, y, curM)
    vi = s:vert(x, y, zbuf[idx], nx, ny, nz, u, v)
    vidx[idx] = vi
    return vi
  end
  for mi = 1, #t.matList do
    local m = t.matList[mi]
    s = b:sub(main.matName(m), W * W)
    curM = m
    for k = 0, W * W - 1 do vidx[k] = -1 end
    for sj = 0, ts - 1 do
      for si = 0, ts - 1 do
        local q = sj * ts + si
        if sqPatched[q] ~= 0 and sqMat[q] == m and not (flush and flush[q] ~= 0) then
          local a, bb = vtx(si, sj), vtx(si + 1, sj)
          local c, d = vtx(si, sj + 1), vtx(si + 1, sj + 1)
          s:tri(a, c, d)
          s:tri(a, d, bb)
        end
      end
    end
  end
end

-- One quad per patched terrain square of tile (tx,ty), heights computed from the
-- terrain (layer map, feather, zones, sink shortfall). Nothing is stored.
-- Returns the number of squares emitted.
function M.emitTerrainSquares(b, tx, ty, zOff)
  local main = ctx
  local ts = main.ts
  ensureTerrain(ts)
  local count = main.fillTerrainTile(tx, ty, tRest, tPatched, tMat)
  if count == 0 then return 0 end
  -- terrain-first: flush squares are drawn by the terrain itself
  if main.terrainFirst() then
    local left = 0
    for sj = 0, ts - 1 do
      for si = 0, ts - 1 do
        local q = sj * ts + si
        if tPatched[q] ~= 0 then
          if main.squareFlush(tx * ts + si, ty * ts + sj) then tPatched[q] = 0 else left = left + 1 end
        end
      end
    end
    if left == 0 then return 0 end
    zOff = zOff + (main.cfg.tiles.terrainFirstLift or 0.006)
  end
  local W = ts + 1
  ensure(W * W)
  for k = 0, W * W - 1 do zbuf[k] = tRest[k] + zOff end
  local sq = main.ter.sq
  local x0, y0 = main.ter.ox + tx * ts * sq, main.ter.oy + ty * ts * sq
  local uvOf = main.uvOf
  local s, curM = nil, nil
  local function vtx(i, j)
    local idx = j * W + i
    local vi = vidx[idx]
    if vi >= 0 then return vi end
    local x, y = x0 + i * sq, y0 + j * sq
    local nx, ny, nz = gridNormal(zbuf, W, W, i, j, sq)
    local u, v = uvOf(x, y, curM)
    vi = s:vert(x, y, zbuf[idx], nx, ny, nz, u, v)
    vidx[idx] = vi
    return vi
  end
  -- distinct materials of the patched squares
  local mats = {}
  for q = 0, ts * ts - 1 do
    if tPatched[q] ~= 0 then mats[tMat[q]] = true end
  end
  for m in pairs(mats) do
    s = b:sub(main.matName(m), W * W)
    curM = m
    for k = 0, W * W - 1 do vidx[k] = -1 end
    for sj = 0, ts - 1 do
      for si = 0, ts - 1 do
        local q = sj * ts + si
        if tPatched[q] ~= 0 and tMat[q] == m then
          local a, bb = vtx(si, sj), vtx(si + 1, sj)
          local c, d = vtx(si, sj + 1), vtx(si + 1, sj + 1)
          s:tri(a, c, d)
          s:tri(a, d, bb)
        end
      end
    end
  end
  return count
end

-- Build the mesh of an active tile: pixels when untouched, full cells when rutted.
local tileBuilder = nil
function M.buildTile(t, rule)
  tileBuilder = tileBuilder or M.newBuilder()
  tileBuilder:reset()
  if t.rutted then
    M.emitTileCells(tileBuilder, t, 0, rule)
  else
    M.emitTilePixels(tileBuilder, t, 0, rule)
  end
  -- decal roads (deepmud_decals): on the untouched terrain squares of the tile
  local dec = extensions and extensions.deepmud_decals
  if dec then dec.overlay(tileBuilder, true, t.key) end
  return tileBuilder:finish()
end

function M.setContext(main)
  ctx = main
  growStep = (main and main.cfg and main.cfg.pool and main.cfg.pool.growStep) or 16
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
end
M.onExtensionLoaded = onExtensionLoaded

return M
