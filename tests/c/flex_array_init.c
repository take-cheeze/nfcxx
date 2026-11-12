/* EXPECT: 0 */
/* GNU C: a flexible array member initialised by elements, in a static object (the global's size is the struct plus the
   elements, docs/notes/pathb-ssa-qbe.md, "the cproc-removal work"). C only: C++ rejects an initialiser for it. */
struct flex { int n; int v[]; };
static struct flex fx = { 2, { 7, 8 } };
static struct flex fy = { 3, { 1, 2, 3 } };
int main(void) {
    int ok = 0;
    ok += fx.n == 2;
    ok += fx.v[0] == 7 && fx.v[1] == 8;
    ok += fy.v[2] == 3;
    ok += sizeof fx == sizeof(int);   /* the flexible member adds no size */
    return ok == 4 ? 0 : 1;
}
