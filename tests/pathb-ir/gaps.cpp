struct BF { unsigned a : 3; unsigned b : 5; };
int vla(int n) { int buf[n]; buf[0] = n; return buf[0]; }
int stmtexpr(int x) { return ({ int y = x + 1; y * 2; }); }
int asmish(int x) { asm volatile("" : : "r"(x)); return x; }
int bits(BF *p) { p->b = 7; return p->b + p->a; }
int walk(int n) {
  int s = 0;
  while (n > 0) { s += n; n--; }
  int k = 0;
  again:
  k++;
  if (k < 3) goto again;
  for (int i = 0; i < n; ++i) { if (i == 2) continue; s += i; }
  return s + k;
}
int main() { BF b; b.a = 1; return vla(3) + stmtexpr(1) + asmish(1) + bits(&b) + walk(4); }
