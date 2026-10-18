// EXPECT: 9
// A default argument may name a preceding parameter in an unevaluated operand (sizeof, decltype): the
// sycl::group_barrier default "decltype(G)::fence_scope" in <sycl/ext/oneapi/experimental/root_group.hpp>.
template <int D> struct grp {
  static constexpr int fence_scope = D;
};

template <int D>
int barrier(grp<D> G, int scope = decltype(G)::fence_scope) {
  return scope;
}

int size_of_first(int G, int x = sizeof(G)) { return x; }

int main() { return barrier(grp<5>{}) + size_of_first(1); }
