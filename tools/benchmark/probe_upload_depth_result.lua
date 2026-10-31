-- Research test T13: prints the histograms collected by probe_upload_depth.lua.
local H = _G.__t13
local lab = { '<1', '1-2', '2-3', '3-5', '5-8', '8-12', '12-20', '20-30', '30+' }
local a, b = {}, {}
for i = 1, 9 do a[#a+1] = lab[i] .. ':' .. (H.depth[i] or 0); b[#b+1] = lab[i] .. ':' .. (H.change[i] or 0) end
local c = {}
for k, v in pairs(H.both) do c[#c+1] = string.format('%s/%s=%d', lab[math.floor(k/100)], lab[k%100], v) end
table.sort(c)
return 'n ' .. H.n .. '\nmaxDepth cm ' .. table.concat(a, ' ') .. '\nmaxChange cm ' .. table.concat(b, ' ') .. '\n' .. table.concat(c, ' ')
