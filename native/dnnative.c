// DeepNode native helper, loaded by BeamNG as Bin64\mswsock.dll (docs/NATIVE_DLL.md).
// Stage 0: forward the two socket functions the exe imports, check the game build, log. Nothing else.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <mswsock.h>
#include <stdio.h>
#include <stdlib.h>

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
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) { DisableThreadLibraryCalls(h); checkBuild(); }
    return TRUE;
}
