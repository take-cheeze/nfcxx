// EXPECT: 13
// A call to a function the module does not define: the host provides it (an import of module env).
extern "C" int host_inc(int x);
int twice(int x) { return host_inc(host_inc(x)); }
int main() { return twice(10) + host_inc(0); }
