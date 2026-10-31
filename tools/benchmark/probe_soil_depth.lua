-- Soil memory check: mean / max rut depth of carved cells by ground kind and pass count
-- (passes >= 6 pooled), over every tile in memory. Run after a bench2.py run without clear.
-- depth of carved cells by pass count and kind (needs soil arrays)
local dec = deepnode_main.decodeZ
local P = deepnode_main.private
local ter = P.ter or nil
local acc = {}
local nt = 0
for _, t in pairs(deepnode_main.tiles) do
  nt = nt + 1
  local NW = t.N + 1
  for idx = 0, NW * NW - 1 do
    if t.rut[idx] < 120 then
      local i, j = idx % NW, math.floor(idx / NW)
      local x, y = t.x0 + i * t.cell, t.y0 + j * t.cell
      local kind = P.kindAtWorld and P.kindAtWorld(x, y) or '?'
      local n = t.passN and t.passN[idx] or 0
      if n > 6 then n = 6 end
      local k = kind .. n
      local a = acc[k] or { n = 0, d = 0, mx = 0 }
      local d = t.rest[idx] - dec(t, idx)
      a.n, a.d = a.n + 1, a.d + d
      if d > a.mx then a.mx = d end
      acc[k] = a
    end
  end
end
local s = { 'tiles ' .. nt }
local keys = {}
for k in pairs(acc) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do local a = acc[k]; s[#s + 1] = string.format('%s: cells %d mean %.3f max %.3f', k, a.n, a.d / a.n, a.mx) end
return table.concat(s, '\n')
