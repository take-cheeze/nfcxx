// TARGET: linux_armv7 arm-linux-gnueabihf
// HOST-REJECTS: yes
// Layout facts of the 32-bit ARM EABI, checked by EDG's tables for linux_armv7: ILP32, long double is double.
#include <cstddef>
#include <cstdint>
#ifndef __arm__
#error "linux_armv7 must predefine __arm__"
#endif
static_assert(sizeof(void*) == 4, "pointers are 32-bit");
static_assert(sizeof(long) == 4, "long is 32-bit (ILP32)");
static_assert(sizeof(long double) == 8, "long double is double on ARM EABI");
static_assert(char(255) > 0, "char is unsigned on ARM");
static_assert(sizeof(std::uint64_t) == 8, "uint64_t from lib/cstdint");
int main() { return 0; }
