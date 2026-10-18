import geom;

int main() {
  Point p{3, 4};
  // 7 + 4 + 3 + 5
  return p.sum() + twice(2) + scale(1) + offset();
}
