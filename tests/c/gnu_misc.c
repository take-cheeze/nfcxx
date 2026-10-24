// EXPECT: 42
// ELF-ONLY: __builtin_isdigit is gcc's (Apple clang has no such builtin)
// GNU C the kernel uses: local labels (__label__) in a macro used twice, packed before a struct body with bit-fields,
// __builtin_isdigit and __builtin_prefetch, the \e escape, void * against a function pointer, the __attribute spelling
#define TRY(x) ({ __label__ out; int r_ = 0; if (x) goto out; r_ = 1; out: r_; })
struct __attribute__((packed)) ctl { unsigned int flush:1, bitmap:1, npt:1, reserved:29; };
struct outer { struct __attribute__((packed)) inner { unsigned int a:1, b:31; } __attribute__((packed)) in; unsigned int id; unsigned long vm; } __attribute__((packed));
_Static_assert(sizeof(struct ctl) == 4 && _Alignof(struct ctl) == 1 && sizeof(struct outer) == 16, "leading packed");
typedef void (*sighandler_t)(int);
#define SIG_IGN ((sighandler_t)1)
static int ignored(void *handler) { return handler == SIG_IGN; }
static __attribute((noinline)) int noinstr_like(void) { return 3; }
int main(void) {
	int a = TRY(0), b = TRY(1);
	struct ctl c = { 1, 0, 1, 5 };
	char esc = '\e';
	long arr[4] = { 1, 2, 3, 4 };
	__builtin_prefetch(&arr[1]); __builtin_prefetch(&arr[2], 1, 3);
	if (a != 1 || b != 0) return 1;
	if (c.flush != 1 || c.npt != 1 || c.reserved != 5) return 2;
	if (esc != 27) return 3;
	if (!__builtin_isdigit('7') || __builtin_isdigit('a') || __builtin_isdigit(-1)) return 4;
	if (!ignored((void *)1) || ignored(0)) return 5;
	if (noinstr_like() != 3) return 6;
	return 42;
}
