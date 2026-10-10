// va_arg of long double: a call of the helper __nfcxx_ld_vaarg (docs/notes/pathb-longdouble.md); the emitter accepts it (the check is in run.sh).
long double ld(int n, ...) {
  __builtin_va_list ap;
  __builtin_va_start(ap, n);
  long double v = __builtin_va_arg(ap, long double);
  __builtin_va_end(ap);
  return v;
}
