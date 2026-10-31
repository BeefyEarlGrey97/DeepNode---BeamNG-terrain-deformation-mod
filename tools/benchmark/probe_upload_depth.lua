-- Research test T13: wraps tileMesh.buildTile and bins every tile upload by its largest rut
-- depth and its largest height change since the tile's last upload (cm). Read with
-- probe_upload_depth_result.lua after bench2.py runs.
local tm = extensions.deepnode_tileMesh
if _G.__t13 then tm.buildTile = _G.__t13.orig end
local orig = tm.buildTile
local H = { orig = orig, n = 0, depth = {}, change = {}, both = {}, snap = setmetatable({}, { __mode = 'k' }) }
_G.__t13 = H
local dec = deepnode_main.decodeZ
local function bin(v) -- cm bins: 0,1,2,3,5,8,12,20,30+
  local cm = v * 100
  local edges = { 1, 2, 3, 5, 8, 12, 20, 30 }
  for i, e in ipairs(edges) do if cm < e then return i end end
  return #edges + 1
end
tm.buildTile = function(t, rule)
  if t.rut and t.rest then
    local prev = H.snap[t]
    local maxD, maxC = 0, 0
    local n = (t.N + 1) * (t.N + 1) - 1
    for idx = 0, n do
      local r = t.rest[idx]
      do
        local z = dec(t, idx)
        local d = r - z
        if d > maxD then maxD = d end
        if prev then
          local p = prev[idx]
          if p then local c = math.abs(z - p); if c > maxC then maxC = c end end
        else
          if d > maxC then maxC = d end
        end
      end
    end
    local s = prev or {}
    for idx = 0, n do s[idx] = dec(t, idx) end
    H.snap[t] = s
    H.n = H.n + 1
    local bd, bc = bin(maxD), bin(maxC)
    H.depth[bd] = (H.depth[bd] or 0) + 1
    H.change[bc] = (H.change[bc] or 0) + 1
    local k = bd * 100 + bc
    H.both[k] = (H.both[k] or 0) + 1
  end
  return orig(t, rule)
end
return 'wrapped'
