// EXPECT: 0
// A variadic function that returns a struct and takes a struct by value (mruby's `mrb_value mrb_funcall(mrb_state *, mrb_value, const char *, mrb_int, ...)`):
// the IR's (variadic N) counts the hidden result pointer, and Path B's SSA route refused the call ("variadic call with 5 named arguments but 4").
#include <stdarg.h>
#include <stddef.h>
typedef struct { unsigned long w; unsigned long tt; } val;   // 16 bytes
typedef struct { int dummy; } state;

__attribute__((noinline)) val call(state *s, val recv, const char *name, long argc, ...) {
  va_list ap;
  val r = { recv.w + (unsigned long)name[0], 0 };
  va_start(ap, argc);
  for (long i = 0; i < argc; i++) r.w += (unsigned long)va_arg(ap, int) * 1000;
  va_end(ap);
  r.tt = (unsigned long)argc;
  (void)s;
  return r;
}

int main(void) {
  state st;
  val v = { 5, 0 };
  val a = call(&st, v, "a", 0);                   // no variadic argument
  val b = call(&st, v, "a", 2, 3, 4);             // two
  if (a.w != 5 + 'a' || a.tt != 0) return 1;
  if (b.w != 5 + 'a' + 7000 || b.tt != 2) return 2;
  return 0;
}
