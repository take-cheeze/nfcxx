#include <stdint.h>
typedef struct { uint64_t lo, hi; } uint128_t;
static inline uint8_t __mrustc_atomicloop8(volatile uint8_t* slot, uint8_t param, int ordering, uint8_t (*cb)(uint8_t, uint8_t)) { old body }
static inline uint16_t __mrustc_atomicloop16(volatile uint16_t* slot, uint16_t param, int ordering, uint16_t (*cb)(uint16_t, uint16_t)) { old body }
static inline uint32_t __mrustc_atomicloop32(volatile uint32_t* slot, uint32_t param, int ordering, uint32_t (*cb)(uint32_t, uint32_t)) { old body }
static inline uint64_t __mrustc_atomicloop64(volatile uint64_t* slot, uint64_t param, int ordering, uint64_t (*cb)(uint64_t, uint64_t)) { old body }
struct __attribute__((__aligned__(16),)) Wide { uint64_t a; };
const char *msg = "keep ,)) in strings";
_Atomic int counter;
__extension__ typedef int ext_t;
void copy(char *__restrict a, const char *__restrict__ b);
extern int strerror_r (int, char *, unsigned long) __asm__ ("" "__xpg_strerror_r");
#pragma pack(push, 1)
struct Packed {
 uint8_t a;
 uint32_t b;
};
#pragma pack(pop)
struct Normal {
 uint8_t a;
};
__attribute__((weak)) union { uint8_t raw[8]; } VTABLE_ONE;
uint8_t TYPEID_TWO __attribute__((weak));
extern char __attribute__((weak)) OPTIONAL_SYM[0];
extern void ZRG4core3foo17h0123456789abcdefE(int);
asm("__rust_alloc");
extern void ZRG4core3bar17h0123456789abcdefE(void);
asm("cfgetispeed@GLIBC_2.2.5");
extern int DATA_OBJ asm("real_data_symbol");
int use_data(void) { return DATA_OBJ + DATA_OBJ_2; }
__attribute__((section(".init_array.0"))) union { uintptr_t raw; } ARGV_INIT;
ARGV_INIT = { .raw = {(uintptr_t)&capture_argv} };
void assert_user(void) {
 ({ if (!"not implemented") ; else __assert_fail ("not implemented", "intr.rs", 7, __PRETTY_FUNCTION__); });
}
uint32_t atomics(uint32_t *p, uint64_t *q, void **r, uint128_t *w, uint128_t v) {
 uint32_t a = ({ __auto_type __atomic_load_ptr = ((uint32_t*)p); __typeof__ ((void)0, *__atomic_load_ptr) __atomic_load_tmp; __atomic_load (__atomic_load_ptr, &__atomic_load_tmp, 5); __atomic_load_tmp; });
 ({ __auto_type __atomic_store_ptr = ((uint64_t*)q); __typeof__ ((void)0, *__atomic_store_ptr) __atomic_store_tmp = (a); __atomic_store (__atomic_store_ptr, &__atomic_store_tmp, 5); });
 uint64_t b = ({ __auto_type __atomic_exchange_ptr = ((uint64_t*)q); __typeof__ ((void)0, *__atomic_exchange_ptr) __atomic_exchange_tmp = (b); __typeof__ ((void)0, *__atomic_exchange_ptr) __atomic_exchange_ret; __atomic_exchange (__atomic_exchange_ptr, &__atomic_exchange_tmp, &__atomic_exchange_ret, 4); __atomic_exchange_ret; });
 _Bool ok = ({ __auto_type __atomic_compare_exchange_ptr = ((uint32_t*)p); __typeof__ ((void)0, *__atomic_compare_exchange_ptr) __atomic_compare_exchange_tmp = (a); __atomic_compare_exchange (__atomic_compare_exchange_ptr, &exp, &__atomic_compare_exchange_tmp, 1, 5, 2); });
 void *pv = ({ __auto_type __atomic_load_ptr = ((void**)r); __typeof__ ((void)0, *__atomic_load_ptr) __atomic_load_tmp; __atomic_load (__atomic_load_ptr, &__atomic_load_tmp, 2); __atomic_load_tmp; });
 uint128_t wl = ({ __auto_type __atomic_load_ptr = ((uint128_t*)w); __typeof__ ((void)0, *__atomic_load_ptr) __atomic_load_tmp; __atomic_load (__atomic_load_ptr, &__atomic_load_tmp, 5); __atomic_load_tmp; });
 ({ __auto_type __atomic_store_ptr = ((uint128_t*)w); __typeof__ ((void)0, *__atomic_store_ptr) __atomic_store_tmp = (v); __atomic_store (__atomic_store_ptr, &__atomic_store_tmp, 3); });
 uint128_t we = ({ __auto_type __atomic_exchange_ptr = ((uint128_t*)w); __typeof__ ((void)0, *__atomic_exchange_ptr) __atomic_exchange_tmp = (v); __typeof__ ((void)0, *__atomic_exchange_ptr) __atomic_exchange_ret; __atomic_exchange (__atomic_exchange_ptr, &__atomic_exchange_tmp, &__atomic_exchange_ret, 5); __atomic_exchange_ret; });
 _Bool wc = ({ __auto_type __atomic_compare_exchange_ptr = ((uint128_t*)w); __typeof__ ((void)0, *__atomic_compare_exchange_ptr) __atomic_compare_exchange_tmp = (v); __atomic_compare_exchange (__atomic_compare_exchange_ptr, &exp, &__atomic_compare_exchange_tmp, 0, 5, 5); });
 return a;
}
void inline_asm(void) {
 uint32_t lo;
 uint32_t hi;
 uint32_t arg = 0;
 uint32_t r0;
 uint32_t r1;
 uint32_t r2;
 uint32_t r3;
 uint64_t slot;
 uint64_t bit;
 void *ptr;
 uintptr_t asm_anon_0 = 0;
 register uint64_t rbx_v asm("rbx") = 5;
 register uint32_t plain_r asm("eax");
 __asm__ __volatile__ ("pause");
 __asm__ __volatile__(".intel_syntax noprefix; /* %0 */;\n .att_syntax; " : "+r" (slot) ::);
 __asm__ __volatile__(".intel_syntax noprefix; /* %0 */;\n .att_syntax; " : "+q" (lo) ::);
 __asm__ __volatile__(".intel_syntax noprefix; prefetcht0 [%0];\n .att_syntax; " : : "r" (ptr): "memory");
 __asm__ __volatile__ ("xgetbv" : "=a" (lo), "=d" (hi) : "c" (arg) );
 __asm__("cpuid" : "=a" (r0), "=b" (r1), "=c" (r2), "=d" (r3) : "a" (arg), "c" (arg) );
 __asm__ __volatile__("lock btsq %1, %0" : "+m" (slot) : "r" (bit) : "cc");
 __asm__ __volatile__("lock btsq %1, %0" : "+m" (slot) : "r" (bit) : "cc");
 __asm__ __volatile__("lock negq %0 ; ret: x" : "+r" (rbx_v), "=r" (asm_anon_0) : "r" (ptr) : "memory", "cc");
 __asm__ __volatile__("mov %0, %0" : "+r" (plain_r) : : );
}
