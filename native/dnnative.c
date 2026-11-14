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
#include <stdint.h>
#include <math.h>

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
    // a large buffer can span several regions (VirtualQuery splits by attributes): check each
    MEMORY_BASIC_INFORMATION m;
    BYTE *a = (BYTE *)p, *end = a + len;
    if ((uintptr_t)p < 0x10000) return 0;
    do {
        if (!VirtualQuery(a, &m, sizeof m)) return 0;
        if (m.State != MEM_COMMIT || !m.Protect || (m.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return 0;
        a = (BYTE *)m.BaseAddress + m.RegionSize;
    } while (a < end);
    return 1;
}
static uintptr_t rd64(uintptr_t a) { return readable((void *)a, 8) ? *(uintptr_t *)a : 0; }
static int rd32(uintptr_t a, unsigned *out) { return readable((void *)a, 4) ? (*out = *(unsigned *)a, 1) : 0; }

// Failure = return false, message. Never lua_error: an error raised from this DLL crashed the game
// while it was unwound (2026-11-14, exe 0x140143396 in the engine's exception path).
static int fail(lua_State *L, const char *msg) { lua.pushboolean(L, 0); lua.pushstring(L, msg); return 2; }

static int l_buildOk(lua_State *L) { lua.pushboolean(L, g_buildOk); return 1; }
static int l_version(lua_State *L) { lua.pushstring(L, "dnnative 4"); return 1; }

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
    *how = "dnNative: userdata expected";
    if (!pay) return 0;
    // payload = LuaIntf object holder (holds the object id, not a pointer); its vtable slot +0x10
    // returns the object, as the engine's method thunk 0x1406c3eb0 does. 0 = object deleted.
    uintptr_t hvt = rd64(pay), get = hvt ? rd64(hvt + 0x10) : 0;
    if (hvt < (uintptr_t)g_base || hvt >= g_imageEnd || get < (uintptr_t)g_base || get >= g_imageEnd)
    {
        *how = "dnNative: not an engine object";
        return 0;
    }
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

// ---------------------------------------------------------------------------------------------
// Raw Lua stack access for numbers and ffi arrays (LuaJIT 2.1 GC64, the build gate pins it):
// lua_State.base at +0x20, .top at +0x28, 8-byte TValues. A number is a plain double; a tagged
// value has (int64 >> 47) = ~itype; cdata = ~10 (-11), its GC object has gct 10 at +9 and its
// data right after the 16-byte header (LuaJIT cdataptr).
static uint64_t *argSlot(lua_State *L, int idx)
{
    uint64_t *b = *(uint64_t **)((BYTE *)L + 0x20), *t = *(uint64_t **)((BYTE *)L + 0x28);
    return idx >= 1 && b + idx - 1 < t ? b + idx - 1 : NULL;
}
static int argNum(lua_State *L, int idx, double *out)
{
    uint64_t *s = argSlot(L, idx);
    if (!s || (uint32_t)((int64_t)*s >> 47) > 0xFFFFFFF2u) return 0;
    memcpy(out, s, 8);
    return 1;
}
static int argInt(lua_State *L, int idx, int lo, int hi, int *out)
{
    double d;
    if (!argNum(L, idx, &d) || d < lo || d > hi || d != (double)(int)d) return 0;
    *out = (int)d;
    return 1;
}
// data of an ffi array argument holding at least `bytes`, or NULL
static void *argCdata(lua_State *L, int idx, size_t bytes)
{
    uint64_t *s = argSlot(L, idx);
    if (!s || (int32_t)((int64_t)*s >> 47) != -11) return NULL;
    BYTE *gc = (BYTE *)(uintptr_t)(*s & ((1ull << 47) - 1));
    if (!readable(gc, 16) || gc[9] != 10) return NULL;
    return readable(gc + 16, bytes ? bytes : 1) ? gc + 16 : NULL;
}

// One submesh of a builder (tileMesh Sub): 8 doubles per vertex (x y z nx ny nz u v), one
// uint16 vertex index per face corner, padded to `cap` corners with corners on vertex 0 (as
// tileMesh padMeshes does).
typedef struct { const double *fb; int nv; const uint16_t *ib; int nc; int cap; } SubBuf;

static int subArgs(lua_State *L, int first, int n, SubBuf *s, int *corners)
{
    *corners = 0;
    for (int k = 0; k < n; k++) {
        int a = first + 5 * k;
        SubBuf *b = &s[k];
        if (!argInt(L, a + 1, 1, 65535, &b->nv) || !argInt(L, a + 3, 0, 65535, &b->nc) ||
            !argInt(L, a + 4, b->nc, 65535, &b->cap))
            return 0;
        b->fb = argCdata(L, a, (size_t)b->nv * 64);
        b->ib = argCdata(L, a + 2, (size_t)b->nc * 2);
        if (!b->fb || (b->nc && !b->ib)) return 0;
        for (int c = 0; c < b->nc; c++)
            if (b->ib[c] >= b->nv) return 0;
        *corners += b->cap;
    }
    return 1;
}

// createMesh's vertex layout: one 44-byte vertex (pos, normal, tangent, uv) per face corner.
// Tangent as the engine (0x1401a5670) and as tileMesh groupBytes: triangle sdir, Gram-Schmidt
// against the corner normal, normalised; all in double, so the floats match the Lua path.
static void packSubs(float *f, const SubBuf *s, int n)
{
    for (int j = 0; j < n; j++) {
        const SubBuf *b = &s[j];
        for (int k = 0; k < b->cap; k += 3) {
            int ix[3];
            for (int c = 0; c < 3; c++) {
                int kk = k + c < b->cap ? k + c : k; // a last partial triangle repeats its first corner
                ix[c] = kk < b->nc ? b->ib[kk] : 0;
            }
            const double *pa = b->fb + 8 * ix[0], *pb = b->fb + 8 * ix[1], *pc = b->fb + 8 * ix[2];
            double e1x = pb[0] - pa[0], e1y = pb[1] - pa[1], e1z = pb[2] - pa[2];
            double e2x = pc[0] - pa[0], e2y = pc[1] - pa[1], e2z = pc[2] - pa[2];
            double s1 = pb[6] - pa[6], t1 = pb[7] - pa[7], s2 = pc[6] - pa[6], t2 = pc[7] - pa[7];
            double den = s1 * t2 - s2 * t1, sx = 0, sy = 0, sz = 0;
            if (den != 0) {
                double r = 1 / den;
                sx = (e1x * t2 - e2x * t1) * r, sy = (e1y * t2 - e2y * t1) * r, sz = (e1z * t2 - e2z * t1) * r;
            }
            int nCorner = b->cap - k < 3 ? b->cap - k : 3;
            for (int c = 0; c < nCorner; c++) {
                const double *p = b->fb + 8 * ix[c];
                double nx = p[3], ny = p[4], nz = p[5];
                double d = sx * nx + sy * ny + sz * nz;
                double gx = sx - nx * d, gy = sy - ny * d, gz = sz - nz * d;
                double l = gx * gx + gy * gy + gz * gz;
                if (l > 0) { l = 1 / sqrt(l); gx *= l, gy *= l, gz *= l; } else gx = gy = gz = 0;
                f[0] = (float)p[0], f[1] = (float)p[1], f[2] = (float)p[2];
                f[3] = (float)nx, f[4] = (float)ny, f[5] = (float)nz;
                f[6] = (float)gx, f[7] = (float)gy, f[8] = (float)gz;
                f[9] = (float)p[6], f[10] = (float)p[7];
                f += 11;
            }
        }
    }
}

#define MAX_SUBS 16

// dnNative.packGroup(dst float[], n, fb1, nv1, ib1, nc1, cap1, ...) -> true. packSubs into an ffi
// array, for comparing with the Lua path (tools/benchmark/ge_extensions/dntestNative.lua).
static int l_packGroup(lua_State *L)
{
    int n, corners;
    SubBuf s[MAX_SUBS];
    if (!argInt(L, 2, 1, MAX_SUBS, &n) || !subArgs(L, 3, n, s, &corners))
        return fail(L, "dnNative.packGroup: bad arguments");
    float *dst = argCdata(L, 1, (size_t)corners * 44);
    if (!dst) return fail(L, "dnNative.packGroup: dst too small");
    packSubs(dst, s, n);
    lua.pushboolean(L, 1);
    return 1;
}

// dnNative.scan(out double[7], fb, nv, ib, nc): out = { change hash, x0, y0, z0, x1, y1, z1 }.
// The hash is tileMesh present's (same quantisation, same order, mod 2^32, exact in int64).
static int l_scan(lua_State *L)
{
    int nv, nc;
    if (!argInt(L, 3, 0, 65535, &nv) || !argInt(L, 5, 0, 65535, &nc)) return fail(L, "dnNative.scan: bad counts");
    double *out = argCdata(L, 1, 7 * 8);
    const double *fb = argCdata(L, 2, (size_t)(nv ? nv : 1) * 64);
    const uint16_t *ib = nc ? argCdata(L, 4, (size_t)nc * 2) : NULL;
    if (!out || !fb || (nc && !ib)) return fail(L, "dnNative.scan: bad arrays");
    const int64_t M = 4294967296ll;
    int64_t a = ((int64_t)nv * 131 + nc) % M;
    double x0 = 1e30, y0 = 1e30, z0 = 1e30, x1 = -1e30, y1 = -1e30, z1 = -1e30;
    for (int k = 0; k < nv; k++) {
        const double *p = fb + 8 * k;
        int64_t v = a * 31 + (int64_t)floor(p[0] * 4096) + (int64_t)floor(p[1] * 4096) * 3 +
                    (int64_t)floor(p[2] * 65536) * 7 + (int64_t)floor(p[3] * 16384) * 11 +
                    (int64_t)floor(p[4] * 16384) * 13 + (int64_t)floor(p[6] * 65536) * 17 +
                    (int64_t)floor(p[7] * 65536) * 19;
        a = ((v % M) + M) % M;
        if (p[0] < x0) x0 = p[0];
        if (p[0] > x1) x1 = p[0];
        if (p[1] < y0) y0 = p[1];
        if (p[1] > y1) y1 = p[1];
        if (p[2] < z0) z0 = p[2];
        if (p[2] > z1) z1 = p[2];
    }
    for (int k = 0; k < nc; k++) a = (a * 31 + ib[k]) % M;
    out[0] = (double)a, out[1] = x0, out[2] = y0, out[3] = z0, out[4] = x1, out[5] = y1, out[6] = z1;
    lua.pushboolean(L, 1);
    return 1;
}

// lock / fill / unlock one vertex buffer of `obj` exactly as createMesh does. NULL = done.
static const char *lockedWrite(uintptr_t obj, int i, unsigned expectCount, const SubBuf *s, int n, const void *bytes)
{
    unsigned count = 0;
    uintptr_t vb = staticVb(obj, i, &count);
    if (!vb) return "no static stride-44 vertex buffer";
    if (count != expectCount) return "vertex count differs from the buffer";
    uintptr_t vt = rd64(vb), lockFn = rd64(vt + 0x68), unlockFn = rd64(vt + 0x78);
    void *ctx = (void *)rd64((uintptr_t)g_base + RVA(0x142a352a0));
    if (lockFn != (uintptr_t)g_base + RVA(0x140e09e40) || unlockFn != (uintptr_t)g_base + RVA(0x140e09f60) || !ctx)
        return "lock/unlock or GFX context not as expected";
    uintptr_t *lockedSlot = (uintptr_t *)(obj + 0x2a8 + 16 * i);
    if (*lockedSlot) return "buffer already locked";
    void *p = NULL;
    ((void (*)(uintptr_t, void *, int, int, void **))lockFn)(vb, ctx, 0, (int)count, &p);
    if (!p) return "lock gave no memory";
    *lockedSlot = (uintptr_t)p; // createMesh keeps the pointer here while locked
    if (bytes) memcpy(p, bytes, (size_t)count * 44);
    else packSubs(p, s, n);
    ((void (*)(uintptr_t, void *))unlockFn)(vb, ctx);
    *lockedSlot = 0;
    return NULL;
}

// dnNative.writeGroup(proceduralMesh, slot 0..2, n, fb1, nv1, ib1, nc1, cap1, ...) -> true.
// Packs the submeshes (corner expansion, padding, tangents) straight into the locked buffer.
static int l_writeGroup(lua_State *L)
{
    const char *how;
    uintptr_t obj = meshArg(L, NULL, NULL, &how);
    if (!obj) return fail(L, how);
    int slot, n, corners;
    SubBuf s[MAX_SUBS];
    if (!argInt(L, 2, 0, 2, &slot) || !argInt(L, 3, 1, MAX_SUBS, &n) || !subArgs(L, 4, n, s, &corners))
        return fail(L, "dnNative.writeGroup: bad arguments");
    const char *err = lockedWrite(obj, slot, (unsigned)corners, s, n, NULL);
    if (err) return fail(L, err);
    lua.pushboolean(L, 1);
    return 1;
}

// dnNative.writeVerts(proceduralMesh, submesh 0..2, bytes) -> true. Replaces the whole vertex buffer
// of that submesh in place, the way createMesh fills it (lock, copy, unlock), without a new buffer.
// bytes = count x 44 (pos, normal, tangent, uv as floats), one vertex per face corner in face order.
static int l_writeVerts(lua_State *L)
{
    const char *how;
    uintptr_t obj = meshArg(L, NULL, NULL, &how);
    if (!obj) return fail(L, how);
    size_t n = 0;
    const char *sub = lua.tolstring(L, 2, NULL), *data = lua.tolstring(L, 3, &n);
    if (!sub || sub[0] < '0' || sub[0] > '2' || sub[1]) return fail(L, "dnNative.writeVerts: submesh 0..2 expected");
    int i = sub[0] - '0';
    if (!data || n % 44) return fail(L, "dnNative.writeVerts: byte count must be vertex count x 44");
    const char *err = lockedWrite(obj, i, (unsigned)(n / 44), NULL, 0, data);
    if (err) return fail(L, err);
    lua.pushboolean(L, 1);
    return 1;
}

// dnNative.probe(proceduralMesh) -> table of strings. READ-ONLY (stage 0 checks of NATIVE_DLL.md).
static int l_probe(lua_State *L)
{
    uintptr_t pay = 0, held = 0;
    const char *how;
    uintptr_t obj = meshArg(L, &pay, &held, &how);
    if (!pay || (!obj && how[0] == 'd')) return fail(L, how); // 'dnNative: ...' = not an engine object
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

// Every exported function runs under SEH: an access violation in this DLL becomes
// `false, message` (and a log line) instead of killing the game.
static int guarded(lua_State *L, lua_CFunction f, const char *name)
{
    __try {
        return f(L);
    } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                                   : EXCEPTION_CONTINUE_SEARCH) {
        char msg[96];
        _snprintf_s(msg, sizeof msg, _TRUNCATE, "access violation in dnNative.%s", name);
        dnlog(msg);
        return fail(L, msg);
    }
}
#define GUARD(fn, name) static int g_##fn(lua_State *L) { return guarded(L, fn, name); }
GUARD(l_probe, "probe")
GUARD(l_writeVerts, "writeVerts")
GUARD(l_writeGroup, "writeGroup")
GUARD(l_packGroup, "packGroup")
GUARD(l_scan, "scan")

static void registerBridge(void)
{
    uintptr_t ge = rd64((uintptr_t)g_base + RVA(0x142c274f8)); // engine::GameEngineLua
    lua_State *L = ge ? (lua_State *)rd64(ge + 0x30) : NULL;
    // LuaJIT GC64 lua_State: GCHeader.gct at +9 is 6 for a thread
    if (!L || !readable(L, 16) || ((BYTE *)L)[9] != 6) { dnlog("bridge: GE lua_State not found"); return; }
    lua.createtable(L, 0, 8);
    lua.pushcclosure(L, l_buildOk, 0), lua.setfield(L, -2, "buildOk");
    lua.pushcclosure(L, l_version, 0), lua.setfield(L, -2, "version");
    lua.pushcclosure(L, g_l_probe, 0), lua.setfield(L, -2, "probe");
    lua.pushcclosure(L, g_l_writeVerts, 0), lua.setfield(L, -2, "writeVerts");
    lua.pushcclosure(L, g_l_writeGroup, 0), lua.setfield(L, -2, "writeGroup");
    lua.pushcclosure(L, g_l_packGroup, 0), lua.setfield(L, -2, "packGroup");
    lua.pushcclosure(L, g_l_scan, 0), lua.setfield(L, -2, "scan");
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
