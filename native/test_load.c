// Offline self-check: load out\mswsock.dll, check exports, and that forwarding reaches the system DLL.
// The host is not BeamNG, so dn_build_ok must be 0.
#include <winsock2.h>
#include <mswsock.h>
#include <stdio.h>
#include <assert.h>
#pragma comment(lib, "ws2_32.lib")

int main(void)
{
    HMODULE m = LoadLibraryA("mswsock.dll"); // the one next to this exe (out\)
    assert(m);
    char path[MAX_PATH];
    GetModuleFileNameA(m, path, MAX_PATH);
    printf("loaded %s\n", path);
    int (*ok)(void) = (int (*)(void))GetProcAddress(m, "dn_build_ok");
    assert(ok && ok() == 0);
    LPFN_GETACCEPTEXSOCKADDRS g = (LPFN_GETACCEPTEXSOCKADDRS)GetProcAddress(m, "GetAcceptExSockaddrs");
    LPFN_ACCEPTEX a = (LPFN_ACCEPTEX)GetProcAddress(m, "AcceptEx");
    assert(g && a);
    // call through: an invalid socket must come back as a socket error from the real function
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
    DWORD n = 0;
    char buf[256];
    BOOL r = a(INVALID_SOCKET, INVALID_SOCKET, buf, 0, 32, 32, &n, NULL);
    int err = WSAGetLastError();
    printf("AcceptEx(invalid) = %d, WSA error %d\n", r, err);
    assert(!r && err != 0);
    puts("OK");
    return 0;
}
