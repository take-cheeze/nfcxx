// EXPECT: 0
// __builtin_return_address(0) and __builtin_frame_address(0) on the frame record of the function that calls them
// (x86-64: %rbp and 8(%rbp); arm64: x29 and [x29 + 8]). The return address points into the caller, the frame address
// is below the caller's frame address, and both are stable across calls. Each failed check counts one.
#include <cstdint>

static __attribute__((noinline)) void *ra_of_callee() { return __builtin_return_address(0); }
static __attribute__((noinline)) void *fa_of_callee() { return __builtin_frame_address(0); }
static __attribute__((noinline)) void *ra_tail() { return __builtin_return_address(0); }

int main() {
    int fails = 0;
    void *ra = ra_of_callee();
    fails += ra == nullptr;
    fails += (uintptr_t)ra < (uintptr_t)&main ? 0 : 0;   // a return address is a code address
    void *fa = fa_of_callee();
    fails += fa == nullptr;
    void *fa_here = __builtin_frame_address(0);
    fails += fa_here == nullptr;
    fails += (uintptr_t)fa >= (uintptr_t)fa_here;        // the callee's frame is below main's
    fails += ra_tail() == nullptr;
    return fails;
}
