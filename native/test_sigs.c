// Offline self-check: map the game exe as an image, run the DLL's signature scan on it and compare
// with native/sigmap.py's answer for the 2026-11-21 build (0x6afb6bf3). usage: test_sigs <exe>
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <assert.h>

int main(int argc, char **argv)
{
    assert(argc == 2);
    HMODULE m = LoadLibraryA("mswsock.dll");
    assert(m);
    int (*scan)(BYTE *, uintptr_t *) = (int (*)(BYTE *, uintptr_t *))GetProcAddress(m, "dn_scan");
    assert(scan);
    HMODULE img = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    assert(img);
    BYTE *base = (BYTE *)((uintptr_t)img & ~(uintptr_t)3);
    uintptr_t got[32] = {0};
    int n = scan(base, got);
    // RVAs from sigmap.py (old -> new), same order as g_sigs
    static const uintptr_t want[] = {0x1215830, 0x126cbba, 0xe09e40, 0xe09f60, 0x1211ef0, 0x12125e0, 0x1211310,
                                     0x1212170, 0x1211fc0, 0x1212bd0, 0x1212a90, 0x1211eb0, 0x1213290, 0x1dabf98,
                                     0x21aab48, 0x2a342b0, 0x2c26508};
    int bad = 0;
    for (int i = 0; i < (int)(sizeof want / sizeof *want); i++)
        if (got[i] != want[i]) printf("sig %d: got %llx want %llx\n", i, (unsigned long long)got[i], (unsigned long long)want[i]), bad++;
    printf("scan found %d, mismatches %d\n", n, bad);
    assert(n == (int)(sizeof want / sizeof *want) && !bad);
    puts("OK");
    return 0;
}
