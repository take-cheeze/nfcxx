// EXPECT: 42
// X86-ONLY: x86 inline assembly (memory operands and multiple alternatives in thunks; docs/notes/inline-asm.md)
// The kernel's shapes: "+m" atomics, "Ir" bit numbers, xchg, "rm"/"g"/"qm" alternatives, "i"(&symbol), "m" on arrays and on a large struct
typedef struct { int counter; } atomic_t;
static inline void atomic_add(int i, atomic_t *v) { __asm__ volatile("lock addl %1, %0" : "+m"(v->counter) : "ir"(i) : "memory"); }
static inline void set_bit(long nr, volatile unsigned long *addr) { __asm__ volatile("lock btsq %1, %0" : "+m"(*addr) : "Ir"(nr) : "memory"); }
static inline long xchg(long *p, long v) { __asm__ volatile("xchgq %0, %1" : "+r"(v), "+m"(*p) : : "memory"); return v; }
static int gvar = 40;
static int load_sym(void) { int r; __asm__("movl %1, %0" : "=r"(r) : "m"(gvar)); return r; }
static int addr_of_sym(void) { int *p; __asm__("leaq %c1(%%rip), %0" : "=r"(p) : "i"(&gvar)); return *p; }
static int rm_in(int x) { int r; __asm__("movl %1, %0" : "=r"(r) : "rm"(x)); return r; }
static int g_in(void) { int r; __asm__("movl %1, %0" : "=r"(r) : "g"(7)); return r; }
static int arr[4] = { 1, 2, 3, 4 };
static int mem_array(void) { int r, *p; __asm__("movl %1, %0" : "=r"(r) : "m"(arr[2])); __asm__("leaq %1, %0" : "=r"(p) : "m"(arr)); return p == arr ? r : -1; }
static int cmpxchg(int *p, int old, int new) {
	int prev = old; unsigned char ok;
	__asm__ volatile("lock cmpxchgl %3, %1\n\tsete %2" : "+a"(prev), "+m"(*p), "=qm"(ok) : "r"(new) : "memory", "cc");
	return ok ? prev : -prev;
}
struct big { long a[8]; };
static void clear_big(struct big *b) { __asm__ volatile("leaq %0, %%rax\n\tmovq $0, 56(%%rax)" : "+m"(*b) : : "rax"); }
int main(void) {
	atomic_t v = { 1 }; atomic_add(41, &v); if (v.counter != 42) return 1;
	unsigned long bits = 0; set_bit(5, &bits); set_bit(63, &bits); if (bits != (1UL << 5 | 1UL << 63)) return 2;
	long x = 3; long old = xchg(&x, 9); if (old != 3 || x != 9) return 3;
	if (load_sym() != 40) return 4;
	if (addr_of_sym() != 40) return 5;
	if (rm_in(11) != 11 || g_in() != 7) return 6;
	if (mem_array() != 3) return 7;
	int m = 5; if (cmpxchg(&m, 5, 8) != 5 || m != 8) return 9;
	if (cmpxchg(&m, 5, 9) != -8 || m != 8) return 10;
	struct big b = { { 1, 2, 3, 4, 5, 6, 7, 8 } }; clear_big(&b); if (b.a[7] != 0 || b.a[6] != 7) return 11;
	return 42;
}
