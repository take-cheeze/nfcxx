// RUN-QEMU: 77
// RUN-QEMU-OUT: sum 6d2e844d
// Runs on the ESP32-C3 emulator (Espressif's QEMU, tests/mcu/run.sh). It prints over UART0 a checksum of a 64-bit and a
// 32-bit hash loop, and returns its low seven bits. The runner checks the printed sum (0x6d2e844d) and the exit status (77).
// No templates: `--emit-c` does not instantiate them (edg_prelink does, on the hosted driver path).
#include <cstdint>

extern "C" void nfcxx_mcu_putc(char c);

static std::uint64_t hash64(std::uint64_t seed, std::uint32_t rounds) {
  std::uint64_t h = seed;
  for (std::uint32_t i = 0; i < rounds; ++i) h = h * 31u + i;
  return h;
}

static std::uint32_t hash32(std::uint32_t seed, std::uint32_t rounds) {
  std::uint32_t h = seed;
  for (std::uint32_t i = 0; i < rounds; ++i) h = h * 31u + i;
  return h;
}

static void put_str(const char *s) {
  while (*s) nfcxx_mcu_putc(*s++);
}

static void put_hex32(std::uint32_t v) {
  static const char digits[] = "0123456789abcdef";
  for (int shift = 28; shift >= 0; shift -= 4) nfcxx_mcu_putc(digits[(v >> shift) & 0xf]);
}

extern "C" int nfcxx_mcu_run(void) {
  put_str("ESP32-C3 ok\n");
  std::uint64_t wide = hash64(0x9e3779b97f4a7c15ull, 64);
  std::uint32_t narrow = hash32(7u, 100);
  std::uint32_t sum = static_cast<std::uint32_t>(wide ^ (wide >> 32)) ^ narrow;
  put_str("sum ");
  put_hex32(sum);
  nfcxx_mcu_putc('\n');
  return static_cast<int>(sum & 0x7f);
}
