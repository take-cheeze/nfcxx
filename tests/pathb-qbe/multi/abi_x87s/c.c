/* The C side of multi/abi_x87s, built by the host C compiler: structs whose only member is a long double. */

typedef struct { long double x; } W;
typedef struct { W inner; } Wn;

W cpp_make(long double v);
long double cpp_sum(W a, int k, W b);
W cpp_twice(W a);

W c_make(long double v)
{
  W w;
  w.x = v;
  return w;
}

long double c_sum(W a, int k, W b)
{
  return a.x * k + b.x;
}

W c_pass(W a, W b)
{
  W r;
  r.x = a.x * 2 + b.x;
  return r;
}

Wn c_nested(Wn a)
{
  Wn r;
  r.inner.x = a.inner.x + 1;
  return r;
}

W c_call_make(W (*f)(long double), long double v)
{
  return f(v);
}

long double c_many(int a, int b, int c, int d, int e, int f, W w, long double x, W v)
{
  return a + b + c + d + e + f + w.x + x + v.x;
}
