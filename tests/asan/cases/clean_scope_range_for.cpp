// CLEAN
// A range-based for whose body declares a local with a destructor and then breaks out of a switch. The range variable has no
// declaration statement (the front end opens it at its first use), so the count of open locals at the end of the switch was one
// more than the scan of labels had: each break closed the scope of the last local, d, before its destructor ran, and the
// destructor read it as stack-use-after-scope (nlohmann/json's patch_inplace, a json_pointer ptr).
#include <vector>
struct D {
  int *p;
  D(int v) : p(new int(v)) {}
  ~D() { delete p; }
};
__attribute__((noinline)) int f(const std::vector<int> &v) {
  int s = 0;
  for (const auto &x : v) {
    D d(x);
    switch (x % 3) {
      case 0: { s += *d.p; break; }
      case 1: { s += 2; break; }
      default: s += 3;
    }
  }
  return s;
}
int main() {
  std::vector<int> v{1, 2, 3, 4, 5, 6};
  return f(v) > 0 ? 0 : 1;
}
