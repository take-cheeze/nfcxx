// device::get_info<max_compute_units> on OpenCL and Level Zero is the device's count, not a placeholder: ggml-sycl takes
// max_compute_units / 16 for its Xe cores (nsm) and divides by that (count_equal: SIGFPE with nsm = 0). Both runtimes must
// give the same count (an Intel GPU's EUs, as DPC++ reports them); the test prints it and checks it is at least 16.
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
  sycl::queue q;
  const sycl::device d = q.get_device();
  const unsigned cu = d.get_info<sycl::info::device::max_compute_units>();
  std::printf("%s: %u compute units\n", d.get_info<sycl::info::device::name>().c_str(), cu);
  if (d.is_gpu() && cu < 16) { std::printf("compute_units: %u, fewer than one Xe core\n", cu); return 1; }
  std::printf("compute_units ok\n");
  return 0;
}
