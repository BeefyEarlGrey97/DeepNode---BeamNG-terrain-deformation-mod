import json, sys, urllib.request
URL = "http://127.0.0.1:29292/mcp"
_id = [0]
def rpc(method, params=None, timeout=120):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"2.0","id":_id[0],"method":method,"params":params or {}}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type":"application/json","Accept":"application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8","replace"))
def call(name, args=None, timeout=120):
    r = rpc("tools/call", {"name":name,"arguments":args or {}}, timeout)
    if "error" in r: return "ERROR: " + json.dumps(r["error"])
    out = []
    for c in r["result"].get("content", []):
        out.append(c.get("text") if c.get("type")=="text" else "[%s %d bytes]" % (c.get("type"), len(c.get("data",""))))
    return "\n".join(out)
if __name__ == "__main__":
    if sys.argv[1] == "list":
        for t in rpc("tools/list")["result"]["tools"]:
            print("##", t["name"], "-", t.get("description","")[:300].replace("\n"," "))
            print("   args:", json.dumps(t.get("inputSchema",{}).get("properties",{}))[:400])
    else:
        args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        if len(sys.argv) > 2 and sys.argv[2].startswith("@"):
            args = json.load(open(sys.argv[2][1:], encoding="utf-8"))
        print(call(sys.argv[1], args))
