// EXPECT: 0
// QBE path (scripts/qbe-prep.py and the -latomic link, docs/notes/realworld.md, blocker 3): libstdc++'s
// std::atomic calls GCC's sized __atomic_*_N builtins (N = 1, 2, 4, 8). cproc has no atomics, so the QBE output
// declares them as the libatomic functions GCC 13 exports, and the link adds -latomic. Each check counts a failure.
#include <atomic>

int main() {
    int fails = 0;

    std::atomic<int> i{5};
    i.store(7);
    fails += i.load() != 7;
    fails += i.fetch_add(3) != 7 || i.load() != 10;
    fails += i.fetch_sub(4) != 10 || i.load() != 6;
    fails += i.exchange(9) != 6 || i.load() != 9;
    int expected = 9;
    fails += !i.compare_exchange_strong(expected, 11) || i.load() != 11;
    expected = 0;
    fails += i.compare_exchange_strong(expected, 12) || expected != 11;

    std::atomic<long> l{1};
    l.fetch_add(41);
    fails += l.load() != 42;

    std::atomic<unsigned char> c{0};
    c.store(200);
    fails += c.load() != 200;

    std::atomic<bool> flag{false};
    flag.store(true);
    fails += !flag.load();

    return fails;
}
