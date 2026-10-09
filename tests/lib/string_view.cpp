// EXPECT: 0
// XFAIL-qbe: cproc rejects empty class definitions (EDG emits "struct X {}" for instantiated trait classes and empty types); see docs/notes/freestanding.md
// <string_view>: construction from literals and (ptr,len), size/access, substr, find, compare.
#include <string_view>

constexpr std::string_view kHello = "hello";
static_assert(kHello.size() == 5);
static_assert(kHello[1] == 'e');
static_assert(kHello.front() == 'h' && kHello.back() == 'o');
static_assert(kHello.substr(1, 3) == "ell");
static_assert(kHello.substr(2) == "llo");
static_assert(kHello.find('l') == 2);
static_assert(kHello.find("lo") == 3);
static_assert(kHello.find("xyz") == std::string_view::npos);
static_assert(kHello.starts_with("he") && kHello.ends_with('o'));
static_assert(kHello == std::string_view("hello", 5));
static_assert(kHello != "help");
static_assert(std::string_view("abc") < std::string_view("abd"));
static_assert(std::string_view("ab") < std::string_view("abc"));
static_assert(std::string_view("b") > std::string_view("abc"));
static_assert(std::string_view().empty());
static_assert(std::string_view("").size() == 0);

int main() {
  int fails = 0;
  const char buf[] = "a\0b";        // embedded NUL: length is explicit
  std::string_view sized(buf, 3);
  fails += sized.size() != 3 || sized[1] != '\0';
  fails += std::string_view(buf).size() != 1;

  std::string_view sv = "key=value";
  fails += sv.find('=') != 3;
  std::string_view k = sv.substr(0, sv.find('='));
  fails += k != "key";
  sv.remove_prefix(4);
  fails += sv != "value";
  sv.remove_suffix(2);
  fails += sv != "val";

  int count = 0;
  for (char c : std::string_view("abcd")) count += c != 0;
  fails += count != 4;

  fails += std::string_view("abc").compare("abd") >= 0;
  fails += std::string_view("abc").compare("abc") != 0;
  fails += std::string_view("abcd").compare("abc") <= 0;
  fails += std::string_view("é").size() != 2;   // UTF-8 bytes, not code points
  return fails;
}
