// Scalar C library functions with trusted summaries (scripts/pathb-libc.effects). The prototypes are declared here,
// so the module holds only this program's functions, which are checked and inferred as nothrow.
extern "C" {
int abs(int);
double fabs(double);
double floor(double);
int sched_yield(void);
int __issignalingf(float);
}
static int magnitude(int x) { return abs(x) + (int)floor(2.5); }
int main() {
  sched_yield();
  return magnitude(-3) + (int)fabs(-1.0) + __issignalingf(1.0f) - 6;
}
