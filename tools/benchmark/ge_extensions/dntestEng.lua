-- dntestEng: engine cost probes for DeepNode research tests (not part of the mod).
-- T1/T2/T17: first-draw cost of a ProceduralMesh upload in view, by case:
--   'fresh'  : a never-drawn object, shared (already drawn) material
--   'same'   : re-upload into the same object (same sizes), every sample
--   'newmat' : a never-drawn object with a material never drawn before
--   'nocoll' : fresh object, collisionType 'None' set before createMesh
--   'idle'   : no upload (control)
-- dntestEng.start{cases={'idle','fresh',...}, n=12, gap=20} ; dntestEng.result()
local M = {}
local S = nil
local KEYS = { 'RenderShadows', 'RenderReflections', 'Render', 'Lua', 'RenderMisc', 'PreRender' }

local function metrics()
  local m = {}
  if Engine.Debug and Engine.Debug.getLastPerformanceMetrics then Engine.Debug.getLastPerformanceMetrics(m) end
  return m
end

local function shaderGen()
  return Engine.Render and Engine.Render.getShaderGenerationCount and Engine.Render.getShaderGenerationCount() or -1
end

local function gridMesh(cx, cy, cz, n, cell, mat)
  local verts, normals, uvs, faces = {}, { { x = 0, y = 0, z = 1 } }, {}, {}
  for j = 0, n do
    for i = 0, n do
      verts[#verts + 1] = { x = cx + i * cell, y = cy + j * cell, z = cz + 0.02 * math.sin(i + j) }
      uvs[#uvs + 1] = { u = i * 0.1, v = j * 0.1 }
    end
  end
  local W = n + 1
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local a, b, c, d = j * W + i, j * W + i + 1, (j + 1) * W + i, (j + 1) * W + i + 1
      -- clockwise seen from above
      faces[#faces + 1] = { v = a, n = 0, u = a }
      faces[#faces + 1] = { v = c, n = 0, u = c }
      faces[#faces + 1] = { v = b, n = 0, u = b }
      faces[#faces + 1] = { v = b, n = 0, u = b }
      faces[#faces + 1] = { v = c, n = 0, u = c }
      faces[#faces + 1] = { v = d, n = 0, u = d }
    end
  end
  return { verts = verts, normals = normals, uvs = uvs, faces = faces, material = mat }
end

local function newObj(name)
  local o = createObject('ProceduralMesh')
  o.canSave = false
  o:registerObject(name)
  scenetree.MissionGroup:addObject(o)
  o:setPosition(vec3(0, 0, 0))
  return o
end

local function newMaterial(k, base)
  local name = 'dntestEng_mat_' .. k .. '_' .. S.session
  local m = createObject('Material')
  m:setField('mapTo', 0, name)
  local src = scenetree.findObject(base)
  if src then
    for _, f in ipairs({ 'baseColorMap', 'normalMap', 'roughnessMap' }) do
      local v = src:getField(f, 0)
      if v and v ~= '' then m:setField(f, 0, v) end
    end
  end
  m:setField('castShadows', 0, '0')
  m.canSave = false
  m:registerObject(name)
  S.mats[#S.mats + 1] = m
  return name
end

function M.start(o)
  o = o or {}
  local cam = core_camera.getPosition()
  local dir = core_camera.getForward()
  local px, py = cam.x + dir.x * 12, cam.y + dir.y * 12
  local pz = core_terrain.getTerrainHeight(vec3(px, py, 0)) or cam.z - 2
  S = { cases = o.cases or { 'idle', 'fresh', 'same', 'newmat', 'nocoll' }, n = o.n or 12, gap = o.gap or 20,
    cell = o.cell or 0.2, cells = o.cells or 20, mat = o.mat or 'deepnode_gridmap_v2_L2',
    px = px - 2, py = py - 2, pz = pz + 0.05, ci = 1, k = 0, wait = 30, rec = nil, out = {}, objs = {}, mats = {},
    session = os.time() % 100000, frame = 0 }
  S.sameObj = newObj('dntestEng_same_' .. S.session)
  S.sameObj:createMesh({ { gridMesh(S.px, S.py, S.pz, S.cells, S.cell, S.mat) } })
  return 'ok'
end

local function upload(case)
  local mesh = gridMesh(S.px, S.py, S.pz, S.cells, S.cell, S.mat)
  local o
  local kk = tonumber(case:match('^k(%d+)$'))
  if kk then
    S.kObjs = S.kObjs or {}
    local t = hptimer()
    for q = 1, kk do
      local ob = S.kObjs[q]
      if not ob then
        ob = newObj(string.format('dntestEng_k_%d_%d', S.session, q))
        ob:createMesh({ { gridMesh(S.px + q * 0.01, S.py, S.pz, S.cells, S.cell, S.mat) } })
        S.kObjs[q] = ob
      end
      ob:createMesh({ { gridMesh(S.px + q * 0.01, S.py, S.pz, S.cells, S.cell, S.mat) } })
    end
    return t:stop(), nil
  end
  if case == 'same' then
    o = S.sameObj
  else
    o = newObj(string.format('dntestEng_%s_%d_%d', case, S.session, S.k))
    S.objs[#S.objs + 1] = o
    if case == 'newmat' then mesh.material = newMaterial(S.k, S.mat) end
    if case == 'nocoll' then o:setField('collisionType', 0, 'None') end
  end
  local t = hptimer()
  o:createMesh({ { mesh } })
  local ms = t:stop()
  if case ~= 'same' then
    -- hide the previous sample's object so only one fresh mesh is in view
    local prev = S.objs[#S.objs - 1]
    if prev then prev:setHidden(true) end
  end
  return ms, (case == 'nocoll') and o:getField('collisionType', 0) or nil
end

local function onUpdate()
  if not S or S.done then return end
  S.frame = S.frame + 1
  local m = metrics()
  if S.rec then
    local r = S.rec
    r.f = r.f + 1
    for _, k in ipairs(KEYS) do r.sum[k] = (r.sum[k] or 0) + (m[k] or 0) end
    -- first frame after the upload frame holds the upload frame's metrics
    if r.f == 1 then for _, k in ipairs(KEYS) do r.first[k] = (r.first[k] or 0) + (m[k] or 0) end end
    if r.f >= 3 then
      r.sg1 = shaderGen()
      local acc = S.out[r.case]
      acc.n = acc.n + 1
      acc.cmMs = acc.cmMs + r.ms
      acc.sg = acc.sg + (r.sg1 - r.sg0)
      for _, k in ipairs(KEYS) do
        acc.first[k] = (acc.first[k] or 0) + (r.first[k] or 0)
        acc.sum3[k] = (acc.sum3[k] or 0) + r.sum[k]
      end
      if r.coll then acc.coll = r.coll end
      S.rec = nil
      S.wait = S.gap
    end
    return
  end
  if S.wait > 0 then S.wait = S.wait - 1; return end
  local case = S.cases[S.ci]
  if not case then S.done = true; return end
  S.out[case] = S.out[case] or { n = 0, cmMs = 0, sg = 0, first = {}, sum3 = {} }
  S.k = S.k + 1
  local sg0 = shaderGen()
  local ms, coll = 0, nil
  if case ~= 'idle' then ms, coll = upload(case) end
  S.rec = { case = case, f = 0, sum = {}, first = {}, ms = ms, sg0 = sg0, coll = coll }
  if S.out[case].n + 1 >= S.n then S.ci = S.ci + 1 end
end

function M.result()
  if not S then return 'not started' end
  local res = { done = S.done == true, frame = S.frame }
  for case, a in pairs(S.out) do
    local r = { n = a.n, createMs = a.n > 0 and a.cmMs / a.n or 0, shaderGen = a.sg, coll = a.coll }
    for _, k in ipairs(KEYS) do
      r[k] = a.n > 0 and (a.first[k] or 0) / a.n or 0
      r[k .. '3'] = a.n > 0 and (a.sum3[k] or 0) / a.n / 3 or 0
    end
    res[case] = r
  end
  return res
end

function M.cleanup()
  if not S then return end
  for _, o in ipairs(S.objs) do if o then o:delete() end end
  if S.sameObj then S.sameObj:delete() end
  for _, o in ipairs(S.kObjs or {}) do o:delete() end
  for _, m in ipairs(S.mats) do if m then m:delete() end end
  S = nil
end

M.onUpdate = onUpdate
return M
