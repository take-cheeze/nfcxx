// EXPECT: 0
// std::initializer_list: braced lists, range-for, size/begin/end, empty lists.
#include <initializer_list>

static int sum(std::initializer_list<int> il) {
  int s = 0;
  for (int x : il) s += x;
  return s;
}

static std::size_t count(std::initializer_list<int> il) { return il.size(); }

struct Holder {
  std::initializer_list<const char*> names;
  Holder(std::initializer_list<const char*> n) : names(n) {}
};

int main() {
  int fails = 0;
  fails += sum({1, 2, 3, 4}) != 10;
  fails += sum({}) != 0;
  fails += count({5, 6, 7}) != 3;

  std::initializer_list<int> il = {10, 20, 30};
  fails += il.size() != 3;
  const int* p = il.begin();
  fails += *p != 10 || *(il.end() - 1) != 30;
  fails += (il.end() - il.begin()) != 3;

  std::initializer_list<int> empty;
  fails += empty.size() != 0 || empty.begin() != empty.end();

  Holder h({"a", "bc"});
  fails += h.names.size() != 2;

  // begin/end free functions
  fails += *std::begin(il) != 10;
  fails += (std::end(il) - std::begin(il)) != 3;  // end - begin

  // nested braces through a function taking initializer_list of initializer_list
  int acc = 0;
  for (int v : {1, 1, 2, 3, 5}) acc += v;
  fails += acc != 12;
  return fails;
}
