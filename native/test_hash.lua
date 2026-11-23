-- LuaJIT side of test_hash.c: tileMesh.lua hash01 / vnoise, same inputs, same print format
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
for k = 0, 19999 do
  local ix, iy = (k * 7919) % 300000 - 1000, (k * 104729) % 400000 - 5000
  io.write(string.format('%.17g %.17g\n', hash01(ix, iy, k % 31), vnoise(ix * 0.37, iy * 0.53, k % 29)))
end
