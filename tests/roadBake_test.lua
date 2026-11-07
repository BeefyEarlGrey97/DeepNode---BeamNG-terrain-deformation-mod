-- Offline test: pure helpers of the baked road layer (deepnode_roadBakeCore).
-- run: luajit tests/roadBake_test.lua   (from the mod root)
-- Values from the gridmap_v2 spike (2026-11-07): tile 9175179 at x0 -328.5, y0 -323.5.

local C = dofile('lua/ge/extensions/deepnode/roadBakeCore.lua')
local fails = 0
local function expect(cond, msg) if not cond then fails = fails + 1; print('FAIL ' .. msg) else print('ok   ' .. msg) end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- tile mapping: uvOf base mode (ox, oy = -1023.5, size 2048, flipV); the spike measured cu 0, cv 0.6
local function uvOf(x, y) return (x + 1023.5) / 2048, 1 - (y + 1023.5) / 2048 end
local m = C.tileMapping(uvOf, 2, -328.5, -323.5, 5)
expect(near(m.sx, 409.6) and near(m.sy, 409.6), 'mapping_scale')
expect(m.su == 1 and m.sv == -1, 'mapping_signs')
expect(near(m.cu, 0.0) and near(m.cv, 0.6), 'mapping_offsets')

-- straight road along +y, 4 m wide, edges every 2 m, texLen 10
local road = { L = {}, R = {}, D = {}, tl = 10 }
for i = 0, 5 do
  road.L[i + 1] = { x = -2, y = i * 2, z = 0 }
  road.R[i + 1] = { x = 2, y = i * 2, z = 0 }
  road.D[i + 1] = i * 2
end
local q = C.tileQuads(road, -1, 3, 5, 0.3) -- tile y 3..8 (+0.3): quads 2..5 overlap
expect(#q == 4, 'quads_clip_count')
expect(near(q[1][9], -0.2) and near(q[1][10], -0.4) and near(q[1][11], 4), 'quads_v_and_width')
expect(#C.tileQuads(road, 10, 3, 5, 0.3) == 0, 'quads_none_off_road')

-- draw order + grouping
local rs = { { id = 1, mat = 'water', prio = 19, tl = 10, quads = { 1 } }, { id = 2, mat = 'large', prio = 18, tl = 10, quads = { 2 } },
  { id = 3, mat = 'furrow', prio = 6, tl = 10, quads = { 3 } }, { id = 4, mat = 'furrow', prio = 8, tl = 10, quads = { 4 } } }
local g = C.drawGroups(rs, true, 64)
expect(g[1].mat == 'furrow' and #g[1].quads == 2 and g[#g].mat == 'water', 'groups_high_on_top')
g = C.drawGroups(rs, false, 64)
expect(g[1].mat == 'water' and g[#g].mat == 'furrow', 'groups_low_on_top')
expect(g[#g].roadIdx[1] ~= nil and g[#g].roadIdx[1] ~= g[#g].roadIdx[2], 'groups_keep_road_index')
local many = {}
for i = 1, 70 do many[i] = i end
g = C.drawGroups({ { id = 1, mat = 'a', prio = 1, tl = 10, quads = many } }, true, 64)
expect(#g == 2 and #g[1].quads == 64 and #g[2].quads == 6, 'groups_split_at_64')

-- signature
local p = { version = 1, size = 512, highOnTop = true }
local rq = { { id = 1, mat = 'water', prio = 19, tl = 10, quads = { { 0, 0, 1, 0, 0, 1, 1, 1, 0, -0.1, 1 } } } }
local s1 = C.signature(rq, p)
expect(#s1 == 8 and s1 == C.signature(rq, p), 'signature_stable')
rq[1].prio = 20
expect(C.signature(rq, p) ~= s1, 'signature_changes_with_roads')
rq[1].prio = 19
expect(C.signature(rq, { version = 1, size = 256, highOnTop = true }) ~= s1, 'signature_changes_with_size')
-- heavy mode lowers the terrain under dug roads: the road regenerates and its 3D length (v) shifts
-- a little; the images must stay cached (only the plan geometry, to 1 cm, counts)
local rv = { { id = 1, mat = 'water', prio = 19, tl = 10, quads = { { 0, 0, 1, 0, 0, 1, 1, 1, 0.0013, -0.1017, 1.002 } } } }
expect(C.signature(rv, p) == s1, 'signature_ignores_v_and_mm_noise')
local rx = { { id = 1, mat = 'water', prio = 19, tl = 10, quads = { { 0.05, 0, 1, 0, 0, 1, 1, 1, 0, -0.1, 1 } } } }
expect(C.signature(rx, p) ~= s1, 'signature_changes_with_plan_geometry')

-- cache paths
local cp = C.cachePaths('gridmap_v2', 9175179, 'a1b2c3d4')
expect(cp.dir == '/deepnode_cache/roadbake/gridmap_v2/', 'cache_dir')
expect(cp.b == '/deepnode_cache/roadbake/gridmap_v2/9175179_a1b2c3d4_b.color.png', 'cache_color_name')
expect(cp.nm == '/deepnode_cache/roadbake/gridmap_v2/9175179_a1b2c3d4_nm.normal.png', 'cache_normal_name')
expect(cp.o:match('_o%.data%.png$') and cp.r:match('_r%.data%.png$') and cp.m:match('_m%.data%.png$'), 'cache_data_names')

-- queue
local qo = C.queueOrder({ [1] = { 0, 0 }, [2] = { 50, 0 }, [3] = { 400, 0 } }, { { 45, 0 } }, 300)
expect(#qo == 2 and qo[1] == 2 and qo[2] == 1, 'queue_nearest_first_within_radius')
expect(#C.queueOrder({ [1] = { 0, 0 } }, {}, 300) == 0, 'queue_empty_without_points')

-- layer fields
local lf = C.layerFields(2, cp, m)
local by = {}
for _, f in ipairs(lf) do by[f[1] .. '@' .. f[2]] = f[3] end
expect(by['activeLayers@0'] == '3' and by['detailMap@2'] == cp.b and by['detailScale@2'] == '409.600000 409.600000', 'layer_fields_layer2')
expect(by['opacityDetailMap@2'] == cp.o and by['detailNormalMap@2'] == cp.nm and by['metallicDetailMap@2'] == cp.m, 'layer_fields_maps')
expect(C.layerFields(4, cp, m) == nil, 'layer_fields_full_material')

-- regions of 4 x 4 tiles (Revision B)
local rx, ry = C.regionOf(-1, 7, 4)
expect(rx == -1 and ry == 1, 'region_of_negative_tiles')
local rx0, ry0 = C.regionOrigin(34, 33, 4, 5, -1023.5, -1023.5)
expect(near(rx0, -343.5) and near(ry0, -363.5), 'region_origin')
expect(C.regionKey(34, 33) == 'r34_33', 'region_key')
expect(C.cachePaths('gridmap_v2', C.regionKey(34, 33), 'a1b2c3d4').b == '/deepnode_cache/roadbake/gridmap_v2/r34_33_a1b2c3d4_b.color.png', 'region_cache_name')
local rm = C.tileMapping(uvOf, 2, rx0, ry0, 20)
expect(near(rm.sx, 102.4) and near(rm.sy, 102.4), 'region_mapping_scale')

-- map size gate: 8 x 8 km maps (hw550 8192 m = 67.1 km2) bake, bigger ones do not
expect(C.mapAllowed(8192, 68) == true, 'map_8192_allowed')
expect(C.mapAllowed(12288, 68) == false, 'map_12288_refused')

print(fails == 0 and 'ALL OK' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
