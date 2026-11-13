// Stack frames on Path B: the locals of inlined calls that are never live together share stack slots, and a function with a try
// block (a setjmp of its EH entry) promotes the locals that are dead across the call, keeping the others in memory. Every call
// below fills an array of its own and sums it back, so a slot shared by two lifetimes that overlap, or a promoted local that the
// second return of the setjmp needed, gives a wrong sum.
// EXPECT: 42
struct E { int code; };
struct Big { int v[64]; };

static int f(int x) {
  Big b;
  for (int i = 0; i < 64; i++) b.v[i] = x + i;
  int s = 0;
  for (int i = 0; i < 64; i++) s += b.v[i];
  if (s == 123456789) throw E{1};
  return s;   // 64 x + 2016
}

static int g(int x) {
  Big b;
  Big c;
  for (int i = 0; i < 64; i++) { b.v[i] = 2 * x + i; c.v[i] = x - i; }
  int s = 0;
  for (int i = 0; i < 64; i++) s += b.v[i] - c.v[i];
  return s;   // 64 x + 4032
}

static int run(int n) {
  int total = 0;
  try {
    total += f(n);
    total += g(n + 1);
    for (int i = 0; i < 3; i++) total += f(n + i);
    if (n == 7) throw E{5};
    total += g(n);
  } catch (E &e) {
    total += e.code * 1000;
  }
  return total;
}

static int want(int n) {
  int t = 64 * n + 2016 + 64 * (n + 1) + 4032;
  for (int i = 0; i < 3; i++) t += 64 * (n + i) + 2016;
  if (n == 7) return t + 5000;
  return t + 64 * n + 4032;
}

int main() {
  int ns[] = {0, 1, 7, 100};
  for (int n : ns)
    if (run(n) != want(n)) return n + 1;
  return 42;
}
