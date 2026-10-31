-- DeepNode 6-truck gridmap_v2 benchmark (2026-10-31): Percherons 1, 2, 3 (mud pit) and 5, 6, 7
-- (sand pit) of the 8-truck reference row (tools/benchmark/data/gridmap_v2/bench_spawn.json,
-- copied into this file so it does not depend on the user's bench_spawn.json), facing south.
-- Removes every other vehicle, rewrites <user folder>/settings/deepnode/bench_spawn.json with
-- the 6 new ids for dntestRun.
-- Run with gridmap_v2 loaded through MCP run_lua (`python lua.py gridmap_spawn6.lua`).
local ref = {
  { -329.167, -269.519, 100.896 }, { -322.979, -269.074, 100.896 }, { -317.427, -268.702, 100.896 },
  { -345.4, -268.7, 100.896 }, { -352.0, -267.2, 100.896 }, { -358.2, -267.2, 100.896 },
}
local old = {}
for i = 0, be:getObjectCount() - 1 do old[#old + 1] = be:getObject(i) end
local list = {}
for n, p in ipairs(ref) do
  local rot = quatFromDir(vec3(0, -1, 0), vec3(0, 0, 1))
  local v = core_vehicles.spawnNewVehicle('percheron', { config = 'vehicles/percheron/s450_8x8_flatbed_A.pc',
    pos = vec3(p[1], p[2], p[3]), rot = rot, autoEnterVehicle = n == 1 })
  if v then list[#list + 1] = { id = v:getID(), p = p, r = { rot.x, rot.y, rot.z, rot.w }, d = { 0, -1 } } end
end
for _, o in ipairs(old) do o:delete() end
jsonWriteFile('/settings/deepnode/bench_spawn.json', { list = list }, true)
if dntestRun then extensions.unload('dntestRun') end
extensions.load('dntestRun')
return jsonEncode(list)
