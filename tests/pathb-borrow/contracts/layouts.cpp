// Frontend (borrow-layout ...) records: the padding of In and Out is not data, so
// passing &o to a reader needs only the fields initialized.
struct In { char c; long l; };
struct Out { int a; In in; };
static long total(const Out *p) { return p->a + p->in.c + p->in.l; }
int main() {
  Out o;
  o.a = 1;
  o.in.c = 2;
  o.in.l = 3;
  return (int)total(&o) - 6;
}
