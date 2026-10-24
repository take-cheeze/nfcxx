// Structs with members a (borrow-layout ...) record does not describe get none:
// a base class, a bit-field, an array, a union, and a long double.
struct Base { int x; };
struct Der : Base { int y; };
struct Bits { int a : 3; int b; };
struct Arr { int v[2]; };
union U { int i; float f; };
struct HasU { U u; };
struct Ld { long double x; };
struct Plain { int z; const Plain *next; };
int main() {
  Der d{};
  Bits b{};
  Arr a{};
  HasU h{};
  Ld l{};
  Plain p{};
  return d.y + b.b + a.v[0] + h.u.i + (int)l.x + p.z;
}
