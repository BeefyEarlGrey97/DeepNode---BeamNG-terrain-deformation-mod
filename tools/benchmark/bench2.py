# usage: python -I bench2.py label runs   -- like bench.py + engine metric sampling while driving
import sys, time, json, statistics as st, threading
sys.path.insert(0, '.'); import mcp
def lua(code, timeout=120): return mcp.call('run_lua', {'code': code}, timeout)
label = sys.argv[1]; runs = int(sys.argv[2])
lua("settings.setValue('fpsLimitBackgroundEnabled', false) if not dmtestRun then extensions.load('dmtestRun') end return 'ok'")
pre = json.loads(lua("""local c=Engine.Platform.getMemoryInfo() collectgarbage() local r = {commit=c.processVirtUsed/1048576, lua=collectgarbage('count')/1024}
if deepmud_main and deepmud_main.isRunning() then deepmud_main.rutLag(true) end return jsonEncode(r)"""))
t0 = time.time()
print(lua("return dmtestRun.start{runs=%d, speed=12.5, dist=110, timeout=30, label='%s', clear=%s}" % (runs, label, 'true' if 'clear' in sys.argv[3:] else 'false')))
seen = 0; samples = []
SKIP = ('physAvailable','physUsed','virtUsed','virtAvailable')
while True:
    time.sleep(0.4)
    r = json.loads(lua("local r=dmtestRun.result() return jsonEncode({step=r.step, n=#r.out, out=r.out})"))
    if r['step'] == 'drive':
        m = json.loads(mcp.call('get_performance_metrics', {}))
        samples.append(m)
    out = r.get('out') or []
    while seen < len(out):
        R = out[seen]; seen += 1
        lag = lua("if deepmud_main and deepmud_main.isRunning() then local l=deepmud_main.rutLag(true) return string.format('lag %.3f/%.2f n%d | front %.3f/%.2f n%d lead %.3f', l.near.avg,l.near.max,l.near.n, l.fresh.avg, l.fresh.max, l.fresh.n, l.lead or -1) end return '-'")
        print('run %d: fps %.1f low1 %.1f min %.1f dCommit %+.1f MB t %.1fs endSpd %.1f mod %s | %s' % (
            R['run'], R['fps'], R['low1'], R['minFps'], R['dCommit'], R['t'], R['avgEndSpeed'], ('%.2f' % R['modMs']) if R.get('modMs') else '-', lag), flush=True)
    if r.get('step') == 'finished': break
post = json.loads(lua("""local c=Engine.Platform.getMemoryInfo() collectgarbage() return jsonEncode({commit=c.processVirtUsed/1048576, lua=collectgarbage('count')/1024})"""))
el = (time.time() - t0) / 60
print('%s: commit %+.1f MB in %.2f min = %.1f MB/min, lua %.1f -> %.1f MB' % (label, post['commit'] - pre['commit'], el, (post['commit'] - pre['commit']) / el, pre['lua'], post['lua']))
keys = sorted(set(k for s in samples for k in s if k not in SKIP))
avg = {k: st.mean(s.get(k, 0) for s in samples) for k in keys}
tot = sum(v for k, v in avg.items())
print('metrics n=%d total %.2f ms: ' % (len(samples), tot) + ' '.join('%s=%.2f' % (k, v) for k, v in sorted(avg.items(), key=lambda x: -x[1]) if v >= 0.05))
json.dump(avg, open('metrics_%s.json' % label, 'w'))
