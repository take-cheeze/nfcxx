// EXPECT: 0
// A trailing array of one element is a flexible array member in pre-C99 code (CPython's `PyObject *ob_item[1]` of tuples):
// the object is allocated with more elements and indexed past the first. gcc takes any trailing array so by default; Path B
// checked the index against 1 and aborted (tests/poly ops.cpp with the Python host, in PyTuple_SET_ITEM). An array that is
// not the last member keeps its bound.
#include <cstdlib>

struct Tuple {
  long size;
  long items[1];
};

struct Inner {
  int a[3];
  int tail;
};

int main() {
  Tuple* t = static_cast<Tuple*>(std::malloc(sizeof(Tuple) + 4 * sizeof(long)));
  t->size = 5;
  for (long i = 0; i < t->size; ++i) t->items[i] = i * i;
  long sum = 0;
  for (long i = 0; i < t->size; ++i) sum += t->items[i];
  std::free(t);
  Inner in = {{1, 2, 3}, 4};
  return sum == 30 && in.a[2] == 3 ? 0 : 1;
}
