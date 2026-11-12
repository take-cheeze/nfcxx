// A designated compound literal initializing a static const object (the kernel's `static const struct xa_limit limit =
// XA_LIMIT(2, U32_MAX)`, libfs.c's simple_offset_add): the front end keeps the designators in the constant, and Path B read
// them as values ("operator unsupported"). Members the list does not name are zero; designators may come in any order.
typedef unsigned int u32;
struct xa_limit { u32 max; u32 min; };
struct wide { int a; struct xa_limit lim; long c; char d[3]; int e; };
#define XA_LIMIT(_min, _max) ((struct xa_limit){ .max = (_max), .min = (_min) })

__attribute__((noinline)) static u32 spread(struct xa_limit l) { return l.max - l.min; }
__attribute__((noinline)) static u32 spread_of_static(void)
{
  static const struct xa_limit limit = XA_LIMIT(2, ((u32)~0U));
  return spread(limit);
}

__attribute__((noinline)) static long sum_wide(void)
{
  static const struct wide w = { .e = 5, .lim = { .min = 3 }, .a = 1, .d = { [1] = 9 } };
  return w.a + w.lim.max + w.lim.min + w.c + w.d[0] + w.d[1] + w.d[2] + w.e;
}

int main(void)
{
  return (spread_of_static() == 0xfffffffdu && sum_wide() == 1 + 0 + 3 + 0 + 0 + 9 + 0 + 5) ? 3 : 1;
}
