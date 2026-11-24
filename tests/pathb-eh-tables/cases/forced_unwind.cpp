// EXPECT: 0
// STDOUT: same
// A forced unwind (glibc's pthread_exit and pthread_cancel: _Unwind_ForcedUnwind with abi::__forced_unwind) through
// Path B's frames: the pads run the destructors on the way, a catch (...) sees it and must rethrow it, and a catch of a
// C++ type does not match it. The cancel reaches the thread at pthread_testcancel, a cancellation point Path B calls
// with a pad around it.
#include <cstdio>
#include <pthread.h>
static char log_buf[512];
static int log_len;
static void say(const char *s) {
  while (*s && log_len < (int)sizeof log_buf - 1) log_buf[log_len++] = *s++;
  log_buf[log_len++] = '\n';
}
struct D {
  const char *n;
  ~D() { say(n); }
};
__attribute__((noinline)) static void leave(int how) {
  D d{"~leave"};
  if (how == 0) pthread_exit(nullptr);
  for (;;) pthread_testcancel();
}
__attribute__((noinline)) static void middle(int how) {
  D d{"~middle"};
  try {
    leave(how);
  } catch (int) {
    say("caught int (wrong)");
  }
}
static void *body(void *arg) {
  int how = (int)(long)arg;
  D d{"~body"};
  try {
    middle(how);
  } catch (...) {
    say("catch (...) rethrows");
    throw;
  }
  say("not reached");
  return nullptr;
}
static volatile int ready;
static void *spin(void *arg) {
  ready = 1;
  return body(arg);
}
int main() {
  pthread_t t;
  pthread_create(&t, nullptr, body, (void *)0L);
  pthread_join(t, nullptr);
  say("-- cancel");
  pthread_create(&t, nullptr, spin, (void *)1L);
  while (!ready) {
  }
  pthread_cancel(t);
  void *r;
  pthread_join(t, &r);
  say(r == PTHREAD_CANCELED ? "canceled" : "not canceled");
  std::fwrite(log_buf, 1, log_len, stdout);
  return 0;
}
