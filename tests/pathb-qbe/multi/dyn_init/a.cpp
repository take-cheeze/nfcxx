// EXPECT: 61
// Two translation units, each with a global object that has a constructor, linked together. Both units' start-up
// routines (.init_array) must run before main; the inline variable and the function-local static of common.h are
// each constructed once, whichever unit gets there first.
#include "common.h"
int constructed;
int destroyed;
Counted::Counted(int w) : weight(w) { constructed += w; }
Counted::~Counted() { destroyed += weight; }
Counted ga(1);
int b_part();   // b.cpp: its own global (weight 2) is constructed; returns local_static_user() / 10000
int main()
{
  int r = 0;
  if (constructed != 1 + 2 + 100) r += 1;        // ga, gb, shared_inline: before main, shared_inline once
  r += local_static_user() == 10000 ? 0 : 2;
  r += b_part() == 1 ? 0 : 4;                    // the same static
  if (constructed != 1 + 2 + 100 + 10000) r += 8;   // once built once
  return r + 61;                                 // 61 when all of it holds
}
