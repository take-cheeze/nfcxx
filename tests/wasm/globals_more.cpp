// EXPECT: 178
// Address items with an addend (&arr[2]), a pointer to a string literal, a float and a negative global, and a global
// with bit-fields. The bit-fields are read through their bytes (a bit-field access is refused): a:3 is 5 and b:5 is 17,
// so the first byte is 5 | 17 << 3 = 141, which the items of the initializer ORed together.
int arr[5] = {10, 20, 30, 40, 50};
int *mid = &arr[2];
const char *word = "abc";
float fl = 2.5f;
long neg = -7;
struct Bits { unsigned a : 3; unsigned b : 5; int c; };
Bits bf = {5, 17, 9};
int main() {
  unsigned char *p = (unsigned char *)&bf;
  int r = *mid + word[1] - 98 + (int)(fl * 2) + (int)neg + bf.c;   // 30 + 0 + 5 - 7 + 9 = 37
  return r + p[0];                                                  // 37 + 141 = 178
}
