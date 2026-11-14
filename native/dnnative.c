// DeepNode native helper, loaded by BeamNG as Bin64\mswsock.dll (docs/NATIVE_DLL.md).
// Forwards the two socket functions the exe imports, checks the game build, logs, and on a known
// build gives GE Lua the `dnNative` table (Lua bridge, below).
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <mswsock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <intrin.h>

// The only build our offsets were read from (BeamNG 0.40.5, exe md5 3c69af2b...).
#define KNOWN_TIMESTAMP 0x6aec5214u
#define KNOWN_IMAGESIZE 0x4cec000u

static HMODULE g_real;
static int g_buildOk;

static void dnlog(const char *msg)
{
    char path[MAX_PATH];
    const char *la = getenv("LOCALAPPDATA");
    if (!la) return;
    _snprintf_s(path, sizeof path, _TRUNCATE, "%s\\BeamNG\\BeamNG.drive\\current\\deepnode_native.log", la);
    FILE *f;
    if (fopen_s(&f, path, "a") == 0) { fprintf(f, "%s\n", msg); fclose(f); }
}

static FARPROC real(const char *name)
{
    if (!g_real) {
        char sys[MAX_PATH];
        GetSystemDirectoryA(sys, MAX_PATH);
        strcat_s(sys, sizeof sys, "\\mswsock.dll");
        g_real = LoadLibraryA(sys); // not in DllMain: loader lock
    }
    return g_real ? GetProcAddress(g_real, name) : NULL;
}

// Forwarders. The exe imports these two only (checked with pefile, 2026-11-14).
BOOL PASCAL dn_AcceptEx(SOCKET a, SOCKET b, PVOID c, DWORD d, DWORD e, DWORD f, LPDWORD g, LPOVERLAPPED h)
{
    static LPFN_ACCEPTEX fn;
    if (!fn) fn = (LPFN_ACCEPTEX)real("AcceptEx");
    if (!fn) { WSASetLastError(WSAEINVAL); return FALSE; }
    return fn(a, b, c, d, e, f, g, h);
}
VOID PASCAL dn_GetAcceptExSockaddrs(PVOID a, DWORD b, DWORD c, DWORD d, struct sockaddr **e, LPINT f,
                                    struct sockaddr **g, LPINT h)
{
    static LPFN_GETACCEPTEXSOCKADDRS fn;
    if (!fn) fn = (LPFN_GETACCEPTEXSOCKADDRS)real("GetAcceptExSockaddrs");
    if (fn) fn(a, b, c, d, e, f, g, h);
}
#pragma comment(linker, "/export:AcceptEx=dn_AcceptEx")
#pragma comment(linker, "/export:GetAcceptExSockaddrs=dn_GetAcceptExSockaddrs")

// Lets a test (or later the Lua bridge) ask whether native writes are allowed on this build.
__declspec(dllexport) int dn_build_ok(void) { return g_buildOk; }

// ---------------------------------------------------------------------------------------------
// Lua bridge. GE Lua runs `pcall(ffi.load, 'dnnative')`; ffi.load asks the sandbox gate, our
// replacement of the gate sees the call came from ffi.load on the main thread and hangs the
// global table `dnNative` on the GE lua_State. The gate still answers as before (ffi.load is
// still denied), so nothing else in the game changes.
// shortcut: addresses hardcoded for 0.40.5 (the build gate keeps them off elsewhere); move to a
// signature scan when a second build must be supported.
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *);
#define LUA_GLOBALSINDEX (-10002)
#define RVA(a) ((a) - 0x140000000ull)

static struct {
    void (*pushcclosure)(lua_State *, lua_CFunction, int);
    void (*setfield)(lua_State *, int, const char *);
    void (*createtable)(lua_State *, int, int);
    void (*pushstring)(lua_State *, const char *);
    const char *(*pushfstring)(lua_State *, const char *, ...);
    void *(*touserdata)(lua_State *, int);
    const char *(*tolstring)(lua_State *, int, size_t *);
    void (*pushboolean)(lua_State *, int);
    int (*error)(lua_State *);
} lua;

static BYTE *g_base;
static uintptr_t g_imageEnd;
static volatile int *g_sandboxFlag; // what the original gate returned
static void *g_ffiLoadRet;          // return address of the gate call inside ffi.load
static DWORD g_mainTid;
static lua_State *g_lastL;

#define VT_PMESH RVA(0x141dacf98) // ProceduralMesh
#define VT_VB RVA(0x1421abb48)    // GFXd3d12VertexBuffer

static int readable(const void *p, size_t len)
{
    MEMORY_BASIC_INFORMATION m;
    if ((uintptr_t)p < 0x10000 || !VirtualQuery(p, &m, sizeof m)) return 0;
    if (m.State != MEM_COMMIT || !m.Protect || (m.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return 0;
    return (BYTE *)p + len <= (BYTE *)m.BaseAddress + m.RegionSize;
}
static uintptr_t rd64(uintptr_t a) { return readable((void *)a, 8) ? *(uintptr_t *)a : 0; }
static int rd32(uintptr_t a, unsigned *out) { return readable((void *)a, 4) ? (*out = *(unsigned *)a, 1) : 0; }

static int fail(lua_State *L, const char *msg) { lua.pushstring(L, msg); return lua.error(L); }

static int l_buildOk(lua_State *L) { lua.pushboolean(L, g_buildOk); return 1; }
static int l_version(lua_State *L) { lua.pushstring(L, "dnnative 1"); return 1; }

// C++ object behind a Lua userdata: the payload itself, or a pointer in it (one or two hops)
static uintptr_t findObject(uintptr_t pay, uintptr_t vt, const char **how)
{
    if (rd64(pay) == vt) { *how = "inline"; return pay; }
    for (int k = 0; k < 8; k++) {
        uintptr_t q = rd64(pay + 8 * k);
        if (!q) continue;
        if (rd64(q) == vt) { *how = "payload ptr"; return q; }
        for (int k2 = 0; k2 < 4; k2++) {
            uintptr_t q2 = rd64(q + 8 * k2);
            if (q2 && rd64(q2) == vt) { *how = "payload ptr ptr"; return q2; }
        }
    }
    return 0;
}

#define FIELD(k, ...) (lua.pushfstring(L, __VA_ARGS__), lua.setfield(L, -2, k))

// ProceduralMesh behind Lua argument 1, or 0. Raises a Lua error if it is not an engine object.
static uintptr_t meshArg(lua_State *L, uintptr_t *payOut, uintptr_t *heldOut, const char **how)
{
    uintptr_t pay = (uintptr_t)lua.touserdata(L, 1);
    if (!pay) fail(L, "dnNative: userdata expected");
    // payload = LuaIntf object holder (holds the object id, not a pointer); its vtable slot +0x10
    // returns the object, as the engine's method thunk 0x1406c3eb0 does. 0 = object deleted.
    uintptr_t hvt = rd64(pay), get = hvt ? rd64(hvt + 0x10) : 0;
    if (hvt < (uintptr_t)g_base || hvt >= g_imageEnd || get < (uintptr_t)g_base || get >= g_imageEnd)
        fail(L, "dnNative: not an engine object");
    uintptr_t held = ((uintptr_t (*)(uintptr_t))get)(pay);
    *how = "not found";
    if (payOut) *payOut = pay, *heldOut = held;
    return held ? findObject(held, (uintptr_t)g_base + VT_PMESH, how) : 0;
}

// Vertex buffer of submesh i if it is the kind createMesh makes (static, stride 44), else 0.
static uintptr_t staticVb(uintptr_t obj, int i, unsigned *count)
{
    uintptr_t vb = rd64(obj + 0x2a0 + 16 * i);
    unsigned stride = 0, type = 9;
    if (!vb || rd64(vb) != (uintptr_t)g_base + VT_VB || !rd32(vb + 0x30, count) || !rd32(vb + 0x70, &stride) ||
        !rd32(vb + 0x74, &type) || stride != 44 || type != 0)
        return 0;
    return vb;
}

// dnNative.writeVerts(proceduralMesh, submesh 0..2, bytes) -> true. Replaces the whole vertex buffer
// of that submesh in place, the way createMesh fills it (lock, copy, unlock), without a new buffer.
// bytes = count x 44 (pos, normal, tangent, uv as floats), one vertex per face corner in face order.
static int l_writeVerts(lua_State *L)
{
    const char *how;
    uintptr_t obj = meshArg(L, NULL, NULL, &how);
    if (!obj) return fail(L, "dnNative.writeVerts: not a live ProceduralMesh");
    size_t n = 0;
    const char *sub = lua.tolstring(L, 2, NULL), *data = lua.tolstring(L, 3, &n);
    if (!sub || sub[0] < '0' || sub[0] > '2' || sub[1]) return fail(L, "dnNative.writeVerts: submesh 0..2 expected");
    int i = sub[0] - '0';
    unsigned count = 0;
    uintptr_t vb = staticVb(obj, i, &count);
    if (!vb) return fail(L, "dnNative.writeVerts: no static stride-44 vertex buffer");
    if (!data || n != (size_t)count * 44) return fail(L, "dnNative.writeVerts: byte count must be vertex count x 44");
    uintptr_t vt = rd64(vb), lockFn = rd64(vt + 0x68), unlockFn = rd64(vt + 0x78);
    void *ctx = (void *)rd64((uintptr_t)g_base + RVA(0x142a352a0));
    if (lockFn != (uintptr_t)g_base + RVA(0x140e09e40) || unlockFn != (uintptr_t)g_base + RVA(0x140e09f60) || !ctx)
        return fail(L, "dnNative.writeVerts: lock/unlock or GFX context not as expected");
    uintptr_t *lockedSlot = (uintptr_t *)(obj + 0x2a8 + 16 * i);
    if (*lockedSlot) return fail(L, "dnNative.writeVerts: buffer already locked");
    void *p = NULL;
    ((void (*)(uintptr_t, void *, int, int, void **))lockFn)(vb, ctx, 0, (int)count, &p);
    if (!p) return fail(L, "dnNative.writeVerts: lock gave no memory");
    *lockedSlot = (uintptr_t)p; // createMesh keeps the pointer here while locked
    memcpy(p, data, n);
    ((void (*)(uintptr_t, void *))unlockFn)(vb, ctx);
    *lockedSlot = 0;
    lua.pushboolean(L, 1);
    return 1;
}

// dnNative.probe(proceduralMesh) -> table of strings. READ-ONLY (stage 0 checks of NATIVE_DLL.md).
static int l_probe(lua_State *L)
{
    uintptr_t pay, held;
    const char *how;
    uintptr_t obj = meshArg(L, &pay, &held, &how);
    lua.createtable(L, 0, 8);
    FIELD("payload", "%p", (void *)pay);
    FIELD("held", "%p", (void *)held);
    FIELD("how", "%s", how);
    if (!obj) return 1;
    FIELD("obj", "%p", (void *)obj);
    for (int i = 0; i < 3; i++) {
        uintptr_t vb = rd64(obj + 0x2a0 + 16 * i);
        if (!vb) continue;
        unsigned count = 0, stride = 0, type = 0;
        int ok = rd64(vb) == (uintptr_t)g_base + VT_VB && rd32(vb + 0x30, &count) && rd32(vb + 0x70, &stride) &&
                 rd32(vb + 0x74, &type);
        char k[8] = "vb0";
        k[2] = (char)('0' + i);
        // expected: vtable ok, stride 44, type 0 (static)
        FIELD(k, "%p vtable=%s count=%d stride=%d type=%d", (void *)vb, ok ? "ok" : "BAD", (int)count, (int)stride,
              (int)type);
    }
    return 1;
}

static void registerBridge(void)
{
    uintptr_t ge = rd64((uintptr_t)g_base + RVA(0x142c274f8)); // engine::GameEngineLua
    lua_State *L = ge ? (lua_State *)rd64(ge + 0x30) : NULL;
    // LuaJIT GC64 lua_State: GCHeader.gct at +9 is 6 for a thread
    if (!L || !readable(L, 16) || ((BYTE *)L)[9] != 6) { dnlog("bridge: GE lua_State not found"); return; }
    lua.createtable(L, 0, 4);
    lua.pushcclosure(L, l_buildOk, 0), lua.setfield(L, -2, "buildOk");
    lua.pushcclosure(L, l_version, 0), lua.setfield(L, -2, "version");
    lua.pushcclosure(L, l_probe, 0), lua.setfield(L, -2, "probe");
    lua.pushcclosure(L, l_writeVerts, 0), lua.setfield(L, -2, "writeVerts");
    lua.setfield(L, LUA_GLOBALSINDEX, "dnNative");
    if (L != g_lastL) {
        char msg[96];
        _snprintf_s(msg, sizeof msg, _TRUNCATE, "bridge: dnNative registered on L=%p", (void *)L);
        dnlog(msg);
        g_lastL = L;
    }
}

// Replaces the sandbox gate (originally `mov eax,[flag]; ret`). Called by every io/os/loadlib/ffi
// function of every Lua state, on any thread: the fast path must stay a load and a compare.
static int dn_gate(void)
{
    int v = *g_sandboxFlag;
    if (_ReturnAddress() == g_ffiLoadRet) {
        if (GetCurrentThreadId() == g_mainTid) registerBridge();
        else dnlog("bridge: ffi.load off the main thread, not registered");
    }
    return v;
}

static void installBridge(void)
{
    // gate: 8b 05 <disp32> c3, then 9 int3 up to the next function (16 bytes free)
    static const BYTE gateRest[] = {0xc3, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc};
    BYTE *gate = g_base + RVA(0x141215780), *site = g_base + RVA(0x14126caea);
    if (gate[0] != 0x8b || gate[1] != 0x05 || memcmp(gate + 6, gateRest, sizeof gateRest) || site[0] != 0xe8 ||
        site + 5 + *(int *)(site + 1) != gate) {
        char msg[128];
        int n = _snprintf_s(msg, sizeof msg, _TRUNCATE, "bridge: gate bytes differ, bridge off:");
        for (int i = 0; i < 16 && n > 0; i++) n += _snprintf_s(msg + n, sizeof msg - n, _TRUNCATE, " %02x", gate[i]);
        dnlog(msg);
        return;
    }
    g_sandboxFlag = (volatile int *)(gate + 6 + *(int *)(gate + 2));
    g_ffiLoadRet = site + 5;
    g_mainTid = GetCurrentThreadId(); // static import: DllMain runs on the game's main thread

    *(void **)&lua.pushcclosure = g_base + RVA(0x141211e40);
    *(void **)&lua.setfield = g_base + RVA(0x141212530);
    *(void **)&lua.createtable = g_base + RVA(0x141211260);
    *(void **)&lua.pushstring = g_base + RVA(0x1412120c0);
    *(void **)&lua.pushfstring = g_base + RVA(0x141211f10);
    *(void **)&lua.touserdata = g_base + RVA(0x141212b20);
    *(void **)&lua.tolstring = g_base + RVA(0x1412129e0);
    *(void **)&lua.pushboolean = g_base + RVA(0x141211e00);
    *(void **)&lua.error = g_base + RVA(0x1412131e0);

    BYTE patch[12] = {0x48, 0xb8}; // mov rax, dn_gate; jmp rax
    void *target = (void *)dn_gate;
    memcpy(patch + 2, &target, 8);
    patch[10] = 0xff, patch[11] = 0xe0;
    DWORD old;
    if (!VirtualProtect(gate, sizeof patch, PAGE_EXECUTE_READWRITE, &old)) { dnlog("bridge: VirtualProtect failed"); return; }
    memcpy(gate, patch, sizeof patch);
    VirtualProtect(gate, sizeof patch, old, &old);
    FlushInstructionCache(GetCurrentProcess(), gate, sizeof patch);
    dnlog("bridge: gate hooked, waiting for pcall(ffi.load, 'dnnative')");
}

static void checkBuild(void)
{
    BYTE *base = (BYTE *)GetModuleHandleA(NULL);
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    DWORD ts = nt->FileHeader.TimeDateStamp, sz = nt->OptionalHeader.SizeOfImage;
    // CEF helper processes run the same exe with --type=...: native features only in the game process
    int helper = strstr(GetCommandLineA(), "--type=") != NULL;
    if (helper) return;
    g_buildOk = ts == KNOWN_TIMESTAMP && sz == KNOWN_IMAGESIZE;
    char exe[MAX_PATH], msg[512];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    _snprintf_s(msg, sizeof msg, _TRUNCATE, "dnnative loaded in %s pid=%lu base=%p ts=0x%08lx size=0x%lx build=%s",
                exe, GetCurrentProcessId(), (void *)base, ts, sz,
                g_buildOk ? "known" : "UNKNOWN (native features off)");
    dnlog(msg);
    g_base = base;
    g_imageEnd = (uintptr_t)base + sz;
    if (g_buildOk) installBridge();
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) { DisableThreadLibraryCalls(h); checkBuild(); }
    return TRUE;
}
