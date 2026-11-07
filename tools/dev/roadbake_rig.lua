-- Calibration rig for the baked road layer (run through the BeamNG MCP: python -I lua.py ...).
-- Lays a patch over an UNDUG road tile: the tile surface (terrain height + 4 mm) with the tile's
-- mud material plus the baked layer, so a screenshot with and without the patch compares the bake
-- against the engine's own decal roads underneath (tools/dev/roadbake_compare.py).
-- Globals (prepend a line):
--   DNRB_TILE  tile key (must have roads and be baked: roadbake_probe.lua 'tile' first)
--   DNRB_RIG   'build' (default) | 'show' | 'hide' | 'remove'
local cmd = rawget(_G, 'DNRB_RIG') or 'build'
local key = rawget(_G, 'DNRB_TILE')
local main = deepnode_main
local C = require('ge/extensions/deepnode/roadBakeCore')
local MESH, MAT = 'deepnode_rbRigMesh', 'deepnode_rbRigMat'
local function find(n) return scenetree.findObject(n) end

if cmd == 'remove' then
  local o = find(MESH); if o then o:delete() end
  return 'removed (material ' .. MAT .. ' kept: a deleted material may still be referenced)'
end
if cmd == 'show' or cmd == 'hide' then
  local o = find(MESH)
  if o then o:setHidden(cmd == 'hide') end
  return cmd
end

local rb = extensions.deepnode_roadBake
local state, files = rb.state(key)
if not files or not (state == 'baked' or state == 'ready' or state == 'cook') then return 'tile not baked: ' .. tostring(state) end
local T = main.tileSize
local KEY = main.KEY
local x0, y0 = main.ter.ox + (key % KEY) * T, main.ter.oy + math.floor(key / KEY) * T
local e = main.mudLayerAt(x0 + T * 0.5, y0 + T * 0.5)
-- the images cover the tile's region (4 x 4 tiles, roadBake REGION)
local rx, ry = C.regionOf(key % KEY, math.floor(key / KEY), 4)
local rx0, ry0 = C.regionOrigin(rx, ry, 4, T, main.ter.ox, main.ter.oy)
local map = C.tileMapping(main.uvOf, e, rx0, ry0, 4 * T)
local src = find(main.matName(e))
local m = find(MAT)
if not m then m = createObject('Material'); m.canSave = false; m:registerObject(MAT) end
m:assignFieldsFromObject(src)
m:setField('mapTo', 0, MAT)
for _, f in ipairs(C.layerFields(tonumber(src:getField('activeLayers', 0)) or 1, files, map)) do m:setField(f[1], f[2], f[3]) end
m:reload()

local N, cell, lift = 25, T / 25, 0.004
local tb = main.ter.tb
local function h(x, y) return tb:getHeight(vec3(x, y, 0)) end
local verts, uvs, nrm, faces = {}, {}, {}, {}
for j = 0, N do for i = 0, N do
  local x, y = x0 + i * cell, y0 + j * cell
  verts[#verts + 1] = { x = x, y = y, z = h(x, y) + lift }
  local u, v = main.uvOf(x, y, e)
  uvs[#uvs + 1] = { u = u, v = v }
  local nx, ny = (h(x - cell, y) - h(x + cell, y)) / (2 * cell), (h(x, y - cell) - h(x, y + cell)) / (2 * cell)
  local l = math.sqrt(nx * nx + ny * ny + 1)
  nrm[#nrm + 1] = { x = nx / l, y = ny / l, z = 1 / l }
end end
local function f(k) faces[#faces + 1] = { v = k, n = k, u = k } end
for j = 0, N - 1 do for i = 0, N - 1 do
  local a, b, c, d = j * (N + 1) + i, j * (N + 1) + i + 1, (j + 1) * (N + 1) + i, (j + 1) * (N + 1) + i + 1
  f(a); f(c); f(d); f(a); f(d); f(b)
end end
local o = find(MESH)
if o then o:delete() end
o = createObject('ProceduralMesh'); o.canSave = false; o:registerObject(MESH)
o:createMesh({ { { verts = verts, normals = nrm, uvs = uvs, faces = faces, material = MAT } } })
return string.format('rig at x0 %.1f y0 %.1f centre %.2f %.2f z %.2f (layer %d, sig %s)', x0, y0, x0 + T / 2, y0 + T / 2,
  h(x0 + T / 2, y0 + T / 2), e, files.b:match('_(%x+)_b'))
