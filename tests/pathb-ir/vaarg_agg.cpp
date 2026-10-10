// va_arg of aggregates (golden: tests/pathb-ir/vaarg_agg.ir): register-class structs by eightbyte, memory-class structs,
// a struct that does not fit the remaining registers (falls back to the overflow area), an empty class; the scalar case
// stays QBE's vaarg. (va_arg of long double: tests/pathb-ir/vaarg_ld.cpp.)
struct I2 { long a, b; };
struct F2 { float x, y; };
struct M1 { int i; double d; };
struct B24 { long a, b, c; };
struct E {};

long agg(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  I2 a = __builtin_va_arg(ap, I2);
  F2 f = __builtin_va_arg(ap, F2);
  M1 m = __builtin_va_arg(ap, M1);
  B24 b = __builtin_va_arg(ap, B24);
  E e = __builtin_va_arg(ap, E);
  int s = __builtin_va_arg(ap, int);
  __builtin_va_end(ap);
  (void)e;
  return a.a + a.b + (long)f.x + (long)f.y + m.i + (long)m.d + b.a + b.b + b.c + s;
}
