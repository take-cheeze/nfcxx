// EXPECT: 0
// STDOUT: same
// thread_local objects with dynamic initialization and destruction: each thread runs the initializer for its own
// copy and the destructor at thread exit; the main thread's copies are destroyed at exit. The threads run one after
// the other (join), so the output order is deterministic.
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
int printf(const char *, ...);
}

struct T {
  int id;
  int val;
  T(int i, int v) : id(i), val(v) { printf("ctor %d val=%d\n", id, val); }
  ~T() { printf("dtor %d val=%d\n", id, val); }
};

static int counter;
static int next_val(int base) { return base + (++counter); }

thread_local T a(1, 100);                     // dynamic init (constructor with arguments) and destructor
thread_local int b = next_val(1000);          // dynamic init without destructor
thread_local T arr[2] = {T(2, 1), T(3, 2)};   // array of objects

// a function-local thread_local: initialized the first time the thread executes the declaration
T &local() {
  thread_local T l(4, 400);
  return l;
}

struct Holder {
  static thread_local T sm;                   // thread_local static data member
  static thread_local int smi;
};
thread_local T Holder::sm(5, 500);
thread_local int Holder::smi = next_val(2000);

static int bad;

extern "C" void *child(void *) {
  printf("child start\n");
  if (a.val != 100) bad |= 1;
  a.val = 101;
  if (arr[1].val != 2) bad |= 2;
  if (b < 1000) bad |= 4;
  local().val = 401;
  if (Holder::sm.val != 500) bad |= 8;
  printf("child end\n");
  return 0;
}

int main() {
  printf("main start\n");
  a.val = 7;
  printf("main a=%d b=%d\n", a.val, b > 1000);
  unsigned long th;
  pthread_create(&th, 0, child, 0);
  pthread_join(th, 0);
  printf("joined\n");
  if (a.val != 7) bad |= 32;
  if (local().val != 400) bad |= 64;
  if (Holder::smi < 2000) bad |= 128;
  printf("main end\n");
  return bad;
}
