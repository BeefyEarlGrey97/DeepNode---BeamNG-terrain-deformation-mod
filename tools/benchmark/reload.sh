#!/usr/bin/env bash
# reload GE Lua + every vehicle's deepmud extension + mod level data; wait until running
cd "$(dirname "$0")"
timeout 20 python -I mcp.py reload_lua >/dev/null 2>&1
for i in $(seq 1 30); do sleep 3; r=$(timeout 10 python -I mcp.py run_lua '{"code":"return tostring(deepmud_main and deepmud_main.isRunning())"}' 2>/dev/null); [ "$r" = "true" ] && break; done
timeout 20 python -I mcp.py run_lua '{"code":"for i=0,be:getObjectCount()-1 do be:getObject(i):queueLuaCommand(\"extensions.reload(\\\"deepmud_vehicle\\\")\") end return 1"}' >/dev/null
sleep 2
timeout 60 python -I mcp.py run_lua '{"code":"deepmud_main.reloadLevelData() return 1"}' >/dev/null
for i in $(seq 1 20); do sleep 3; r=$(timeout 10 python -I mcp.py run_lua '{"code":"settings.setValue(\"fpsLimitBackgroundEnabled\", false) if not dmtestRun then extensions.load(\"dmtestRun\") end return tostring(deepmud_main and deepmud_main.isRunning())"}' 2>/dev/null); [ "$r" = "true" ] && break; done
timeout 20 python -I mcp.py run_lua '{"code":"for i=0,be:getObjectCount()-1 do be:getObject(i):queueLuaCommand(\"controller.mainController.setGearboxMode(\\\"arcade\\\")\") end local e=deepmud_main.stats().lastError return \"running \" .. tostring(deepmud_main.isRunning()) .. \" err=\" .. tostring(e)"}'
timeout 20 python -I mcp.py get_logs '{"lines":80}' | grep -i "deepmud\|error" | grep -iv "securecomm" | tail -6
