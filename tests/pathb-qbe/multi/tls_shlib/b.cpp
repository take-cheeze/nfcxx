// SHARED: yes
// This unit is linked as a shared library: thread-local definitions must be valid in a shared object (initial-exec
// access through the GOT; a local-exec access would not link with -shared).
thread_local int tls_x = 11;
__thread double tls_d[3] = {1.0, 2.0, 3.0};
int tls_read_x() { return tls_x; }
