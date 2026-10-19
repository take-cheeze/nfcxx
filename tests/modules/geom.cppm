export module geom;

export struct Point {
  int x;
  int y;
  int sum() const { return x + y; }
};

export template <class T>
T twice(T v) {
  return v + v;
}

// __builtin_expect is predeclared in every translation unit; the body is in the interface, so the importer calls it.
export inline int scale(int v) {
  return __builtin_expect(v, 1) * 3;
}

export int offset() {
  return 5;
}
