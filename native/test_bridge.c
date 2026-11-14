// Offline self-check of the bridge's pointer walk (the part that runs on game memory).
#include "dnnative.c"
#include <assert.h>

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
    puts("OK");
    return 0;
}
