# A CMake project that links the CUDA driver the usual way (CUDA::cuda_driver, as libtorch's caffe2::cuda and
# llama.cpp's ggml-cuda do): with nfcc as the C compiler the link goes through libcudart instead
# (tests/cuda/driver/run.sh, docs/notes/cuda-driver.md).
cmake_minimum_required(VERSION 3.18)
project(nfcxx_cuda_driver C)
find_package(CUDAToolkit REQUIRED)
add_executable(real ../real.c)
target_link_libraries(real PRIVATE CUDA::cuda_driver)
