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
  Checkbox = function(l) rec(l); return false end,
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
os.exit(fails == 0 and 0 or 1)
