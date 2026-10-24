// EXPECT: 42
// #pragma pack (the kernel's ACPI tables, hyperv.h): pack(N), pack(), pack(push, N), pack(pop), as gcc lays them out. cproc
// ignored every pragma before -G; it now honours pack and refuses the pragmas it does not know.
#include <stddef.h>
#pragma pack(1)
struct acpi_header { char sig[4]; unsigned int length; unsigned char rev; unsigned long long addr; unsigned short id; };
#pragma pack()
struct normal { char c; unsigned int i; };
#pragma pack(push, 2)
struct two { char c; unsigned int i; double d; struct normal n; };
#pragma pack(push, 1)
struct inner { char c; long l; };
#pragma pack(pop)
struct two_again { char c; long l; };
#pragma pack(pop)
struct after { char c; long l; };
#define CHECK(c) _Static_assert(c, #c)
CHECK(sizeof(struct acpi_header) == 19 && offsetof(struct acpi_header, addr) == 9 && _Alignof(struct acpi_header) == 1);
CHECK(sizeof(struct normal) == 8);
CHECK(offsetof(struct two, i) == 2 && offsetof(struct two, d) == 6 && offsetof(struct two, n) == 14 && sizeof(struct two) == 22 && _Alignof(struct two) == 2);
CHECK(sizeof(struct inner) == 9 && sizeof(struct two_again) == 10 && sizeof(struct after) == 16);
int main(void) { struct acpi_header h = { "RSDP", 36, 2, 0x1122334455667788ull, 7 }; return h.addr == 0x1122334455667788ull && h.id == 7 ? 42 : 1; }
