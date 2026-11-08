// Freestanding C++ for the card: a virtual destructor (needs the k1om libC.a), a template and double arithmetic.
// Expected output on the card: fp=2812 (1.5*1.5+0.5 + 0.25*0.25 = 2.8125, truncated after *1000).
extern "C" int printf(const char *, ...);
struct B { virtual double f(double x) const { return x * 2.0; } virtual ~B() {} };
struct C : B { double f(double x) const override { return x * x + 0.5; } };
template <typename T> T sq(T v) { return v * v; }
int main() {
  C c;
  B *b = &c;
  double r = b->f(1.5) + sq<double>(0.25);
  printf("fp=%d\n", (int)(r * 1000.0));
  return 0;
}
