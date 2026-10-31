-- DeepNode 4-truck gridmap_v2 benchmark (2026-10-31): Percherons 1, 2 (mud pit) and 5, 6 (sand
-- pit) of the 8-truck spawn in <user folder>/settings/deepnode/bench_spawn.json (see
-- gridmap_setup.lua / data/), facing south. Rewrites bench_spawn.json with the 4 new ids.
-- Run with gridmap_v2 loaded through MCP run_lua (`python lua.py gridmap_spawn4.lua`).
local d = jsonReadFile('/settings/deepnode/bench_spawn.json')
local pick = { 1, 2, 5, 6 }
local old = getPlayerVehicle(0)
local list = {}
for n, k in ipairs(pick) do
  local e = d.list[k]
  local rot = quatFromDir(vec3(e.d[1], e.d[2], 0), vec3(0, 0, 1))
  local v = core_vehicles.spawnNewVehicle('percheron', { config = 'vehicles/percheron/s450_8x8_flatbed_A.pc', pos = vec3(e.p[1], e.p[2], e.p[3]), rot = rot, autoEnterVehicle = n == 1 })
  if v then list[#list + 1] = { id = v:getID(), p = e.p, r = e.r, d = e.d } end
end
if old then old:delete() end
jsonWriteFile('/settings/deepnode/bench_spawn.json', { list = list }, true)
if dntestRun then extensions.unload('dntestRun') end
extensions.load('dntestRun')
return jsonEncode(list)
