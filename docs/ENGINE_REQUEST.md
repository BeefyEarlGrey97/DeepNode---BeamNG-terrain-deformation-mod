# Engine feature request draft: in-place ProceduralMesh update

Draft for the BeamNG developers (not sent). Numbers are DeepNode measurements on BeamNG.drive
0.40, DirectX 12, gridmap_v2 (see ENGINE_FINDINGS.md).

## What DeepNode does

DeepNode draws deformable mud and sand ruts as `ProceduralMesh` tiles (5 m, 0.2 m cells) and
re-uploads a tile with `createMesh` whenever its ruts change: ~1,400 tile uploads per 20 s run with
4 trucks. Physics runs on the engine terrain (`setHeightGrid` + `updateGrid`), which works well.

## What an upload costs today

- `createMesh` CPU: ~0.2-0.35 ms per call + ~0.18 µs per face corner + ~0.38 µs per vertex.
- `RenderShadows` on the upload frame: +0.65-0.76 ms per call, also when re-uploading the same
  object with the same buffer sizes, also with `collisionType 'None'` and a material with
  `castShadows 0`. Not shader generation (`getShaderGenerationCount` flat). k uploads in one
  frame: +0.8 / 1.24 / 2.33 / 4.13 ms for k = 1 / 2 / 4 / 8 (close to linear).
- Engine memory grows with each upload whose buffer sizes differ from the object's previous
  ones and is not returned while the game runs.

For comparison, a raw D3D11 buffer update is well under a microsecond on the CPU.

## Request

1. An in-place update for an existing ProceduralMesh with unchanged topology, e.g.
   `obj:updateVertices(positions, normals)` (same vertex count and index buffer), that does not
   rebuild render instances or shadow-caster state. Unreal's
   `UDynamicMeshComponent::FastNotifyPositionsUpdated` and Unity's `Mesh.MarkDynamic` are the
   models.
2. Or a "dynamic" flag on ProceduralMesh that skips whatever per-`createMesh` setup the shadow
   pass pays for.
3. Longer term: a Lua-writable height/displacement texture a terrain overlay material can read
   (the route every AAA deformable-snow/mud system uses).

Expected effect for DeepNode: most of the fixed per-upload cost (~1.2 ms CPU + ~0.6 ms render
per upload) would go, which is the remaining gap to the frame rate with the mod off.
