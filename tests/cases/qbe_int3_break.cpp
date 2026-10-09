// EXPECT: 4
// QBE path (scripts/qbe-prep.rb): `__asm__ volatile("int $3\n" : :)` is doctest's DOCTEST_BREAK_INTO_DEBUGGER.
// cproc has no inline asm, so the statement becomes a call to a weak `int3; ret` stub in the assembly tail
// (docs/notes/realworld.md). The SIGTRAP handler counts each break and returns, and execution resumes at the
// stub's ret, so every break below is counted and the program keeps running. cproc rejects volatile stores,
// so the handler stores normally and main reads the counter through a volatile load.
#include <csignal>

static int breaks;
static void on_trap(int) { breaks = breaks + 1; }
static int count() { return *(volatile int *)&breaks; }

#define BREAK_INTO_DEBUGGER() __asm__ volatile("int $3\n" : :)

static void check_once() { BREAK_INTO_DEBUGGER(); }

int main() {
    std::signal(SIGTRAP, on_trap);
    BREAK_INTO_DEBUGGER();
    if (count() == 1) { BREAK_INTO_DEBUGGER(); }
    check_once();
    __asm__("int $3\n" : :);  // the same statement without `volatile`
    return count();
}
