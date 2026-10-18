// EXPECT: 0
// NFCXX-FLAGS: --dialect=clang -Wno-narrowing
// A braced list of non-constant int64 values for an aggregate int[N] parameter (the std::array<int, N> of ggml-sycl's
// calculate_offset, norm.cpp:18) narrows to int. Clang mode makes the candidate non-viable unless the narrowing is a warning
// (-Wno-narrowing, as icpx and ggml-sycl build with). Both forms: N explicit (calc<3>) and N deduced from another argument.
// A header-free aggregate stands in for std::array, so the clang-mode check runs without the host library headers.
template <class T, unsigned long N>
struct arr {
  T v[N];
};

template <unsigned long N>
long calc(const arr<int, N> &strides, const arr<int, N> &indices) {
  long offset = 0;
  for (unsigned long i = 0; i < N; i++) offset += strides.v[i] * indices.v[i];
  return offset;
}

int main() {
  long s0 = 12, s1 = 4, s2 = 1;  // not constants: the narrowing is a non-constant one
  int row = 1;
  long explicit_n = calc<3>({{s0, s1, s2}}, {{row, row, row}});
  arr<int, 3> idx = {{row, row, row}};
  long deduced_n = calc(idx, {{s0, s1, s2}});
  return (explicit_n == 17 && deduced_n == 17) ? 0 : 1;
}
