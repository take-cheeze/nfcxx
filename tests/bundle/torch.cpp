// libtorch (CPU tensors, autograd, the CUDA backend if a GPU is there) for tests/bundle/torch.sh: built against the CUDA
// libtorch, bundled with its CUDA libraries, and run with the original libtorch out of reach.
#include <torch/torch.h>
#include <iostream>
#include <cstdlib>
#include <dlfcn.h>
#include <sstream>
int main() {
  torch::manual_seed(0);
  auto a = torch::arange(9, torch::kFloat).reshape({3, 3});
  auto b = a.matmul(a.t()) + torch::ones({3, 3});
  std::cout << b << "\n";
  torch::nn::Linear lin(3, 2);
  auto y = lin(a).sum();
  y.backward();
  std::cout << "grad " << lin->weight.grad().sizes() << "\n";
  std::cout << "cuda available " << torch::cuda::is_available() << " devices " << torch::cuda::device_count() << "\n";
#ifdef __EDG__
  // nfcxx: a plain throw inside libc10 (gcc's __cxa_throw) cannot be caught by EDG's handlers (docs/notes/eh-shim.md),
  // so the CUDA tensor is only made when there is a GPU.
  if (torch::cuda::is_available()) std::cout << "on cuda " << torch::ones({2}).to(torch::kCUDA) << "\n";
  else std::cout << "no GPU\n";
#else
  try {
    auto c = torch::ones({2}).to(torch::kCUDA);
    std::cout << "on cuda " << c << "\n";
  } catch (const c10::Error &e) {
    std::string w = e.what();
    std::cout << "c10::Error caught: " << w.substr(0, w.find('\n')) << "\n";
  }
#endif
  // The libraries libtorch and cuDNN dlopen when a GPU asks for them: load each here (T_DLOPEN, space separated).
  if (const char *list = std::getenv("T_DLOPEN")) {
    std::istringstream is(list);
    for (std::string n; is >> n;) {
      void *h = dlopen(n.c_str(), RTLD_NOW | RTLD_GLOBAL);
      std::cout << "dlopen " << n << ": " << (h ? "ok" : dlerror()) << "\n";
    }
  }
  return 0;
}
