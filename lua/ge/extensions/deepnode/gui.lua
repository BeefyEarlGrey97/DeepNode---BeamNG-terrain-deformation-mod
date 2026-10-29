-- deepnode_gui
-- Small ImGui window with three tabs: Run, Config, Debug.
-- Cost rules (the old window made Lua garbage every frame):
--  * nothing runs while the window is closed;
--  * readouts are formatted twice a second into a line list; a frame only draws them;
--  * config sliders write straight into deepnode_main.cfg and are saved to
--    /settings/deepnode/gui.json one second after the last change (main merges that file
--    over config.json at every start, so changes survive restarts).
-- ui_imgui (lua/common/extensions/ui/imgui_luaintf.lua): Begin/End, BeginTabBar/Item,
-- Button, Checkbox, SliderFloat, SliderInt, TextUnformatted, PushStyleColor2, PlotLines1.

local M = {}

local sfmt = string.format
local im = nil
local open = nil

local REFRESH = 0.5      -- s between readout updates
local SAVE_DELAY = 1     -- s after the last slider change
local HIST = 60          -- plot samples (30 s at REFRESH)

-- Config sliders: { path, label, min, max, format, needsRestart, integer }
-- A row with only a name is a heading.
local SLIDERS = {
  { 'Chunks' },
  { 'tiles.targetSize', 'Tile size', 2, 15, '%.1f m', true },
  { 'tiles.cellSize', 'Cell size', 0.1, 0.5, '%.2f m', true },
  { 'sectors.tiles', 'Sector size', 2, 10, '%d tiles', true, true },
  { 'layers.depthScale', 'Depth x', 0.25, 3, '%.2f', true },
  { 'Distance' },
  { 'sectors.loadRadius', 'View dist', 40, 400, '%.0f m' },
  { 'ring.boxMargin', 'Detail margin', 0, 30, '%.1f m' },
  { 'ring.frozenOwnMeshRadius', 'Rut detail', 0, 200, '%.0f m' },
  { 'ring.vehicleRange', 'Vehicle range', 50, 1000, '%.0f m' },
  { 'ring.maxVehicles', 'Max vehicles', 1, 32, '%d', false, true },
  { 'Update' },
  { 'ring.tileRebuildHz', 'Tile rate', 2, 30, '%.0f Hz' },
  { 'ring.farRebuildHz', 'Far tile rate', 0.5, 10, '%.1f Hz' },
  { 'sectors.refreshInterval', 'Sector refresh', 0.05, 2, '%.2f s' },
  { 'ring.maxMeshBuildsPerSec', 'Uploads', 5, 120, '%d /s', false, true },
  { 'ring.freezeDelay', 'Freeze delay', 0.2, 5, '%.1f s' },
  { 'reset.idleSeconds', 'Rut fade (0 off)', 0, 600, '%.0f s' },
  { 'Tyre mud' },
  { 'clods.buildRate', 'Build-up', 0.1, 5, '%.1fx' },
  { 'clods.wearRate', 'Wear-off', 0.1, 5, '%.1fx' },
  { 'clods.chunkRate', 'Chunks', 0, 40, '%.0f /coat' },
  { 'clods.chunkLife', 'Chunk life', 0.5, 10, '%.1f s' },
  { 'clods.chunkMax', 'Max chunks', 0, 64, '%d', false, true },
  { 'clods.drawDist', 'Draw dist', 20, 300, '%.0f m' },
  { 'clods.tyreBrightness', 'Mud brightness', 0.3, 1.5, '%.2f' },
  { 'Budget' },
  { 'perf.targetFps', 'Target fps', 30, 144, '%.0f' },
  { 'perf.uploadMsMax', 'Upload max', 0.5, 8, '%.1f ms' },
  { 'perf.uploadEvery', 'Upload every', 1, 8, '%d frames', false, true },
  { 'sectors.buildBudgetMs', 'Sector max', 0.5, 6, '%.1f ms' },
}
-- other values the GUI owns and saves
local EXTRA = { 'clods.enabled', 'render.disableSSS', 'debug.tiles', 'debug.sectors', 'debug.boxes', 'debug.drawRadius',
  'clods.kinds' }
local KIND_COLORS = { { 'mud', 'Mud colour' }, { 'sand', 'Sand colour' } }

local st = {
  t = -1, lines = {}, histFps = {}, histMod = {}, histN = 0,
  dtMax = 0, metr = {}, metrAcc = {}, metrN = 0, metrT = 0,
  saveAt = nil, session = nil, applied = {}, zoneR = nil, zoneD = nil,
}
local ptr = {}           -- path -> FloatPtr / IntPtr / BoolPtr
local col = nil

local function main() return extensions and extensions.deepnode_main end

local function split(path)
  local a, b = path:match('^(%w+)%.(%w+)$')
  return a, b
end
local function getv(cfg, path)
  local a, b = split(path)
  return cfg[a] and cfg[a][b]
end
local function setv(cfg, path, v)
  local a, b = split(path)
  cfg[a] = cfg[a] or {}
  cfg[a][b] = v
end

local function ensure()
  if im then return true end
  im = ui_imgui
  if not im then return false end
  open = im.BoolPtr(false)
  for _, s in ipairs(SLIDERS) do
    if s[2] then ptr[s[1]] = s[7] and im.IntPtr(0) or im.FloatPtr(0) end
  end
  ptr.chunks = im.BoolPtr(false)
  for _, p in ipairs(EXTRA) do
    if p ~= 'clods.kinds' then ptr[p] = p == 'debug.drawRadius' and im.FloatPtr(80) or im.BoolPtr(true) end
  end
  for _, kc in ipairs(KIND_COLORS) do ptr['col_' .. kc[1]] = im.ArrayFloat(3) end
  st.zoneR, st.zoneD = im.FloatPtr(6), im.FloatPtr(0.35)
  for i = 1, HIST do st.histFps[i] = 0; st.histMod[i] = 0 end
  col = {
    ok = im.ImVec4(0.45, 0.9, 0.45, 1), warn = im.ImVec4(1, 0.8, 0.25, 1), bad = im.ImVec4(1, 0.4, 0.35, 1),
    dim = im.ImVec4(0.65, 0.65, 0.65, 1), txt = im.ImVec4(0.92, 0.92, 0.92, 1),
    own = im.ImVec4(0.25, 0.55, 1, 1), sec = im.ImVec4(0.55, 0.72, 1, 1), frozen = im.ImVec4(1, 0.25, 0.2, 1),
    near = im.ImVec4(0, 0.9, 0.9, 1), far = im.ImVec4(1, 0.6, 0.15, 1), build = im.ImVec4(1, 0.95, 0.2, 1),
    box = im.ImVec4(1, 1, 1, 1),
  }
  return true
end

function M.open() if ensure() then open[0] = true; st.t = -1 end end
function M.close() if ensure() then open[0] = false end end
function M.toggle() if ensure() then open[0] = not open[0]; st.t = -1 end end
function M.isOpen() return open ~= nil and open[0] == true end

local function ctext(c, s)
  im.PushStyleColor2(im.Col_Text, col[c] or col.txt)
  im.TextUnformatted(s)
  im.PopStyleColor(1)
end

local function msCol(ms, warn, bad)
  if ms >= bad then return 'bad' elseif ms >= warn then return 'warn' end
  return 'ok'
end

-------------------------------------------------------------------------------
-- saving
-------------------------------------------------------------------------------
local function save(m)
  local out = {}
  local function put(path)
    local a, b = split(path)
    local v = getv(m.cfg, path)
    if v ~= nil then out[a] = out[a] or {}; out[a][b] = v end
  end
  for _, s in ipairs(SLIDERS) do if s[2] then put(s[1]) end end
  for _, p in ipairs(EXTRA) do put(p) end
  -- of the kinds only the colours (the rest stays with config.json)
  local ks = out.clods and out.clods.kinds
  if ks then
    local cols = {}
    for k, K in pairs(ks) do if type(K) == 'table' and K.color then cols[k] = { color = K.color } end end
    out.clods.kinds = cols
  end
  put('physics.mode')
  put('roads.mode')
  m.saveGuiConfig(out)
end

local function changed() st.saveAt = os.clock() + SAVE_DELAY end
-- start reads gui.json: write a pending change before any start/restart
local function flush(m) if st.saveAt then st.saveAt = nil; save(m) end end
-- a setting changed outside the window (key binding): save it like a slider move
function M.markChanged() changed() end

-------------------------------------------------------------------------------
-- readouts (REFRESH s)
-------------------------------------------------------------------------------

local function sampleMetrics()
  if not (Engine.Debug and Engine.Debug.getLastPerformanceMetrics) then return end
  local m = st.metr
  Engine.Debug.getLastPerformanceMetrics(m)
  local acc = st.metrAcc
  for _, k in ipairs({ 'Lua', 'LuaPre', 'Render', 'RenderShadows', 'RenderReflections', 'PhysicsNodes',
    'PhysicsAndVLUA', 'FPSLimiter', 'WaitNextFrame' }) do
    acc[k] = (acc[k] or 0) + (tonumber(m[k]) or 0)
  end
  st.metrN = st.metrN + 1
end

local function line(c, s) st.lines[#st.lines + 1] = { c, s } end

local function refresh(m)
  local lines = st.lines
  for i = #lines, 1, -1 do lines[i] = nil end
  local s = m.stats()
  local pf = s.perf or {}
  local running = m.isRunning()

  -- engine frame breakdown, averaged over the samples since the last refresh
  local a, n = st.metrAcc, math.max(1, st.metrN)
  local function av(k) return (a[k] or 0) / n end
  local frameMs = (pf.fps or 0) > 0 and 1000 / pf.fps or 0
  local busy = math.max(0, frameMs - av('FPSLimiter') - av('WaitNextFrame'))
  local fpsMin = st.dtMax > 0 and 1 / st.dtMax or 0
  local modMs = pf.frameAvg or 0

  line(fpsMin < 30 and 'bad' or (fpsMin < 50 and 'warn' or 'ok'),
    sfmt('FPS   %5.1f   min %4.0f   frame %5.1f ms', pf.fps or 0, fpsMin, frameMs))
  line('txt', sfmt('CPU   busy %4.1f ms  Lua %4.2f  Render %4.2f', busy, av('Lua') + av('LuaPre'), av('Render')))
  line('txt', sfmt('      Shadow %4.2f  Refl %4.2f  Phys %4.2f', av('RenderShadows'), av('RenderReflections'),
    av('PhysicsNodes') + av('PhysicsAndVLUA')))
  line(msCol(modMs, 2, 5), sfmt('MOD   %4.2f ms avg  %4.2f max  %3.0f pct of busy', modMs, s.maxFrameMs or 0,
    busy > 0 and 100 * modMs / busy or 0))
  -- module breakdown, biggest first, 4 per line
  local list = {}
  for name, e in pairs(s.timings or {}) do list[#list + 1] = { name, e.last } end
  table.sort(list, function(x, y) return x[2] > y[2] end)
  local parts = {}
  for i = 1, math.min(8, #list) do parts[#parts + 1] = sfmt('%s %.2f', list[i][1], list[i][2]) end
  if #parts > 0 then line('dim', '      ' .. table.concat(parts, '  ', 1, math.min(4, #parts))) end
  if #parts > 4 then line('dim', '      ' .. table.concat(parts, '  ', 5)) end

  line('txt', sfmt('MEM   game %5.0f MB  %+4.0f since start', pf.procMB or 0, pf.growthMB or 0))
  line('txt', sfmt('      Lua %4.0f MB  VRAM %5.0f MB', (pf.luaKB or 0) / 1024, pf.vramMB or 0))
  if s.memory then
    line('txt', sfmt('      mod: tiles %.1f  mesh %.1f  maps %.1f MB', s.memory.tilesMB or 0, s.memory.meshMB or 0,
      s.memory.terrainMB or 0))
  end

  if running then
    local sec = s.sectors or {}
    line('txt', sfmt('CHUNK tiles %d act %d frz   sectors %d/%d', s.activeTiles or 0, s.frozenTiles or 0,
      sec.built or 0, sec.loaded or 0))
    line('txt', sfmt('      meshes %d used  %d pool   %.0f up/s  %.1f ms', s.poolInUse or 0, s.poolCreated or 0,
      pf.meshBuildsPerSec or 0, pf.uploadBudget or 0))
    local inMud = 0
    for _, v in ipairs(m.vehicleStats()) do if v.wheels > 0 then inMud = inMud + 1 end end
    line('txt', sfmt('VEH   %d  (%d in mud)   grass %d', s.vehicles or 0, inMud, s.grassLifted or 0))
    local cl = s.clods
    if cl then
      line('txt', sfmt('TYRE  %d shown of %d  coat %.2f  chunks %d/%d', cl.visibleWheels or 0, cl.wheels or 0,
        cl.avgCoat or 0, cl.chunks or 0, cl.chunkObjects or 0))
      line('dim', sfmt('      meshes %d (%d wait)  mat updates %d (%.2f ms avg)', cl.meshes or 0, cl.pendingMeshes or 0,
        cl.flushes or 0, (cl.flushes or 0) > 0 and (cl.flushMs or 0) / cl.flushes or 0))
    end
    local dr = s.drape
    if s.draping then
      line('warn', sfmt('ROADS draping...  %d on mud', s.roadsOver or 0))
    else
      line((dr and dr.ready < 0.9) and 'warn' or 'txt', sfmt('ROADS %d on mud  %d wait  %d bad%s', s.roadsOver or 0,
        s.roadsPending or 0, s.roadsBad or 0, dr and sfmt('   drape %.1f s  hit %.0f pct', dr.ms / 1000, dr.ready * 100) or ''))
    end
  end

  -- history for the plots (ring buffer; the binding reads a 1-based Lua table)
  local k = st.histN % HIST + 1
  st.histFps[k], st.histMod[k] = pf.fps or 0, modMs
  st.histN = st.histN + 1
  st.err = s.lastError or ''
  st.runCol = msCol(modMs, 2, 5)
  st.runLine = sfmt('RUNNING   %.0f fps   mod %.2f ms', pf.fps or 0, modMs)
  st.zoneLabel = sfmt('Clear zones (%d)###clr', m.zoneCount())
  local dl = s.debugLines
  st.dbgLine = dl and sfmt('%d tiles  %d sectors  %d lines', dl.tiles, dl.sectors, dl.lines) or ''

  for key in pairs(a) do a[key] = 0 end
  st.metrN, st.dtMax = 0, 0
end

local function syncPtrs(m)
  local cfg = m.cfg
  for _, s in ipairs(SLIDERS) do
    if s[2] then ptr[s[1]][0] = tonumber(getv(cfg, s[1])) or s[3] end
  end
  for _, p in ipairs(EXTRA) do
    local v = getv(cfg, p)
    if p == 'debug.drawRadius' then ptr[p][0] = tonumber(v) or 80 elseif p ~= 'clods.kinds' then ptr[p][0] = v ~= false end
  end
  local ks = cfg.clods and cfg.clods.kinds or {}
  for _, kc in ipairs(KIND_COLORS) do
    local col = ks[kc[1]] and ks[kc[1]].color
    if col then
      local a = ptr['col_' .. kc[1]]
      a[0], a[1], a[2] = col[1] or 1, col[2] or 1, col[3] or 1
    end
  end
  ptr.chunks[0] = m.debugChunks()
  -- values of the restart-only sliders that the running mud was built with
  local sess = m.private and m.private.session
  if m.isRunning() and sess ~= st.session then
    st.session = sess
    for _, s in ipairs(SLIDERS) do if s[6] then st.applied[s[1]] = getv(cfg, s[1]) end end
  end
end

-------------------------------------------------------------------------------
-- tabs
-------------------------------------------------------------------------------
local function tabRun(m)
  local running = m.isRunning()
  if running then
    ctext(st.runCol or 'ok', st.runLine or 'RUNNING')
  else
    ctext('warn', 'STOPPED')
  end
  if st.err and st.err ~= '' then ctext('bad', st.err) end
  im.Separator()
  if im.Button(running and 'Stop' or 'Start', im.ImVec2(90, 0)) then flush(m); m.toggle(); st.t = -1 end
  im.SameLine()
  if im.Button('Restart', im.ImVec2(90, 0)) then flush(m); m.reloadLevelData(); st.t = -1 end
  if im.Button('Smooth ruts', im.ImVec2(90, 0)) then m.clearRuts() end
  im.SameLine()
  if im.Button('Wash tyres', im.ImVec2(90, 0)) then m.cleanWheels() end
  -- experimental: decal roads drawn on the mud (molded into it, left out where tyres
  -- dug); on/off live, off by default
  ptr.decals = ptr.decals or im.BoolPtr(false)
  ptr.decals[0] = m.decalRoadsOn and m.decalRoadsOn() or false
  if im.Checkbox('Experimental', ptr.decals) then
    m.setDecalRoads(ptr.decals[0])
    changed()
  end
  if im.IsItemHovered() then
    im.SetTooltip('Experimental: decal roads (mud furrows, dirt tracks) drawn into the mud meshes.\n' ..
      'Off (default): undug mud in heavy physics still shows the level\'s own decal roads;\n' ..
      'meshed mud (sand, vanilla physics) shows only its terrain material (cheaper).')
  end
  -- physics option (deepnode_physics): restarts the mod; the terrain under the mud changes,
  -- so switch with no vehicle sunk in it
  local ph = extensions and extensions.deepnode_physics
  if ph then
    local heavy = ph.mode() == 'heavy'
    if im.Button(heavy and 'Physics: HEAVY###phys' or 'Physics: vanilla###phys', im.ImVec2(186, 0)) then
      flush(m)
      ph.setMode(heavy and 'vanilla' or 'heavy')
      st.t = -1
    end
    if im.IsItemHovered() then
      im.SetTooltip('vanilla: BeamNG ground models.\n' ..
        'heavy: thicker mud/sand ground models, ruts lower the hard floor (rut walls).\n' ..
        'Restarts the mod: switch with no vehicle sunk in the mud.')
    end
  end
  im.Separator()
  if im.Checkbox('Tyre mud', ptr['clods.enabled']) then m.setClodsEnabled(ptr['clods.enabled'][0]); changed() end
  if im.Checkbox('Chunk outline', ptr.chunks) then m.setDebugChunks(ptr.chunks[0]) end
  if im.Checkbox('SS shadows off', ptr['render.disableSSS']) then
    m.setScreenSpaceShadowsOff(ptr['render.disableSSS'][0]); changed()
  end
  im.Separator()
  im.PushItemWidth(150)
  im.SliderFloat('Zone radius', st.zoneR, 2, 40, '%.0f m')
  im.SliderFloat('Zone depth', st.zoneD, 0.05, 1, '%.2f m')
  im.PopItemWidth()
  if im.Button('Add zone here', im.ImVec2(110, 0)) then flush(m); m.addZoneHere(st.zoneR[0], st.zoneD[0]) end
  im.SameLine()
  if im.Button(st.zoneLabel or 'Clear zones###clr', im.ImVec2(110, 0)) then flush(m); m.removeZones() end
end

local function tabConfig(m)
  local cfg = m.cfg
  local pending = false
  for _, s in ipairs(SLIDERS) do
    if s[6] and st.applied[s[1]] ~= nil and st.applied[s[1]] ~= getv(cfg, s[1]) then pending = true end
  end
  if pending then
    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.7, 0.35, 0.05, 1))
    if im.Button('Restart to apply *', im.ImVec2(150, 0)) then flush(m); m.reloadLevelData(); st.t = -1 end
    im.PopStyleColor(1)
  else
    im.BeginDisabled(true); im.Button('Restart to apply *', im.ImVec2(150, 0)); im.EndDisabled()
  end
  im.SameLine()
  if im.Button('Defaults', im.ImVec2(80, 0)) then st.saveAt = nil; m.resetGuiConfig(); st.t = -1 end
  im.PushItemWidth(170)
  for _, s in ipairs(SLIDERS) do
    if not s[2] then
      im.SeparatorText(s[1])
    else
      local label = s[6] and (s[2] .. ' *') or s[2]
      local p = ptr[s[1]]
      local hit
      if s[7] then hit = im.SliderInt(label, p, s[3], s[4], s[5]) else hit = im.SliderFloat(label, p, s[3], s[4], s[5]) end
      if hit then
        setv(cfg, s[1], p[0]); changed()
        if s[1] == 'clods.tyreBrightness' then
          local wm = extensions and extensions.deepnode_wheelMud
          if wm and wm.refreshColors then wm.refreshColors() end
        elseif s[1] == 'perf.uploadEvery' then
          local tmm = extensions and extensions.deepnode_tileMesh
          if tmm and tmm.setUploadEvery then tmm.setUploadEvery(p[0]) end
        end
      end
    end
    if s[1] == 'clods.tyreBrightness' then
      local wm = extensions and extensions.deepnode_wheelMud
      for _, kc in ipairs(KIND_COLORS) do
        local a = ptr['col_' .. kc[1]]
        -- 32 = ImGuiColorEditFlags_NoInputs (swatch + picker only)
        if im.ColorEdit3(kc[2], a, 32) and wm and wm.setKindColor then
          wm.setKindColor(kc[1], a[0], a[1], a[2])
          changed()
        end
      end
    end
  end
  im.PopItemWidth()
end

local function legend(c, s, last)
  ctext(c, s)
  if not last then im.SameLine() end
end

local function tabDebug(m)
  for _, l in ipairs(st.lines) do ctext(l[1], l[2]) end
  if st.histN > 1 then
    local off = st.histN % HIST
    im.PlotLines1('##fps', st.histFps, HIST, off, 'fps 30 s', 0, 75, im.ImVec2(-1, 34))
    im.PlotLines1('##mod', st.histMod, HIST, off, 'mod ms 30 s', 0, 6, im.ImVec2(-1, 34))
  end
  if im.Button('Lua cleanup', im.ImVec2(100, 0)) then m.flushMemory('button'); st.t = -1 end
  im.SeparatorText('Outline')
  if im.Checkbox('On', ptr.chunks) then m.setDebugChunks(ptr.chunks[0]) end
  for _, p in ipairs({ { 'debug.tiles', 'Tiles' }, { 'debug.sectors', 'Sectors' }, { 'debug.boxes', 'Boxes' } }) do
    im.SameLine()
    if im.Checkbox(p[2], ptr[p[1]]) then setv(m.cfg, p[1], ptr[p[1]][0]); changed() end
  end
  im.PushItemWidth(170)
  if im.SliderFloat('Radius', ptr['debug.drawRadius'], 20, 250, '%.0f m') then
    setv(m.cfg, 'debug.drawRadius', ptr['debug.drawRadius'][0]); changed()
  end
  im.PopItemWidth()
  legend('own', 'own'); legend('sec', 'sector'); legend('frozen', 'frozen'); legend('near', 'near')
  legend('far', 'far'); legend('build', 'build'); legend('box', 'box', true)
  if ptr.chunks[0] and st.dbgLine then ctext('dim', st.dbgLine) end
end

local TABS = { { 'Run', tabRun }, { 'Config', tabConfig }, { 'Debug', tabDebug } }
local selectTab = nil
-- console: deepnode_main.gui.selectTab('Debug')
function M.selectTab(name) selectTab = name; M.open() end

local function body(m)
  local err = nil
  if im.BeginTabBar('deepnodeTabs') then
    local sel = selectTab
    selectTab = nil
    for _, tb in ipairs(TABS) do
      -- 2 = ImGuiTabItemFlags_SetSelected
      if im.BeginTabItem(tb[1], nil, (sel == tb[1]) and 2 or 0) then
        local ok, e = pcall(tb[2], m)
        if not ok then err = e end
        im.EndTabItem()
      end
    end
    im.EndTabBar()
  end
  if err then error(err, 0) end
end

local function onUpdate(dtReal)
  if not open or not open[0] then
    -- pending save still goes out after the window closes
    if st.saveAt and os.clock() >= st.saveAt then local m = main(); st.saveAt = nil; if m then save(m) end end
    return
  end
  local m = main()
  if not m then return end
  local now = os.clock()
  if dtReal and dtReal > st.dtMax then st.dtMax = dtReal end
  if now - st.metrT >= 0.1 then st.metrT = now; sampleMetrics() end
  if now - st.t >= REFRESH then
    st.t = now
    syncPtrs(m)
    refresh(m)
  end
  if st.saveAt and now >= st.saveAt then st.saveAt = nil; save(m) end

  im.SetNextWindowSize(im.ImVec2(360, 520), im.Cond_FirstUseEver)
  -- Begin/End stay balanced even when the body fails
  if im.Begin('DeepNode', open) then
    local ok, err = pcall(body, m)
    if not ok then
      log('E', 'deepnode', 'gui error: ' .. tostring(err))
      open[0] = false
    end
  end
  im.End()
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, 'manual')
  ensure()
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
