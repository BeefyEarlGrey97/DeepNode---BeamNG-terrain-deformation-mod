# Handoff: createMesh cost research (2026-11-10)

BeamNG 0.40.5, D3D12. The exe md5 is `3c69af2b…`, the same file as the Ghidra copy in
`~/beamng-decomp`. All results come from static reading of the decompiled exe, the stock shaders
and the shader cache. Nothing was tested in game. Full write-up: `docs/ENGINE_FINDINGS.md`
(ProceduralMesh section, and "GPU height map for the own slot" under Custom shaders). Commits on
`test`: `ae8d3f0`, `502a1c7`.

## Goal
Cut the per-upload engine cost of `ProceduralMesh:createMesh` with no visual change (rule:
`feedback-no-visual-tradeoffs`). The cost: ~0.36 ms per call + 0.46 ms per submesh, plus
+0.75 ms `RenderShadows` and part of `RenderReflections` on the first draw after each call.

## The three routes the user proposed
1. **Skip the collision build** (stub `updatePhysicsCollision`, vtable +0x1b8, via ffi). Stopped:
   a safety classifier ended the design mid-way. **Do not redo it.** The supported part already
   exists: the `be:reloadCollision()` compaction frees the memory.
2. **In-place vertex buffer write.** The D3D12 static VB is re-lockable: lock `0x140e09e40` hands
   out an upload-heap staging block, unlock `0x140e09f60` does barriers + `CopyBufferRegion`. But
   Lua has no API for it: it would need native calls into engine objects. **New risk:** bindless
   draws read their vertices from the arena (t10), so a VB rewrite may not show on screen. Not built.
3. **Shadow cost.** Root cause found. Every `createMesh` (`0x1401a60b0`) deletes all of the
   object's MatInstances (list at obj+0x240), at the start and at the end. The next prepRenderImage
   (`0x1401aa2b0`) calls `updateMaterial` (`0x1401abc20`), which makes one MatInstance per
   distinct material. Then every pass rebuilds its hook. `ShadowMaterialHook::init`
   (`0x1404cb370`) allocates a new ShadowMatInstance (0x788 B). Prepass and reflection-depth hooks
   do the same. There is no cache, cvar or field to avoid it. **Dead end for Lua.**

Other facts:
- The exe exports only 15 C functions (`BNG_DBG_DRAW_*` + GPU hints). There is no native mesh API.
  BeamNGpy (tech) talks to the same GE Lua.
- The sun PSSM has no static-caster cache. The "still caster keeps cached depth" settings are for
  local-light cluster shadows only.
- ProceduralMesh vtable `0x141dacf98` (inherits SceneObject directly). castRay = +0x1e8/+0x1f0/+0x1f8.

## Live route: GPU height map in the own shader slot
Idea: upload each tile once, stamp ruts into a PostEffect target, and displace in the VS. Then a
deepening needs no `createMesh` at all, which removes the material rebuild, the collision build and
the upload.
- Own slot: a ShaderData named `ParallaxInteriorShaderData` (proven 11-07: VS displacement of a
  ProceduralMesh).
- Texture access: bindless shaders can index the global `materialTextures2D[65536]` (t26
  space0, `materialInputBindless.h.hlsl`). **Missing link: getting the target's table index
  into our shader.** CustomMaterial `sampler` fields are ignored in this slot.
- Materials do resolve `#name` textures. The bindless material init `0x1407fb4a0` calls
  `NamedTexTarget::find` `0x1407ed3d0`. Which material field feeds it is not identified.
- Shadow: the hook keeps our own CustomMaterial when its vtable +0x1b8 is true. That is the
  bindless flag the slot sets (`0x1407be400` reads `[mat+0xb28]+0xf1`), so the shadow pass should
  run our VS. Unproven: the 11-07 cache holds no shadow permutation of the test shader.
- The G-buffer pass DID run our shader (an `MFT_PrePassConditioner` permutation is in the cache).

## Next step (needs the game running; new shaders have crashed the game before)
Live probe:
1. Create a PostEffect named target (overlay ping-pong recipe) and write a magic texel into it.
2. Give a standard Material that target as a texture (`baseColorMap = "#dnH"`) on a test mesh.
   Does the target show?
3. Make a slot shader that scans `materialTextures2D[i]` for the magic texel and writes the found
   index as colour. Read it with a screenshot.
4. After a sunlit frame, check `temp/shaders/shaders.d3d12.db` for a shadow permutation of the
   shader.
No cbuffers in the custom shader: `perDraw` cbuffers crashed the game.

## Tools
- Ghidra project `~/beamng-decomp/gproj`. Run scripts from bash:
  `cmd //c "C:\\Users\\Admin\\beamng-decomp\\run_script.bat" <Script>.java <a1> <a2> <a3>`
  (max 3 args, full path).
- Scripts: DecompByStrings, DecompCallers, DecompCallees (new), DumpVtable (new).
- Leftover folders `~/beamng-decomp/out_vt`, `out_vt2` (a safety check blocked the cleanup).
