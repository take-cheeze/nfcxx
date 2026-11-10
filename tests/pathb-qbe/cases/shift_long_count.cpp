// The count of a shift may be a long: the check is at the count's width, and a count in range shifts the value.
// 1 << 5 = 32; 256 >> 5 = 8; 40 total.
// EXPECT: 40
unsigned f(unsigned x, unsigned long n) { return x << n; }
unsigned g(unsigned x, unsigned long n) { return x >> n; }
int main() { return (int)(f(1u, 5ul) + g(256u, 5ul)); }
