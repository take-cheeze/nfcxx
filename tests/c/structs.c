/* EXPECT: 78 */
/* Structs, unions, bitfields, arrays of structs, struct return and copy. */
struct pt { int x, y; };
struct rect { struct pt a, b; char tag[4]; };
union u { unsigned int i; unsigned char c[4]; float f; };
struct bits { unsigned a : 3, b : 5; };

static struct pt add(struct pt p, struct pt q) { struct pt r = { p.x + q.x, p.y + q.y }; return r; }

int main(void) {
  struct rect r = { { 1, 2 }, { 10, 20 }, "ab" };
  struct rect r2 = r;
  r2.a = add(r.a, r.b);                         /* 11, 22 */
  union u v; v.i = 0x01020304;
  int le = v.c[0] == 4;                         /* little-endian */
  struct bits b = { 5, 17 };
  struct pt arr[3] = { { 1, 1 }, { 2, 2 }, { 3, 3 } };
  int sum = 0;
  for (int i = 0; i < 3; i++) sum += arr[i].x * arr[i].y;   /* 14 */
  return r2.a.x + r2.a.y + le + b.a + b.b + sum + (int)sizeof(struct pt);
}
