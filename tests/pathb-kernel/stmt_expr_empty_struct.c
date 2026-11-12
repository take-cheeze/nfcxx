// A statement expression whose value is an empty struct (the kernel's `lockdep_pin_lock()` without lockdep:
// `({ struct pin_cookie cookie = { }; cookie; })`, assigned to a member). The front end folds the value to an
// aggregate constant; Path B refused the function ("operator unsupported") because it had no lowering for it.
struct pin_cookie { };
struct rq_flags { int before; struct pin_cookie cookie; int after; };

#define pin_lock(l) ({ struct pin_cookie cookie = { }; cookie; })

__attribute__((noinline)) static void rq_pin_lock(struct rq_flags *rf, void *l)
{
  rf->cookie = pin_lock(l);
  rf->after = 7;
}

int main(void)
{
  struct rq_flags rf = { 1, { }, 2 };
  rq_pin_lock(&rf, 0);
  return (rf.before == 1 && rf.after == 7 && sizeof(struct pin_cookie) == 0) ? 0 : 1;
}
