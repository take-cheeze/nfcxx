// A user-declared type for the nfceval tests: the snippets see this declaration through
// eng.include("vec3.hpp"). len2/scale are defined out of line in host.cpp (they reach the snippet through
// the host binary's exported symbols); dot is inline.
#pragma once
struct Vec3 {
  double x, y, z;
  double len2() const;
  void scale(double k);
  double dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
};

struct Counter {
  int n = 0;
  int bump(int by);
};
