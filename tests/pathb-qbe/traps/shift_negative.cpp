// Checked shift: a negative count must abort (cshr).
__attribute__((noinline)) int id(int x) { return x; }
__attribute__((noinline)) int shr(int a, int n) { return a >> n; }
int main() { return shr(64, id(-1)); }
