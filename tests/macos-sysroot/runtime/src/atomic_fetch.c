/* The sized read-modify-write functions GCC's libatomic and clang's __atomic builtins name with an _N suffix (for
   example __atomic_add_fetch_8), for 1, 2, 4 and 8 bytes. Each returns the value after the operation, with the memory
   order given by the caller. They are written with clang's __atomic_*_fetch builtins, which are lowered inline for these
   sizes, so the functions do not call back into a library. Written from the GCC __atomic builtin specification
   (the __atomic_*_fetch built-in functions); no GCC or libatomic source is used. */
#include <stddef.h>

#define NFCXX_FETCH_OP(op, name, T, N)                                            \
  T name##_##N(volatile void *ptr, T val, int memorder) {                         \
    return __atomic_##op##_fetch((volatile T *)ptr, val, memorder);               \
  }

#define NFCXX_FETCH_OPS(T, N)                                                     \
  NFCXX_FETCH_OP(add, __atomic_add_fetch, T, N)                                   \
  NFCXX_FETCH_OP(sub, __atomic_sub_fetch, T, N)                                   \
  NFCXX_FETCH_OP(and, __atomic_and_fetch, T, N)                                   \
  NFCXX_FETCH_OP(or, __atomic_or_fetch, T, N)                                     \
  NFCXX_FETCH_OP(xor, __atomic_xor_fetch, T, N)

NFCXX_FETCH_OPS(unsigned char, 1)
NFCXX_FETCH_OPS(unsigned short, 2)
NFCXX_FETCH_OPS(unsigned int, 4)
NFCXX_FETCH_OPS(unsigned long long, 8)
