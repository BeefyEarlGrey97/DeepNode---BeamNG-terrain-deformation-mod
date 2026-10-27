import sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
import mcp
print(mcp.call('run_lua', {'code': open(sys.argv[1], encoding='utf-8').read()}, timeout=600))
