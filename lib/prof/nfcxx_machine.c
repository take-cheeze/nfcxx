/* Run-time hardware probe for the roofline model (see nfcxx_machine.h).
 *
 * Clock estimate: a chain of 10^7 dependent 64-bit adds, each add separated
 * from the next by an empty asm barrier so the compiler cannot fold them. On
 * x86 and most other cores a simple add has a one-cycle latency, so
 * adds / elapsed-ns is the core clock in GHz. Timed with CLOCK_MONOTONIC, best
 * of 5 runs. Turbo states and VM steal time make it approximate.
 *
 * Bandwidth: a read-sum over a buffer of 2 * L3 bytes (256 MB when the L3 size
 * is unknown), touched once before timing. Eight accumulators keep the loads
 * independent. Best of 3 passes, bytes / elapsed-s / 1e9. This is single-thread
 * bandwidth.
 *
 * Define NFCXX_MACHINE_QUICK to make nfcxx_machine_probe() skip both timings. */
#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE /* sched_getaffinity() and CPU_COUNT() are GNU in glibc */

#include "nfcxx_machine.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <sched.h>
#endif
#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#endif

#define NFCXX_CLOCK_ADDS 10000000u /* dependent adds per clock run */
#define NFCXX_CLOCK_RUNS 5
#define NFCXX_BW_RUNS 3
#define NFCXX_BW_DEFAULT_BYTES ((uint64_t)256 << 20)

/* Sink for measured values so the optimizer cannot drop the work. */
static volatile uint64_t g_sink;

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static uint64_t sysconf_u(int name) {
  long v = sysconf(name);
  return v > 0 ? (uint64_t)v : 0;
}

/* Reads the first line of a small sysfs file. */
static int read_small(const char *path, char *out, size_t cap) {
  FILE *f = fopen(path, "r");
  int ok;
  if (!f) return 0;
  ok = fgets(out, (int)cap, f) != NULL;
  fclose(f);
  if (ok) out[strcspn(out, "\n")] = '\0';
  return ok;
}

/* "48K", "2048K", "1M" -> bytes. */
static uint64_t parse_size(const char *s) {
  char *end = NULL;
  unsigned long long v = strtoull(s, &end, 10);
  if (end == s) return 0;
  if (*end == 'K' || *end == 'k') v <<= 10;
  else if (*end == 'M' || *end == 'm') v <<= 20;
  else if (*end == 'G' || *end == 'g') v <<= 30;
  return (uint64_t)v;
}

#if defined(__linux__)
/* Fills L1d, L2 and L3 from /sys/devices/system/cpu/cpu0/cache/index*. */
static void probe_cache_sysfs(nfcxx_machine *m) {
  char path[160], type[32], size[32], line[32];
  int i;
  for (i = 0; i < 16; i++) {
    int level;
    uint64_t sz, ln;
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu0/cache/index%d/level", i);
    if (!read_small(path, line, sizeof line)) break;
    level = atoi(line);
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu0/cache/index%d/type", i);
    if (!read_small(path, type, sizeof type)) break;
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu0/cache/index%d/size", i);
    if (!read_small(path, size, sizeof size)) break;
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu0/cache/index%d/coherency_line_size", i);
    if (!read_small(path, line, sizeof line)) break;
    sz = parse_size(size);
    ln = (uint64_t)atoi(line);
    if (level == 1 && strcmp(type, "Data") == 0) {
      if (!m->l1d_size) { m->l1d_size = sz; m->l1d_line = (uint32_t)ln; }
    } else if (level == 2 && strcmp(type, "Instruction") != 0) {
      if (!m->l2_size) { m->l2_size = sz; m->l2_line = (uint32_t)ln; }
    } else if (level == 3 && strcmp(type, "Instruction") != 0) {
      if (!m->l3_size) { m->l3_size = sz; m->l3_line = (uint32_t)ln; }
    }
  }
}
#endif

/* Fills whatever sysfs did not, from the sysconf cache names. */
static void probe_cache_sysconf(nfcxx_machine *m) {
#ifdef _SC_LEVEL1_DCACHE_SIZE
  if (!m->l1d_size) m->l1d_size = sysconf_u(_SC_LEVEL1_DCACHE_SIZE);
  if (!m->l1d_line) m->l1d_line = (uint32_t)sysconf_u(_SC_LEVEL1_DCACHE_LINESIZE);
#endif
#ifdef _SC_LEVEL2_CACHE_SIZE
  if (!m->l2_size) m->l2_size = sysconf_u(_SC_LEVEL2_CACHE_SIZE);
  if (!m->l2_line) m->l2_line = (uint32_t)sysconf_u(_SC_LEVEL2_CACHE_LINESIZE);
#endif
#ifdef _SC_LEVEL3_CACHE_SIZE
  if (!m->l3_size) m->l3_size = sysconf_u(_SC_LEVEL3_CACHE_SIZE);
  if (!m->l3_line) m->l3_line = (uint32_t)sysconf_u(_SC_LEVEL3_CACHE_LINESIZE);
#endif
}

/* First "model name" line of /proc/cpuinfo. */
static void probe_model(nfcxx_machine *m) {
  char line[512];
  FILE *f = fopen("/proc/cpuinfo", "r");
  if (!f) return;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "model name", 10) == 0) {
      char *c = strchr(line, ':');
      size_t n;
      if (c) {
        c++;
        while (*c == ' ' || *c == '\t') c++;
        n = strcspn(c, "\n");
        if (n >= sizeof m->cpu_model) n = sizeof m->cpu_model - 1;
        memcpy(m->cpu_model, c, n);
        m->cpu_model[n] = '\0';
      }
      break;
    }
  }
  fclose(f);
}

#if defined(__x86_64__) || defined(__i386__)
/* ISA bits from CPUID. AVX and AVX512 also need the OS to save the state
 * (XCR0), so the xgetbv check is part of the result. */
static uint32_t probe_isa(void) {
  unsigned a = 0, b = 0, c = 0, d = 0;
  uint32_t f = 0;
  unsigned lo, hi;
  uint64_t xcr0;
  if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
  if (d & (1u << 26)) f |= NFCXX_ISA_SSE2;
  if (c & (1u << 20)) f |= NFCXX_ISA_SSE42;
  if (!((c >> 27) & 1) || !((c >> 28) & 1)) return f; /* OSXSAVE and AVX */
  __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
  xcr0 = ((uint64_t)hi << 32) | lo;
  if ((xcr0 & 0x6) != 0x6) return f; /* XMM and YMM state saved by the OS */
  f |= NFCXX_ISA_AVX;
  if (__get_cpuid_max(0, NULL) < 7) return f;
  __cpuid_count(7, 0, a, b, c, d);
  if (b & (1u << 5)) f |= NFCXX_ISA_AVX2;
  if ((xcr0 & 0xe6) == 0xe6 && (b & (1u << 16))) f |= NFCXX_ISA_AVX512F;
  return f;
}
#else
static uint32_t probe_isa(void) { return 0; }
#endif

#if defined(__GNUC__)
/* Read through a volatile so the increment is not a compile-time constant:
 * an "add reg, imm" can be folded away at rename on recent Intel cores, which
 * would make the chain look many times faster than the clock. */
static volatile uint64_t g_one = 1;

/* Returns GHz from a dependent add chain (add reg, reg; latency 1). */
static double measure_clock_ghz(void) {
  double best = 1e30;
  int r;
  uint64_t sink = 0;
  for (r = 0; r < NFCXX_CLOCK_RUNS; r++) {
    uint64_t x = (uint64_t)r;
    uint64_t one = g_one;
    uint32_t i;
    double t0 = now_s();
    for (i = 0; i < NFCXX_CLOCK_ADDS / 8; i++) {
#define NFCXX_DEP_ADD() do { x += one; __asm__ volatile("" : "+r"(x)); } while (0)
      NFCXX_DEP_ADD(); NFCXX_DEP_ADD(); NFCXX_DEP_ADD(); NFCXX_DEP_ADD();
      NFCXX_DEP_ADD(); NFCXX_DEP_ADD(); NFCXX_DEP_ADD(); NFCXX_DEP_ADD();
#undef NFCXX_DEP_ADD
    }
    double t = now_s() - t0;
    sink += x;
    if (t < best) best = t;
  }
  g_sink = sink;
  return best > 0 ? (double)NFCXX_CLOCK_ADDS / best / 1e9 : 0.0;
}
#else
static double measure_clock_ghz(void) { return 0.0; } /* needs GNU asm barrier */
#endif

/* Eight independent accumulators; n is a multiple of 8. */
static uint64_t read_sum(const uint64_t *p, size_t n) {
  uint64_t a0 = 0, a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0, a6 = 0, a7 = 0;
  size_t i;
  for (i = 0; i < n; i += 8) {
    a0 += p[i]; a1 += p[i + 1]; a2 += p[i + 2]; a3 += p[i + 3];
    a4 += p[i + 4]; a5 += p[i + 5]; a6 += p[i + 6]; a7 += p[i + 7];
  }
  return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}

/* Returns GB/s from a streaming read over a buffer larger than the L3. */
static double measure_bw_gbs(uint64_t l3_size) {
  /* Just over the L3 size: the spec only asks for "larger than L3", and a
 * larger buffer costs page faults and time on machines with a big L3. */
  uint64_t bytes = l3_size ? l3_size + ((uint64_t)1 << 20) : NFCXX_BW_DEFAULT_BYTES;
  uint64_t *buf;
  size_t n;
  double best = 1e30;
  int r;
  uint64_t sink = 0;
  bytes &= ~(uint64_t)63;
  if (bytes < 64) return 0.0;
  buf = malloc((size_t)bytes);
  if (!buf) return 0.0;
  memset(buf, 0x5a, (size_t)bytes); /* first touch, so pages are mapped */
  n = (size_t)(bytes / sizeof(uint64_t));
  for (r = 0; r < NFCXX_BW_RUNS; r++) {
    double t0 = now_s();
    sink += read_sum(buf, n);
    double t = now_s() - t0;
    if (t < best) best = t;
  }
  g_sink = sink;
  free(buf);
  return best > 0 ? (double)bytes / best / 1e9 : 0.0;
}

int nfcxx_machine_probe_ex(nfcxx_machine *m, unsigned flags) {
  long v;
  if (!m) return -1;
  memset(m, 0, sizeof *m);

  v = sysconf(_SC_NPROCESSORS_ONLN);
  m->ncpu_online = v > 0 ? (int)v : 1;
  m->ncpu_affinity = m->ncpu_online;
#if defined(__linux__)
  {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) == 0) {
      int cnt = CPU_COUNT(&set);
      if (cnt >= 1) m->ncpu_affinity = cnt;
    }
  }
  probe_cache_sysfs(m);
#endif
  probe_cache_sysconf(m);

  m->page_size = sysconf_u(_SC_PAGESIZE);
  if (!m->page_size) m->page_size = 4096;
  m->phys_mem = sysconf_u(_SC_PHYS_PAGES) * m->page_size;

  probe_model(m);
  m->isa_flags = probe_isa();

  if (!(flags & NFCXX_MACHINE_SKIP_CLOCK)) m->clock_ghz = measure_clock_ghz();
  if (!(flags & NFCXX_MACHINE_SKIP_BW)) m->mem_bw_gbs = measure_bw_gbs(m->l3_size);
  return 0;
}

int nfcxx_machine_probe(nfcxx_machine *m) {
#ifdef NFCXX_MACHINE_QUICK
  return nfcxx_machine_probe_ex(m, NFCXX_MACHINE_SKIP_CLOCK | NFCXX_MACHINE_SKIP_BW);
#else
  return nfcxx_machine_probe_ex(m, 0);
#endif
}

/* Appends formatted text to a bounded buffer, keeping the full length. */
struct outbuf {
  char *buf;
  size_t cap;
  size_t len;
};

static void outf(struct outbuf *o, const char *fmt, ...) {
  va_list ap;
  size_t room = o->len < o->cap ? o->cap - o->len : 0;
  int n;
  va_start(ap, fmt);
  n = vsnprintf(room ? o->buf + o->len : NULL, room, fmt, ap);
  va_end(ap);
  if (n > 0) o->len += (size_t)n;
}

static void cache_line(struct outbuf *o, const char *name, uint64_t size, uint32_t line) {
  if (size)
    outf(o, "%-14s: %llu KiB, line %u B\n", name, (unsigned long long)(size >> 10), (unsigned)line);
  else
    outf(o, "%-14s: unknown\n", name);
}

size_t nfcxx_machine_format(const nfcxx_machine *m, char *buf, size_t cap) {
  struct outbuf o;
  o.buf = buf;
  o.cap = cap;
  o.len = 0;
  if (cap) buf[0] = '\0';
  if (!m) return 0;

  outf(&o, "%-14s: %s\n", "cpu model", m->cpu_model[0] ? m->cpu_model : "unknown");
  outf(&o, "%-14s: %d online, %d in affinity mask\n", "cpus", m->ncpu_online, m->ncpu_affinity);
  cache_line(&o, "L1d cache", m->l1d_size, m->l1d_line);
  cache_line(&o, "L2 cache", m->l2_size, m->l2_line);
  cache_line(&o, "L3 cache", m->l3_size, m->l3_line);
  outf(&o, "%-14s: %llu B\n", "page size", (unsigned long long)m->page_size);
  outf(&o, "%-14s: %llu MiB\n", "physical mem", (unsigned long long)(m->phys_mem >> 20));
  outf(&o, "%-14s: ", "isa");
  if (!m->isa_flags) outf(&o, "none");
  if (m->isa_flags & NFCXX_ISA_SSE2) outf(&o, "sse2 ");
  if (m->isa_flags & NFCXX_ISA_SSE42) outf(&o, "sse4.2 ");
  if (m->isa_flags & NFCXX_ISA_AVX) outf(&o, "avx ");
  if (m->isa_flags & NFCXX_ISA_AVX2) outf(&o, "avx2 ");
  if (m->isa_flags & NFCXX_ISA_AVX512F) outf(&o, "avx512f ");
  outf(&o, "\n");
  if (m->clock_ghz > 0)
    outf(&o, "%-14s: %.3f GHz (dependent add chain)\n", "clock", m->clock_ghz);
  else
    outf(&o, "%-14s: not measured\n", "clock");
  if (m->mem_bw_gbs > 0)
    outf(&o, "%-14s: %.2f GB/s (streaming read-sum)\n", "mem bandwidth", m->mem_bw_gbs);
  else
    outf(&o, "%-14s: not measured\n", "mem bandwidth");
  return o.len;
}
