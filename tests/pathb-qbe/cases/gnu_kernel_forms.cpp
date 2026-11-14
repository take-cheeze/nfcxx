// EXPECT: 0
// GNU C forms of the kernel's shape (docs/notes/pathb-ssa-qbe.md, "the cproc-removal work"): __attribute__((cleanup)) runs
// the function at the end of the variable's scope; noinline keeps a call; section(...) with used keeps a static object;
// and a GNU case range (a flexible array member initialised by elements is C only: see tests/c). Each failed check counts one.
#include <cstdio>

static int cleaned;
static void rel(int *p) { cleaned += *p; }
static __attribute__((noinline)) int noin(int x) { return x * 3; }
// ELF section names; Mach-O needs "segment,section" (so the section is an ELF-only check).
#if defined(__APPLE__)
int keep_me = 5;
#else
int __attribute__((section("mydata"), used)) keep_me = 5;
#endif
static int sw(int x) {
    switch (x) {
    case 0 ... 999: return 1;
    default: return 2;
    }
}
int main() {
    int ok = 0;
    { int a __attribute__((cleanup(rel))) = 4; }
    ok += cleaned == 4;
    ok += noin(2) == 6;
    ok += keep_me == 5;
    ok += sw(500) == 1 && sw(5000) == 2;
    return ok == 4 ? 0 : 1;
}
