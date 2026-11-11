// EXPECT: 42
// ELF-ONLY: mode on an enum is gcc's; Apple clang ignores it there
// GNU mode on an enum (the kernel's trace enums: enum afs_call_trace { ... } __mode(byte)): the integer type of that size,
// signed when a value is negative, as gcc lays it out. cproc ignored the attribute before, and the enums were 4 bytes.
enum small { A, B, C = 200 } __attribute__((__mode__(byte)));
enum neg { N = -5, P = 100 } __attribute__((mode(QI)));
enum wide { W = 1 } __attribute__((mode(DI)));
struct rec { enum small s; char c; enum neg n; };
_Static_assert(sizeof(enum small) == 1 && sizeof(enum neg) == 1 && sizeof(enum wide) == 8 && sizeof(struct rec) == 3, "mode");
int main(void) { enum small s = C; enum neg n = N; struct rec r = { C, 1, N }; return s == 200 && (int)n == -5 && r.n < 0 ? 42 : 1; }
