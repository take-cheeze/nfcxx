# Profile data: format and tools

Decision for how profiles are stored, exchanged and read, for the profiling work described in the design discussion
(the nfcast JIT tier, the size-to-cost fit, and profile-guided optimization). Nothing here is implemented yet.

## What was checked (2026-11-26, this container and the repo)

| Item | Found | Notes |
| --- | --- | --- |
| `valgrind`, `callgrind_annotate` | yes | `/usr/bin/valgrind`, `/usr/bin/callgrind_annotate` |
| `gcov` | yes | `/usr/bin/gcov` |
| `perf` | no | not installed |
| `pprof`, `protoc`, `flatc` | no | not installed |
| tcmalloc / gperftools, protobuf, flatbuffers in the repo | no | not linked or vendored anywhere (`3rd/` has edg, mruby, mruby-json, mruby-marshal, mruby-onig-regexp, qbe, quickjs) |
| protobuf in the repo | yes, by hand | `lib/uop/nfcuop_onnx_import.cpp` parses ONNX `ModelProto` with its own wire-format reader; no libprotobuf |
| protobuf in CI / setup | yes, system package | `.github/workflows/ci.yml` installs `protobuf-compiler libprotobuf-dev`; `scripts/setup-onnxsim.sh` builds onnxsim against it |
| SQLite | yes | `scripts/setup-sqlite.sh`, `lib/sqlcache` (`docs/notes/sqlite.md`) |
| apt candidates (not installed) | yes | `libgoogle-perftools-dev` 2.15, `libprotobuf-dev` 3.21.12, `libflatbuffers-dev` 2.0.8 |

## Decisions

1. **Runtime format: our own versioned binary, zero dependencies.** Read and written by the nfcast runtime and by
   `--profile-use`. Little-endian, fixed-width integers, a header with a magic number, a format version, the IR hash (the
   merkle key) and the build flags, then a string table and fixed-size records. A reader rejects a mismatched version or
   hash. Writing it needs no codegen and no library.

2. **Interchange: pprof `profile.proto`, produced by a tool, not by the runtime.** It is the one format that existing
   viewers (`pprof`, and tools that read the same protobuf) already understand, and it carries labels, so the input size
   can be a sample label. The runtime never links protobuf. A converter from the binary format writes the pprof file with a
   small hand-written encoder (the wire format is varints and length-delimited fields, as in the ONNX reader).

3. **gcc-backend PGO: gcov `.gcda` / `.gcno`, as the compiler produces them.** We do not design our own format for this.
   Path B (QBE) has no PGO; its counters, when added, are internal to the IR pass and use the same site keys.

4. **Tools.**
   - *callgrind* (installed) is the deterministic cost cross-check for the step-count proxy. No integration needed: run the
     program under `valgrind --tool=callgrind`, read with `callgrind_annotate`. Slow, so for small inputs only.
   - *gcov* (installed) for coverage-style counts if needed; it is also the PGO format above.
   - *perf* is not installed. It would need `linux-perf` (or the matching package) from apt before it is usable. Not needed
     for the first step.
   - *gperftools / tcmalloc* is available from apt but is **not** adopted. Its CPU profiler writes pprof format, which
     decision 2 already covers, but linking it adds a dependency for a sampling view that callgrind and the interpreter's own
     counters already give. Revisit only if sampling on real hardware is needed.
   - Chrome trace stays a view, produced from the binary file on request.

## Timeline records and the critical path

The per-run profile also keeps a timeline: one record per timed event (a call of a function, a tier compile, a loop run).
A record has these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | u32 | unique within the run |
| `parent` | u32 | enclosing event on the same thread, 0 for none |
| `tid` | u32 | thread that ran the event |
| `ts` | u64 | start time, in nanoseconds from the run's start |
| `dur` | u64 | duration, in nanoseconds |
| `site` | u32 | the site key (string table index of the function plus its ordinal, as above) |
| `waits_for` | u32 | id of the event whose completion released this one, 0 for none |

Nesting on one thread already gives the parent relation, so `parent` is enough there. `waits_for` is the field that
crosses threads: a call that waited for an asynchronous tier compile points at the compile's `id`. Without it, two
overlapping spans cannot be told apart as dependent or independent.

The critical path is then the longest weighted path through these records. Each event finishes at
`ts + dur`, and a waiting event starts after the finish of the event named in `waits_for`. Walk back from the event that
finishes last, following `waits_for` where set and `parent` otherwise.

In Chrome trace output, `waits_for` becomes a flow event (`ph: "s"` on the releasing event, `ph: "f"` on the waiting one).
In the binary profile, it is the `u32` field above.

## Protobuf: making it cheaper

Protobuf is only needed at the interchange boundary (decision 2), so the cheap options are about keeping it out of the hot
path:

- **Keep it off the runtime and the compiler's read path.** Profiles are written in our binary format; protobuf is produced
  only when someone exports to pprof. This is the main saving, and it costs nothing.
- **Hand-written encoder for the pprof subset.** The fields we need (sample type, sample, location, function, string table,
  label) are few. A writer of a few hundred lines avoids the libprotobuf dependency, its code generation and its runtime
  allocations. The ONNX reader in the repo is the precedent.
- **Write only what is used.** Skip unknown-field handling in the writer (we never read pprof back), and dedupe strings
  through the string table, which pprof already expects.
- **Compression is optional.** pprof files are gzip-compressed; gzip is the expensive part for large profiles. Compress
  only at export, and only if the viewer needs it.
- If a reader for pprof is ever needed, reuse the ONNX reader's wire-format code rather than adding libprotobuf.

## FlatBuffers: is it cheaper?

Its advantage is zero-copy reads: fields are read in place from the buffer, with no parse step. That matters for large
messages read often. Profile files here are small aggregates (per-function records, size buckets, feedback summaries), read
once at startup or at compile time, so the parse is unlikely to be the bottleneck. The compile and the program run dominate.

FlatBuffers would also need `flatc` code generation and a library, and it is not a format any existing profiling tool reads,
so we would still need the converter for pprof. Overall it adds more than it saves.

The simplest option that gets the same zero-copy benefit is what decision 1 already is: a fixed-layout binary with an offset
table, read with `memcpy` or `mmap`. Measure the read time on a realistic profile before choosing anything more complex; no
timing has been done yet.

## Allocation counts by site (prototype, format version 1)

Implemented in `lib/prof/nfcxx_prof.c` and `lib/prof/nfcxx_alloc.c`; read by `tools/prof/prof2sql.c`. A chunk with
`tid = 0xFFFFFFFC` holds one thread's allocation counts, written when the thread exits (and for the calling thread at
process exit):

| Field | Type | Meaning |
| --- | --- | --- |
| `tid` | u32 | `0xFFFFFFFC` |
| `count` | u32 | **bytes**, not rows: 28 per row. A reader that does not know the tid skips `count` bytes, as it does for the machine and counter chunks |
| row: `site` | u32 | the site (as in the event records); `0xFFFFFFFF` = outside (no open call), `0xFFFFFFFE` = overflow (the thread had no row left for the site) |
| row: `allocs` | u64 | `malloc`, `calloc` and `realloc` calls made while the site was the innermost open call (`realloc` counts one allocation) |
| row: `bytes` | u64 | bytes requested by those calls (`calloc` counts `n * m`) |
| row: `frees` | u64 | `free` calls, and `realloc` calls with a non-NULL old block, made at the site |

Each field is written in host byte order at offsets 0, 4, 12 and 20 of the 28-byte row (no padding). A site may appear
in several chunks, one per thread, and in one chunk only once per thread; a reader adds the rows of a site together.

Rules:

- A thread's row is chosen by its innermost open call: the enter hook pushes the enclosing row and the exit hook pops it.
  A call that finds no row (the table holds 768 sites already) counts in the overflow row. Before a thread's first event,
  its allocations count in the run's totals only (the `0xFFFFFFFD` chunk), not in any site.
- The wrappers do not allocate and do not lock: each adds to the calling thread's own row.
- If the enter stack cannot grow, the call's allocations count in the enclosing call's row and its exit is not popped.
- Totals (`0xFFFFFFFD`) include everything; the per-site rows do not, by design, cover allocations made before a thread's
  first event, nor those of a thread still running at exit.

`prof2sql` stores the rows in `sites(allocs, alloc_bytes, frees)`; the `(outside)` and `(overflow)` rows have calls 0.

## Open items

- Confirm the record layout and size buckets (the size-to-cost fit in the design discussion) before writing the binary
  writer.
- Decide whether `perf` is worth installing for this container.
- Add the callgrind cross-check to the test plan once the step counter exists.
