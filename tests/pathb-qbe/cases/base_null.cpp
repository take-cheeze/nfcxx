// Path B: converting a null pointer to a derived class into a pointer to a base class gives a null pointer, for a first
// base (offset 0) and for a second base (offset 8) alike. EDG lowers the conversion to `&p->__b_N`, which must not
// be a null-dereference trap: it is address arithmetic. (std::map's node pointers are null all the time.)
// EXPECT: 7
struct A { long a; };
struct B { long b; };
struct D : A, B { long d; };

static A *to_a(D *p) { return p; }
static B *to_b(D *p) { return p; }
static long take(A *x, B *y) { return (x == 0 ? 1 : 0) + (y == 0 ? 2 : 0); }

int main()
{
  D d;
  D *none = 0;
  long r = take(to_a(none), to_b(none));        // 1 + 2
  if (to_b(&d) != static_cast<B *>(&d)) return 1;
  if ((char *)to_b(&d) - (char *)&d != 8) return 2;
  return (int)(r + 4);
}
