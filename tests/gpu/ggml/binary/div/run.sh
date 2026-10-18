#!/usr/bin/env bash
# The real ggml-sycl binbcast.cpp entry point ggml_sycl_div (OpenCL): the shared driver ../bin_run.sh builds it as a TU of
# ../bin_real.cpp, runs it on the Intel XPU and checks the mutant. See ../bin_run.sh for the checks and the environment.
exec "$(dirname "$0")/../bin_run.sh" div
