#!/usr/bin/env bash
# Offline syntax + global check of the deepmud mod with LuaJIT (same compiler as BeamNG).
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
exit $rc
