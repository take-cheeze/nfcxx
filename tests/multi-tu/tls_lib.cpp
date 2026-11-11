// Linked into a shared library by run.sh (nfcxx -c -fPIC, then nfcxx -shared): thread-local definitions must be valid
// in a shared object. Local exec (%fs:sym@tpoff) is refused by ld with -shared, so every access here, to the exported,
// the file-static and the function-local variable alike, has to be by initial exec (or general dynamic).
thread_local int tls_exported = 11;
static thread_local long tls_static = 100;
long tls_next() {
  static thread_local int calls;   // function-local: its own TLS object, internal to this unit
  return tls_static + ++calls + tls_exported;
}
