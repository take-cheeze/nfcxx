// Classes whose triviality for the purposes of calls (IA-64 C++ ABI) decides whether they travel in registers or
// through a hidden pointer, for tests/call-abi/run.sh. The library and the caller are built by different compilers.
#include <cstdint>
#include <optional>
#include <string>

enum class Dev : int8_t { CPU = 0, CUDA = 1 };
// C++20 conditionally trivial special members (P0848): two copy (or move) constructors, one eligible.
template<bool B> struct Copy {
  int v;
  Copy(int x) : v(x) {}
  Copy(const Copy&) requires B = default;
  Copy(const Copy& o) requires (!B) : v(o.v) {}
};
// An unconstrained user-provided copy constructor beside a constrained trivial one (libstdc++'s std::optional): when
// both are satisfied the constrained one is more constrained, so it is the eligible one.
template<bool B> struct Pair {
  int v;
  Pair(int x) : v(x) {}
  Pair(const Pair& o) : v(o.v) {}
  Pair(const Pair&) requires B = default;
};
template<bool B> struct Move {
  int v;
  Move(int x) : v(x) {}
  Move(const Move&) = delete;
  Move(Move&&) requires B = default;
  Move(Move&& o) requires (!B) : v(o.v) {}
};
template<class T> struct Wrap { T t; };
// A deleted copy constructor and a trivial move constructor: in registers (only "all deleted" forces memory).
struct MoveOnly { int v; MoveOnly(int x) : v(x) {} MoveOnly(const MoveOnly&) = delete; MoveOnly(MoveOnly&&) = default; };

std::optional<Dev> r_opt();
std::optional<int> r_opti();
std::optional<std::string> r_ostr();
Copy<true> r_copy();
Copy<false> r_copyn();
Pair<true> r_pair();
Pair<false> r_pairn();
Move<true> r_move();
Wrap<Copy<true>> r_wrap();
MoveOnly r_moveonly();
int p_opt(std::optional<Dev>);
int p_opti(std::optional<int>, std::optional<long>);
int p_ostr(std::optional<std::string>);
int p_copy(Copy<true>);
int p_copyn(Copy<false>);
int p_pair(Pair<true>);
int p_pairn(Pair<false>);
int p_move(Move<true>);
int p_wrap(Wrap<Copy<true>>);
int p_moveonly(MoveOnly);
