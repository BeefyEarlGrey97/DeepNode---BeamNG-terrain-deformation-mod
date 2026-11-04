-- deepnode_materials
-- Which terrain layers deform. Pure functions (no engine calls): tests/materials_test.lua.
--  * One row per ground model (the label players see in the Run tab), holding every layer
--    that uses it. A layer with no ground model gets a row under its own name.
--  * Rows of hard ground are left out: a word of the ground model or of the layer name is
--    one of HARD (ATT's 'ice' layer runs on SNOW, polish_roads_winter's snowy road layer
--    'groundmodel_asphalt_broken' too). Words are the letter runs: DIRT_ROCKY is
--    'dirt' + 'rocky', not 'rock'; 'asphalt1' is 'asphalt'.
--  * Defaults (every session starts from them, ticks are never saved): a layer is soft when
--    its name or ground model contains one of the soft texts (mud, sand, snow), as before
--    the list existed. Kind = that text; otherwise picked from the ground model: 'firm' for
--    ground that is not mud, sand or snow (grass, dirt, forest floor: shallow prints, no
--    tyre coat; user test on gridmap_v2: GRASS as mud sank too deep and caked the tyres).
--  * Layers ticked beyond the defaults are marked `byHand`: heavy mode gives them their
--    kind's soft layer but keeps the level's friction (deepnode_physics).

local M = {}

M.SOFT = { 'mud', 'sand', 'snow' }
M.HARD = {
  asphalt = true, concrete = true, rock = true, rocks = true, cliff = true, ice = true, cobblestone = true,
  cobble = true, slippery = true, metal = true, wood = true, plastic = true, kickplate = true, rumble = true,
  spike = true, grid = true, frictionless = true, void = true, shock = true, test = true, leaves = true,
  branches = true, collision = true, marble = true, tarmac = true, warning = true,
}

local function hard(s)
  for w in tostring(s or ''):lower():gmatch('%a+') do
    if M.HARD[w] then return true end
  end
  return false
end

-- soft text found in the layer name or ground model, nil if none
function M.softText(name, gm, soft)
  local a, b = tostring(name or ''):lower(), tostring(gm or ''):lower()
  for _, s in ipairs(soft or M.SOFT) do
    local p = tostring(s):lower()
    if p ~= '' and (a:find(p, 1, true) or b:find(p, 1, true)) then return p end
  end
  return nil
end

-- kind from the ground model alone (layers ticked by hand)
function M.kindOf(gm)
  local g = tostring(gm or ''):lower()
  if g:find('snow', 1, true) then return 'snow' end
  if g:find('sand', 1, true) then return 'sand' end
  if g:find('mud', 1, true) then return 'mud' end
  return 'firm'
end

function M.label(L)
  local g = tostring(L.gm or '')
  if g == '' then g = tostring(L.name or '') end
  return g:upper()
end

-- layers: table index -> { name, gm }. Returns rows sorted by label:
-- { label, kind, default, layers = { { name, idx, default } } }; hidden rows left out.
function M.rows(layers, soft)
  local by, list = {}, {}
  local idxs = {}
  for e in pairs(layers or {}) do idxs[#idxs + 1] = e end
  table.sort(idxs)
  for _, e in ipairs(idxs) do
    local L = layers[e]
    if not hard(L.gm) and not hard(L.name) then
      local key = M.label(L)
      local r = by[key]
      if not r then
        r = { label = key, kind = M.kindOf(L.gm), default = false, layers = {} }
        by[key] = r
        list[#list + 1] = r
      end
      local t = M.softText(L.name, L.gm, soft)
      if t and not r.default then r.default = true; r.kind = t end
      r.layers[#r.layers + 1] = { name = L.name, idx = e, default = t ~= nil }
    end
  end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list
end

-- Sets L.soft, L.kind, L.byHand on every layer. ticks: label -> bool (nil = default).
function M.apply(layers, ticks, soft)
  for _, L in pairs(layers or {}) do
    local t = M.softText(L.name, L.gm, soft)
    -- hidden (hard) layers never deform, whatever their name says
    local listed = not hard(L.gm) and not hard(L.name)
    local tick = ticks and ticks[M.label(L)]
    local on = listed and t ~= nil
    if listed and tick ~= nil then on = tick end
    L.soft = on
    L.kind = on and (t or M.kindOf(L.gm)) or nil
    L.byHand = on and t == nil or false
  end
end

return M
