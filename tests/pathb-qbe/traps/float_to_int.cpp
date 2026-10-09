// Float to int: a value outside the int range must abort (cf2i).
__attribute__((noinline)) double id(double x) { return x; }
__attribute__((noinline)) int conv(double x) { return (int)x; }
int main() { return conv(id(1e30)); }
