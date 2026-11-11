// Prints every table in tables.inc in the canonical form that gen.rb prints from the Ruby values (stderr of
// gen-tables.sh). check-tables.sh compares the two.
#include "tables.inc"
#include <cstdio>

static const char *tf(bool b) { return b ? "true" : "false"; }

int main() {
  std::printf("VOID");
  for (size_t i = 0; i < VOID_N; i++) std::printf("|%s", VOID[i]);
  std::printf("\n");
  for (size_t i = 0; i < SCALARS_N; i++) {
    const ScalarType &t = SCALARS[i];
    std::printf("SCALARS|%s|%s|%d", t.name, t.kind, t.size);
    if (t.arity == 4) std::printf("|%s|%s", tf(t.is_signed), tf(t.is_bool));
    std::printf("\n");
  }
  std::printf("DYNSHARED_SYM|%s\n", DYNSHARED_SYM);
  std::printf("STRING_PREFIX|%s\n", STRING_PREFIX);
  for (size_t i = 0; i < DEVICE_INTRINSICS_N; i++) std::printf("DEVICE_INTRINSICS|%s|%s\n", DEVICE_INTRINSICS[i].key, DEVICE_INTRINSICS[i].value);
  for (size_t i = 0; i < WARP_SHUFFLES_N; i++) std::printf("WARP_SHUFFLES|%s|%s\n", WARP_SHUFFLES[i].key, WARP_SHUFFLES[i].value);
  for (size_t i = 0; i < WARP_VOTES_N; i++) std::printf("WARP_VOTES|%s|%s\n", WARP_VOTES[i].key, WARP_VOTES[i].value);
  for (size_t i = 0; i < FLOAT_TO_INT_BUILTINS_N; i++) std::printf("FLOAT_TO_INT_BUILTINS|%s|%s\n", FLOAT_TO_INT_BUILTINS[i].key, FLOAT_TO_INT_BUILTINS[i].value);
  for (size_t i = 0; i < SCALAR_U32_N; i++) std::printf("SCALAR_U32|%s|%s|%d\n", SCALAR_U32[i].key, SCALAR_U32[i].op, SCALAR_U32[i].n);
  for (size_t i = 0; i < HALF_BUILTINS_N; i++) std::printf("HALF_BUILTINS|%s|%s|%d\n", HALF_BUILTINS[i].key, HALF_BUILTINS[i].op, HALF_BUILTINS[i].n);
  for (size_t i = 0; i < FLOAT_BUILTINS_N; i++) {
    const KvFloatOp &f = FLOAT_BUILTINS[i];
    std::printf("FLOAT_BUILTINS|%s|%s%s|%d\n", f.key, f.is_symbol ? ":" : "", f.op, f.n);
  }
  for (size_t i = 0; i < ATOMICS_N; i++) std::printf("ATOMICS|%s|%s|%s\n", ATOMICS[i].key, ATOMICS[i].op, ATOMICS[i].type);
  return 0;
}
