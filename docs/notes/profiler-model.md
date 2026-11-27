# Profiler: the performance model and where its data lives

This note is the design for the model that turns profile data and machine parameters into predictions and diagnoses. The
collection side is in `docs/notes/profiler.md` (runtime, string table, `--profile`), and the file format in
`docs/notes/profile-format.md`. Nothing in this note beyond the importer is implemented.

## Inputs

Three kinds of data, kept apart so that each can be reused:

| Input | Source | Where it is stored |
| --- | --- | --- |
| **Program behaviour**: per-site calls, inclusive and exclusive time, timeline | `lib/prof` profile file | SQLite, `runs` and `sites` (done: `tools/prof/prof2sql.c`) |
| **Machine parameters**: cores, cache sizes and line sizes, ISA flags, clock, measured bandwidth and flop rate | `lib/prof/nfcxx_machine` probe (in progress) | SQLite, `machines` (planned) |
| **Workload counts**: allocations and bytes, compute operations, input sizes | counters (planned); compute operations for C from callgrind | SQLite, `sites` columns (`self_instructions` done) and `size_samples` (planned) |

The model reads the three and writes predictions and diagnoses. It never reads the hardware directly, so a model run on
stored data gives the same answer on any machine.

## Models

Each model is a short function from the inputs to a number that can be checked against a measurement.

### 1. Roofline (per site)

Attainable performance is `min(peak_flops, bandwidth * intensity)`, where intensity is compute operations over bytes moved
(Williams, Waterman and Patterson, 2009). For a site:

- `intensity = compute_ops / bytes`, with bytes from the allocation and load/store counters.
- The site is **compute-bound** when its intensity is above the machine's balance point `peak_flops / bandwidth`, and
  **memory-bound** below it. The diagnosis is the ratio of its measured rate to the bound that applies.

Machine side: `peak_flops` from the probe's flop-rate microbenchmark, `bandwidth` from its streaming read. Both are noisy on a
shared host, so the stored value is the best of several runs with the spread kept beside it.

### 2. Cache knees (per site, from the size fit)

The size-to-cost fit (earlier design) gives cost against input size. A change of slope where the working set crosses a
cache capacity is a knee. The model predicts the knee at the L1, L2 and L3 sizes from the machine record and reports the
measured knee beside them. A knee at a different size is a finding: either the working set is not what the size measure
says, or the cache sizes in the machine record are wrong (the probe's L3 figure needs checking on bare metal).

### 3. ECM, Execution-Cache-Memory (per loop; later)

Hager and Treibig's model gives the time of a loop as in-core time plus one transfer time per cache level, using per-level
bandwidths. It is more accurate than roofline for loops but needs the per-iteration data traffic per level. The first
version uses the counters at the level of a site; ECM is added once loop-level counters exist.

### 4. Amdahl and LogP (for threads)

The critical path (timeline, `waits_for`) gives the serial part of a run. Amdahl's law then bounds the speed-up from more
threads: `speedup <= 1 / (serial + (1 - serial) / threads)`. For the cost of waiting, LogP (Culler et al., 1993) gives the
latency `L`, overhead `o` and gap `g` of a synchronisation. The probe would measure them with a ping-pong between two
threads; the first version uses only Amdahl.

## Outputs

- A per-site table: calls, inclusive and exclusive time, intensity, bound, achieved fraction of the bound.
- A per-run critical path, with the serial fraction and the Amdahl bound.
- Knee reports for sites with a size fit.
- Every output records the machine it was computed for, so a result is never compared with a result from another machine
  without the difference being visible.

## SQLite layout

What exists (`tools/prof/prof2sql.c`, test `tests/prof/sqlite.sh`):

- `runs(run_id, source, imported_at, format_version, events, threads, open_calls)`
- `sites(run_id, site, name, calls, inclusive_ns, exclusive_ns, self_instructions)`, key `(run_id, site)`. The last column
  is the compute count of a C site: callgrind's self Ir of its function, NULL unless prof2sql is given a callgrind file
  (`docs/notes/profiler.md`, "Compute counts").

Planned:

- `machines(machine_id, cpu_model, isa_flags, ncpu, caches_json, clock_ghz, bandwidth_gbps, flops_gflops, probed_at)`, and
  `runs.machine_id` to link each run to the machine it ran on.
- `sites.allocs`, `sites.alloc_bytes`, and `sites.intensity` (computed). `compute_ops` is `self_instructions` for C (callgrind
  Ir, which counts the hook set-up too); nfcast will need its own count from node evaluations.
- `size_samples(run_id, site, size, cost_ns)`: the points of the size fit, bucketed by power of two.
- `edges(run_id, from_id, to_id, kind)` for `waits_for` and the call tree, for the critical path.

The exporter that reads the file and the importer keep the schema version in a table, so a database made by an older
importer is detected rather than misread.

## Why SQLite and not Chrome trace or pprof for this

Chrome trace and pprof are views of one run. The model needs to compare many runs and many machines, which is a query
problem, and SQLite answers those queries with plain SQL (`SUM`, `GROUP BY`, a join of runs and machines). The file format
stays small and fast to read at compile time; the database is for analysis only and is never on the path of the JIT or the
compiler.

## Validation

- The exclusive times of all sites in a run add up to the inclusive time of the thread's top-level calls. This is tested
  now (`tests/prof/dbcheck.c`).
- Roofline predictions are checked against a microbenchmark with a known intensity (a streaming sum and a dense multiply)
  before they are trusted on a program.
- The compute counts of C sites are checked against callgrind (`tests/prof/callgrind.sh`, a separate test): callgrind's self
  Ir sums to its totals, each site's profile calls equal callgrind's calls to it, and each site's `self_instructions` equals
  the self Ir of its function found through nm.
- Knee predictions are checked by running the same site at sizes either side of the predicted knee.

## Caveats

- A model is only as good as its parameters, and a VM reports nominal values (the 2.30 GHz clock, the 504 MB L3 seen here).
  Every stored parameter carries how it was obtained.
- Hardware counters are not available on this machine (no CPU PMU in `/sys/bus/event_source`), so intensity uses our own
  counts, not measured cache misses. Simulated misses from `valgrind --tool=cachegrind` (installed here) can stand in for
  them on a development run.
- Roofline and Amdahl describe averages. A site can be memory-bound for one input and compute-bound for another, which is
  what the size fit is for.

## Order of work

1. Machine table and the probe's output stored with each run.
2. Roofline classification per site, once the compute and allocation counters exist.
3. Size samples and knees.
4. Amdahl bound from the critical path.
5. ECM and LogP, when loop counters and the synchronisation probe exist.

## Roofline proxy (implemented)

`tools/prof/model.c` (test: `tests/prof/model.sh`) applies the roofline per site, with proxies because no hardware counters
exist here: work is callgrind's self instructions (`sites.self_instructions`), traffic is the bytes the site requested from the
heap (`sites.alloc_bytes`), the peak is the machine record's clock times one instruction per cycle, and the bandwidth is the
machine record's streaming bandwidth. The clock and bandwidth need a profile taken with `NFCXX_PROFILE_BENCH=1`; without them
the tool says so. A site with no heap traffic is reported as compute-bound; its efficiency is therefore against the peak.

Limits: allocated bytes are not memory traffic (a site can stream a buffer it did not allocate, or allocate and not touch it),
one instruction per cycle is an assumption, and a short site's self time is dominated by the profiler's own overhead, so its
efficiency is not meaningful. The output is an estimate to rank sites, not a measurement.
