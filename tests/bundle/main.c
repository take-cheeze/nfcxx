// The program: local-exec TLS of its own, initial-exec access to libA's TLS, threads, the libraries' functions.
#include <pthread.h>
#include <stdio.h>
#include <string.h>
extern __thread int a_tls;
extern int a_counter;
extern const char *a_table[];
int a_get(void), b_get(void), *a_tls_addr(void), a_call_hook(void), a_interposed(void), a_ifunc(void), a_ver(void);
void a_bump(void);
__thread int m_tls = 3;
__thread char m_tls_bss[100];
static char order[64];
void note(const char *s) { strcat(order, s); }
__attribute__((constructor)) static void m_init(void) { note("M"); }
__attribute__((destructor)) static void m_fini(void) { printf("fini M\n"); fflush(stdout); }
int interposed(void) { return 2; }
static void *thread(void *arg) {
  long k = (long)arg;
  a_tls += (int)k; m_tls += (int)k; m_tls_bss[50] = (char)k;
  int v = b_get() + a_tls + m_tls + m_tls_bss[50];
  return (void *)(long)(v + (a_tls_addr() == &a_tls ? 1000 : 0));
}
int main(void) {
  printf("order %s\n", order);
  printf("tls %d %d %d %d\n", a_get(), b_get(), a_tls, m_tls);
  pthread_t t[3];
  for (long k = 0; k < 3; k++) pthread_create(&t[k], 0, thread, (void *)(k + 1));
  for (int k = 0; k < 3; k++) { void *r; pthread_join(t[k], &r); printf("thread %d %ld\n", k, (long)r); }
  a_bump();
  printf("copy %d %s %s\n", a_counter, a_table[1], a_table[2]);
  printf("hook %d interposed %d ifunc %d ver %d\n", a_call_hook(), a_interposed(), a_ifunc(), a_ver());
  return 0;
}
