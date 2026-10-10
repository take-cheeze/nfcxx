// Path B: __builtin_object_size of a member of a global structure. The front end folds the address of g.m into the address
// of g plus an offset; the member is recovered from the pointer's type and the offset, so TYPE 1 gives the member's size
// (as gcc does), not -1. The values are the ones gcc -O0 prints for these expressions.
// The exit code is the number of wrong results.
// EXPECT: 0
// GCC: undefined   (the values are g++'s: checked with g++ -O0 when this probe was written. The nfcxx gcc backend
// (EDG's C output) answers TYPE 1 of a member of a global differently, so only EXPECT is compared.)
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)

struct G { int a; int m[4]; char c; struct { char x[3]; } in; };
G g;
G gg[2];
struct P { char pad[5]; struct { int q; } s; } gp;

int main() {
  // (TYPE 1 of &g.a, &g and &gg[1], and of &gg[1].a, is not asked: the folded address is the same as that of the
  // structure itself, so the IL cannot tell them apart; the answer is -1 there. docs/notes/pathb-hosted.md.)
  CHECK(__builtin_object_size(&g.m, 1) == 16);
  CHECK(__builtin_object_size(&g.m, 0) == 20);
  CHECK(__builtin_object_size(&g.in, 1) == 3);
  CHECK(__builtin_object_size(&g.in.x[1], 1) == 2);
  CHECK(__builtin_object_size(&g.m[1], 1) == 12);
  CHECK(__builtin_object_size(&gg[1].m, 1) == 16);
  CHECK(__builtin_object_size(&gg[1].c, 1) == 1);
  CHECK(__builtin_object_size(&g.c, 0) == 4);
  CHECK(__builtin_object_size(&g.c, 1) == 1);
  CHECK(__builtin_object_size(&gp.s, 1) == 4);
  CHECK(__builtin_object_size(&gp.s, 0) == 4);
  // an element of an array of structures is a sub-object, and so are its members
  CHECK(__builtin_object_size(&gg[1].in, 1) == 3);
  CHECK(__builtin_object_size(&gg[1].in.x[1], 1) == 2);
  CHECK(__builtin_object_size(&gg[1].m[1], 1) == 12);
  CHECK(__builtin_object_size(&gg[0].m, 1) == 16);
  CHECK(__builtin_object_size(&gg[1].c, 1) == 1);
  CHECK(__builtin_object_size(&gg[1].m, 1) == 16);
  return bad;
}
