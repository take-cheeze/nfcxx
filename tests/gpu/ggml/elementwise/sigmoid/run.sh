#!/usr/bin/env bash
# The real ggml-sycl element_wise.cpp entry point ggml_sycl_sigmoid (OpenCL): the shared driver ../ew_run.sh builds it as a TU of
# ../ew_real.cpp, runs it on the Intel XPU and checks the mutant. See ../ew_run.sh for the checks and the environment.
exec "$(dirname "$0")/../ew_run.sh" sigmoid
