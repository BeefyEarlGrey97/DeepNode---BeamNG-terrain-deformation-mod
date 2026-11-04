-- Offline test: which widgets each GUI tab draws.
-- run: luajit tests/gui_tabs_test.lua   (from the mod root)
-- A stub ui_imgui records every labelled widget under the tab that is open.

local drawn = {}         -- tab label -> { widget label -> true }
local tab = nil
local function rec(label) if tab and type(label) == 'string' then drawn[tab][(label:gsub('###.*', ''):gsub(' %(.*', ''))] = true end end
local function ptrf(v) return function() return { [0] = v } end end
local im = setmetatable({
  BoolPtr = ptrf(false), FloatPtr = ptrf(0), IntPtr = ptrf(0),
  ArrayFloat = function() return { [0] = 1, 1, 1 } end,
  ImVec2 = function() return {} end, ImVec4 = function() return {} end,
  Begin = function() return true end,
  BeginTabBar = function() return true end,
  BeginTabItem = function(l) tab = l; drawn[l] = {}; return true end,
  EndTabItem = function() tab = nil end,
  Button = function(l) rec(l); return false end,
  Checkbox = function(l, p)
    rec(l)
    if CLICK and l:find(CLICK, 1, true) == 1 then p[0] = not p[0]; return true end
    return false
  end,
  SliderFloat = function(l) rec(l); return false end,
  SliderInt = function(l) rec(l); return false end,
  ColorEdit3 = function(l) rec(l); return false end,
  SeparatorText = function(l) rec(l) end,
}, { __index = function() return function() return false end end })
ui_imgui = im
setExtensionUnloadMode = function() end
log = function(_, _, msg) error(msg) end
Engine = {}

local cfg = { ring = {}, clods = { kinds = {} }, debug = {} }
extensions = {
  deepnode_main = {
    cfg = cfg, isRunning = function() return true end, debugChunks = function() return false end,
    stats = function() return { perf = {} } end, vehicleStats = function() return {} end,
    zoneCount = function() return 0 end, private = {},
    materialRows = function()
      return { { label = 'SNOW_DEEP', kind = 'snow', on = true, default = true },
               { label = 'DIRT_LOOSE', kind = 'mud', on = false, default = false } }
    end,
    setMaterialTick = function(label, on) TICKED = { label, on }; return true end,
    materialTicksPending = function() return TICKED ~= nil end,
  },
}

local gui = dofile('lua/ge/extensions/deepnode/gui.lua')
gui.onExtensionLoaded()
gui.open()
gui.onUpdate(0.016)

local fails = 0
local function expect(cond, msg) if not cond then fails = fails + 1; print('FAIL ' .. msg) else print('ok   ' .. msg) end end

expect(drawn.Run and drawn.Debug, 'Run and Debug tabs drawn')
for _, w in ipairs({ 'Add zone here', 'Clear zones', 'Zone radius', 'Zone depth' }) do
  expect(not drawn.Run[w], w .. ' not on Run tab')
  expect(drawn.Debug[w], w .. ' on Debug tab')
end
expect(drawn.Run['Start'] or drawn.Run['Stop'], 'Start/Stop stays on Run tab')

-- deformable ground list: one checkbox per ground model row, ticking calls setMaterialTick
expect(drawn.Run['Deformable ground'], 'Run tab has the Deformable ground section')
expect(drawn.Run['SNOW_DEEP'] and drawn.Run['DIRT_LOOSE'], 'one checkbox per ground model row')
CLICK = 'DIRT_LOOSE'
gui.onUpdate(0.016)
expect(TICKED and TICKED[1] == 'DIRT_LOOSE' and TICKED[2] == true, 'ticking DIRT_LOOSE calls setMaterialTick(DIRT_LOOSE, true)')
CLICK = nil
os.exit(fails == 0 and 0 or 1)
