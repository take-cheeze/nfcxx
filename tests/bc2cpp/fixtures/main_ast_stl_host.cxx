// A host `main` for main_ast_producers_diff.rb: the constructs main_roots.rb reads (native_ast_returns_check.rb's main
// fixture) plus the libstdc++ headers a real host program includes, whose internals (static_assert messages, throw
// strings of member-template patterns, folded builtins) are what the two AST producers disagree on.
#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>
struct mrb_state { int x; };
struct mrb_value { int v; };
typedef unsigned int mrb_sym;
mrb_value mrb_funcall(mrb_state *, mrb_value, const char *, int, ...);
struct Base { virtual ~Base() {} virtual int hook(mrb_state *m, mrb_value v) { mrb_funcall(m, v, "virtual_hook", 0); return 1; } };
struct Derived : Base {
  std::vector<int> items;
  std::map<std::string, int> table;
  std::unique_ptr<int> owned = std::make_unique<int>(1);
  int hook(mrb_state *m, mrb_value v) override { mrb_funcall(m, v, "derived_hook", 0); return 2; }
};
template <typename T> void tcall(mrb_state *m, mrb_value v, T) { mrb_funcall(m, v, "templated_call", 0); }
int main(int argc, char **argv) {
  mrb_state st; mrb_state *m = &st; mrb_value self = {0};
  Derived d;
  d.items.assign(argc + 3, 1);
  d.items.insert(d.items.begin(), {1, 2, 3});
  std::sort(d.items.begin(), d.items.end());
  d.table["k"] = argc;
  std::function<int(int)> f = [m, self](int z) { mrb_funcall(m, self, "std_function_call", z); return z; };
  f(1);
  std::string s = std::string("abc") + argv[0];
  std::vector<bool> bits(4);
  bits.insert(bits.begin(), true);
  double nan = std::nan("");
  Base *b = &d; b->hook(m, self);
  tcall(m, self, nan);
  mrb_funcall(m, self, s.c_str(), 0);
  mrb_funcall(m, self, "main_call", 0);
  return static_cast<int>(std::lround(nan)) + static_cast<int>(bits.size());
}
