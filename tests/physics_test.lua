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
      staticFrictionCoefficient = 0.35, slidingFrictionCoefficient = 0.32 } },
    floorLift = { mud = 1.0 } } } },
  private = {},
  layerKindAt = function() return kindAt[1], kindAt[2] end,
}
local ph = dofile('lua/ge/extensions/deepnode/physics.lua')
local layers = {
  [0] = { name = 'Mud', gm = 'MUD', soft = true, kind = 'mud' },
  [1] = { name = 'Grass', gm = 'GRASS', soft = true, kind = 'mud', byHand = true },
  -- Camodo-like: DIRT used by a default soft layer and by a hand-ticked one
  [2] = { name = 'Mud2', gm = 'DIRT', soft = true, kind = 'mud' },
  [3] = { name = 'Dirt', gm = 'DIRT', soft = true, kind = 'mud', byHand = true },
}
ph.start(main, layers)
local G, D = core_environment.groundModels.GRASS.cdata, core_environment.groundModels.DIRT.cdata
expect(setCalls.GRASS == 1, 'hand-ticked GRASS gets heavy values (setGroundModel called)')
expect(math.abs(G.defaultDepth - 0.2) < 1e-6 and G.fluidDensity == 20000, 'GRASS soft layer depth and density from the mud kind')
expect(math.abs(G.staticFrictionCoefficient - 0.61) < 1e-6, 'GRASS keeps the level friction (no slick mud grip)')
expect(math.abs(D.staticFrictionCoefficient - 0.35) < 1e-6, 'DIRT with a default soft layer gets the full mud values')

kindAt = { 'mud', true }
expect(math.abs(ph.initialLift(0, 0, 0.35) - 0.35) < 1e-6, 'hand-ticked layer gets the kind floor lift (terrain stays at the surface)')

ph.stop()
expect(math.abs(G.defaultDepth - 0.05) < 1e-6 and math.abs(G.staticFrictionCoefficient - 0.61) < 1e-6, 'stop puts GRASS back')
os.exit(fails == 0 and 0 or 1)
