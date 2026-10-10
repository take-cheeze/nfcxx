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
| `cc -E (preprocess)`, `qbe-prep.rb (mruby, rewrite for cproc)`, `cproc (C to QBE IL)`, `qbe (IL to assembly)`, `weak-symbols.rb (mruby)`, `cc -c (assemble)` | qbe-backend | each step of `scripts/qbe-cc`, once per object file |
| `C input: <file>` | driver | one per `.c` input (they skip EDG; `docs/notes/realworld.md`, "C inputs") |

EDG's front end is not timed on its own when compiling. Its time is inside the `eccp` span together
with the C compile and link, and the gcc backend's C compile is also inside that span. The QBE steps
are timed separately, so for the QBE backend the front end plus link is roughly the `eccp` span
minus the `qbe-backend` spans. Splitting EDG's own passes would need changes inside EDG.

## Format and limits

- The file is a JSON array of complete (`"ph":"X"`) events, plus one instant event `trace_end`.
  Each process appends its own events, so the file is only complete once the driver exits.
- Clock: `date +%s%N` (GNU date). This works on Linux only; on macOS the times would be wrong.
- Each span starts a `date` process, so tracing adds about 1 ms per span.
- Failed steps record no span. The `nfcxx` span is still written, because the driver records it on exit.

## Test

`tests/trace/run.sh` checks the output for both backends: the file is valid JSON, every span has a
non-negative duration, the expected spans are present, and the program's exit code still matches
its `EXPECT`. CI runs it.
