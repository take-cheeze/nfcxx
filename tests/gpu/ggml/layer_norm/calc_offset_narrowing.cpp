// The smallest reproducer of the front-end refusal that blocks ggml-sycl norm.cpp (LAYER_NORM and GROUP_NORM, one TU):
// the calculate_offset call of norm.cpp:18 (the helper is common.hpp:658, with std::array<int, N> parameters), with int64_t
// strides. The braced list narrows int64_t to int, so no overload is viable:
//   error: no instance of function template "calculate_offset" matches the argument list
// Compile with the Path B front end (scripts/pathb-dump --ir -std=c++17 this_file.cpp). The control, the same call with int
// strides (a function f(int, int, int, int)), compiles.
#include <array>
#include <cstdint>
#include <cstddef>

template <int N>
size_t calculate_offset(const std::array<int, N> & strides, const std::array<int, N> & indices) {
    size_t offset = 0;
    for (int i = 0; i < N; i++) {
        offset += strides[i] * indices[i];
    }
    return offset;
}

size_t f(int64_t s0, int64_t s1, int64_t s2, int row) {
    return calculate_offset<3>({s0, s1, s2}, {row, row, row});
}
