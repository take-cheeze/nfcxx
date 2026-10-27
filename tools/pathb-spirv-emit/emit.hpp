// The C++ port of scripts/pathb-spirv-emit.rb (Path B: SPIR-V from the nfcxx mid-level IR, for the SYCL runtimes). The
// module is the Ruby's, word for word, and so is the manifest: emit_module follows the Ruby's emit_module step by step.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct Emitted {
  bool has_module = false;            // false when the unit has no kernels (the Ruby returns nil words)
  std::vector<uint32_t> words;
  std::vector<std::string> manifest;  // its lines
};

// Throws Refused or BadIR (ir.hpp).
Emitted emit_module(const std::string &src, bool kernel_cl);
