#!/usr/bin/env bash
# Offline syntax + global check of the deepnode mod with LuaJIT (same compiler as BeamNG).
# usage: tools/dev/luacheck.sh [mod_root]   (default: this repository)
LJ=${LUAJIT:-luajit}   # set LUAJIT=/path/to/luajit if it is not on PATH
R=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$R" || exit 1
rc=0
for f in $(find lua scripts -name '*.lua'); do
  if out=$("$LJ" -b "$f" /dev/null 2>&1); then echo "OK   $f"; else echo "FAIL $out"; rc=1; fi
done
echo "--- global writes (expect only castRayStatic):"
for f in $(find lua -name '*.lua'); do "$LJ" -bl "$f" 2>/dev/null | grep -o 'GSET.*"[^"]*"' | grep -o '"[^"]*"' | sort -u | sed "s|^|$f: |"; done
echo "--- global reads outside the engine's names (expect none; a local used out of its scope reads as a global):"
KNOWN='^(_G|Engine|FS|GBitmap|MatrixF|ColorF|ColorI|VariableRegistry|be|obj|v|castRayStatic|collectgarbage|core_[a-z_]*|coroutine|createObject|debug|debugDrawer|deepnode_main|electrics|error|extensions|getAllVehicles|getCurrentLevelIdentifier|getMissionFilename|getObjectByID|getPlayerVehicle|guihooks|hptimer|input|io|ipairs|jsonReadFile|jsonWriteFile|log|math|next|os|pairs|pcall|powertrain|rawget|rawset|require|scenetree|select|serialize|setExtensionUnloadMode|setmetatable|getmetatable|settings|simTimeAuthority|string|table|tonumber|tostring|type|ui_imgui|ui_message|unpack|vec3|quat|controller|mapmgr|wheels|sensors|beamstate|bdebug|drivetrain|M|xpcall|print|loadstring|load|dump|dumps|ffi|bit|jit|quatFromDir|map|spawn|gameplay_[a-z_]*|ui_[a-z_]*|core_environment|clamp|lerp)$'
for f in $(find lua scripts -name '*.lua'); do
  bad=$("$LJ" -bl "$f" 2>/dev/null | grep -o 'GGET.*"[^"]*"' | grep -o '"[^"]*"' | tr -d '"' | sort -u | grep -Ev "$KNOWN" | tr '
' ' ')
  if [ -n "$bad" ]; then echo "$f: $bad"; fi
done
exit $rc
