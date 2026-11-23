-- dnJitBench: fixed Lua workloads to compare game builds (LuaJIT versions) without physics noise.
-- run() -> text: median ms of 7 rounds per workload. Needs DeepNode running (tile emitter context).
local M = {}
local ffi = require('ffi')
local bxor, rshift, band, tobit = bit.bxor, bit.rshift, bit.band, bit.tobit
local floor = math.floor

local function hash01(ix, iy, salt)
  local h = bxor(tobit(ix * 374761393), tobit(iy * 668265263), salt or 0)
  h = tobit(bxor(h, rshift(h, 13)) * 1274126177)
  h = bxor(h, rshift(h, 16))
  return band(h, 0xffff) / 65535
end
local function vnoise(x, y, salt)
  local ix, iy = floor(x), floor(y)
  local fx, fy = x - ix, y - iy
  fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
  local a, b = hash01(ix, iy, salt), hash01(ix + 1, iy, salt)
  local c, d = hash01(ix, iy + 1, salt), hash01(ix + 1, iy + 1, salt)
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
end

local function wNoise()
  local s = 0
  for k = 0, 300000 do s = s + vnoise(k * 0.37, k * 0.53, k % 29) end
  return s
end
local function wTables()
  local t = {}
  for k = 1, 200000 do t[k] = { x = k, y = k * 2, z = k * 3 } end
  local s = 0
  for k = 1, #t do local e = t[k]; s = s + e.x + e.y * e.z end
  return s
end
local function wFfi()
  local n = 676
  local a, b = ffi.new('float[?]', n), ffi.new('uint8_t[?]', n)
  local s = 0
  for r = 1, 2000 do
    for i = 0, n - 1 do
      b[i] = (i * r) % 256
      a[i] = a[i] * 0.5 + b[i] * 0.001
      s = s + math.min(b[i], 128) * 0.0078125 + math.max(b[i] - 128, 0) / 127
    end
  end
  return s
end

-- synthetic rutted tile (25 x 25 cells, every cell soft, rut pattern + track) for tileMesh.emitTileCells
local tile = nil
local function makeTile()
  local main = deepnode_main
  local N, cps = main.N, main.cps
  local ts, W = N / cps, N + 1
  local t = { N = N, cps = cps, ts = ts, cell = main.cell, x0 = 0, y0 = 0, gx0 = 100, gy0 = 200,
    rutted = true, matList = { 0 }, anyFlush = false }
  t.rut, t.track = ffi.new('uint8_t[?]', W * W), ffi.new('uint8_t[?]', W * W)
  t.rest, t.floor = ffi.new('float[?]', W * W), ffi.new('float[?]', W * W)
  t.soft, t.sqMat = ffi.new('uint8_t[?]', N * N), ffi.new('uint8_t[?]', ts * ts)
  for j = 0, N do
    for i = 0, N do
      local k = j * W + i
      t.rest[k], t.floor[k] = 100, 99.6
      t.rut[k] = (i % 7 < 3) and (40 + (j * 3) % 60) or ((i % 7 == 3) and 170 or 128)
      t.track[k] = (i % 7 < 4) and 200 or 0
    end
  end
  ffi.fill(t.soft, N * N, 1)
  return t
end
local function wTile()
  local tm = extensions.deepnode_tileMesh
  tile = tile or makeTile()
  local b = tm.newBuilder(true)
  for _ = 1, 60 do
    b:reset()
    tm.emitTileCells(b, tile, 0, nil)
  end
  return b:vertexCount()
end

local function median(f)
  local ts = {}
  for r = 1, 7 do
    local t = hptimer()
    f()
    ts[r] = t:stop()
  end
  table.sort(ts)
  return ts[4]
end

function M.run()
  local out = { jit.version, string.format('jit %s', tostring(jit.status())) }
  for _, w in ipairs({ { 'noise', wNoise }, { 'tables', wTables }, { 'ffi', wFfi }, { 'tile60', wTile } }) do
    out[#out + 1] = string.format('%s %.2f ms', w[1], median(w[2]))
  end
  return table.concat(out, ' | ')
end
return M
