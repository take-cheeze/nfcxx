// The program of the shared-library case (see tls_lib.cpp): each thread has its own copy of the library's
// thread-local variables, and the program and the library see the same exported one.
#include <cstdio>
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
}
extern thread_local int tls_exported;
long tls_next();

static long child_first;
extern "C" void *child(void *) { child_first = tls_next(); return nullptr; }

int main() {
  tls_exported = 20;
  long a = tls_next(), b = tls_next();         // 100 + 1 + 20, 100 + 2 + 20
  unsigned long t;
  pthread_create(&t, nullptr, child, nullptr);
  pthread_join(t, nullptr);                   // the child's copies start fresh: 100 + 1 + 11
  printf("%ld %ld %ld\n", a, b, child_first);
  return !(a == 121 && b == 122 && child_first == 112);
}
