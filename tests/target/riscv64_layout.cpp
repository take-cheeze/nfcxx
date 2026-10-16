// TARGET: linux_riscv64 riscv64-linux-gnu
// HOST-REJECTS: yes
// RUN-QEMU: 0
// Layout facts of the RISC-V 64-bit Linux ABI (LP64D), checked by EDG's tables for linux_riscv64.
#include <cstddef>
#include <cstdint>
#ifndef __riscv
#error "linux_riscv64 must predefine __riscv"
#endif
static_assert(sizeof(void*) == 8, "pointers are 64-bit");
static_assert(sizeof(long) == 8, "long is 64-bit (LP64)");
static_assert(sizeof(long double) == 16, "long double is IEEE quad");
static_assert(char(255) > 0, "char is unsigned on RISC-V Linux");
static_assert(sizeof(std::uint32_t) == 4, "uint32_t from lib/cstdint");
int main() { return 0; }
