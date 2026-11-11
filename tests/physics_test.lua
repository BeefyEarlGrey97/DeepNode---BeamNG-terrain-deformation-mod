-- Offline test: heavy physics for ground models ticked by hand in the Run tab (deepnode_physics).
-- run: luajit tests/physics_test.lua   (from the mod root)
-- Stub engine: core_environment.groundModels entries + be:setGroundModel.

local fails = 0
local function expect(cond, msg) if not cond then fails = fails + 1; print('FAIL ' .. msg) else print('ok   ' .. msg) end end

log = function() end
setExtensionUnloadMode = function() end
local function gm(depth, sf, rho)
  return { cdata = { staticFrictionCoefficient = sf, slidingFrictionCoefficient = sf - 0.05, defaultDepth = depth,
    fluidDensity = rho, flowConsistencyIndex = 100, hydrodynamicFriction = 0, stribeckVelocity = 4, strength = 1,
    roughnessCoefficient = 0, flowBehaviorIndex = 0.5, dragAnisotropy = 0, shearStrength = 0 } }
end
core_environment = { groundModels = { GRASS = gm(0.05, 0.61, 8000), MUD = gm(0.25, 0.35, 20000), DIRT = gm(0, 0.7, 14000) } }
local setCalls = {}
be = { setGroundModel = function(_, name, c) setCalls[name] = (setCalls[name] or 0) + 1 end }

local kindAt = { 'mud', false }
local main = {
  cfg = { physics = { mode = 'heavy', heavy = {
    groundModels = { mud = { defaultDepth = 0.2, flowConsistencyIndex = 17000, fluidDensity = 20000,
      staticFrictionCoefficient = 0.35, slidingFrictionCoefficient = 0.32 },
      firm = { defaultDepth = 0.06, flowConsistencyIndex = 3000 } },
    floorLift = { mud = 1.0, firm = 1.0 } } } },
  private = {},
  layerKindAt = function() return kindAt[1], kindAt[2] end,
}
local ph = dofile('lua/ge/extensions/deepnode/physics.lua')
local layers = {
  [0] = { name = 'Mud', gm = 'MUD', soft = true, kind = 'mud' },
  [1] = { name = 'Grass', gm = 'GRASS', soft = true, kind = 'firm', byHand = true },
  -- Camodo-like: DIRT used by a default soft layer and by a hand-ticked one
  [2] = { name = 'Mud2', gm = 'DIRT', soft = true, kind = 'mud' },
  [3] = { name = 'Dirt', gm = 'DIRT', soft = true, kind = 'mud', byHand = true },
}
ph.start(main, layers)
local G, D = core_environment.groundModels.GRASS.cdata, core_environment.groundModels.DIRT.cdata
expect(setCalls.GRASS == 1, 'hand-ticked GRASS gets heavy values (setGroundModel called)')
expect(math.abs(G.defaultDepth - 0.06) < 1e-6 and G.flowConsistencyIndex == 3000 and G.fluidDensity == 8000,
  'GRASS gets the thin firm soft layer, density stays the level one')
expect(math.abs(G.staticFrictionCoefficient - 0.61) < 1e-6, 'GRASS keeps the level friction (no slick mud grip)')
expect(math.abs(D.staticFrictionCoefficient - 0.35) < 1e-6, 'DIRT with a default soft layer gets the full mud values')

kindAt = { 'mud', true }
expect(math.abs(ph.initialLift(0, 0, 0.35) - 0.35) < 1e-6, 'hand-ticked layer gets the kind floor lift (terrain stays at the surface)')

-- belly support: the floor follows tyre-carved levels (t.sup), not body dents
do
  local NW = 11
  local function dec(t, idx, c) local r, f = t.rest[idx], t.floor[idx]; return f + (r - f) * math.min(c, 128) / 128 end
  local t = { rest = {}, floor = {}, rut = {} }
  for i = 0, NW * NW - 1 do t.rest[i], t.floor[i], t.rut[i] = 0, -0.65, 128 end
  main.N, main.cps, main.KEY, main.tiles = 10, 5, 1000, { [0] = t }
  main.ter = { localZ = false, oz = 0 }
  main.decodeZ = function(tt, idx) return dec(tt, idx, tt.rut[idx]) end
  main.decodeCode = dec
  main.private.sinkLift0, main.private.sinkBase = { [1] = 0.6 }, { [1] = -0.65 }
  local h = { floorReach = 0.3, floorMargin = 0.03 }
  local idx = 5 * NW + 5
  t.rut[idx] = 64 -- drawn at -0.325 (a body dent)
  main.private.supOn = true
  local l, carved = ph.wantedLiftForTests(1, 1, 1, h)
  expect(carved and math.abs(l - 0.6) < 1e-6, 'body dent only: carved (drawn low) but the floor stays up')
  t.sup = {}
  for i = 0, NW * NW - 1 do t.sup[i] = 128 end
  t.sup[idx] = 80 -- the tyre was at -0.24375
  l = ph.wantedLiftForTests(1, 1, 1, h)
  expect(math.abs(l - (-0.24375 - 0.03 + 0.65)) < 1e-6, 'tyre level under a deeper dent: floor at the tyre level')
  main.private.supOn = false
  l = ph.wantedLiftForTests(1, 1, 1, h)
  expect(math.abs(l - (-0.325 - 0.03 + 0.65)) < 1e-6, 'bellySupport off: floor follows the drawn dent')
end

ph.stop()
expect(math.abs(G.defaultDepth - 0.05) < 1e-6 and math.abs(G.staticFrictionCoefficient - 0.61) < 1e-6, 'stop puts GRASS back')
os.exit(fails == 0 and 0 or 1)
