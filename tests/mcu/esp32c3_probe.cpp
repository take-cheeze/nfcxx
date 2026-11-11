// ESP32-C3 (RV32IMC, ILP32, little-endian, bare metal). EDG has no bare-metal RV32 table, so tests/mcu/run.sh
// generates the C for the linux_riscv32 stand-in (scripts/gen-c-target.sh) and clang compiles it for
// riscv32-unknown-elf -march=rv32imc -mabi=ilp32. Nothing here runs yet: this is the compile-only step.
#include <cstddef>
#include <cstdint>

static_assert(sizeof(void *) == 4, "pointers are 32-bit");
static_assert(sizeof(long) == 4, "long is 32-bit (ILP32)");
static_assert(sizeof(std::size_t) == 4, "size_t is 32-bit");
static_assert(char(255) > 0, "char is unsigned on RISC-V (clang and the ABI agree)");
static_assert(sizeof(std::uint64_t) == 8, "uint64_t from lib/cstdint");

// A register-only kernel in the shape of MCU code: a 64-bit accumulator on a 32-bit core, a template, and an
// extern "C" entry point the startup code would call.
template <typename T>
T mix(T seed, std::uint32_t rounds) {
  T h = seed;
  for (std::uint32_t i = 0; i < rounds; ++i) h = h * 31u + i;
  return h;
}

extern "C" std::uint32_t nfcxx_mcu_main(void) {
  std::uint64_t wide = mix<std::uint64_t>(0x9e3779b97f4a7c15ull, 64);
  std::uint32_t narrow = mix<std::uint32_t>(7u, 100);
  return static_cast<std::uint32_t>(wide ^ (wide >> 32)) ^ narrow;
}
