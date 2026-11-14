-- Offline test: lazy builder tables and in-place writes into a larger buffer (tileMesh, Exotic).
-- run: luajit tests/inplace_test.lua   (from the mod root)
-- Stub engine objects and a fake dnNative (scan hashes nothing, writeGroup records its call).

local fails = 0
local function expect(cond, msg) if not cond then fails = fails + 1; print('FAIL ' .. msg) else print('ok   ' .. msg) end end

log = function() end
setExtensionUnloadMode = function() end
MatrixF = function() return {} end
scenetree = {}
local created = 0
createObject = function()
  return { createMesh = function(o, l) created = created + 1; o.cap = l[1] and l[1][1] and #l[1][1].faces end, registerObject = function() end,
    setPosition = function() end, setHidden = function() end, setTransform = function() end }
end
vec3 = function(x, y, z) return { x = x, y = y, z = z } end

local writes = {}
local scanN = 0
dnNative = {
  buildOk = function() return true end,
  writeVerts = function() return true end,
  -- different hash per call: every present is a change
  scan = function(out, fb, nv)
    scanN = scanN + 1
    out[0] = scanN
    local x0, y0, z0, x1, y1, z1 = 1e30, 1e30, 1e30, -1e30, -1e30, -1e30
    for k = 0, nv - 1 do
      local x, y, z = fb[8 * k], fb[8 * k + 1], fb[8 * k + 2]
      x0, y0, z0, x1, y1, z1 = math.min(x0, x), math.min(y0, y), math.min(z0, z), math.max(x1, x), math.max(y1, y), math.max(z1, z)
    end
    out[1], out[2], out[3], out[4], out[5], out[6] = x0, y0, z0, x1, y1, z1
    return true
  end,
  writeGroup = function(o, slot, n, fb, nv, ib, nc, cap)
    writes[#writes + 1] = { o = o, slot = slot, n = n, nv = nv, nc = nc, cap = cap }
    return true
  end,
}

local tm = dofile('lua/ge/extensions/deepnode/tileMesh.lua')
local ctx = { cfg = { pool = { mode = 'pair' }, native = {} }, tileSize = 8, ter = { ox = 0, oy = 0 } }
tm.setContext(ctx)
tm.initPool(4, 1)

-- a grid of n x n quads on a 4 m tile, material mat
local function build(b, n, mat)
  b:reset()
  local s = b:sub(mat, (n + 1) * (n + 1))
  for j = 0, n do for i = 0, n do s:vert(i * 0.5, j * 0.5, 0.01 * i * j, 0, 0, 1, i / n, j / n) end end
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local a, c = j * (n + 1) + i, (j + 1) * (n + 1) + i
      s:tri(a, c, a + 1); s:tri(a + 1, c, c + 1)
    end
  end
  return b:finish()
end

-- 1. lazy tables equal the eager ones
local eager, lazy = tm.newBuilder(false), tm.newBuilder(true)
local me, ml = build(eager, 3, 'm')[1], build(lazy, 3, 'm')[1]
expect(rawget(ml, 'verts') == nil, 'lazy mesh has no Lua tables after finish')
expect(tm.vertCount({ ml }) == 16 and rawget(ml, 'verts') == nil, 'vertCount without filling the tables')
local same = #ml.verts == #me.verts and #ml.faces == #me.faces
for k = 1, #me.verts do
  local a, b, na, nb, ua, ub = me.verts[k], ml.verts[k], me.normals[k], ml.normals[k], me.uvs[k], ml.uvs[k]
  same = same and a.x == b.x and a.y == b.y and a.z == b.z and na.z == nb.z and ua.u == ub.u and ua.v == ub.v
end
for k = 1, #me.faces do same = same and me.faces[k].v == ml.faces[k].v and ml.faces[k].n == ml.faces[k].v end
expect(same, 'lazy tables match the eager build (verts, normals, uvs, faces)')
-- mid-build reads (decals / road copies) see what is built so far
lazy:reset()
local s = lazy:sub('m', 4)
s:vert(0, 0, 0, 0, 0, 1, 0, 0); s:vert(1, 0, 0, 0, 0, 1, 1, 0); s:vert(0, 1, 0, 0, 0, 1, 0, 1)
s:tri(0, 2, 1)
local v1, _, f1 = s:tables()
local nv1, nf1 = #v1, #f1 -- same arrays as the next call: keep the counts
s:vert(1, 1, 0, 0, 0, 1, 1, 1); s:tri(1, 2, 3)
local v2, _, f2 = s:tables()
expect(nv1 == 3 and nf1 == 3 and #v2 == 4 and #f2 == 6 and v2[4].x == 1 and f2[6].v == 3, 'Sub:tables follows a build in progress')

-- 2. present: first createMesh, then smaller mesh written in place into the larger buffer
local chunk = { x0 = 0, y0 = 0, N = 8 }
tm.present(chunk, build(lazy, 6, 'm'))
local obj = chunk.obj
local cap = obj.cap -- padded corner count at createMesh time
expect(created == 1 and obj ~= nil, 'first present creates the mesh')
local small = build(lazy, 3, 'm')
tm.present(chunk, small)
local w = writes[#writes]
expect(created == 1 and #writes == 1 and chunk.obj == obj, 'smaller mesh written in place, no createMesh')
expect(w and w.cap == cap and w.nc == 54 and w.nv == 16, 'in-place write padded to the old buffer (' .. tostring(w and w.cap) .. ' vs ' .. cap .. ')')
expect(rawget(small[1], 'verts') == nil and small[1].cap == nil, 'in-place path never filled the Lua tables, cap cleared')
-- 3. larger than the buffer: createMesh, reason grow
tm.present(chunk, build(lazy, 8, 'm'))
local _, nW, nF, nO, nNew, nMat, nGrow = tm.inPlaceStats()
expect(created == 2 and nGrow == 1 and nNew == 1 and nW == 1 and nF == 0 and nO == 0, 'bigger mesh goes to createMesh (reason grow)')
-- 4. other material: createMesh, reason mat
tm.present(chunk, build(lazy, 3, 'other'))
_, _, _, _, _, nMat = tm.inPlaceStats()
expect(created == 3 and nMat == 1, 'other material goes to createMesh (reason mat)')

print(fails == 0 and 'ALL OK' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
