// EXPECT: 42
// X86-ONLY-qbe: cproc takes __builtin_extract_return_addr only where it is the identity (x86-64)
// __builtin_extract_return_addr of a return address (the kernel's vsprintf, %pS) is that address on x86-64
static void *seen;
__attribute__((noinline)) static void *whoami(void) { return __builtin_extract_return_addr(__builtin_return_address(0)); }
__attribute__((noinline)) static void caller(void) { seen = whoami(); __asm__ volatile("" ::: "memory"); }
int main(void) {
	caller();
	char *ra = seen;
	if (ra <= (char *)caller || ra > (char *)caller + 64) return 1;
	return __builtin_extract_return_addr(&seen) == &seen ? 42 : 2;
}
