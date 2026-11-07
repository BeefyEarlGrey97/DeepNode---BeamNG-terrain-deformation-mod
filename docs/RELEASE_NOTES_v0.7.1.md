# DeepNode v0.7.1 — hotfix: safer defaults

Defaults changed (your saved GUI settings in `settings/deepnode/gui.json` still win):
- Pre-rutted decal roads: **off** (`roads.preRut` false). Tick "Pre-rutted roads (beta)" on the Run tab and Restart to use them.
- Decal roads on mud: **none** (`roads.mode` 'off'): no decal road over soft ground, terrain material only. The "Decal roads on mud" button cycles off / vanilla / copies.

Also in this build (since v0.7.0): road mode 'vanilla', print depth shading and wet mud rim.

No code changes in this hotfix; benchmark numbers as in v0.7.0.
