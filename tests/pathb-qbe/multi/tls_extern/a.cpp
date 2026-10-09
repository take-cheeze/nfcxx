// EXPECT: 0
// Thread-local objects across translation units: b.cpp defines them, this unit only declares them (the declaration
// is accessed through the GOT, initial-exec TLS) and a second thread must see its own copies.
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
}
extern thread_local int tls_x;
extern __thread double tls_d[3];
int tls_read_x();           // reads b.cpp's view of the same object

static int child_bad;
extern "C" void *child(void *) {
  int bad = 0;
  if (tls_x != 11) bad |= 1;                // the initializer, not main's 99
  if (tls_d[2] != 3.0) bad |= 2;
  tls_x = 500;
  if (tls_read_x() != 500) bad |= 4;        // both units agree inside one thread
  child_bad = bad;
  return 0;
}

int main() {
  int bad = 0;
  tls_x = 99;
  tls_d[2] = 30.0;
  unsigned long th;
  pthread_create(&th, 0, child, 0);
  pthread_join(th, 0);
  bad |= child_bad;
  if (tls_x != 99 || tls_read_x() != 99) bad |= 8;
  if (tls_d[2] != 30.0) bad |= 16;
  return bad;
}
