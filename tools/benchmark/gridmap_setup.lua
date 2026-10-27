-- Deep Mud benchmark setup, gridmap_v2: 8 Percherons (s450_8x8_flatbed_A) in a row north of the
-- mud pit (x -334..-306) and the sand pit (x -368..-340), all facing south into the pits.
-- Run with gridmap_v2 loaded: paste into the GE Lua console, or send the file text through the
-- MCP run_lua tool (`python lua.py gridmap_setup.lua`). load_file/dofile only see it after a mod remount.
-- Needs tools/benchmark/ge_extensions/dmtestRun.lua copied to <user folder>/lua/ge/extensions/.
-- Then: dmtestRun.start{runs = 3, speed = 12.5, dist = 110, timeout = 30, clear = true}
--       dmtestRun.result()  (fps, low1, memory and rut lag per run)

local POS = {
  { -329.17, -269.52 }, { -322.98, -269.07 }, { -317.43, -268.70 }, { -311.34, -270.16 }, -- mud lane
  { -345.40, -268.69 }, { -351.97, -267.15 }, { -358.16, -267.18 }, { -364.61, -267.88 }, -- sand lane
}
local Z = 101.2
local CONFIG = 'vehicles/percheron/s450_8x8_flatbed_A.pc'
local ROT = quat(0, 0, 0, 1) -- identity = heading south (direction vector 0,-1)

-- remove other vehicles, reuse existing Percherons
local have = {}
for i = be:getObjectCount() - 1, 0, -1 do
  local v = be:getObject(i)
  if v:getJBeamFilename() == 'percheron' and #have < #POS then have[#have + 1] = v else v:delete() end
end
local list = {}
for k, p in ipairs(POS) do
  local v = have[k]
  if v then
    v:setPositionRotation(p[1], p[2], Z, ROT.x, ROT.y, ROT.z, ROT.w)
    v:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
  else
    v = core_vehicles.spawnNewVehicle('percheron', { config = CONFIG, pos = vec3(p[1], p[2], Z), rot = ROT, autoEnterVehicle = false })
  end
  -- spawned AI-less vehicles start in 'realistic' gearbox mode and stay in neutral
  v:queueLuaCommand('if controller.mainController and controller.mainController.setGearboxMode then controller.mainController.setGearboxMode("arcade") end')
  list[#list + 1] = { id = v:getID(), p = { p[1], p[2], Z }, r = { ROT.x, ROT.y, ROT.z, ROT.w }, d = { 0, -1 } }
end
jsonWriteFile('/settings/deepmud/bench_spawn.json', { list = list }, true)
settings.setValue('fpsLimitBackgroundEnabled', false) -- an unfocused window is capped at 60 fps
if not dmtestRun then extensions.load('dmtestRun') end
be:enterVehicle(0, be:getObjectByID(list[1].id))
return #list .. ' Percherons ready; run dmtestRun.start{runs=3, speed=12.5, dist=110, timeout=30, clear=true}'
