// CLEAN
// Temporaries and compound literals around C++ code: a literal in a function that has exception handling and destructors, a
// temporary bound to a reference (its lifetime is the reference's), braced temporaries passed to a function, an
// initializer_list's backing array, a literal in a statement expression, in a lambda and in a template, and a switch left
// and entered again with a literal behind a case label. All accesses are inside the scope of the object.
#include <initializer_list>
#include <string>
#include <vector>

struct P { int x, y; };
struct Guard {
  int *flag;
  explicit Guard(int *f) : flag(f) { ++*flag; }
  ~Guard() { --*flag; }
};

static int sum(const int *a, int n) {
  int s = 0;
  for (int i = 0; i < n; i++) s += a[i];
  return s;
}
static int px(P p) { return p.x + p.y; }
static int total(std::initializer_list<int> l) {
  int s = 0;
  for (int v : l) s += v;
  return s;
}

static int with_eh(int n) {
  int flag = 0;
  int r = 0;
  try {
    Guard g(&flag);
    int *a = (int[]){n, 2, 3};
    r += sum(a, 3);
    if (n == 3) throw n;
    P *p = &(P){n, 4};
    r += p->x + p->y;
  } catch (int v) {
    int *b = (int[]){v, 5};
    r += b[0] + b[1];
  }
  return r + flag;
}

static int refs(int n) {
  const P &r = P{n, 3};
  const int &i = n + 1;
  P q = P{n, 9};
  int r2 = r.x + r.y + i + q.y;
  {
    const P &s = P{r2, 1};
    r2 += s.x + s.y;
  }
  return r2 + px(P{n, 1}) + px((P){2, n});
}

static int init_lists(int n) {
  std::initializer_list<int> il = {n, n + 1, n + 2};
  int s = 0;
  for (int v : il) s += v;
  for (int v : {n, 1, 2}) s += v;
  std::vector<int> vec{n, 7, 8};
  for (int v : vec) s += v;
  return s + total({n, 3}) + (int)std::string("ab").size();
}

static int stmt_expr(int n) {
  int r = ({
    int *a = (int[]){n, 6, 7};
    a[0] + a[1] + a[2];
  });
  int *p = (int[]){r, 1};
  return r + p[0] + p[1];
}

template <class T>
static T tmpl(T n) {
  T *a = (T[]){n, n};
  return a[0] + a[1];
}

static int lambda(int n) {
  auto f = [](int k) {
    int *a = (int[]){k, k + 1};
    return a[0] + a[1];
  };
  return f(n) + f(n + 1);
}

static int sw_again(int n) {
  int r = 0;
  for (int round = 0; round < 3; round++) {
    switch ((n + round) % 3) {
    case 0:
      r += sum((int[]){n, 1}, 2);
      break;
    case 1: {
      int *a = (int[]){n, round, 3};
      r += a[0] + a[1] + a[2];
    }
    // fall through
    case 2:
      r += px((P){round, 2});
      break;
    }
  }
  return r;
}

int main() {
  int r = 0;
  for (int i = 0; i < 5; i++) {
    r += with_eh(i) + refs(i) + init_lists(i) + stmt_expr(i) + tmpl(i) + lambda(i) + sw_again(i);
  }
  return r == 0 ? 1 : 0;
}
