// EXPECT: 0
// STDOUT: same
// extern thread_local objects with dynamic initialization: b.cpp defines them, this unit only declares them. A use
// here goes through the _ZTW wrapper, which calls the defining unit's _ZTH init function (a weak reference when the
// unit has none), so each thread constructs its own copy on first use and destroys it at thread exit.
extern "C" {
int pthread_create(unsigned long *, const void *, void *(*)(void *), void *);
int pthread_join(unsigned long, void **);
int printf(const char *, ...);
}

struct T {
  int id;
  int val;
  T(int i, int v) : id(i), val(v) { printf("ctor %d val=%d\n", id, val); }
  ~T() { printf("dtor %d val=%d\n", id, val); }
};

extern thread_local T ext_obj;
extern thread_local int ext_int;
int read_in_b();   // b.cpp's view of ext_obj

static int bad;

extern "C" void *child(void *) {
  printf("child start\n");
  if (ext_obj.val != 10) bad |= 1;      // first use in this thread constructs it
  ext_obj.val = 11;
  if (read_in_b() != 11) bad |= 2;      // the same copy in the defining unit
  if (ext_int < 5000) bad |= 4;
  printf("child end\n");
  return 0;
}

int main() {
  printf("main start\n");
  if (ext_obj.val != 10) bad |= 8;
  ext_obj.val = 12;
  unsigned long th;
  pthread_create(&th, 0, child, 0);
  pthread_join(th, 0);
  printf("joined\n");
  if (ext_obj.val != 12 || read_in_b() != 12) bad |= 16;
  printf("main end\n");
  return bad;
}
