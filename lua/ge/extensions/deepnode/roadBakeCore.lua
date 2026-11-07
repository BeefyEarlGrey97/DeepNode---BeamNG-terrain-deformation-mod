-- deepnode_roadBakeCore
-- Pure helpers of the baked road layer (roads.mode 'bake', deepnode_roadBake): no engine calls,
-- tested offline by tests/roadBake_test.lua.
--
-- A baked tile carries five images (colour, opacity, normal, roughness, metallic) that the tile's
-- mud material reads as one detail-only layer. The detail maps repeat once per tile: the mud
-- mesh UV is the terrain UV (main.uvOf), so detailScale = 1 / (UV span of one tile), and the
-- bake maps each texel back to the world point the material will show it on (tileMapping).

local M = {}

local bit = require('bit')
local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt
local sfmt = string.format

-- texture mapping of a tile: tc = frac(cu + su (x - x0) / size), frac(cv + sv (y - y0) / size)
function M.tileMapping(uvOf, e, x0, y0, size)
  local u0, v0 = uvOf(x0, y0, e)
  local u1, v1 = uvOf(x0 + size, y0 + size, e)
  local sx, sy = 1 / abs(u1 - u0), 1 / abs(v1 - v0)
  local function frac(v) v = v % 1; if v > 1 - 1e-9 then v = 0 end; return v end
  return { sx = sx, sy = sy, cu = frac(u0 * sx), cv = frac(v0 * sy),
    su = u1 > u0 and 1 or -1, sv = v1 > v0 and 1 or -1 }
end

-- road quads over a tile (grown by margin): { ax, ay, bx, by, dx, dy, cx, cy, v0, v1, width }
-- with a, b = left, right edge at i and d, c = left, right edge at i + 1; v = -distance / textureLength
function M.tileQuads(road, x0, y0, size, margin)
  local L, R, D, tl = road.L, road.R, road.D, road.tl
  local out = {}
  local xa, xb, ya, yb = x0 - margin, x0 + size + margin, y0 - margin, y0 + size + margin
  for i = 1, #L - 1 do
    local a, b, c, d = L[i], R[i], R[i + 1], L[i + 1]
    if max(a.x, b.x, c.x, d.x) > xa and min(a.x, b.x, c.x, d.x) < xb
      and max(a.y, b.y, c.y, d.y) > ya and min(a.y, b.y, c.y, d.y) < yb then
      local w0 = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
      local w1 = sqrt((c.x - d.x) ^ 2 + (c.y - d.y) ^ 2)
      out[#out + 1] = { a.x, a.y, b.x, b.y, d.x, d.y, c.x, c.y, -D[i] / tl, -D[i + 1] / tl, (w0 + w1) * 0.5 }
    end
  end
  return out
end

-- roads in draw order (first = bottom): highOnTop draws higher renderPriority later
local function sorted(roads, highOnTop)
  local list = {}
  for i, r in ipairs(roads) do list[i] = r end
  table.sort(list, function(a, b)
    if a.prio ~= b.prio then
      if highOnTop then return a.prio < b.prio end
      return a.prio > b.prio
    end
    return a.id < b.id
  end)
  return list
end

-- consecutive roads of one material and texture length share a bake step; a step holds at most
-- maxQuads quads (the shader's constant slots), roadIdx[k] = draw index of quads[k]'s road
function M.drawGroups(roads, highOnTop, maxQuads)
  local groups = {}
  local g = nil
  for ri, r in ipairs(sorted(roads, highOnTop)) do
    for _, q in ipairs(r.quads) do
      if not g or g.mat ~= r.mat or g.tl ~= r.tl or #g.quads >= maxQuads then
        g = { mat = r.mat, tl = r.tl, quads = {}, roadIdx = {} }
        groups[#groups + 1] = g
      end
      g.quads[#g.quads + 1] = q
      g.roadIdx[#g.quads] = ri
    end
  end
  return groups
end

-- 8 hex chars over everything the images depend on (FNV-1a 32)
function M.signature(roads, params)
  local parts = { tostring(params.version), tostring(params.size), tostring(params.highOnTop) }
  for _, r in ipairs(sorted(roads, params.highOnTop)) do
    parts[#parts + 1] = sfmt('%s|%s|%s', tostring(r.mat), tostring(r.prio), tostring(r.tl))
    -- plan geometry only (corners, width) to 1 cm: v comes from the road's 3D length, which
    -- shifts when heavy mode lowers the terrain under it and the road regenerates (a signature
    -- with v rebaked every dug tile on each start, 2026-11-07)
    for _, q in ipairs(r.quads) do
      if type(q) == 'table' then
        for k = 1, 8 do parts[#parts + 1] = sfmt('%d', floor(q[k] * 100 + 0.5)) end
        parts[#parts + 1] = sfmt('%d', floor((q[11] or 0) * 100 + 0.5))
      end
    end
  end
  local s = table.concat(parts, ';')
  local h = bit.tobit(2166136261)
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    -- h * 16777619 = (h << 24) + h * 403, kept exact in 32 bits (a plain product passes 2^53)
    h = bit.tobit(bit.lshift(h, 24) + bit.tobit(h * 403))
  end
  return bit.tohex(h)
end

function M.cachePaths(level, key, sig)
  local dir = '/deepnode_cache/roadbake/' .. tostring(level) .. '/'
  local base = dir .. tostring(key) .. '_' .. sig
  return { dir = dir, b = base .. '_b.color.png', o = base .. '_o.data.png', nm = base .. '_nm.normal.png',
    r = base .. '_r.data.png', m = base .. '_m.data.png' }
end

-- tile keys within radius of any point, nearest first (ties by key)
function M.queueOrder(tiles, points, radius)
  local r2 = radius * radius
  local list, dist = {}, {}
  for key, c in pairs(tiles) do
    local best = nil
    for _, p in ipairs(points) do
      local d = (c[1] - p[1]) ^ 2 + (c[2] - p[2]) ^ 2
      if not best or d < best then best = d end
    end
    if best and best <= r2 then list[#list + 1] = key; dist[key] = best end
  end
  table.sort(list, function(a, b) if dist[a] ~= dist[b] then return dist[a] < dist[b] end return a < b end)
  return list
end

-- material fields of the baked layer (nil: the material has no free layer)
function M.layerFields(activeLayers, files, map)
  if activeLayers >= 4 then return nil end
  local L = activeLayers
  return {
    { 'activeLayers', 0, tostring(L + 1) },
    { 'baseColorFactor', L, '1 1 1 1' }, { 'opacityFactor', L, '1' },
    { 'roughnessFactor', L, '1' }, { 'metallicFactor', L, '1' },
    { 'detailMap', L, files.b }, { 'detailBaseColorMapStrength', L, '1' },
    { 'opacityDetailMap', L, files.o }, { 'detailOpacityMapStrength', L, '1' },
    { 'detailNormalMap', L, files.nm }, { 'detailNormalMapStrength', L, '1' },
    { 'roughnessDetailMap', L, files.r }, { 'detailRoughnessMapStrength', L, '1' },
    { 'metallicDetailMap', L, files.m }, { 'detailMetallicMapStrength', L, '1' },
    { 'detailScale', L, sfmt('%.6f %.6f', map.sx, map.sy) },
  }
end

if setExtensionUnloadMode then
  M.onExtensionLoaded = function() setExtensionUnloadMode(M, 'manual') end
end

return M
