// EXPECT: 0
// STDOUT: same
// More forms of thread_local objects with dynamic initialization: internal linkage (static, anonymous namespace),
// a constant-initialized object next to dynamic ones (no wrapper), a reference, an inline variable and a template
// static data member (both may be defined by several units), a function-local one in a loop and in a template,
// a thread that never touches the objects (no construction, no destruction), and several threads at the same time.
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

static int seed(int x) { return x * 2; }

static thread_local T st(1, 10);               // internal linkage
namespace { thread_local T anon(2, 20); }      // internal linkage, anonymous namespace
thread_local int plain = 77;                   // constant initialization: no dynamic initialization
thread_local int computed = seed(21);
thread_local int &ref = computed;              // dynamically initialized reference
inline thread_local T inl(3, 30);              // inline variable (C++17)

template <class U> struct Tmpl {
  static thread_local U v;
};
template <class U> thread_local U Tmpl<U>::v(4, 40);

template <int N> int &fnlocal() {
  thread_local int x = seed(N);
  return x;
}

int loop_local(int n) {
  int sum = 0;
  for (int i = 0; i < n; i++) {
    thread_local T l(5, 50);                   // constructed once per thread, not per iteration
    sum += l.val;
  }
  return sum;
}

static int bad;

extern "C" void *idle(void *) { return 0; }    // never touches a thread_local: nothing is constructed or destroyed

extern "C" void *worker(void *) {
  printf("worker start\n");
  if (st.val != 10) bad |= 1;
  if (anon.val != 20) bad |= 2;
  if (plain != 77) bad |= 4;
  if (computed != 42 || ref != 42) bad |= 8;
  ref = 43;
  if (computed != 43) bad |= 16;
  if (inl.val != 30) bad |= 32;
  if (Tmpl<T>::v.val != 40) bad |= 64;
  if (fnlocal<5>() != 10 || fnlocal<6>() != 12) bad |= 128;
  if (loop_local(3) != 150) bad |= 256;
  printf("worker end\n");
  return 0;
}

int main() {
  unsigned long th;
  pthread_create(&th, 0, idle, 0);
  pthread_join(th, 0);
  printf("idle joined\n");
  pthread_create(&th, 0, worker, 0);
  pthread_join(th, 0);
  printf("worker joined\n");
  if (st.val != 10 || anon.val != 20) bad |= 512;
  if (computed != 42) bad |= 1024;
  printf("main end %d\n", Tmpl<T>::v.val);
  return bad;
}
