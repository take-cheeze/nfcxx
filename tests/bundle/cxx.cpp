// C++ through the bundled libstdc++ and libgcc_s: streams, containers, strings, exceptions thrown by the library
// (std::vector::at, std::stoi) and by the program, caught on both sides, a static object's destructor.
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
struct Noisy {
  std::string name;
  ~Noisy() { std::cout << "destroy " << name << std::endl; }
};
static Noisy global{"global"};
static int depth(int n) {
  if (n == 0) throw std::runtime_error("bottom");
  return depth(n - 1) + 1;
}
int main() {
  std::map<std::string, int> m;
  for (const char *w : {"pear", "apple", "fig", "apple"}) m[w]++;
  std::ostringstream os;
  for (auto &kv : m) os << kv.first << '=' << kv.second << ' ';
  std::cout << os.str() << std::endl;
  std::vector<int> v(3, 7);
  try {
    v.at(5) = 1;
  } catch (const std::out_of_range &) {
    std::cout << "out_of_range from the library" << std::endl;
  }
  try {
    std::stoi("not a number");
  } catch (const std::invalid_argument &) {
    std::cout << "invalid_argument from the library" << std::endl;
  }
  try {
    depth(20);
  } catch (const std::exception &e) {
    std::cout << "caught " << e.what() << std::endl;
  }
  std::string s = std::to_string(12345) + "/" + std::to_string(6.5);
  std::cout << s << " " << s.size() << std::endl;
  return 7;
}
