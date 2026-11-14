// Offline self-check of the bridge's pointer walk (the part that runs on game memory) and of the
// mesh helpers, through a fake LuaJIT GC64 stack.
#include "dnnative.c"
#include <assert.h>

// a fake lua_State: base at +0x20, top at +0x28 (what argSlot reads)
static BYTE fakeL[0x40];
static uint64_t stack[16];
static int pushed;
static const char *pushedMsg;
static void stubBool(lua_State *L, int b) { (void)L; pushed = b; }
static void stubStr(lua_State *L, const char *m) { (void)L; pushedMsg = m; }
static void setTop(int n)
{
    *(uint64_t **)(fakeL + 0x20) = stack;
    *(uint64_t **)(fakeL + 0x28) = stack + n;
}
static uint64_t num(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
// ffi array: 16-byte GC header (gct 10 at +9), data after it
static void *cdata(size_t bytes, uint64_t *tv)
{
    BYTE *gc = calloc(1, 16 + bytes);
    gc[9] = 10;
    *tv = ((uint64_t)(int64_t)-11 << 47) | (uint64_t)(uintptr_t)gc;
    return gc + 16;
}

int main(void)
{
    uintptr_t vt = 0x1234;
    uintptr_t obj[2] = {vt, 0};          // object: first qword = vtable
    uintptr_t hop[2] = {0, (uintptr_t)obj}; // pointer to it at +8
    uintptr_t pay[3] = {0, 0, (uintptr_t)hop};
    const char *how = "";
    assert(findObject((uintptr_t)obj, vt, &how) == (uintptr_t)obj && !strcmp(how, "inline"));
    assert(findObject((uintptr_t)hop, vt, &how) == (uintptr_t)obj && !strcmp(how, "payload ptr"));
    assert(findObject((uintptr_t)pay, vt, &how) == (uintptr_t)obj && !strcmp(how, "payload ptr ptr"));
    assert(findObject((uintptr_t)pay, vt + 1, &how) == 0);
    assert(!readable(NULL, 8) && !readable((void *)0x1000, 8) && readable(obj, sizeof obj));
    assert(rd64(8) == 0);
    // a buffer over two regions (different protection) is readable; a reserved page is not
    BYTE *two = VirtualAlloc(NULL, 3 * 4096, MEM_RESERVE, PAGE_NOACCESS);
    VirtualAlloc(two, 2 * 4096, MEM_COMMIT, PAGE_READWRITE);
    DWORD old;
    VirtualProtect(two + 4096, 4096, PAGE_READONLY, &old);
    assert(readable(two + 100, 6000) && !readable(two + 100, 2 * 4096));

    // the 5-vertex mesh of the LuaJIT reference: present's hash for it is 1670147956
    lua.pushboolean = stubBool;
    lua.pushstring = stubStr;
    lua_State *L = (lua_State *)fakeL;
    double *out = cdata(7 * 8, &stack[0]);
    double *fb = cdata(5 * 64, &stack[1]);
    uint16_t *ib = cdata(9 * 2, &stack[3]);
    for (int k = 1; k <= 5; k++) {
        double *p = fb + 8 * (k - 1);
        p[0] = -345.25 + k * 0.731, p[1] = 120.5 - k * 1.3, p[2] = 99.87 - k * 0.0123;
        p[3] = 0.01 * k, p[4] = -0.02 * k, p[5] = 0.999, p[6] = k * 0.37, p[7] = -k * 0.53;
    }
    static const uint16_t faces[9] = {0, 2, 1, 1, 2, 3, 3, 2, 4};
    memcpy(ib, faces, sizeof faces);
    stack[2] = num(5), stack[4] = num(9);
    setTop(5);
    double d;
    assert(argNum(L, 3, &d) && d == 5 && !argNum(L, 1, &d) && !argNum(L, 6, &d));
    assert(argCdata(L, 2, 5 * 64) == fb && !argCdata(L, 3, 8));
    assert(l_scan(L) == 1 && pushed == 1 && out[0] == 1670147956.0);
    // bad input: false + message, no error raised
    stack[2] = num(-1);
    assert(l_scan(L) == 2 && pushed == 0 && pushedMsg && strstr(pushedMsg, "bad counts"));
    stack[2] = num(5);
    assert(out[1] == fb[0] && out[4] == fb[8 * 4] && out[2] == fb[8 * 4 + 1] && out[3] == fb[8 * 4 + 2]);

    // packing: 9 corners + 3 padding corners on vertex 0
    SubBuf s = {fb, 5, ib, 9, 12};
    float f[12 * 11];
    packSubs(f, &s, 1);
    for (int c = 0; c < 12; c++) {
        int v = c < 9 ? faces[c] : 0;
        assert(f[11 * c] == (float)fb[8 * v] && f[11 * c + 9] == (float)fb[8 * v + 6]);
        double tl = f[11 * c + 6] * f[11 * c + 6] + f[11 * c + 7] * f[11 * c + 7] + f[11 * c + 8] * f[11 * c + 8];
        assert(c < 9 ? fabs(tl - 1) < 1e-5 : tl == 0); // real triangles: unit tangent; padding: none
    }
    puts("OK");
    return 0;
}
