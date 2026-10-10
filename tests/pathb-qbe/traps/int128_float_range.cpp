// A conversion of a floating value that does not fit a 128-bit integer aborts, as the IR's cf2i does for the other integer
// types (docs/notes/pathb-int128.md). gcc leaves this undefined, so the gcc backend is not compared.
// TRAP-EXIT: 134
typedef __int128 i128;

static volatile double big = 1.0e40;

int main() {
  i128 v = (i128)(big * 2.0);   // 2e40 >= 2^127: abort
  return (int)(v != 0);
}
