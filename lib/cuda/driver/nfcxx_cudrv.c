// The CUDA driver API through the CUDA runtime (scripts/cuda-driver-shim, docs/notes/cuda-driver.md).
//
// Every driver function of nfcxx_cudrv_table.inc (generated from cuda.h and cudaTypedefs.h: the linked name, the base
// name, the ABI version, 1 for the legacy default stream or 2 for the per-thread one) is a trampoline that jumps
// through its slot. A slot starts at the function's resolve stub, which saves the argument registers, asks libcudart
// for the driver's function (cudaGetDriverEntryPointByVersion, libcudart 12.5 or later), stores it in the slot and jumps
// to it; later calls jump straight there. No signature is needed, so one trampoline serves every function.
//
// When the driver function cannot be had (no driver: cudart reports an error; a symbol or version the installed
// driver does not have), the slot gets a function that returns a CUresult: CUDA_ERROR_NO_DEVICE without a driver,
// CUDA_ERROR_NOT_FOUND or CUDA_ERROR_NOT_SUPPORTED otherwise. cuGetErrorString and cuGetErrorName then answer from
// here, so the program can still print what went wrong. The functions are hidden: they bind the program's own calls
// and do not interpose libcuda.so.1 for other libraries.

#if !defined(__x86_64__) || !defined(__linux__)
#error "the CUDA driver shim is x86-64 Linux only"
#endif

// From cuda_runtime_api.h, declared here so that the shim needs no CUDA header to compile. A strong reference: a link
// against libcudart before 12.5 fails, and --as-needed keeps libcudart.
extern int cudaGetDriverEntryPointByVersion(const char *symbol, void **funcPtr, unsigned int cudaVersion,
                                            unsigned long long flags, int *driverStatus);

enum { CUDA_SUCCESS_ = 0, CUDA_ERROR_INVALID_VALUE_ = 1, CUDA_ERROR_NO_DEVICE_ = 100, CUDA_ERROR_NOT_FOUND_ = 500,
       CUDA_ERROR_NOT_SUPPORTED_ = 801 };

struct entry {
  const char *name, *base;
  unsigned version;
  unsigned long long flags;
};
static const struct entry entries[] = {
#define X(name, base, ver, flags) {#name, base, ver, flags},
#include "nfcxx_cudrv_table.inc"
#undef X
};
enum {
#define X(name, base, ver, flags) idx_##name,
#include "nfcxx_cudrv_table.inc"
#undef X
  n_entries
};

static int fail_code = CUDA_ERROR_NOT_FOUND_;
static int fail(void) { return fail_code; }

static const char *fallback_text(int e, int name) {
  switch (e) {
    case CUDA_SUCCESS_: return name ? "CUDA_SUCCESS" : "no error";
    case CUDA_ERROR_INVALID_VALUE_: return name ? "CUDA_ERROR_INVALID_VALUE" : "invalid argument";
    case CUDA_ERROR_NO_DEVICE_: return name ? "CUDA_ERROR_NO_DEVICE" : "no CUDA driver or device (the CUDA runtime could not load the driver)";
    case CUDA_ERROR_NOT_FOUND_: return name ? "CUDA_ERROR_NOT_FOUND" : "the CUDA driver has no such function";
    case CUDA_ERROR_NOT_SUPPORTED_: return name ? "CUDA_ERROR_NOT_SUPPORTED" : "the CUDA driver is too old for this function";
    default: return 0;
  }
}
static int local_error_string(int e, const char **s) {
  if (!s) return CUDA_ERROR_INVALID_VALUE_;
  *s = fallback_text(e, 0);
  return *s ? CUDA_SUCCESS_ : CUDA_ERROR_INVALID_VALUE_;
}
static int local_error_name(int e, const char **s) {
  if (!s) return CUDA_ERROR_INVALID_VALUE_;
  *s = fallback_text(e, 1);
  return *s ? CUDA_SUCCESS_ : CUDA_ERROR_INVALID_VALUE_;
}

extern void *nfcxx_cudrv_slots[];

// Called by the resolve stubs (below) with the entry's index; returns where the call goes.
__attribute__((used)) static void *nfcxx_cudrv_resolve(unsigned i) {
  const struct entry *e = &entries[i];
  void *fn = 0;
  int status = 0;
  if (cudaGetDriverEntryPointByVersion(e->base, &fn, e->version, e->flags, &status) != 0) {
    fn = 0;
    fail_code = CUDA_ERROR_NO_DEVICE_;
  } else if (status != 0 || !fn) {
    fn = 0;
    fail_code = status == 2 ? CUDA_ERROR_NOT_SUPPORTED_ : CUDA_ERROR_NOT_FOUND_;
  }
  if (!fn) {
    if (i == idx_cuGetErrorString) fn = (void *)local_error_string;
    else if (i == idx_cuGetErrorName) fn = (void *)local_error_name;
    else fn = (void *)fail;
  }
  __atomic_store_n(&nfcxx_cudrv_slots[i], fn, __ATOMIC_RELEASE);
  return fn;
}

// The common resolve path: the stub put the index in %r11d. The integer and vector argument registers are saved
// around the C call (at entry %rsp is 8 mod 16: the caller's return address; 6 pushes and 136 bytes make it 0).
__asm__(".pushsection .text\n"
        ".p2align 4\n"
        "nfcxx_cudrv_resolve_common:\n"
        "  push %rdi\n  push %rsi\n  push %rdx\n  push %rcx\n  push %r8\n  push %r9\n"
        "  sub $136, %rsp\n"
        "  movdqu %xmm0, 0(%rsp)\n  movdqu %xmm1, 16(%rsp)\n  movdqu %xmm2, 32(%rsp)\n  movdqu %xmm3, 48(%rsp)\n"
        "  movdqu %xmm4, 64(%rsp)\n  movdqu %xmm5, 80(%rsp)\n  movdqu %xmm6, 96(%rsp)\n  movdqu %xmm7, 112(%rsp)\n"
        "  mov %r11d, %edi\n"
        "  call nfcxx_cudrv_resolve\n"
        "  mov %rax, %r11\n"
        "  movdqu 0(%rsp), %xmm0\n  movdqu 16(%rsp), %xmm1\n  movdqu 32(%rsp), %xmm2\n  movdqu 48(%rsp), %xmm3\n"
        "  movdqu 64(%rsp), %xmm4\n  movdqu 80(%rsp), %xmm5\n  movdqu 96(%rsp), %xmm6\n  movdqu 112(%rsp), %xmm7\n"
        "  add $136, %rsp\n"
        "  pop %r9\n  pop %r8\n  pop %rcx\n  pop %rdx\n  pop %rsi\n  pop %rdi\n"
        "  jmp *%r11\n"
        ".popsection\n");

// One trampoline and one resolve stub per function (extended asm, for the index operands, so inside a function that is
// never called), and the slot array.
#define X(name, base, ver, flags)                                                                     \
  __asm__ volatile(".pushsection .text\n"                                                          \
                   ".globl " #name "\n.hidden " #name "\n.type " #name ",@function\n" #name ":\n"    \
                   "  jmp *nfcxx_cudrv_slots+8*%c0(%%rip)\n"                                        \
                   ".size " #name ",.-" #name "\n"                                                  \
                   "nfcxx_cudrv_stub_" #name ":\n"                                                   \
                   "  mov $%c0, %%r11d\n"                                                            \
                   "  jmp nfcxx_cudrv_resolve_common\n"                                             \
                   ".popsection\n" ::"i"(idx_##name));
__attribute__((used)) static void nfcxx_cudrv_trampolines(void) {
#include "nfcxx_cudrv_table.inc"
}
#undef X

__asm__(".pushsection .data\n.p2align 3\n.globl nfcxx_cudrv_slots\n.hidden nfcxx_cudrv_slots\nnfcxx_cudrv_slots:\n");
#define X(name, base, ver, flags) __asm__(".quad nfcxx_cudrv_stub_" #name "\n");
#include "nfcxx_cudrv_table.inc"
#undef X
__asm__(".popsection\n");
