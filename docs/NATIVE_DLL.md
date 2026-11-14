# Native route: in-place mesh updates (living document)

Status: **proxy loads in game; Lua bridge built, not yet run in game** (last update 2026-11-14).
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
| 3 | Helper DLL: signature scan, build check, guarded write, one C function for Lua | - | proxy + build gate loading in game (11-14); Lua bridge built (11-14, offline-tested, not run in game); scan, write open |
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
- 2026-11-14: **moved to its own edition.** Branch `exotic` = DeepNode Exotic (Lua mod + native
  helper); `test`/`main` stay Lua-only (native commit reverted there, `exotic` merged that revert with
  `-s ours`, so later `git merge test` on exotic keeps `native/`). Local mod folder
  `mods/unpacked/deepnode_exotic` is a git worktree of `exotic`. Both editions share every Lua path:
  enable only one in the mod manager.

- 2026-11-14: **Lua bridge built** (offline tests pass, not yet run in game). Trigger: the sandbox
  gate 0x141215780 is `mov eax,[0x144a676e0]; ret` + 10 bytes int3 padding. On a known build the DLL
  checks those bytes and that the `call` at 0x14126caea (inside `ffi.load`) targets it, then
  overwrites the gate with `mov rax, dn_gate; jmp rax`. `dn_gate` returns the same flag; only when
  its return address is the `ffi.load` site and the thread is the main thread (the one that ran
  `DllMain`: mswsock is a static import) it reads the GE `lua_State` (global 0x142c274f8, +0x30,
  checks `gct == 6` at +9 = LuaJIT GC64 thread) and sets global `dnNative` = { `buildOk`, `version`,
  `probe` }. `ffi.load` itself stays denied. So GE Lua does `pcall(ffi.load, 'dnnative')`, then uses
  `dnNative`. Re-registers on every such call, so a Lua reload (new state) just calls it again.
  `dnNative.probe(proceduralMesh)` = the stage 0 read-only checks moved into C (object behind the
  userdata, VB vtable / count / stride / type per submesh), returned as strings (`lua_pushnumber` not
  pinned yet; `lua_pushfstring` `%d`/`%p`). Addresses hardcoded behind the build gate (shortcut until a
  second build). Test: `tools/benchmark/ge_extensions/dntestNative.lua`; offline: `native/out/test_bridge.exe`.
  Open: GE Lua on the main thread? (the log says "ffi.load off the main thread" if not.)

## Lua C API (from the existing Ghidra project, 2026-11-14, NOT re-analysed)
Found in the already-decompiled sandbox output (`~/beamng-decomp/out_sbx2/`), no new Ghidra run.
`FUN_14124e3f0` is LuaJIT's `ll_loadfunc` (lib_package.c): the strings `LOADLIB: %s`, `_LOADLIB`,
`luaopen_%s`, `luaJIT_BC_%s` fix it against LuaJIT source, so each helper it calls is a public Lua
C API function. Addresses absolute (image base 0x140000000); RVA = addr - base.

| Address | RVA | Lua C API | Confidence |
|---|---|---|---|
| 0x141211f10 | 0x1211f10 | `lua_pushfstring(L,fmt,...)` | high (two call sites, "LOADLIB: %s") |
| 0x1412117e0 | 0x12117e0 | `lua_gettable(L,idx)` | high (reg cache lookup) |
| 0x141212ba0 | 0x1212ba0 | `lua_isnil`/type check (L,idx)->int | med |
| 0x141212b20 | 0x1212b20 | `lua_touserdata(L,idx)` | high |
| 0x1412127b0 | 0x12127b0 | `lua_settop` (= lua_pop) | high |
| 0x141211b40 | 0x1211b40 | `lua_newuserdata(L,sz)` | high |
| 0x141210fb0 | 0x1210fb0 | `luaL_setmetatable`/getmetatable("_LOADLIB") | med |
| 0x1412121a0 | 0x12121a0 | `lua_pushvalue(L,idx)` | high |
| 0x141212740 | 0x1212740 | `lua_settable(L,idx)` | high |
| 0x1412120c0 | 0x12120c0 | `lua_pushstring(L,s)` | high |
| 0x141211e00 | 0x1211e00 | `lua_pushboolean(L,b)` | high ('*' branch) |
| 0x141211e40 | 0x1211e40 | `lua_pushcclosure(L,fn,n)` | high — the registration anchor |
| 0x141215780 | 0x1215780 | sandbox gate ()->int, 0 = denied | high (44 callers: all loadlib/os/io) |

The registration anchor is `lua_pushcclosure` (0x141211e40): push our C function, then `lua_setfield`
to hang it on a global table. These RVAs are per-build; the DLL must signature-scan, not hardcode.
Still to find for the bridge: the **GE `lua_State*` global**, `lua_setfield`/`lua_setglobal`,
`lua_gettop`, `lua_tonumber`/`tointeger`, `lua_pushnumber`/`pushinteger`. `lua_touserdata`
(0x141212b20) already gives the ProceduralMesh pointer from a Lua userdata.
Flipping 0x141215780 to non-zero would let `ffi.load` work from Lua, but that is not the plan
(fragile global patch); we register our own cfunction instead.

### Rest of the bridge (same Ghidra project, read-only, 2026-11-14 pass 2)
Found by callers/strings sweeps over the existing `bng` project (`out_lua2`, `out_ns`, `out_si`), no
re-analysis. New `run_script.bat` passes (DecompByStrings / DecompCallers, `-noanalysis -readOnly`).

| Address | RVA | Symbol | How found | Conf |
|---|---|---|---|---|
| 0x141212530 | 0x1212530 | `lua_setfield(L,idx,k)` | reg template FUN_14011abf0, right after pushcclosure | high |
| 0x141211260 | 0x1211260 | `lua_createtable(L,na,nh)` | same, builds module table | med |
| 0x1412129e0 | 0x12129e0 | `lua_tolstring(L,idx,len)` | Lua panic fn reads error msg | high |
| 0x1412131e0 | 0x12131e0 | `lua_error(L)` (no return) | end of luaL_argerror | high |
| 0x141214a70 | 0x1214a70 | `luaL_ref(L,t)` | reg template, stores into REGISTRYINDEX | med |
| 0x141212ca0 | 0x1212ca0 | `luaL_argerror(L,n,msg)` | string "bad argument #%d.." | high |
| 0x141214690 | 0x1214690 | `luaL_newstate()` | installs the panic fn as atpanic | high |

**GE lua_State (the bootstrap target):** `engine::GameEngineLua` global at **0x142c274f8**
(RVA 0x2c274f8); its ctor path (`FUN_140798370`, calls `luaSandboxInit` with `"lua/ge/main.lua"`)
stores the state from `luaL_newstate` at **object + 0x30**. So in the DLL:
`lua_State* L = *(void**)(*(uintptr_t*)(base+0x2c274f8) + 0x30);` (verify both derefs before use).

**Bootstrap path now complete:** get L (above) -> `lua_createtable` / push a global table ->
`lua_pushcclosure`(0x141211e40) + `lua_setfield`(0x141212530) per function. Inside a call:
`lua_touserdata`(0x141212b20) gives the ProceduralMesh ptr, `lua_tolstring`(0x1412129e0) a packed
data string, `lua_error`(0x1412131e0) to fail.

**Still to pin** (generic, high-volume; entry region = callers of typerror 0x1412130a0): `lua_gettop`,
`lua_tonumber`/`tointeger`, `lua_pushnumber`/`pushinteger`. Needed only once the arg/return data path
(Lua table vs packed string) is chosen.

**Aside — `engine::luaSandboxInit` (FUN_14079cde0):** the sandbox is ON by default; launching BeamNG
with **`-disable-sandbox`** turns it off, which would make `ffi.load` work from Lua and skip the DLL
bridge entirely. Rejected for shipping (disables all sandbox protection, is a per-user launch flag),
but useful for local bring-up/testing of the write logic in plain Lua before the DLL is ready.
