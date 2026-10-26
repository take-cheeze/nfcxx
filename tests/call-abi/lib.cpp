// The callee side of tests/call-abi/run.sh.
#include "abi.h"
std::optional<Dev> r_opt() { return Dev::CUDA; }
std::optional<int> r_opti() { return 11; }
std::optional<std::string> r_ostr() { return std::string("twelve"); }
Copy<true> r_copy() { return 13; }
Copy<false> r_copyn() { return 14; }
Pair<true> r_pair() { return 15; }
Pair<false> r_pairn() { return 16; }
Move<true> r_move() { return 17; }
Wrap<Copy<true>> r_wrap() { return {Copy<true>(18)}; }
MoveOnly r_moveonly() { return 19; }
int p_opt(std::optional<Dev> d) { return d ? 20 + (int)*d : -1; }
int p_opti(std::optional<int> a, std::optional<long> b) { return a && b ? *a + (int)*b : -1; }
int p_ostr(std::optional<std::string> s) { return s ? (int)s->size() : -1; }
int p_copy(Copy<true> c) { return c.v; }
int p_copyn(Copy<false> c) { return c.v; }
int p_pair(Pair<true> c) { return c.v; }
int p_pairn(Pair<false> c) { return c.v; }
int p_move(Move<true> m) { return m.v; }
int p_wrap(Wrap<Copy<true>> w) { return w.t.v; }
int p_moveonly(MoveOnly m) { return m.v; }
