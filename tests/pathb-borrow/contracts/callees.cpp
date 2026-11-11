// Pointer-parameter callees; summaries in the sidecar .effects files are checked against these bodies.
struct Pair { int a; int b; };
void init_pair(Pair *p, int v) { p->a = v; p->b = v + 1; }
int sum(const Pair *p) { return p->a + p->b; }
int *second(Pair *p) { return &p->b; }
void bump(int *p) { *p += 1; }
