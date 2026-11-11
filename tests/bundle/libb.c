// libB needs libA: it uses libA's TLS (general dynamic), libA's functions, and has its own TLS and constructor.
extern __thread int a_tls;
int a_get(void);
void note(const char *s);
__thread long b_tls[4] = {1, 2, 3, 4};
__attribute__((constructor)) static void b_init(void) { note("B"); }
int b_get(void) { b_tls[0]++; return a_get() + a_tls + (int)b_tls[0]; }
