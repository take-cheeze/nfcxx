// EXPECT: 77
// GCC: undefined
// A local assigned after setjmp and read after longjmp has the last assigned value. C says such a non-volatile
// local is indeterminate, so the gcc backend is not compared; Path B keeps the slots of a function that calls
// setjmp in memory (QBE would otherwise promote them to temporaries holding the value at the setjmp call).
extern "C" {
int _setjmp(void *);
void longjmp(void *, int) __attribute__((noreturn));
}

static long buf[64];  // larger than any jmp_buf

static void jump(int v) { longjmp(buf, v); }

static int run() {
  int a = 1;
  int b = 2;
  int hits = 0;
  if (_setjmp(buf) == 0) {
    a = 10;        // changed after setjmp
    b += 30;
    hits = 5;
    jump(3);
  }
  // here after longjmp: a == 10, b == 32, hits == 5
  return a + b + hits + 30;   // 10 + 32 + 5 + 30 = 77
}

int main() { return run(); }
