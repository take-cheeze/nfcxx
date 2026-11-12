// EXPECT: 0
// Path B: `char str[1]` as the last member of a struct is the pre-C99 flexible array (TinyCC's TokenSym, indexed by the
// length of the name that follows the header). Its subscript is not bounds-checked, as gcc's -fstrict-flex-arrays=1 and the
// default 0. A one-element array that is not last, and a longer last array, are still checked (tests/pathb-qbe/traps).
#include <cstdlib>
#include <cstring>

struct Sym {
  int tok;
  int len;
  char str[1];
};

__attribute__((noinline)) static Sym *make(const char *s, int len) {
  Sym *p = (Sym *)malloc(sizeof(Sym) + len);
  p->tok = 1;
  p->len = len;
  memcpy(p->str, s, len);
  p->str[len] = 0;
  return p;
}

int main() {
  Sym *p = make("hello", 5);
  int ok = strcmp(p->str, "hello") == 0 && p->str[4] == 'o';
  free(p);
  return ok ? 0 : 1;
}
