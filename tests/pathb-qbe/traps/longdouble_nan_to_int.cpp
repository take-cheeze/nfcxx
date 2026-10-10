// Long double NaN to an integer type must abort (cf2i).
__attribute__((noinline)) long double id(long double x) { return x; }
__attribute__((noinline)) unsigned char conv(long double x) { return (unsigned char)x; }
int main() {
  long double inf = id(1e4000L) * id(1e4000L);
  if (conv(id(255.75L)) != 255) return 1;
  return conv(inf - inf);
}
