# Native route: in-place mesh updates (living document)

Status: **stage 0 written, not yet run in game** (last update 2026-11-14).
This file is updated every time something new is found. Newest entries go to the log at the end.

## Why
The mod is CPU-bound. Of its ~7 ms per frame at speed, about 5 ms sit inside the engine and come
from `ProceduralMesh:createMesh`, called for every rut change:

| Cost per call | Cause (decompiled, see ENGINE_FINDINGS.md) |
|---|---|
| ~0.36 ms + 0.46 ms per submesh | new vertex and index buffers, CPU copies |
| +0.75 ms `RenderShadows`, part of `RenderReflections` on first draw | every MatInstance of the object is deleted and rebuilt |
| memory growth until `be:reloadCollision()` | a new physics collision mesh per call |

Lua has no way around any of these. The only fix is to stop calling `createMesh` when only the
vertex heights of an existing tile change, and to write the new vertices into the buffer the tile
already has.

## Goal
- A rut change on an existing tile costs one buffer copy, not a `createMesh`.
- No visual change (rule: no visual trade-offs).
- The mod still works without the native part: any failed check falls back to `createMesh`.

Not goals: an own renderer, moving the stamping maths to C (about 1.5 ms of Lua, later if at all),
skipping the collision build by patching the engine (that design was stopped on 2026-11-10: not
redone here).

## Approach
A. **Helper called from Lua, in-place vertex writes.** Chosen (user, 2026-11-14).
B. A plus the stamping in C. Later, only if a profile asks for it.
C. Own D3D12 renderer for the mud. Rejected: months of work, breaks hardest on game updates.

Reference: the free polarmoon.io graphics plugin. It is one proxy DLL (`mswsock.dll` in `Bin64`,
loaded in place of the system one), hooks DXGI / D3D, runs Lua snippets in the game and refuses to
start on a game version it does not know. What we take from it: the loading pattern works on
BeamNG, and a version gate is mandatory. Its protected code was not examined.

Loading order to try: `ffi.load` of a DLL from GE Lua first (no file in `Bin64`, no hijack); a
proxy DLL only if the game blocks that.

## Engine facts used (BeamNG 0.40.5, exe md5 `3c69af2b…`, D3D12)
Image base 0x140000000. Verified on 2026-11-14: the installed exe has the same md5 as the Ghidra
copy in `~/beamng-decomp`.

| What | Where |
|---|---|
| ProceduralMesh vtable | 0x141dacf98 |
| `createMesh` (Lua binding) | 0x1401a60b0 |
| vertex buffer handle of submesh i (0..2) | obj + 0x2a0 + 16 i (qword), locked pointer at +8 |
| index buffer handle of submesh i | obj + 0x2d0 + 8 i |
| `GFXd3d12VertexBuffer` vtable | 0x1421abb48 |
| vertex buffer: vertex count / stride / type | vb + 0x30 / + 0x70 (44) / + 0x74 (0 = static) |
| lock (vtable + 0x68) | 0x140e09e40: `(vb, ctx, start, count, &ptr)`, hands out upload-heap staging |
| unlock (vtable + 0x78) | 0x140e09f60: `(vb, ctx)`, barriers + `CopyBufferRegion` |
| `ctx` passed to lock / unlock | global 0x142a352a0 |
| MatInstance list | obj + 0x240 |
| CPU copies for ray casts | obj + 0x388 / + 0x3a0 |
| PhysicsRep | obj + 0x3d0 |

Vertex layout, 44 bytes: position (12), normal (12), tangent (12), uv (8).
An object has at most 3 submeshes.

## Open risks
1. **Bindless draws may not read the vertex buffer.** The G-buffer shaders read vertices from a
   byte arena (t10). If the buffer is copied into the arena only at `createMesh`, an in-place
   write will not show. This decides the whole route: stage 1 answers it.
2. **Threading.** Lock and unlock record on the frame command list. `createMesh` does this from GE
   Lua on the main thread, so the same call from GE Lua should be as safe. Not proven.
3. **Stale CPU data.** Ray-cast copies, world box and collision keep the old heights. Mud meshes
   are not vehicle collision, but the camera ray and the bounds must be checked.
4. **Game updates** move every address. Each build needs its own table, found by signature scan;
   unknown build means fallback to `createMesh`.
5. **Crashes.** A wrong pointer kills the game. Reads are checked with `VirtualQuery`; writes only
   after stage 0 confirmed every offset on the running build.

## Stages
| # | Step | Writes to engine memory | State |
|---|---|---|---|
| 0 | Read-only probe: is `ffi.load` allowed, find the C++ object behind the Lua userdata, check vtables, vertex count, stride | no | run 11-14: `ffi.load` and pointer cdefs blocked by the game's sandbox; checks must move into a proxy DLL |
| 1 | One test mesh, away from the mod: lock, change heights, unlock. Does the picture change? Do shadows follow? | test mesh only | - |
| 2 | Measure: in-place write against `createMesh`, same mesh (ms per call, `RenderShadows`, memory) | test mesh only | - |
| 3 | Helper DLL: signature scan, build check, guarded write, one C function for Lua | - | proxy + build gate done and loading in game (11-14); Lua bridge, scan, write open |
| 4 | Hook into `tileMesh.present` behind a config switch, fallback kept; only for same-size updates | mod meshes | - |
| 5 | Bench (2 runs per variant, gridmap_v2) and visual comparison | - | - |

Stage 0 tool: `tools/benchmark/ge_extensions/dntestNative.lua`
(`extensions.load('dntestNative'); dump(dntestNative.run())`, in a loaded level).

## Log
- 2026-11-14: route chosen. polarmoon.io zip inspected without running it (loading pattern
  above). Buffer handle offsets read from the saved `createMesh` decompile. Stage 0 probe written;
  the game was not running, so nothing is measured yet. `ffi.load` is not removed anywhere in the
  shipped Lua, and GE Lua already uses `ffi.C` (debug draw), so it is expected to work: unconfirmed.
- 2026-11-14, stage 0 run (gridmap_v2): **the Lua route is dead.** BeamNG's LuaJIT build
  (`LuaJIT 2.1.1788767029`) has a sandbox compiled in: `ffi.cdef`/`ffi.load` are C functions (no Lua
  wrapper to get around). Measured in GE Lua (MCP and a file extension alike):
  `ffi.load('kernel32')` = "sandbox: ffi.load denied"; `ffi.cdef` rejects every pointer type and
  every function declaration ("invalid C type"; plain `typedef int/uint32_t/size_t` pass);
  `ffi.new('uint8_t*')` rejected, `ffi.new('uint8_t[4]')` allowed; `ffi.cast('void*', 0)` gives a
  number. So Lua cannot read engine memory at all: the probe's checks must move into the DLL.
  The exe exports no `lua_*` symbols (LuaJIT linked in statically): a DLL that wants to give Lua a
  function must find the Lua C API by signature scan. Exe imports `VERSION.dll`, `WINMM.dll`,
  `MSWSOCK.dll`, `dxgi.dll`, `d3d11.dll`, `d3d12.dll`; none is a KnownDLL on this PC, so any can be
  proxied from `Bin64`. polarmoon.io takes `mswsock.dll`; it is no longer supported, so ours takes
  `mswsock.dll` too (user, 2026-11-14): the two cannot be installed together. Toolchain: VS 18 Community (MSVC) is installed.
  polarmoon.io zip, static look only: 10.8 MB, wxWidgets UI, 6 MB `.vlizer` protected section,
  exports the mswsock pair + `CreateDXGIFactory*` + `D3D11CreateDevice`, strings "Plugin is not
  compatible with game version", `hookInit`, embedded `"lua": ""` snippets, D3D12 draw diagnostics.
- 2026-11-14: **own proxy built** (`native/`, not a patched polarmoon.io: its code is protected and
  licensed, and the only part we need is the loading trick). `native/dnnative.c` = `Bin64\mswsock.dll`:
  forwards the two imports the exe takes from mswsock (`AcceptEx`, `GetAcceptExSockaddrs`; checked
  with pefile) to `System32\mswsock.dll`, loaded on first call (not in `DllMain`). Build gate: exe
  `TimeDateStamp 0x6aec5214` + `SizeOfImage 0x4cec000` (0.40.5, md5 `3c69af2b…`), exported as
  `dn_build_ok()`. Writes one line to `<user folder>\deepnode_native.log` on load.
  `native/build.bat` builds it plus `test_load.exe` (offline check: exports present, forwarding
  reaches the real AcceptEx, gate off outside BeamNG): passes. Installed to `Bin64` 2026-11-14;
  first in-game load not checked yet (needs a game restart). Uninstall = delete `Bin64\mswsock.dll`.
  Next: the Lua bridge (find the Lua C API in the exe by signature, register `dnNative` in GE Lua).
- 2026-11-14, after a restart: **proxy loads in game.** Log shows `BeamNG.drive.x64.exe ts=0x6aec5214
  size=0x4cec000 build=known`; gridmap_v2 loads, DeepNode runs, no crash. Both `Bin64\MSWSOCK.dll`
  (ours) and `System32\mswsock.dll` are mapped in the game process. The DLL also loaded in the 6 CEF
  helper processes (same exe, `--type=renderer`, `--type=gpu-process`, ...): the gate now skips any
  process whose command line has `--type=` (rebuilt + offline test passes; that build goes in on the
  next restart, since the loaded DLL is locked).
