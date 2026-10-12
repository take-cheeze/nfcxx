// Parse test: the template kernels of kernel_hdr.cuh (launch bounds in a header) must reach the host compile without
// a parse error. The host copy is never run; the check is that the driver accepts the file.
#include "kernel_hdr.cuh"

int main() {
    return 0;
}
