# DeepNode v0.1.3 — gradual tyre mud, heavy physics by default, decal roads switch (2026-10-29)

## Tyre mud
- **Builds up gradually:** a tyre in mud now takes several seconds to cake up (coverage ~0.6 after
  6.5 s at 18 km/h on a Percheron; before, fully covered in ~3 s with visible jumps). The drawn
  coverage steps every 0.25 s per wheel instead of 0.5 s.
- **No more snapping colour:** when a wheel goes from mud to sand, sand to mud, or onto hard ground,
  the coat keeps its look for 1 s, then blends over 1 s; the mud/sand texture swaps half way.
  Before, colour and texture switched within ~0.3 s.
- **Falls off faster:** cleaning starts 1 s after leaving the mud (was 2 s); the loose layer drops
  in under a second, the packed layer wears off about 10x faster than before.
- New settings: `clods.lookDelay`, `lookFade`, `coverUpRate`, `coverDownRate`, `colorFlushGap`
  (see docs/REFERENCE.md).

## Defaults
- **Heavy physics is the default.**
- **"Experimental decal road"** (DeepNode window, Run tab, was "Decal roads on mud"), off by default:
  - Off: no decal road shows on the mud or sand. Every decal road that touches soft ground is
    hidden whole (also its stretch on hard ground right next to the mud).
  - On: the decal roads show on the mud and sand again (the level's own on undug mud, drawn into
    the mud meshes elsewhere).
  - Switches live, the setting is saved.

## Fixed
- Switching the decal roads off and on left garbage strips on the mud (the overlay materials were
  deleted while still in use).
- Decal overlay flickered against the mud surface beyond ~10 m (lifted 4 -> 8 mm).

## Measured (gridmap_v2, one Percheron on a 60 m circle through the mud and sand pits, heavy physics)
- 59.7 fps mean (vsync on), ~4.5 tyre material updates per second.
- Mod start: 238 decal roads hidden in 62 ms.
- No 8-truck benchmark was run for this release; the rendering and rut pipeline are unchanged since
  v0.1.2 (see its notes: 45.3 fps vanilla physics, 8 trucks).

## Install
Download `DeepNode-v0.1.3.zip` and drop it, unextracted, into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\`. Remove the older DeepNode zip (or an unpacked
copy) first. Settings saved in `<user folder>/settings/deepnode/gui.json` override the new defaults:
if you saved physics or decal-road settings before, set them again in the DeepNode window.

## Known issues
- Frame rate with 8 trucks: ~45 fps in vanilla mode (75-79 with the mod off): every mesh upload
  costs engine time.
- With the decal roads on, vanilla physics mud shows them duller than the game draws them (alpha clip).
- Rut deepening behind the front axle can lag seconds in existing ruts.
- Sand still uses the full mud mesh in heavy mode.
