-- Dev probe for deepnode_roadBake (run through the BeamNG MCP: python -I lua.py tools/dev/roadbake_probe.lua).
-- Set the globals before running (prepend a line, e.g. rawset(_G, 'DNRB_CMD', 'start')):
--   DNRB_CMD  'start'  load + start roadBake next to the running mod (no main wiring needed)
--             'tile'   move DNRB_TILE to the front of the queue
--             'status' print stats, the state of DNRB_TILE and its files (default)
--             'stop'   stop roadBake and list leftover deepnode_rb* objects
--   DNRB_TILE tile key (deepnode_main.tileKey(tx, ty)), e.g. 9175179 on gridmap_v2
local cmd = rawget(_G, 'DNRB_CMD') or 'status'
local key = rawget(_G, 'DNRB_TILE')
local out = {}
local rb = extensions.deepnode_roadBake
if cmd == 'start' then
  if not rb then extensions.load('deepnode_roadBake'); rb = extensions.deepnode_roadBake end
  out[#out + 1] = 'roads ' .. tostring(rb.start(deepnode_main))
elseif not rb then
  return 'roadBake not loaded (DNRB_CMD start)'
end
if cmd == 'tile' and key then rb.prioritize(key) end
if cmd == 'stop' then
  rb.stop()
  local left = {}
  for _, cls in ipairs({ 'PostEffect', 'ShaderData', 'GFXStateBlockData', 'Material' }) do
    for _, n in ipairs(scenetree.findClassObjects(cls) or {}) do
      if n:find('^deepnode_rb') then left[#left + 1] = cls .. ':' .. n end
    end
  end
  out[#out + 1] = 'left: ' .. (#left > 0 and table.concat(left, ', ') or 'none')
end
local st = rb.stats()
out[#out + 1] = string.format('stats roads %d tiles %d queued %d baked %d (cached %d) ready %d fallback %d failed %d bakeMs %.1f %s',
  st.roads, st.tiles, st.queued, st.baked, st.cached, st.ready, st.fallback, st.failed, st.bakeMs, st.lastError)
if key then
  local s, files = rb.state(key)
  out[#out + 1] = 'tile ' .. key .. ' state ' .. tostring(s) .. ' hasRoads ' .. tostring(rb.hasRoads(key))
  for _, n in ipairs({ 'b', 'o', 'nm', 'r', 'm' }) do
    if files then
      out[#out + 1] = string.format('  %s %s png %s dds %s', n, files[n], tostring(FS:fileExists(files[n])),
        tostring(FS:fileExists('/temp' .. files[n]:gsub('%.png$', '.dds'))))
    end
  end
end
return table.concat(out, '\n')
