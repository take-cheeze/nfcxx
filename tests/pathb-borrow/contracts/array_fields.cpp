// Struct records with array fields: a whole-object read of Grid needs every declared field byte, including
// the elements of the arrays, and the callees are inferred from their bodies.
struct Buf { char tag; int v[2]; };
struct Grid { Buf rows[2]; };
static int sum(const Buf *b) { return b->tag + b->v[0] + b->v[1]; }
static int sumg(const Grid *g) { return sum(&g->rows[0]) + sum(&g->rows[1]); }
int main() {
  Grid g;
  g.rows[0].tag = 1; g.rows[0].v[0] = 2; g.rows[0].v[1] = 3;
  g.rows[1].tag = 1; g.rows[1].v[0] = 2; g.rows[1].v[1] = 3;
  return sumg(&g) - 12;
}
