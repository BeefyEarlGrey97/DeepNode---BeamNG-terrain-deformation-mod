// Offline self-check: prints dn_hash01 / dn_vnoise for the inputs test_hash.lua prints the Lua values
// for; tools compare the two outputs line by line (native/test_hash.sh).
#include <windows.h>
#include <stdio.h>
#include <assert.h>
int main(void)
{
    HMODULE m = LoadLibraryA("mswsock.dll");
    assert(m);
    double (*h)(double, double, int) = (double (*)(double, double, int))GetProcAddress(m, "dn_hash01");
    double (*v)(double, double, int) = (double (*)(double, double, int))GetProcAddress(m, "dn_vnoise");
    assert(h && v);
    for (int k = 0; k < 20000; k++) {
        double ix = (k * 7919) % 300000 - 1000, iy = (k * 104729) % 400000 - 5000;
        printf("%.17g %.17g\n", h(ix, iy, k % 31), v(ix * 0.37, iy * 0.53, k % 29));
    }
    return 0;
}
