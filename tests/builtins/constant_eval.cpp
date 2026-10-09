// EXPECT: 0
// __builtin_is_constant_evaluated: true in constant evaluation, false at run time.
constexpr bool in_ce() { return __builtin_is_constant_evaluated(); }
static_assert(in_ce(), "must be true inside a constant expression");
static_assert(in_ce() == true);

bool runtime_value() { return __builtin_is_constant_evaluated(); }

int main() {
  int fails = 0;
  fails += runtime_value() != false;
  fails += in_ce() != false;  // called at run time: must be false
  constexpr bool c = in_ce();
  fails += c != true;
  return fails;
}
