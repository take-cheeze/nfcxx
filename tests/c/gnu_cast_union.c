// EXPECT: 42
// GNU casts to a union type (the kernel's (union ibs_fetch_ctl)config), in code and in a static initializer; an aligned
// attribute below a member's alignment is ignored outside a packed struct, as gcc does; zero-length arrays
union ctl { unsigned long val; struct { unsigned int lo, hi; } w; };
static union ctl from(unsigned long c) { union ctl f = (union ctl)c; return f; }
static union ctl g = (union ctl)0x500000002ul;
struct big { long x; };
struct s { int a; struct big g __attribute__((aligned(4))); int b; };
_Static_assert(__builtin_offsetof(struct s, g) == 8 && sizeof(struct s) == 24, "aligned(4) ignored unless packed");
struct zl { int n; int data[0]; };
int z0[0];
_Static_assert(sizeof(struct zl) == 4 && sizeof z0 == 0, "zero-length arrays");
int main(void) {
	struct zl v; if (sizeof v.data != 0 || (char *)(&v.data + 1) != (char *)v.data) return 2; union ctl f = from(0x0000002800000002ul); return f.w.lo + f.w.hi == 42 && g.w.hi == 5 ? 42 : 1; }
