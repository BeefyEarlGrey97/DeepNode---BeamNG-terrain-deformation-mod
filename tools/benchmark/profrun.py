import sys, time, json, re
sys.path.insert(0, '.'); import mcp
def lua(code, timeout=120): return mcp.call('run_lua', {'code': code}, timeout)
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 1
print(lua("if not dntestProf then extensions.load('dntestProf') end return dntestProf.install()"))
lua("dntestProf.reset() return 1")
print(lua("return dntestRun.start{runs=%d, speed=12.5, dist=110, timeout=30, label='prof'}" % runs))
while True:
    time.sleep(2)
    r = json.loads(lua("local r=dntestRun.result() return jsonEncode({step=r.step})"))
    if r['step'] == 'finished': break
rep = lua("return dntestProf.report(1)")
lua("dntestProf.uninstall() return 1")
parts = rep.split(' | ')
frames = None
for p in parts:
    m = re.match(r'perf ([\d.]+)ms x([\d.]+)', p)
    if m: frames = float(m.group(2))
print('frames', frames)
for p in parts:
    m = re.match(r'(\S+) ([\d.]+)ms x([\d.]+) max([\d.]+)', p)
    if m and frames:
        print('%-12s %.3f ms/frame  calls/frame %.2f  max %s' % (m.group(1), float(m.group(2)) / frames, float(m.group(3)) / frames, m.group(4)))
    elif not m:
        print(p)
