-- DeepNode benchmark setup, johnson_valley: 8 Percherons, each driving its own 100 m circle at
-- 40 km/h inside flat mud zones (the JV sand dunes are too steep: trucks bog down).
-- 1. Copy tools/benchmark/data/johnson_valley/zones.json to
--    <user folder>/settings/deepnode/levels/johnson_valley.json (7 circle zones, r 108 m, 0.35 m
--    deep, hex around (-418, -994)) and restart the mod (deepnode_main.reloadLevelData()).
-- 2. Spawn 8 Percherons anywhere (s450_8x8_flatbed_A), then in the GE Lua console:
--      python lua.py jv_setup.lua   (or paste into the GE Lua console)
--    Needs tools/benchmark/ge_extensions/dntestCircles.lua in <user folder>/lua/ge/extensions/.
--    Truck 8 shares the centre circle with truck 1, half a lap behind.
-- 3. Measure with get_performance_metrics / deepnode_main.perf() / deepnode_main.rutLag(true);
--    dntestCircles.state() reports laps, speed and recoveries. Trucks reset every 240 s.

local CENTRES = {
  { -418.0, -994.0 }, { -215.2, -939.6 }, { -363.6, -791.2 }, { -566.5, -845.5 },
  { -620.8, -1048.4 }, { -472.4, -1196.8 }, { -269.5, -1142.5 },
}
local cars = {}
for i = 0, be:getObjectCount() - 1 do
  local v = be:getObject(i)
  if v:getJBeamFilename() == 'percheron' and #cars < 8 then
    local k = #cars + 1
    local c = CENTRES[(k - 1) % #CENTRES + 1]
    cars[k] = { vid = v:getID(), cx = c[1], cy = c[2], a0 = k > #CENTRES and math.pi or 0 }
    v:queueLuaCommand('if controller.mainController and controller.mainController.setGearboxMode then controller.mainController.setGearboxMode("arcade") end')
  end
end
settings.setValue('fpsLimitBackgroundEnabled', false)
if not dntestCircles then extensions.load('dntestCircles') end
dntestCircles.start({ R = 100, kph = 40, cars = cars, resetEvery = 240 })
dntestCircles.place()
return #cars .. ' Percherons placed on their circles'
