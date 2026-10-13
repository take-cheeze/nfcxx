// grid-wide cooperative groups are refused by name: a grid barrier needs a cooperative launch.
#include <cooperative_groups.h>
namespace cg = cooperative_groups;
__global__ void k(float *o) {
  const cg::grid_group g = cg::this_grid();
  o[0] = 1.0f;
  g.sync();
}
int main() { return 0; }
