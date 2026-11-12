# DeepNode v0.8.1 — physics tune-up (2026-11-12)

## Changed
- **Dig belly-deep**: in heavy mode mud ruts can go 0.65 m deep (was 0.35 m), and spinning /
  rocking digs further (`kinds.mud.spinDigMax` 0.3). Rocking a Ural 60 s on fresh mud: tyre sink
  0.22 -> 0.54 m. A first pass digs the same as before.
- **Belly support** (`stamp.bellySupport`, on): the physics floor follows what the tyres carved,
  not body / hull dents, so a dug-in truck rests on the mud between its ruts.
- **Slick tyres** (`clods.grip`): a mud-coated tyre grips less (friction x 1 - 0.45 x coat).
  Deflated tyres are skipped; reset / unload / mod stop restore the jbeam values.

## Also
- DeepNode logo in the README and the mod window.

## Known
- A truck still never fully bogs down (OPEN_ISSUES 33): deep-mud traction comes from the ground
  model's drag on submerged tread nodes, not tyre friction.

Install: drop `DeepNode-v0.8.1.zip` into `mods/`.
