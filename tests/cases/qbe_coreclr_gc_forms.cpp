// EXPECT: 0
// MACOS-XFAIL-gcc: Apple clang rejects the volatile-qualified address that EDG passes to __sync_*_4 ("address argument to
// atomic builtin must be a pointer to integer or pointer"); gcc on Linux accepts it. The QBE path has no such check.
// QBE path (scripts/qbe-prep, docs/notes/coreclr-gc.md): cproc has no volatile stores, so the qualifier is dropped
// (on a cast and on an object, including a block-scope local), and GCC's __sync read-modify-write builtins become
// helpers over cproc's __atomic_* builtins. CoreCLR's GC uses all of these (src/coreclr/gc/env/volatile.h and
// gcenv.interlocked.inl). Each check counts a failure.
#include <cstdint>

struct Flag {
    volatile int32_t m_val;
};

int main() {
    int fails = 0;

    // volatile objects and casts (EDG writes `*(volatile T *)&x = v` for Volatile<T>::Store)
    volatile int32_t v = 3;
    v = 5;
    fails += v != 5;

    Flag f{1};
    *(volatile int32_t *)&f.m_val = 7;
    fails += f.m_val != 7;

    uint64_t wide = 0;
    *(volatile uint64_t *)&wide = 1ull << 40;
    fails += wide != (1ull << 40);

    // a volatile block-scope local whose address is never taken otherwise
    {
        volatile int32_t local = 0;
        local = 9;
        fails += local != 9;
    }

    // GCC's __sync builtins, 4 and 8 bytes: the new value for *_and_fetch, the old value for compare-and-swap
    uint32_t a = 10;
    fails += __sync_add_and_fetch_4(&a, 5u) != 15 || a != 15;
    fails += __sync_sub_and_fetch_4(&a, 3u) != 12;
    fails += __sync_and_and_fetch_4(&a, 6u) != 4;
    fails += __sync_or_and_fetch_4(&a, 1u) != 5;
    fails += __sync_xor_and_fetch_4(&a, 0xffu) != 250;
    fails += __sync_val_compare_and_swap_4(&a, 250u, 9u) != 250 || a != 9;
    fails += __sync_val_compare_and_swap_4(&a, 5u, 1u) != 9 || a != 9;  // a failed swap returns the current value

    uint64_t b = 1ull << 40;
    fails += __sync_add_and_fetch_8(&b, 1ull) != (1ull << 40) + 1;
    fails += __sync_val_compare_and_swap_8(&b, (1ull << 40) + 1, 2ull) != (1ull << 40) + 1 || b != 2;
    fails += __sync_sub_and_fetch_8(&b, 1ull) != 1;

    // hints and bit builtins used by the GC
    __builtin_prefetch(&a);
    __builtin_prefetch(&a, 1, 3);
    fails += __builtin_ffs(0) != 0 || __builtin_ffs(1) != 1 || __builtin_ffs(0x100) != 9 || __builtin_ffs(-8) != 4;

    return fails;
}
