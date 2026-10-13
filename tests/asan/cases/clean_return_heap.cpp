// CLEAN
// Functions return pointers to heap and static data, and never a pointer to their own locals: the locals of a returned frame
// are not read after it (their fake frames are freed at the return), and the returned pointers stay valid.
#include <cstdlib>
static int counter = 0;
static int *next_counter() { return &counter; }
static int *make_array(int n) {
  int *a = (int *)std::malloc(n * sizeof(int));
  for (int i = 0; i < n; i++) a[i] = i * i;
  return a;
}
static const char *greeting(int which) {
  static const char hello[] = "hello";
  char local[8] = "bye";
  if (which) return hello;
  return local[0] ? "bye" : "";
}
int main(int argc, char **) {
  for (int i = 0; i < 10; i++) ++*next_counter();
  int *a = make_array(8 + argc);
  int s = a[7 + argc] + counter;
  std::free(a);
  return (s == 64 + 10 && *greeting(1) == 'h' && greeting(0)[0] == 'b') ? 0 : 1;
}
