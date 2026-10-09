extern "C" int printf(const char *, ...);

struct T {
  int id;
  int val;
  T(int i, int v) : id(i), val(v) { printf("ctor %d val=%d\n", id, val); }
  ~T() { printf("dtor %d val=%d\n", id, val); }
};

static int seed() { return 5000; }

thread_local T ext_obj(9, 10);
thread_local int ext_int = seed();

int read_in_b() { return ext_obj.val; }
