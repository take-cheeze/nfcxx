// Handlers are checked on the paths that reach them: the state of each throw point of the try body, with the
// body's locals destroyed. may() is a may-throw callee (throws/may.effects).
struct E { int code; };
void may(int *p);
// 1: the body initializes x only after the throwing call
int late_init() {
  int x;
  int y = 0;
  try { may(&y); x = 1; } catch (...) { return x; }
  return x;
}
// 2: initialized before the try: no error
int early_init() {
  int x = 0;
  try { may(&x); } catch (...) { return x; }
  return x;
}
// 3: a pointer to a local of the try body, used in the handler
int dangling_body() {
  int *p = 0;
  int y = 0;
  try { int inner = 1; p = &inner; may(&y); } catch (...) { return *p; }
  return 0;
}
// 5: the outer handler is reached directly when the inner one catches only int
int outer_direct() {
  int x;
  int y = 0;
  try { try { may(&y); } catch (int) { x = 5; throw; } } catch (...) { return x; }
  return 0;
}
// 6: the inner catch (...) catches everything, so the outer handler sees only the rethrow, after x = 5
int outer_after_rethrow() {
  int x;
  int y = 0;
  try { try { may(&y); } catch (...) { x = 5; throw; } } catch (...) { return x; }
  return 0;
}
// 4: the caught object, used after its handler
int dangling_exception() {
  E dummy{0};
  const E *q = &dummy;
  int y = 0;
  try { may(&y); } catch (const E &e) { q = &e; }
  return q->code;
}
