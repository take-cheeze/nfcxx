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

## Open items

- Confirm the record layout and size buckets (the size-to-cost fit in the design discussion) before writing the binary
  writer.
- Decide whether `perf` is worth installing for this container.
- Add the callgrind cross-check to the test plan once the step counter exists.
