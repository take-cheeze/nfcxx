// Atomics for threads (pathb-wasm-emit.rb --threads): the functions below are called from several worker threads that share
// one memory. The host (tests/wasm-threads/host.cjs) owns the words they touch; the module has no static data of its own.
extern "C" void bump(int *p, int n) {
  for (int i = 0; i < n; i++) __atomic_fetch_add(p, 1, __ATOMIC_SEQ_CST);
}

extern "C" void bump64(long long *p, int n) {
  for (int i = 0; i < n; i++) __sync_fetch_and_add(p, 1);
}

extern "C" int cas(int *p, int expect, int desire) { return __sync_val_compare_and_swap(p, expect, desire); }

extern "C" int xchg(int *p, int v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }

extern "C" int load(int *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }

extern "C" void store(int *p, int v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }

extern "C" void fence() { __atomic_thread_fence(__ATOMIC_SEQ_CST); }

// a static with an initializer: it is in the module's data, which __nfcxx_init applies once (not once per thread)
int shared_init = 100;

extern "C" void bump_shared(int n) {
  for (int i = 0; i < n; i++) __atomic_fetch_add(&shared_init, 1, __ATOMIC_SEQ_CST);
}

extern "C" long long shared_addr() { return (long long)&shared_init; }

// a thread-local: each thread has its own copy, starting at 5 (the module's initial image); the adds need no atomics
thread_local int tl = 5;

extern "C" int tl_bump(int n) {
  for (int i = 0; i < n; i++) tl++;
  return tl;
}

extern "C" int tl_get() { return tl; }

// Threads created by the module: pthread_create and pthread_join are the host's (env imports); the host starts each thread
// as an instance over the same memory, and joins wait for it to finish.
extern "C" int pthread_create(unsigned long long *th, void *attr, void *(*start)(void *), void *arg);
extern "C" int pthread_join(unsigned long long th, void **ret);

int joined_shared = 0;

extern "C" void *joined_worker(void *arg) {
  long long v = (long long)arg;
  for (int i = 0; i < 1000; i++) __atomic_fetch_add(&joined_shared, 1, __ATOMIC_SEQ_CST);
  return (void *)(v * 10);
}

extern "C" int run_threads(int n) {
  unsigned long long th[8];
  for (int i = 0; i < n; i++) pthread_create(&th[i], 0, joined_worker, (void *)(long long)(i + 1));
  int sum = 0;
  for (int i = 0; i < n; i++) {
    void *r = 0;
    pthread_join(th[i], &r);
    sum += (int)(long long)r;
  }
  return sum;
}

extern "C" int joined_get() { return __atomic_load_n(&joined_shared, __ATOMIC_SEQ_CST); }
