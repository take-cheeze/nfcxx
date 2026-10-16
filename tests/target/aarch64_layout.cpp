// TARGET: linux_aarch64 aarch64-linux-gnu
// HOST-REJECTS: yes
// Layout facts of AAPCS64 Linux, checked by EDG's own tables for the target (nfcxx --freestanding --target=linux_aarch64).
// The host (x86-64) fails the char and long double lines, so the same file is refused without --target.
#include <cstddef>
#include <cstdint>
#ifndef __aarch64__
#error "linux_aarch64 must predefine __aarch64__"
#endif
static_assert(sizeof(void*) == 8, "pointers are 64-bit");
static_assert(sizeof(long) == 8, "long is 64-bit (LP64)");
static_assert(sizeof(long double) == 16, "long double is IEEE quad");
static_assert(alignof(long double) == 16, "quad is 16-aligned");
static_assert(char(255) > 0, "char is unsigned on aarch64 Linux");
static_assert(sizeof(std::uint64_t) == 8, "uint64_t from lib/cstdint");
int main() { return 0; }
