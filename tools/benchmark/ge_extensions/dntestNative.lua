-- dntestNative: READ-ONLY check of the native Lua bridge (docs/NATIVE_DLL.md, stages 0 and 3).
-- Not part of the mod. Needs Bin64\mswsock.dll from native/ and a game restart after installing it.
-- All memory reads happen in the DLL (dnNative.probe), each one checked with VirtualQuery.
--   extensions.load('dntestNative'); dump(dntestNative.run())
local M = {}

local function gridMesh(n, cell, mat)
  local verts, normals, uvs, faces = {}, { { x = 0, y = 0, z = 1 } }, {}, {}
  for j = 0, n do
    for i = 0, n do
      verts[#verts + 1] = { x = i * cell, y = j * cell, z = 0.125 * ((i + j) % 2) }
      uvs[#uvs + 1] = { u = i * 0.1, v = j * 0.1 }
    end
  end
  local W = n + 1
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local a, b, c, d = j * W + i, j * W + i + 1, (j + 1) * W + i, (j + 1) * W + i + 1
      for _, v in ipairs({ a, c, b, b, c, d }) do faces[#faces + 1] = { v = v, n = 0, u = v } end
    end
  end
  return { verts = verts, normals = normals, uvs = uvs, faces = faces, material = mat }
end

function M.run()
  -- ffi.load stays denied; the DLL registers dnNative while the gate is asked
  local _, err = pcall(require('ffi').load, 'dnnative')
  local out = { ffiLoad = tostring(err), bridge = rawget(_G, 'dnNative') ~= nil }
  if not out.bridge then return out end
  out.version = dnNative.version()
  out.buildOk = dnNative.buildOk()

  -- a small test mesh far below the world (nothing to see, nothing to hit)
  local o = createObject('ProceduralMesh')
  o.canSave = false
  o:registerObject('dntestNative_mesh')
  scenetree.MissionGroup:addObject(o)
  o:setPosition(vec3(0, 0, -5000))
  local mesh = gridMesh(4, 0.25, 'WarningMaterial')
  o:createMesh({ { mesh } })
  out.sentVerts = #mesh.verts -- expect vb0 count to match
  local ok, probe = pcall(dnNative.probe, o)
  out.probe = probe
  out.probeOk = ok
  o:delete()
  return out
end

-- Stage 1: one visible test mesh, rewritten in place (writeVerts) vs rebuilt (createMesh).
--   dntestNative.place()        flat 4 m x 4 m grid on the ground 8 m in front of the camera
--   dntestNative.bump(h, 'cm')  rebuild with a bump of height h via createMesh (reference look)
--   dntestNative.bump(h, 'w')   same bump written in place via dnNative.writeVerts
--   dntestNative.clear()
local N, CELL, NAME = 16, 0.25, 'dntestNative_s1'
local ffi = require('ffi')

local function heights(h)
  local z = {}
  for j = 0, N do
    for i = 0, N do
      local dx, dy = (i - N / 2) * CELL, (j - N / 2) * CELL
      z[j * (N + 1) + i] = h * math.exp(-(dx * dx + dy * dy) / 0.8)
    end
  end
  return z
end

-- face corners in createMesh order: per quad (a, c, b), (b, c, d)
local function corners()
  local W, out = N + 1, {}
  for j = 0, N - 1 do
    for i = 0, N - 1 do
      local a, b, c, d = j * W + i, j * W + i + 1, (j + 1) * W + i, (j + 1) * W + i + 1
      for _, v in ipairs({ a, c, b, b, c, d }) do out[#out + 1] = v end
    end
  end
  return out
end

local function pos(v, z) return (v % (N + 1)) * CELL, math.floor(v / (N + 1)) * CELL, z[v] end
local function uv(v) return (v % (N + 1)) * 0.25, math.floor(v / (N + 1)) * 0.25 end

-- per-corner flat normal of its triangle (both paths use the same normals)
local function triNormal(z, t, cs)
  local ax, ay, az = pos(cs[t], z)
  local bx, by, bz = pos(cs[t + 1], z)
  local cx, cy, cz = pos(cs[t + 2], z)
  local ux, uy, uz, vx, vy, vz = bx - ax, by - ay, bz - az, cx - ax, cy - ay, cz - az
  local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
  local l = math.sqrt(nx * nx + ny * ny + nz * nz)
  return nx / l, ny / l, nz / l
end

local function buildCm(z)
  local cs, verts, uvs, normals, faces = corners(), {}, {}, {}, {}
  for v = 0, (N + 1) * (N + 1) - 1 do
    local x, y, zz = pos(v, z)
    verts[v + 1] = { x = x, y = y, z = zz }
    local u, w = uv(v)
    uvs[v + 1] = { u = u, v = w }
  end
  for t = 1, #cs, 3 do
    local nx, ny, nz = triNormal(z, t, cs)
    normals[#normals + 1] = { x = nx, y = ny, z = nz }
    for k = 0, 2 do faces[#faces + 1] = { v = cs[t + k], n = #normals - 1, u = cs[t + k] } end
  end
  return { verts = verts, normals = normals, uvs = uvs, faces = faces, material = 'WarningMaterial' }
end

-- the 44-byte vertices createMesh would upload (pos, normal, tangent, uv), tangent as engine 0x1401a5670
local function buildBytes(z)
  local cs = corners()
  local f = ffi.new('float[?]', #cs * 11)
  for t = 1, #cs, 3 do
    local nx, ny, nz = triNormal(z, t, cs)
    local p, q = {}, {}
    for k = 0, 2 do
      p[k] = { pos(cs[t + k], z) }
      q[k] = { uv(cs[t + k]) }
    end
    local e1 = { p[1][1] - p[0][1], p[1][2] - p[0][2], p[1][3] - p[0][3] }
    local e2 = { p[2][1] - p[0][1], p[2][2] - p[0][2], p[2][3] - p[0][3] }
    local s1, t1, s2, t2 = q[1][1] - q[0][1], q[1][2] - q[0][2], q[2][1] - q[0][1], q[2][2] - q[0][2]
    local r = 1 / (s1 * t2 - s2 * t1)
    local sx, sy, sz = (e1[1] * t2 - e2[1] * t1) * r, (e1[2] * t2 - e2[2] * t1) * r, (e1[3] * t2 - e2[3] * t1) * r
    local d = sx * nx + sy * ny + sz * nz
    sx, sy, sz = sx - nx * d, sy - ny * d, sz - nz * d
    local l = math.sqrt(sx * sx + sy * sy + sz * sz)
    if l > 0 then sx, sy, sz = sx / l, sy / l, sz / l end
    for k = 0, 2 do
      local o = (t - 1 + k) * 11
      f[o], f[o + 1], f[o + 2] = p[k][1], p[k][2], p[k][3]
      f[o + 3], f[o + 4], f[o + 5] = nx, ny, nz
      f[o + 6], f[o + 7], f[o + 8] = sx, sy, sz
      f[o + 9], f[o + 10] = q[k][1], q[k][2]
    end
  end
  return ffi.string(f, #cs * 44)
end

function M.place()
  M.clear()
  local cam, dir = core_camera.getPosition(), core_camera.getForward()
  local p = cam + vec3(dir.x, dir.y, 0):normalized() * 8
  local hit = castRayStatic(p + vec3(0, 0, 50), vec3(0, 0, -1), 200)
  p.z = p.z + 50 - (hit or 50)
  local o = createObject('ProceduralMesh')
  o.canSave = false
  o:registerObject(NAME)
  scenetree.MissionGroup:addObject(o)
  o:setPosition(p - vec3(N * CELL / 2, N * CELL / 2, -0.02))
  o:createMesh({ { buildCm(heights(0)) } })
  return { pos = tostring(p) }
end

function M.bump(h, how)
  local o = scenetree.findObject(NAME)
  if not o then return 'place() first' end
  local z = heights(h)
  if how == 'w' then
    pcall(ffi.load, 'dnnative')
    local t0 = os.clock()
    local bytes = buildBytes(z)
    local t1 = os.clock()
    local ok, err = pcall(dnNative.writeVerts, o, 0, bytes)
    return { ok = ok, err = not ok and tostring(err) or nil, buildMs = (t1 - t0) * 1000, writeMs = (os.clock() - t1) * 1000 }
  end
  local t0 = os.clock()
  o:createMesh({ { buildCm(z) } })
  return { ok = true, createMeshMs = (os.clock() - t0) * 1000 }
end

function M.clear()
  local o = scenetree.findObject(NAME)
  if o then o:delete() end
end

return M
