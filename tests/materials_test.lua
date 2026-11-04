-- Offline test: terrain material rows for the Run tab tick list (deepnode_materials).
-- run: luajit tests/materials_test.lua   (from the mod root)
-- Layer lists are the real ones of the levels (internalName, groundmodelName).

local mat = dofile('lua/ge/extensions/deepnode/materials.lua')
local fails = 0
local function expect(cond, msg) if not cond then fails = fails + 1; print('FAIL ' .. msg) else print('ok   ' .. msg) end end

local function layers(list)
  local t = {}
  for i, p in ipairs(list) do t[i - 1] = { name = p[1], gm = p[2] } end
  return t
end
local function rowsByLabel(ls)
  local by = {}
  for _, r in ipairs(mat.rows(ls)) do by[r.label] = r end
  return by
end

-- johnson_valley
local jv = layers({ { 'rockydirt', 'DIRT_ROCKY' }, { 'Grass2', 'SAND' }, { 'dirt_sandy', 'DIRT_SANDY' },
  { 'dirt_rocky', 'DIRT_ROCKY' }, { 'dirt_rocky_large', 'DIRT_ROCKY_LARGE' }, { 'dirt_loose', 'DIRT_LOOSE' },
  { 'asphalt', 'ASPHALT' }, { 'asphalt2', 'ASPHALT' }, { 'dirt_loose_dusty', 'DIRT_LOOSE_DUSTY' }, { 'sand', 'SAND' },
  { 'dirt_grass', 'DIRT_GRASS' }, { 'Dirt', 'DIRT_ROCKY' }, { 'groundmodel_asphalt1', 'ASPHALT' }, { 'Grass', 'GRASS' } })
local r = rowsByLabel(jv)
expect(r.SAND and r.SAND.default and r.SAND.kind == 'sand', 'JV SAND row ticked by default, kind sand')
expect(#r.SAND.layers == 2, 'JV SAND row holds Grass2 and sand')
expect(r.DIRT_SANDY and r.DIRT_SANDY.default and r.DIRT_SANDY.kind == 'sand', 'JV DIRT_SANDY ticked, kind sand')
expect(r.DIRT_ROCKY and not r.DIRT_ROCKY.default and r.DIRT_ROCKY.kind == 'firm', 'JV DIRT_ROCKY listed, unticked, kind firm')
expect(#r.DIRT_ROCKY.layers == 3, 'JV DIRT_ROCKY row holds rockydirt, dirt_rocky, Dirt')
expect(r.GRASS and not r.GRASS.default and r.GRASS.kind == 'firm', 'JV GRASS listed, unticked, kind firm')
expect(r.ASPHALT == nil, 'JV ASPHALT hidden')

-- polish_roads_winter (map ships SNOW_DEEP / ASPHALT_SNOW / ASPHALT_SLUSH)
local pw = layers({ { 'groundmodel_asphalt1', 'ASPHALT_SLUSH' }, { 'groundmodel_asphalt_broken', 'SNOW' },
  { 'Asphalt_wet', 'ICE' }, { 'Slonecznik', 'ASPHALT_SNOW' }, { 'Grass', 'SNOW_DEEP' }, { 'Pszenica', 'SNOW_DEEP' },
  { 'dirt_grass', 'SNOW_DEEP' }, { 'Rock', 'ICE' }, { 'Piaseczek', 'SNOW_DEEP' }, { 'Bruczek', 'ICE' }, { 'Bruczekdwa', 'ICE' } })
r = rowsByLabel(pw)
expect(r.SNOW_DEEP and r.SNOW_DEEP.default and r.SNOW_DEEP.kind == 'snow', 'PW SNOW_DEEP ticked, kind snow')
expect(#r.SNOW_DEEP.layers == 4, 'PW SNOW_DEEP holds 4 layers')
expect(r.ICE == nil and r.ASPHALT_SNOW == nil and r.ASPHALT_SLUSH == nil, 'PW ice and snowy asphalt hidden')
expect(r.SNOW == nil, 'PW SNOW on layer groundmodel_asphalt_broken hidden (a road layer)')

-- automation_test_track: the ice layer has ground model SNOW
local att = layers({ { 'groundmodel_asphalt1', 'ASPHALT' }, { 'concrete', 'ASPHALT' }, { 'dirt_dusty', 'DIRT_DUSTY' },
  { 'dirt_loose', 'DIRT_LOOSE' }, { 'Sand', 'BEACHSAND' }, { 'mud', 'MUD' }, { 'grass', 'GRASS' }, { 'grass2', 'GRASS2' },
  { 'grass3', 'GRASS3' }, { 'grass4', 'GRASS' }, { 'dirt_grass', 'DIRT_GRASS' }, { 'Forest', 'FOREST' },
  { 'Rock_cliff', 'ROCK' }, { 'ice', 'SNOW' }, { 'snow', 'SNOW' } })
r = rowsByLabel(att)
expect(r.SNOW and r.SNOW.default and r.SNOW.kind == 'snow', 'ATT SNOW ticked, kind snow')
expect(#r.SNOW.layers == 1 and r.SNOW.layers[1].name == 'snow', 'ATT SNOW row leaves the ice layer out')
expect(r.MUD and r.MUD.default and r.MUD.kind == 'mud', 'ATT MUD ticked')
expect(r.BEACHSAND and r.BEACHSAND.default and r.BEACHSAND.kind == 'sand', 'ATT BEACHSAND ticked, kind sand')
expect(r.FOREST and not r.FOREST.default, 'ATT FOREST listed, unticked')
expect(r.ROCK == nil, 'ATT ROCK hidden')

-- Camodo: layer Mud on ground model DIRT (soft by its name), Dirt on DIRT (not)
local cam = layers({ { 'Mud', 'DIRT' }, { 'Dirt', 'DIRT' }, { 'Snowy', 'SNOW' }, { 'Rock', 'Rock' } })
r = rowsByLabel(cam)
expect(r.DIRT and r.DIRT.kind == 'mud', 'Camodo DIRT row kind mud')
local soft = {}
for _, L in ipairs(r.DIRT.layers) do soft[L.name] = L.default end
expect(soft.Mud == true and soft.Dirt == false, 'Camodo default per layer: Mud soft, Dirt hard')
expect(r.Rock == nil and r.ROCK == nil, 'Camodo lower-case Rock ground model hidden')

-- a layer without a ground model is listed by its own name
r = rowsByLabel(layers({ { 'BeachSand', 'BEACHSAND' }, { 'Grass', '' } }))
expect(r.GRASS and not r.GRASS.default, 'empty ground model: row labelled by the layer name')

-- ticks: apply(layers, ticks) sets soft, kind and byHand (ticked beyond the defaults)
local ls = layers({ { 'sand', 'SAND' }, { 'dirt_loose', 'DIRT_LOOSE' }, { 'asphalt', 'ASPHALT' } })
mat.apply(ls, nil)
expect(ls[0].soft and ls[0].kind == 'sand' and not ls[0].byHand, 'no ticks: defaults (sand soft)')
expect(not ls[1].soft and not ls[2].soft, 'no ticks: dirt_loose and asphalt hard')
mat.apply(ls, { SAND = false, DIRT_LOOSE = true, ASPHALT = true })
expect(not ls[0].soft, 'unticked SAND: hard')
expect(ls[1].soft and ls[1].kind == 'firm' and ls[1].byHand, 'ticked DIRT_LOOSE: soft, kind firm, marked byHand')
expect(mat.kindOf('MUD') == 'mud' and mat.kindOf('DIRT_SANDY') == 'sand' and mat.kindOf('SNOW_DEEP') == 'snow', 'kindOf keeps mud / sand / snow ground models')
expect(not ls[2].soft, 'a tick on a hidden ground model does nothing')

os.exit(fails == 0 and 0 or 1)
