/* A C++ program for the profiler's exception test (tests/prof/eh.sh, Path B with --profile): a recursive function throws
 * from its bottom call, through a second profiled function that holds an object with a destructor, and main catches it.
 * The profile must be balanced: every frame the throw leaves has its exit recorded. */
#include <cstdio>

struct Thrown {
  int depth;
};

struct Scope {
  int *count;
  ~Scope() { ++*count; }
};

int destructed = 0;

__attribute__((noinline)) int descend(int n) {
  if (n == 0) throw Thrown{7};
  return descend(n - 1) + 1;
}

__attribute__((noinline)) int through(int n) {
  Scope s{&destructed};
  return descend(n) * 2;
}

int main() {
  int caught = -1;
  try {
    caught = through(5);
  } catch (const Thrown &t) {
    caught = t.depth;
  }
  std::printf("caught %d destructed %d\n", caught, destructed);
  return 0;
}
