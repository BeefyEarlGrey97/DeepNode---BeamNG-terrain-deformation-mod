#!/usr/bin/env bash
# reload GE Lua + every vehicle's deepnode extension + mod level data; wait until running
cd "$(dirname "$0")"
timeout 20 python -I mcp.py reload_lua >/dev/null 2>&1
for i in $(seq 1 30); do sleep 3; r=$(timeout 10 python -I mcp.py run_lua '{"code":"return tostring(deepnode_main and deepnode_main.isRunning())"}' 2>/dev/null); [ "$r" = "true" ] && break; done
timeout 20 python -I mcp.py run_lua '{"code":"for i=0,be:getObjectCount()-1 do be:getObject(i):queueLuaCommand(\"extensions.reload(\\\"deepnode_vehicle\\\")\") end return 1"}' >/dev/null
sleep 2
timeout 60 python -I mcp.py run_lua '{"code":"deepnode_main.reloadLevelData() return 1"}' >/dev/null
for i in $(seq 1 20); do sleep 3; r=$(timeout 10 python -I mcp.py run_lua '{"code":"settings.setValue(\"fpsLimitBackgroundEnabled\", false) if not dntestRun then extensions.load(\"dntestRun\") end return tostring(deepnode_main and deepnode_main.isRunning())"}' 2>/dev/null); [ "$r" = "true" ] && break; done
timeout 20 python -I mcp.py run_lua '{"code":"for i=0,be:getObjectCount()-1 do be:getObject(i):queueLuaCommand(\"controller.mainController.setGearboxMode(\\\"arcade\\\")\") end local e=deepnode_main.stats().lastError return \"running \" .. tostring(deepnode_main.isRunning()) .. \" err=\" .. tostring(e)"}'
timeout 20 python -I mcp.py get_logs '{"lines":80}' | grep -i "deepnode\|error" | grep -iv "securecomm" | tail -6
