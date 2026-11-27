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
emit them, the file has no IR hash, and no compute counts from the runtime (callgrind gives them offline, see "Compute counts" below). The
string table of site names is done (below). Those are the next steps below.

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

## Overhead, measured

`tests/prof/overhead.sh` times one enter/exit pair (2,000,000 pairs, three runs each, Xeon VM here):

| Mode | ns per pair |
| --- | ---: |
| profiling off (`NFCXX_PROFILE` unset) | 0.8 |
| TSC clock (default where the TSC is invariant) | 34 to 38 |
| `CLOCK_MONOTONIC` (`NFCXX_PROFILE_CLOCK=monotonic`, or no invariant TSC) | 50 to 52 |

The TSC is calibrated against `CLOCK_MONOTONIC` for 5 ms when the profile starts. The counters chunk records which clock
was used (`clock=tsc` or `clock=monotonic`). Measured on one machine only; the flush cost is included.

## Next steps, in order

1. **Compiler emission.** A `--profile` flag in the driver that, for the gcc backend, adds `-finstrument-functions` with
   `__cyg_profile_func_enter/exit` mapped onto the runtime, so no compiler change is needed for a first measurement. Then
   the Path B IR pass that emits `__nfcxx_prof_enter(site)` and `__nfcxx_prof_exit(site)` around each function and loop.
   Site numbers come from the compiler and go in a string table in the file.
2. **Allocation counts.** Count `malloc` and `free` calls and bytes. Two ways: `--wrap=malloc` at link time for compiled
   programs, and the `gc_alloc` chokepoint in `lib/ast/nfcast_core.cpp` (plus the one direct `std::malloc` there) for nfcast.
   Counts go into the per-function record; sampling by bytes is kept for stack capture.
3. **Compute counts.** Done for C programs from callgrind, as the external cross-check (see "Compute counts" below). Still to
   do: node evaluations for nfcast, counted in the existing dispatch.
4. **nfcast tier.** Done in the prototype behind `NFCAST_TIER_PROFILE=1` (`docs/notes/ast.md`, "Tiering"): the generated C calls
   `__nfcxx_prof_enter` / `__nfcxx_prof_exit` per function (site = FNV-1a of the proto's tier serial and number), the flag is in the
   compile cache key and the Merkle hash, and an abandoned run closes the calls it left open. Open: each shared object has its own
   copy of the runtime, so a run with several compiled units keeps only the last profile written to `NFCXX_PROFILE`. The fix is for
   the host to load one runtime (RTLD_GLOBAL) that the objects bind to.

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

`tools/prof/prof2sql.c` stores the machine text and the three totals on each `runs` row.

## Allocation counts per site (done)

The allocations of a call are attributed to the site of its innermost open call, not to a captured stack. Each thread
keeps a fixed table of rows, one per site (1024 slots, at most 768 sites), allocated at its first event. The enter hook
makes the site's row the current one and the exit hook restores the enclosing one; the malloc wrappers add to the current
row without allocating or locking. A thread writes its rows as a `0xFFFFFFFC` chunk when it exits. The format is in
`docs/notes/profile-format.md`. Sites that did not fit are counted in an overflow row. The test program
`tests/prof/allocsites.c` checks the exact counts of two functions (`tests/prof/sqlite.sh`).

`tools/prof/prof2sql.c` stores the machine text and the three totals on each `runs` row.

## Compute counts (C programs, from callgrind)

The compute count of a site is its **self instructions**: callgrind's `Ir` (instructions executed) for the site's function,
counting only the cost lines of the function's own code. Callgrind records the cost of a call on the call line as the
callee's inclusive cost, so the self figure leaves out the callees. It is stored as `sites.self_instructions`
(`tools/prof/prof2sql.c`, optional third argument `CALLGRIND_OUT`; NULL when no callgrind file is given).

What it counts and what it does not:

- Counted: the function's own instructions, including the set-up of the hook call that `-finstrument-functions` adds at the
  enter and exit of each call. The hooks' bodies are separate callgrind functions (`__cyg_profile_func_enter`,
  `__nfcxx_prof_enter` and so on). In the `cprog` run each runs 178 times at about 14 to 15 Ir per call, about 10,000 of the
  479,000 instructions of the whole run. They belong to no site, so the profiler's own cost is visible this way.
- Not counted: callees the profiler did not instrument, such as libc's `malloc` and `printf`. They are separate callgrind functions and
  outside the site's self Ir, but their time is inside its `exclusive_ns`. So for `main` the two figures measure different
  things (147 Ir against about 2 ms of exclusive time); for `fib` they agree in kind.
- Recursion: callgrind names the recursive levels `fib`, `fib'2`, and so on. A site sums all of them.

Matching a site to a callgrind function (`map_callgrind` in `tools/prof/prof2sql.c`):

- A site named by its symbol (an exported function such as `main`) matches the callgrind function of that name.
- A site named `+0x<offset>` is a static function. Callgrind names it by its symbol, but the profile does not carry that
  name. The callgrind file is therefore written with `--dump-instr=yes`, which gives the address of each function's entry
  (the target of its first call). A base is taken from a named site: `base = entry(named) - site(named)`, which is the link
  address of `__executable_start`. The `+0x` site then matches the function whose entry is `base + offset`.
- Where it can fail: (1) a profile with no symbol-named site that callgrind has an entry for (no `main`, say): the `+0x`
  sites stay NULL and prof2sql warns; (2) a static function reached only by a tail jump, which callgrind records as a jump
  rather than a call, has no entry and stays NULL; (3) two callgrind functions at one entry address (aliases): the first
  one found is used. The check in `tests/prof/callgrind_check.py` maps `+0x` sites through nm instead, so any disagreement
  with the entry mapping is a FAIL.

Test: `tests/prof/callgrind.sh`, which runs `tests/prof/callgrind_check.py`. It is a separate test and not in the default
run. It needs valgrind and takes about a second here (the driver build included), well under the 30 s limit, so it could
join the default run if valgrind is assumed. Its checks: callgrind's self Ir sums to its totals; main's inclusive Ir is at
least fib's self Ir; the callgrind entries of `main` and `fib` equal their nm addresses; and for each site the profile's
calls equal callgrind's calls and `self_instructions` equals the self Ir found through nm.

## Path B hooks (`--profile` on the SSA route)

`scripts/pathb-cc.rb --profile` (and `scripts/pathb-ssa-build --profile`) sets `Qbe.prof` in `scripts/pathb-ssa-qbe.rb`. The
emitter then calls the runtime at the start of each defined function and before each `ret`:

    call $__nfcxx_prof_enter_addr(l $FUNCTION)
    ...
    call $__nfcxx_prof_exit_addr(l $FUNCTION)

with `$FUNCTION` the symbol the function is defined under (the hidden entry's body is `NAME.nfcxxhid`). The runtime names
each site by the function's address, as the gcc hooks do (`lib/prof/nfcxx_prof_cyg.c`). Without `--profile` the emitted
assembly is unchanged: `tests/pathb-prof/run.sh` checks the hooks are referenced only with the flag, and a plain object from
the untouched HEAD is byte-identical to one from the working tree.

Limits, not done:
- The driver does not yet route `--profile` through Path B: `scripts/nfcxx-loop.rb` still forces the gcc backend for it, and
  the Path B link does not add the runtime. The test links the runtime by hand.
- A function left by a C++ exception (or a longjmp) does not run its exit hook, so its call stays open in the profile. The
  EH landing pads would need the exit hook too.
- `tests/pathb-cc/run.sh` already fails on HEAD for `template` and `ir-opt-inline-explicit` (their objects differ from the
  bash oracle); this change does not affect that.
