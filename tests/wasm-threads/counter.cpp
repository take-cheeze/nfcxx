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
