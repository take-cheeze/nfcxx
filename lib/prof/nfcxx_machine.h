/* Run-time hardware probe for the roofline model. See nfcxx_machine.c.
 *
 * Zero in a size, line, GHz or GB/s field means "unknown" or "not measured".
 * All fields are plain integers or doubles so a binary writer can copy them
 * field by field. */
#ifndef NFCXX_MACHINE_H
#define NFCXX_MACHINE_H

#include <stddef.h>
#include <stdint.h>

/* isa_flags bits (x86 only; other architectures leave them zero) */
#define NFCXX_ISA_SSE2 (1u << 0)
#define NFCXX_ISA_SSE42 (1u << 1)
#define NFCXX_ISA_AVX (1u << 2)
#define NFCXX_ISA_AVX2 (1u << 3)
#define NFCXX_ISA_AVX512F (1u << 4)

/* flags for nfcxx_machine_probe_ex() */
#define NFCXX_MACHINE_SKIP_CLOCK (1u << 0)
#define NFCXX_MACHINE_SKIP_BW (1u << 1)

typedef struct nfcxx_machine {
  int ncpu_online;     /* sysconf(_SC_NPROCESSORS_ONLN) */
  int ncpu_affinity;   /* CPUs in this process's affinity mask */
  uint64_t l1d_size;   /* bytes */
  uint32_t l1d_line;   /* bytes */
  uint64_t l2_size;
  uint32_t l2_line;
  uint64_t l3_size;
  uint32_t l3_line;
  uint64_t page_size; /* bytes */
  uint64_t phys_mem;  /* bytes */
  char cpu_model[128]; /* from "model name" in /proc/cpuinfo */
  uint32_t isa_flags;  /* NFCXX_ISA_* bits */
  double clock_ghz;    /* dependent integer add chain, best of 5 */
  double mem_bw_gbs;   /* streaming read-sum, best of 3, GB = 1e9 bytes */
} nfcxx_machine;

/* Fills *m with everything. Returns 0 on success, -1 if m is NULL. */
int nfcxx_machine_probe(nfcxx_machine *m);

/* Same as nfcxx_machine_probe() but skips the measurements named in flags.
 * Compile with -DNFCXX_MACHINE_QUICK to make nfcxx_machine_probe() skip both. */
int nfcxx_machine_probe_ex(nfcxx_machine *m, unsigned flags);

/* Writes a multi-line, human-readable description into buf (NUL-terminated
 * when cap > 0). Returns the length the full text needs, as snprintf does. */
size_t nfcxx_machine_format(const nfcxx_machine *m, char *buf, size_t cap);

#endif
