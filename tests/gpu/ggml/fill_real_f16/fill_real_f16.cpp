// The F16 case of the real ggml-sycl fill.cpp (ggml/src/ggml-sycl/fill.cpp, unchanged), compiled as this program's own TU
// through the nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir
// first). sycl::half comes from lib/sycl-ggml/sycl/half_type.hpp (the minimal IEEE binary16 type the ggml sources use).
// The ggml helpers and the backend's ggml_sycl_info() / get_current_device_id() / g_ggml_sycl_debug come from
// libggml-sycl.so (linked with -lggml-sycl). run.sh passes a version script that makes every symbol of the executable
// local, so this TU's dpct helper copies do not interpose the library's (see fill_real/fill_real.cpp).
#include "fill.cpp"
#include <cstdio>
#include <cstring>

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t k = 303 * 207 * 11 * 3;               // the test_fill shape in tests/test-backend-ops.cpp
    const float value = 2.0f;
    const sycl::half expected(value);                     // the fill value converted to half, as ggml_sycl_op_fill does
    sycl::half * dst = sycl::malloc_shared<sycl::half>(k + 64, q);
    const sycl::half guard(-7.0f);
    for (int64_t i = 0; i < k + 64; i++) dst[i] = guard;  // guard tail past k must stay untouched

    ggml_tensor t{};
    t.type = GGML_TYPE_F16;
    t.ne[0] = k; t.ne[1] = 1; t.ne[2] = 1; t.ne[3] = 1;
    t.nb[0] = sizeof(sycl::half); t.nb[1] = t.nb[0] * t.ne[0]; t.nb[2] = t.nb[1]; t.nb[3] = t.nb[2];
    t.data = dst;
    memcpy(t.op_params, &value, sizeof(float));

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;
    ggml_sycl_fill(ctx, &t);
    q.wait();

    int64_t bad = 0, guard_writes = 0;
    for (int64_t i = 0; i < k; i++) bad += (float)dst[i] != (float)expected;
    for (int64_t i = k; i < k + 64; i++) guard_writes += (float)dst[i] != (float)guard;
    printf("mismatches: %lld of %lld, guard writes: %lld of 64\n", (long long)bad, (long long)k, (long long)guard_writes);
    sycl::free(dst, q);
    return bad != 0 || guard_writes != 0;
}
