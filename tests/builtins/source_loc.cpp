// EXPECT: 0
// __builtin_FILE, __builtin_LINE, __builtin_FUNCTION.
extern "C" int strcmp(const char*, const char*);
extern "C" unsigned long strlen(const char*);
const char* where() { return __builtin_FUNCTION(); }
int main() {
  int fails = 0;
  fails += __builtin_LINE() != 8;          // this line
  fails += strcmp(__builtin_FUNCTION(), "main") != 0;
  fails += strcmp(where(), "where") != 0;
  const char* f = __builtin_FILE();
  // the file name ends with source_loc.cpp
  unsigned long n = strlen(f);
  fails += n < 14 || strcmp(f + n - 14, "source_loc.cpp") != 0;
  return fails;
}
