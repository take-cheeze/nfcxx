// Path B: __builtin_object_size gives the real answer where the pointer is the address of a known local or global
// object (a variable, a member, an element at a constant index, a constant offset), -1 (0 for types 2 and 3) where it is
// not: a pointer that was loaded. TYPE 1 asks for the closest surrounding member. The pointer is not evaluated.
// (TYPE 1 of the folded address of a member of a global structure is -1 here and is not tested; the gcc back end
// answers it differently again. docs/notes/pathb-hosted.md, "Known limits".)
// The exit code is the number of wrong results.
// EXPECT: 0
typedef unsigned long size_t_;
static int bad;
#define CHECK(c) do { if (!(c)) ++bad; } while (0)
#define UNK (~0UL)

char g[10];
struct S { char a[4]; int b; char tail[3]; } gs;
int gi;
int garr2[3][4];
char *volatile vp = g;  // a pointer loaded from a volatile: unknown to both compilers

int side_effect(int *c) { return ++*c; }

static size_t_ locals(int n) {
  char loc[16];
  S ls;
  int one;
  CHECK(__builtin_object_size(loc, 0) == 16);
  CHECK(__builtin_object_size(loc + 4, 0) == 12);
  CHECK(__builtin_object_size(&loc[15], 0) == 1);
  CHECK(__builtin_object_size(&loc[16], 0) == 0);
  CHECK(__builtin_object_size(loc, 2) == 16);
  CHECK(__builtin_object_size(&one, 0) == sizeof one);
  CHECK(__builtin_object_size(&ls, 0) == sizeof ls);
  CHECK(__builtin_object_size(&ls.b, 0) == sizeof ls - 4);
  CHECK(__builtin_object_size(&ls.b, 1) == 4);
  CHECK(__builtin_object_size(ls.a, 1) == 4);
  CHECK(__builtin_object_size(ls.a, 0) == sizeof ls);
  CHECK(__builtin_object_size(&ls.a[1], 1) == 3);
  CHECK(__builtin_object_size(&ls.a[1], 0) == sizeof ls - 1);
  CHECK(__builtin_object_size(&ls.tail[2], 1) == 1);
  CHECK(__builtin_object_size(&ls, 1) == sizeof ls);
  CHECK(__builtin_object_size((char *)&ls + 2, 0) == sizeof ls - 2);
  CHECK(__builtin_object_size((void *)loc, 0) == 16);
  CHECK(__builtin_object_size((const char *)loc, 3) == 16);
  return (size_t_)n;
}

int main() {
  locals(3);
  // globals
  CHECK(__builtin_object_size(g, 0) == 10);
  CHECK(__builtin_object_size(g + 3, 0) == 7);
  CHECK(__builtin_object_size(&g[9], 0) == 1);
  CHECK(__builtin_object_size(g + 10, 0) == 0);
  CHECK(__builtin_object_size(g, 3) == 10);
  CHECK(__builtin_object_size(&gi, 0) == sizeof gi);
  CHECK(__builtin_object_size(&gs, 0) == sizeof gs);
  CHECK(__builtin_object_size(&gs.b, 0) == sizeof gs - 4);
  CHECK(__builtin_object_size(&gs.a[1], 0) == sizeof gs - 1);
  CHECK(__builtin_object_size(&garr2[1][2], 0) == sizeof garr2 - 6 * sizeof(int));
  CHECK(__builtin_object_size(garr2, 1) == sizeof garr2);
  // a pointer that was loaded is unknown
  CHECK(__builtin_object_size(vp, 0) == UNK);
  CHECK(__builtin_object_size(vp + 2, 1) == UNK);
  CHECK(__builtin_object_size(vp, 2) == 0);
  CHECK(__builtin_object_size(vp, 3) == 0);
  // the pointer expression is not evaluated
  int cnt = 0;
  size_t_ u = __builtin_object_size(&g[side_effect(&cnt)], 0);
  CHECK(cnt == 0);
  CHECK(u == UNK || u == 9);
  return bad;
}
