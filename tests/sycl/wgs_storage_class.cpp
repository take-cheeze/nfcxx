// Work-group statics of four element widths, written and read across work-items: float (4 bytes), short (2 bytes, two items
// share a 32-bit word), unsigned char (1 byte, four items share a word), double (8 bytes). The static accesses go to the
// group's Workgroup-storage variable (tests/sycl/run.sh checks the storage class of the emitted module). Every item checks
// its values against the host's. Expected output: "wgs_storage_class ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

int main() {
    sycl::queue q;
    float * outf = sycl::malloc_shared<float>(64, q);
    short * outh = sycl::malloc_shared<short>(64, q);
    unsigned char * outb = sycl::malloc_shared<unsigned char>(64, q);
    double * outd = sycl::malloc_shared<double>(64, q);
    for (int i = 0; i < 64; i++) { outf[i] = -1.0f; outh[i] = -1; outb[i] = 0; outd[i] = -1.0; }
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(64), sycl::range<1>(64)), [=](sycl::nd_item<1> it) {
        syclex::work_group_static<float[64]> F;
        syclex::work_group_static<short[64]> H;
        syclex::work_group_static<unsigned char[64]> B;
        syclex::work_group_static<double[8]> D;
        const int i = (int) it.get_local_id(0);
        F[i] = 0.5f * (float) i;
        H[i] = (short) (i - 32);
        B[i] = (unsigned char) (i * 3 + 1);
        if (i < 8) D[i] = 1.5 * (double) i;
        sycl::group_barrier(it.get_group());
        outf[i] = F[63 - i];
        outh[i] = H[63 - i];
        outb[i] = B[(i + 17) % 64];
        if (i < 8) outd[i] = D[7 - i];
    }).wait();
    int bad = 0;
    for (int i = 0; i < 64; i++) {
        const float wf = 0.5f * (float) (63 - i);
        const short wh = (short) ((63 - i) - 32);
        const unsigned char wb = (unsigned char) (((i + 17) % 64) * 3 + 1);
        if (outf[i] != wf || outh[i] != wh || outb[i] != wb) {
            if (bad < 4) std::printf("item %d: float %g (want %g), short %d (want %d), byte %d (want %d)\n", i, (double) outf[i], (double) wf, (int) outh[i], (int) wh, (int) outb[i], (int) wb);
            bad++;
        }
        if (i < 8 && outd[i] != 1.5 * (double) (7 - i)) {
            if (bad < 4) std::printf("item %d: double %g (want %g)\n", i, outd[i], 1.5 * (double) (7 - i));
            bad++;
        }
    }
    std::printf(bad ? "wgs_storage_class FAIL %d\n" : "wgs_storage_class ok\n", bad);
    return bad != 0;
}
