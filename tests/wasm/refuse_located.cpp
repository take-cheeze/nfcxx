// REFUSE: variadic call (in _Z4showi, at refuse_located.cpp:6)
// A refusal names the function (mangled; the explorer demangles it) and the line of the statement.
int printf(const char *, ...);

int show(int x) {
  return printf("%d\n", x);
}

int main() { return show(1); }
