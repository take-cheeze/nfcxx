// CLEAN
// A function left by a throw never runs its unpoison, so its redzones stay poisoned in the dead frame. A later call that
// reuses that stack must not see them in its own objects.
struct E {};
__attribute__((noinline)) int thrower(int n) {
  int buf[8];
  buf[0] = n;
  for (int i = 1; i < 8; i++) buf[i] = buf[i - 1] + 1;
  if (buf[7] > 0) throw E();
  return buf[3];
}
__attribute__((noinline)) int user(int n) {
  int a[64];
  for (int i = 0; i < 64; i++) a[i] = i + n;
  int s = 0;
  for (int i = 0; i < 64; i++) s += a[i];
  return s;
}
int main() {
  int t = 0;
  for (int k = 0; k < 3; k++) {
    try { thrower(k + 1); } catch (E &) { t++; }
    t += user(k) & 1;
  }
  return t > 100;
}
