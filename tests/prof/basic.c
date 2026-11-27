/* Program for tests/prof/run.sh: one thread's worth of enter/exit pairs at site 7, two threads at site 9. */
#include "nfcxx_prof.h"

#include <pthread.h>
#include <stdio.h>

#define N 1000

static volatile long sink;

static void work(uint32_t site, int n) {
  int i;
  for (i = 0; i < n; i++) {
    __nfcxx_prof_enter(site);
    sink += i;
    __nfcxx_prof_exit(site);
  }
}

static void *thread_main(void *arg) {
  (void)arg;
  work(9, N);
  return NULL;
}

int main(void) {
  pthread_t t[2];
  int i;
  printf("enabled=%d\n", __nfcxx_prof_enabled());
  work(7, N);
  for (i = 0; i < 2; i++) pthread_create(&t[i], NULL, thread_main, NULL);
  for (i = 0; i < 2; i++) pthread_join(t[i], NULL);
  printf("done\n");
  return 0;
}
