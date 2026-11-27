# Profiler: design and first step

The profiler records timed enter and exit events per site, for a run of a compiled program or of the nfcast interpreter,
and writes them to a profile file. The formats are in `docs/notes/profile-format.md`; this note covers how the profile is
produced and switched on.

## Status

Implemented so far (prototype, format version 1):

- `lib/prof/nfcxx_prof.{c,h}`: the runtime. `__nfcxx_prof_enter(site)` and `__nfcxx_prof_exit(site)`, timed with
  `CLOCK_MONOTONIC`, buffered per thread in chunks of 4096 records, written under a lock.
- Start-up: a `constructor` function reads `NFCXX_PROFILE`. When it names a file, the file is opened, the header is
  written and recording starts before `main`. When it is unset or empty, nothing is opened and the enter and exit calls
  return at once.
- `tests/prof/run.sh`: builds `basic.c` and `check.c`, and checks that no file is written without the variable, and that
  with it the file holds the expected pairs at two sites over three threads, with enters and exits alternating per thread
  and timestamps not going backwards.

- `--profile` in the driver (`scripts/nfcxx-loop.rb`): adds `-finstrument-functions` to the C compiles and links
  `lib/prof/nfcxx_prof.c` and `lib/prof/nfcxx_prof_cyg.c`, which map gcc's `__cyg_profile_func_enter/exit` onto the
  runtime. It implies the gcc backend and is refused with `--backend=pathb`. The site of a function is its address for now.
  `tests/prof/run.sh` builds `cprog.c` with it and checks the profile (`check_any.c`): fib(10) gives 178 pairs at 2 sites.
  Only C inputs are covered so far; the C++ path and the nfcast tier are not.

Not yet done: the Path B IR does not emit the calls, the C++ path does not pass the flag through, the nfcast tier does not
emit them, the file has no IR hash, and no allocation or compute counts. The string table of site names is done (below). Those are the next
steps below.

## Switching on

| Setting | Effect |
| --- | --- |
| `NFCXX_PROFILE=path` | write the profile to `path` (created or truncated) |
| unset or empty | no file, no buffering; the enter and exit calls return at once |

The constructor is the start-up hook: it runs before `main` for every program that links `lib/prof`, with no change to
`main` and no symbol interposition. A program that does not link `lib/prof` is not affected at all.

When the compiler emits the calls (next step), the `--profile` flag decides whether they are emitted, so a normal build
has no calls in it. The environment variable only decides whether a profile is written, so an instrumented binary can be
run with and without profiling.

## Overhead, as built now

Each enter or exit costs one load of a global flag when profiling is off. When it is on, one `clock_gettime` (vDSO), one
16-byte store into a thread-local buffer, and a `write` per 4096 events. The per-event `clock_gettime` is the largest cost;
`rdtsc` (calibrated at start-up) is the planned replacement. These costs are estimates from the code, not measurements. No
benchmark has been run yet.

## Next steps, in order

1. **Compiler emission.** A `--profile` flag in the driver that, for the gcc backend, adds `-finstrument-functions` with
   `__cyg_profile_func_enter/exit` mapped onto the runtime, so no compiler change is needed for a first measurement. Then
   the Path B IR pass that emits `__nfcxx_prof_enter(site)` and `__nfcxx_prof_exit(site)` around each function and loop.
   Site numbers come from the compiler and go in a string table in the file.
2. **Allocation counts.** Count `malloc` and `free` calls and bytes. Two ways: `--wrap=malloc` at link time for compiled
   programs, and the `gc_alloc` chokepoint in `lib/ast/nfcast_core.cpp` (plus the one direct `std::malloc` there) for nfcast.
   Counts go into the per-function record; sampling by bytes is kept for stack capture.
3. **Compute counts.** From callgrind (instruction counts) as the external cross-check; from node evaluations for nfcast,
   counted in the existing dispatch.
4. **nfcast tier.** Emit the calls into the tier's generated C when profiling is on, and add the profiling flag to the cache
   key so instrumented and plain code are never served in place of each other.
5. **Cheaper timestamps.** Replace `clock_gettime` with a calibrated `rdtsc`, after the overhead has been measured.

## Decisions taken in the prototype

- String table: a chunk with tid 0 written at exit, one entry per site seen, `{ site, len, name }`. A name comes from
  `dladdr` on the site's address (exported symbols only; `--profile` passes `-rdynamic` so global functions are named),
  or `+0x<offset>` for a static function. The tests check that `main` is named.
- The site identity is a 32-bit number chosen by the compiler (later: the string table index plus an ordinal, as in the
  format note). The prototype takes it as given.
- Records are host byte order with a byte-order marker in the header, rather than the little-endian layout in the format
  note. Little-endian is the only layout in use here; the marker lets a reader reject a foreign file.
- The format is written by the runtime with no dependency beyond libc and pthreads, as the format note asks.

## Limits

- A thread still running at exit loses its unflushed records. Flushing at exit for the calling thread only is the
  deliberate choice here; joining workers before exit, as the test does, gives the full profile.
- A write error turns recording off for the rest of the run rather than silently losing data mid-file.

## Machine record and allocation counts (done)

Two more chunks, both written at exit with a reserved tid and counted in bytes:

- `tid = 0xFFFFFFFE`: the machine description (`nfcxx_machine_format`). Quick by default: sysfs and cpuid only. Set
  `NFCXX_PROFILE_BENCH=1` to add the clock and bandwidth measurements (about 0.4 s).
- `tid = 0xFFFFFFFD`: the allocation totals as `allocs=N alloc_bytes=B frees=F`. Under `--profile` the link wraps
  `malloc`, `calloc`, `realloc` and `free` (`lib/prof/nfcxx_alloc.c`); without the wrap the counts are zero. The runtime's
  own buffers are counted too, a few KB.

`tools/prof/prof2sql.c` stores the machine text and the three totals on each `runs` row. Per-site allocation counts need
stack capture and are not done.
