// A brace initializer that names fewer elements than an array of a class with a trivial default constructor has: the
// elements it does not name are zero-initialized (value-initialization of a class whose default constructor is not
// user-provided). EDG records that zeroing on the declaration (initk_zero), not as a statement; Path B lost it, and
// ggml-sycl's fattn-vec kernel read its stack's earlier contents in `sycl::half2 Q_reg[..][..] = {{{0.0f, 0.0f}}}`.
// The stack below is filled first, so the elements hold non-zero bytes unless the initializer zeroes them.
// EXPECT: 0
struct H {
  short v[2];
  H() = default;
  H(short a, short b) : v{a, b} {}
};

__attribute__((noinline)) static int fill_stack(int seed) {
  volatile int junk[64];
  for (int i = 0; i < 64; i++) junk[i] = seed * 0x1010101 + i;
  return junk[seed & 63];
}

__attribute__((noinline)) static int sum_class() {
  H arr[4] = {{1, 2}};
  int s = 0;
  for (int i = 0; i < 4; i++) s += arr[i].v[0] + arr[i].v[1];
  return s;   // 3: arr[1..3] are zero
}

__attribute__((noinline)) static int sum_nested() {
  H m[2][3] = {{{4, 5}}};
  int s = 0;
  for (int i = 0; i < 2; i++)
    for (int j = 0; j < 3; j++) s += m[i][j].v[0] + m[i][j].v[1];
  return s;   // 9: only m[0][0] is non-zero
}

int main() {
  int bad = 0;
  fill_stack(7);
  if (sum_class() != 3) bad |= 1;
  fill_stack(9);
  if (sum_nested() != 9) bad |= 2;
  return bad;
}
