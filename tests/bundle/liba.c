// libA: TLS in every model, a constructor and destructor, a weak hook, a symbol the program interposes, an IFUNC,
// two versions of one symbol, and data the program reaches through a copy relocation.
#include <stdio.h>
__thread int a_tls = 5;                                   // general dynamic from the others, local dynamic here
static __thread int a_tls_local = 7;
static __thread char a_tls_bss[64];
__attribute__((tls_model("initial-exec"))) __thread int a_ie = 11;
int a_counter = 100;                                      // the program's copy relocation
const char *a_table[] = {"zero", "one", "two"};           // data with relocations, also copied
void note(const char *s);                                 // defined by the program: initialization order
__attribute__((constructor)) static void a_init(void) { note("A"); a_counter++; }
__attribute__((destructor)) static void a_fini(void) { printf("fini A %d\n", a_counter); fflush(stdout); }
int a_get(void) { a_tls_bss[3]++; return a_tls + a_tls_local + a_ie + a_tls_bss[3]; }
int *a_tls_addr(void) { return &a_tls; }
int a_hook(void) __attribute__((weak));
int a_call_hook(void) { return a_hook ? a_hook() : -1; }
int interposed(void) { return 1; }
int a_interposed(void) { return interposed(); }
void a_bump(void) { a_counter++; }
static int impl_fast(void) { return 42; }
static int impl_slow(void) { return 41; }
static int (*resolve_ifunc(void))(void) { return a_counter >= 0 ? impl_fast : impl_slow; }
int a_ifunc(void) __attribute__((ifunc("resolve_ifunc")));
int a_ver_old(void) { return 1; }
int a_ver_new(void) { return 2; }
__asm__(".symver a_ver_old,a_ver@V1");
__asm__(".symver a_ver_new,a_ver@@V2");
