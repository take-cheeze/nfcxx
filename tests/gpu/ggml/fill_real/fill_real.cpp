// The real ggml-sycl fill.cpp (ggml/src/ggml-sycl/fill.cpp, unchanged), compiled as this program's own TU through the
// nfcxx SYCL flow. The include resolves through -I: the ggml-sycl source dir (run.sh puts a mutant copy's dir first).
// The ggml helpers and the backend's ggml_sycl_info() / get_current_device_id() / g_ggml_sycl_debug come from
// libggml-sycl.so (linked with -lggml-sycl).
//
// The link must hide this TU's own definitions of the dpct helpers (run.sh passes a version script that makes every
// symbol of the executable local). The TU is built with the compat headers (lib/sycl, the nfcxx SYCL subset), so its
// copies of dpct::dev_mgr, dpct::device_ext and their std:: instantiations differ in layout from libggml-sycl's; left
// exported, they interpose the library's copies at run time and ggml_sycl_info() crashes in dpct::get_device_info.
#include "fill.cpp"
#include <cstdio>
#include <cstring>

int main() {
    sycl::queue q{sycl::gpu_selector_v};
    printf("device: %s\n", q.get_device().get_info<sycl::info::device::name>().c_str());

    const int64_t k = 303 * 207 * 11 * 3;               // the test_fill shape in tests/test-backend-ops.cpp
    const float value = 2.0f;
    float * dst = sycl::malloc_shared<float>(k + 64, q);
    for (int64_t i = 0; i < k + 64; i++) dst[i] = -7.0f;  // guard tail past k must stay untouched

    ggml_tensor t{};
    t.type = GGML_TYPE_F32;
    t.ne[0] = k; t.ne[1] = 1; t.ne[2] = 1; t.ne[3] = 1;
    t.nb[0] = sizeof(float); t.nb[1] = t.nb[0] * t.ne[0]; t.nb[2] = t.nb[1]; t.nb[3] = t.nb[2];
    t.data = dst;
    memcpy(t.op_params, &value, sizeof(float));

    ggml_backend_sycl_context ctx(0);
    ctx.qptrs[0][0] = &q;
    ggml_sycl_fill(ctx, &t);
    q.wait();

    int64_t bad = 0, guard = 0;
    for (int64_t i = 0; i < k; i++) bad += dst[i] != value;
    for (int64_t i = k; i < k + 64; i++) guard += dst[i] != -7.0f;
    printf("mismatches: %lld of %lld, guard writes: %lld of 64\n", (long long)bad, (long long)k, (long long)guard);
    sycl::free(dst, q);
    return bad != 0 || guard != 0;
}
