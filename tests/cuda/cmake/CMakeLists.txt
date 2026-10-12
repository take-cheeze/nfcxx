# The CUDA route through CMake: CMAKE_CUDA_COMPILER is scripts/nfcxx-cuda (nvcc-compatible, nfcxx underneath).
cmake_minimum_required(VERSION 3.18)
project(nfcxx_cuda_cmake LANGUAGES CXX CUDA)
set(CMAKE_CUDA_ARCHITECTURES 75)
add_library(kernel STATIC kernel.cu)
target_compile_options(kernel PRIVATE "$<$<COMPILE_LANGUAGE:CUDA>:-use_fast_math;-extended-lambda>")
