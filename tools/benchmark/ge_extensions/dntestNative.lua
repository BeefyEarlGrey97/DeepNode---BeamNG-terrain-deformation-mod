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

return M
