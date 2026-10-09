// EXPECT: 134
// nfcxx_panic: a failed check writes a message to stderr and aborts (SIGABRT -> shell status 134).
// The in-range access before it must not panic.
#include <array>
#include <cstddef>

int main() {
  std::array<int, 2> a = {1, 2};
  if (a.at(1) != 2) return 1;
  std::size_t i = a.size() + 3;   // out of range
  return a.at(i);                 // panics, so the process aborts
}
