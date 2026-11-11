# Compile-time tracing

`nfcxx --trace=FILE` (or `NFCXX_TRACE=FILE`) writes a Chrome trace-event JSON file. Open it in
[ui.perfetto.dev](https://ui.perfetto.dev) with "Open trace file". The times are wall-clock.

## What is timed

| Span | Category | Where |
| --- | --- | --- |
| `nfcxx` | driver | the whole run |
| `host C++ headers` | driver | querying the host g++ for its include directories |
| `cpfe --emit-c (front end)` | frontend | `--emit-c` only: the EDG front end alone |
| `eccp (front end, C compile, link)` | eccp | the whole compile, including EDG's C compile and the link |
| `cc -E (preprocess)`, `qbe-prep (rewrite for cproc)`, `cproc (C to QBE IL)`, `qbe (IL to assembly)`, `weak-symbols`, `cc -c (assemble)` | qbe-backend | each step of `scripts/qbe-cc`, once per object file |
| `C input: <file>` | driver | one per `.c` input (they skip EDG; `docs/notes/realworld.md`, "C inputs") |
| `cuda-rewrite (host copy): F.cu`, `cuda-rewrite (device unit): F.cu` | cuda | the rewriter's two passes over a `.cu` input |
| `pathb-dump --ir (device front end): F.cu`, `pathb-ptx-emit --emit: F.cu (N groups)`, `ptxas: F.cu` | cuda | the device image: EDG to IR, IR to PTX modules, PTX to cubins (none on a device cache hit, see `docs/notes/cxx-driver.md`) |
| `pathb-ptx-emit --embed: F.cu` | cuda | the registration tail of the host copy |

EDG's front end is not timed on its own when compiling. Its time is inside the `eccp` span together
with the C compile and link, and the gcc backend's C compile is also inside that span. The QBE steps
are timed separately, so for the QBE backend the front end plus link is roughly the `eccp` span
minus the `qbe-backend` spans. Splitting EDG's own passes would need changes inside EDG.

## A whole build: `NFCXX_TIME_LOG`

`NFCXX_TIME_LOG=FILE` appends every span to FILE as one text line, `SECONDS<Tab>CATEGORY<Tab>SPAN<Tab>SOURCE`, without
writing a trace file. The compiles of a parallel build (one driver per source) share the file, and the scripts a driver
runs (the QBE steps) log under its source too. Rank the stages, or sum them per stage:

    NFCXX_TIME_LOG=$PWD/time.log tests/llamacpp/cuda/build.sh
    sort -rn time.log | head
    awk -F'\t' '{ split($3, a, ":"); t[a[1]] += $1 } END { for (k in t) printf "%8.1f %s\n", t[k], k }' time.log | sort -rn

## Format and limits

- The file is a JSON array of complete (`"ph":"X"`) events, plus one instant event `trace_end`.
  Each process appends its own events, so the file is only complete once the driver exits.
- Clock: `date +%s%N` (GNU date). This works on Linux only; on macOS the times would be wrong.
- Each span starts a `date` process, so tracing adds about 1 ms per span.
- Failed steps record no span. The `nfcxx` span is still written, because the driver records it on exit.

## Test

`tests/trace/run.sh` checks the output for both backends: the file is valid JSON, every span has a
non-negative duration, the expected spans are present, and the program's exit code still matches
its `EXPECT`; and the time log's lines (four fields, the QBE steps under the source). CI runs it.
`tests/cuda/run.sh` (local, needs CUDA) checks the `.cu` stages in the time log.
