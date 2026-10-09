// EXPECT: 0
// STDOUT: same
// inline thread_local variables, template static data members and function-local thread_locals of inline functions,
// defined in a header shared by two units: one copy per thread, constructed once, destroyed once.
#include "common.h"

extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
}

static int bad;

extern "C" void *child(void *) {
  printf("child start\n");
  hv.val = 71;
  if (use_in_b() != 71 + 80 + 9) bad |= 1;    // b.cpp sees this thread's copies
  Tmpl<T>::v.val = 81;
  hfn() = 10;
  if (use_in_b() != 71 + 81 + 10) bad |= 2;
  printf("child end\n");
  return 0;
}

int main() {
  printf("main start\n");
  if (use_in_b() != 70 + 80 + 9) bad |= 4;
  unsigned long th;
  pthread_create(&th, 0, child, 0);
  pthread_join(th, 0);
  printf("joined\n");
  if (hv.val != 70 || Tmpl<T>::v.val != 80 || hfn() != 9) bad |= 8;
  printf("main end\n");
  return bad;
}
