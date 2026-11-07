#!/usr/bin/env bash
# Offline compile check of the mod's post effect shaders with the Windows SDK dxc.
# A post effect shader that fails to compile in game fails silently (the old shader keeps drawing),
# so check here before loading. Builds a temp include tree: the game's shaders/common + the mod's.
# usage: tools/dev/shadercheck.sh [game_dir]
#   DXC=/path/to/dxc.exe overrides the SDK lookup.
G=${1:-"/c/Program Files (x86)/Steam/steamapps/common/BeamNG.drive"}
R=$(cd "$(dirname "$0")/../.." && pwd)
DXC=${DXC:-$(ls "/c/Program Files (x86)/Windows Kits/10/bin/"*/x64/dxc.exe 2>/dev/null | tail -1)}
[ -x "$DXC" ] || { echo "dxc not found (set DXC)"; exit 2; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shaders"
cp -r "$G/shaders/common" "$T/shaders/"
cp -r "$R/shaders/common/postFx/deepnode" "$T/shaders/common/postFx/"
cd "$T" || exit 2
rc=0
for f in shaders/common/postFx/deepnode/*P.hlsl; do
  for st in PS VS; do
    t=ps_6_0; [ $st = VS ] && t=vs_6_0
    if out=$("$DXC" -nologo -T $t -E main -D SHADER_STAGE_$st=1 -I . -I shaders/common "$f" -Fo /dev/null 2>&1); then
      echo "OK   $st $(basename "$f")"
    else
      echo "FAIL $st $(basename "$f")"; echo "$out" | grep -m3 error; rc=1
    fi
  done
done
exit $rc
