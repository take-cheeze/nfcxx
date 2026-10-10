/* The C side of multi/ldr_ptr, built by the host C compiler: it calls the function pointers that Path B made, and returns
   pointers that Path B calls through the indirect call thunk. */

long double cpp_mul(long double x, int k);

static long double c_mul(long double x, int k) { return x * k - 0.5L; }

long double c_cfun(long double x, int k) { return x * k + 0.25L; }

long double c_apply(long double (*f)(long double, int), long double x, int k) { return f(x, k); }

long double (*c_pick(int which))(long double, int)
{
  return which ? cpp_mul : c_mul;
}
