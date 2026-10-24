// A C++ shared object with a C interface: it throws and catches inside, keeps state in a std::map, and uses
// thread_local storage in libstdc++ (the exception globals) and its own.
#include <map>
#include <stdexcept>
#include <string>
static std::map<std::string, int> table;
thread_local int calls;
extern "C" int cxx_count(const char *word) {
  calls++;
  try {
    if (!*word) throw std::invalid_argument("empty word");
    return ++table[word];
  } catch (const std::invalid_argument &) {
    return -1;
  }
}
extern "C" int cxx_calls(void) { return calls; }
extern "C" int cxx_parse(const char *s) {
  try {
#ifdef NO_LIBRARY_THROW  // nfcxx -shared links no EH shim: an exception thrown inside libstdc++ is not caught here
    if (*s < '0' || *s > '9') throw std::invalid_argument(s);
#endif
    return std::stoi(s);
  } catch (const std::exception &) {
    return -2;
  }
}
