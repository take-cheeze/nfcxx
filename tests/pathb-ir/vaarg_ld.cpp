// va_arg of long double: the IR carries it and the emitter refuses it by name (QBE has no 80-bit type; the check is in run.sh).
long double ld(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  long double v = __builtin_va_arg(ap, long double);
  __builtin_va_end(ap);
  return v;
}
