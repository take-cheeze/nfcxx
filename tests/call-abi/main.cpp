// The caller side of tests/call-abi/run.sh: every value must arrive as sent.
#include <cstdio>
#include "abi.h"
int main() {
  auto o = r_opt();
  std::printf("r_opt %d\n", o ? (int)*o : -1);
  std::printf("r_opti %d\n", r_opti().value_or(-1));
  std::printf("r_ostr %s\n", r_ostr().value_or("none").c_str());
  std::printf("r_copy %d r_copyn %d r_pair %d r_pairn %d\n", r_copy().v, r_copyn().v, r_pair().v, r_pairn().v);
  std::printf("r_move %d r_wrap %d r_moveonly %d\n", r_move().v, r_wrap().t.v, r_moveonly().v);
  std::printf("p_opt %d p_opti %d p_ostr %d\n", p_opt(Dev::CUDA), p_opti(20, 22), p_ostr(std::string("abcdefg")));
  std::printf("p_copy %d p_copyn %d p_pair %d p_pairn %d\n", p_copy(31), p_copyn(32), p_pair(33), p_pairn(34));
  std::printf("p_move %d p_wrap %d p_moveonly %d\n", p_move(Move<true>(35)), p_wrap({Copy<true>(36)}), p_moveonly(MoveOnly(37)));
  return 0;
}
