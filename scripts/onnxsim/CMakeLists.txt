# libnfconnxsim.so: onnxsim's C++ differentiator (graph_grad.cpp, qat_graph_builder.cpp) with the onnx it bundles and a C ABI shim.
# Configured by scripts/setup-onnxsim.sh with -DONNXSIM_SRC=<the unpacked onnxsim sdist>.
cmake_minimum_required(VERSION 3.26)
project(nfconnxsim CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(BUILD_SHARED_LIBS OFF)
set(ONNX_BUILD_PYTHON OFF CACHE BOOL "" FORCE)
set(ONNX_GEN_PB_TYPE_STUBS OFF CACHE BOOL "" FORCE)
set(ONNX_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ONNX_INSTALL OFF CACHE BOOL "" FORCE)
set(ONNX_USE_PROTOBUF_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(ONNX_ML ON CACHE BOOL "" FORCE)
add_subdirectory(${ONNXSIM_SRC}/third_party/onnx onnx EXCLUDE_FROM_ALL)
add_library(nfconnxsim SHARED
  nfc_onnxsim.cpp
  ${ONNXSIM_SRC}/onnxsim/graph_grad.cpp
  ${ONNXSIM_SRC}/onnxsim/qat_graph_builder.cpp)
target_include_directories(nfconnxsim PRIVATE ${ONNXSIM_SRC}/onnxsim)
target_link_libraries(nfconnxsim PRIVATE onnx onnx_proto)
set_target_properties(nfconnxsim PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_link_options(nfconnxsim PRIVATE -Wl,--exclude-libs,ALL)
