// EXPECT: 0
// A `static const` struct copied whole (`*p = z`): the padding after the last member is zero. mruby's gc.c copies RVALUE_zero over
// every new object; the struct there is a header plus `char padding[24]`, which stops 4 bytes short of the union's 40, and the
// union's `super` pointer lives in those bytes. Path B left them as stack garbage (mrbc crashed in the GC).
#include <string.h>
enum T { T_FALSE, T_X };
struct H { void *c; enum T tt:8; unsigned gc:3; unsigned fr:1; unsigned fl:20; };
struct Init { struct H h; char pad[24]; };            // pad starts at 12: 4 bytes of tail padding
struct Free { struct H h; void *next; };
struct Cls { void *c; unsigned bits; void *iv; void *mt; void *super; };
union R { struct Init init; struct Free fr; struct Cls cls; };
struct Obj { union R as; };

__attribute__((noinline)) static void poison(void) { volatile char buf[256]; for (int i = 0; i < 256; i++) buf[i] = (char)0xab; }

__attribute__((noinline)) static void init(struct Obj *p) {
  static const struct Obj z = { { { 0, T_FALSE } } };
  *p = z;
}

int main(void) {
  struct Obj o;
  memset(&o, 0xcd, sizeof o);
  poison();
  init(&o);
  unsigned char zero[sizeof o]; memset(zero, 0, sizeof zero);
  if (memcmp(&o, zero, sizeof o) != 0) return 1;
  if (o.as.cls.super != 0) return 2;
  return 0;
}
