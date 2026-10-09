// Path B: thread-local objects (docs/notes/pathb-stage3.md, "thread_local"). Each thread has its own copy; the main
// thread's value must be unchanged by what a second thread does to its copy, and a new thread starts from the
// static initializer, not from the creator's value. __thread and thread_local, initialized and zero, a struct, an
// array, a function-local thread_local, a pointer taken to the object, a static (internal) one.
// EXPECT: 0
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
}

__thread int t_counter = 5;
thread_local long t_zero;
thread_local char t_arr[8] = {1, 2, 3, 4};
struct Pair { int a; double b; };
thread_local Pair t_pair = {7, 2.5};
static __thread unsigned short t_static = 9;
int g_shared = 100;                 // an ordinary global: shared between the threads

int bump() { return ++t_counter; }
int local_tls() {
  static thread_local int calls = 10;   // a function-local thread_local object
  return ++calls;
}
int *addr_of_counter() { return &t_counter; }

static int child_bad;               // read by main after the join
extern "C" void *child(void *) {
  int bad = 0;
  if (t_counter != 5) bad |= 1;     // starts from the initializer, not from main's 42
  if (t_zero != 0) bad |= 2;
  if (t_arr[3] != 4 || t_arr[7] != 0) bad |= 4;
  if (t_pair.a != 7 || t_pair.b != 2.5) bad |= 8;
  if (t_static != 9) bad |= 16;
  if (local_tls() != 11) bad |= 32;
  t_counter = 1000; t_zero = -1; t_arr[3] = 99; t_pair.a = 77; t_static = 1;
  int *p = addr_of_counter();
  if (*p != 1000) bad |= 64;
  g_shared += 1;
  child_bad = bad;
  return 0;
}

int main() {
  int bad = 0;
  t_counter = 42; t_zero = 3; t_arr[3] = 5; t_pair.b = 0.5; t_static = 2;
  int *mine = addr_of_counter();
  local_tls();
  unsigned long th;
  pthread_create(&th, 0, child, 0);
  pthread_join(th, 0);
  bad |= child_bad;
  if (t_counter != 42 || *mine != 42) bad |= 256;       // untouched by the child
  if (t_zero != 3 || t_arr[3] != 5 || t_pair.a != 7 || t_pair.b != 0.5 || t_static != 2) bad |= 512;
  if (local_tls() != 12) bad |= 1024;                    // main's own function-local counter
  if (bump() != 43) bad |= 2048;
  if (g_shared != 101) bad |= 4096;
  return bad;
}
