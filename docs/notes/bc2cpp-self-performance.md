# Self-compilation performance measurements

Measured November 20, 2026 on Linux x86-64 with CRuby 4.0.5 + YJIT, nfcxx's gcc backend, `-O2`,
16 shards and eight native-build workers. These are single-host development measurements, not statistical
performance guarantees.

## Repeated cleanliness probes

On the fixed 314-file self-AOT source snapshot from `826988d35`, guarded root-probe reuse with immutable facts
reduced complete Ruby generation from **361.16 to 238.83 seconds**. Method-compilation calls fell from
85,792 to 45,164, while all 4,387 translated methods remained present. Bytecode was identical. All 17,144
generated C++ function definitions also matched after normalizing generated helper identifiers; unused
declaration ordering and helper numbering differed.

An answer that depends on a cycle or depth guard cannot be cached for every nested context. The new cache
reuses such answers only at an empty probe stack with the same unconditional facts, and preserves the guard
signal on a hit. Facts are frozen snapshots: adding or changing an unconditional answer creates a new version,
so context checks use object identity instead of comparing the entire hash. An unchanged answer retains its
version. Layout-dependent probe invalidation also clears guarded root answers.

`probe_root_cache_probe.rb` checks nested and depth-limited contexts, fact additions/replacements/deletions,
explicit invalidation, guard propagation, cache-off behavior and rejection of untracked in-place mutations.

## Native build balance

Using the exact same captured C++ before and after re-sharding:

| Measurement | Owner grouping | Oversized-owner splitting |
| --- | ---: | ---: |
| Cold native build | 213.47 s | 131.23 s |
| Largest translation-unit compile | 192.63 s | 43.89 s |
| Largest compiler-process RSS | 4.76 GiB | 0.97 GiB |
| Aggregate user CPU | 664.36 s | 668.78 s |

The improvement comes from removing the long single-worker tail, rather than reducing total compiler CPU.
Three alternating quiet-host runs on a 96-method compiler input had median runtimes of 25.29 seconds before
and 25.65 seconds after, with identical output. This smoke measurement does not establish a small runtime
performance difference.

Splitting is enabled automatically for self builds through `BC2CPP_SHARD_SPLIT_OWNERS=1`. Ordinary builds retain
their owner grouping by default, including Optcarrot's default four-shard layout. Explicit hot owners remain
pinned. See [owner sharding](bc2cpp-owner-shards.md) for linkage and state-sharing checks.

## Shard rewriting

The C++ scanner now counts braces directly on lines without comments or quoted literals, provided it is not
inside a multiline comment or raw string. Other lines retain the full lexical scanner. This avoids allocating
one-character Strings for most generated statements; the scanner's callers only read the retained line text.

On the same frozen 46 MiB raw compiler C++ capture, complete 16-shard rewriting under CRuby 4 + YJIT changed
as follows. These exit-handler times are separate from the logged generation phases below.

| Layout | Before | Updated | Allocated objects before / updated |
| --- | ---: | ---: | ---: |
| Default owner grouping | 16.66 s | 6.32 s | 242.19 M / 53.83 M |
| Oversized-owner splitting | 16.50 s | 6.60 s | 242.19 M / 53.83 M |

Every output file was byte-identical in both layouts. All per-line scanner records also matched on the current
self image's main C++ and 15 shards. The shard checks cover multiline raw strings/comments crossing ordinary
lines, quoted braces, division, shared mutable/constant state, linked generated code and runtime parity.

## Current-source self generation

The current 324-file compiler graph includes the new cache and lookup checks:

| Logged generation phase | Baseline | Updated |
| --- | ---: | ---: |
| Compile all methods | 346.022 s | 113.496 s |
| All logged phases | 410.079 s | 176.520 s |

The lookup check also avoids probing a class body that a prepended method overrides: an exact class guard
cannot bypass that prepend. Its regression checks both dispatch precedence and interpreted/compiled behavior,
and reproduces the former bad arm when the check is disabled.

These generation totals exclude startup and exit-handler shard splitting. Since self compilation consumes
the compiler's own source, this comparison includes the small source changes themselves. The fixed-input
measurements above isolate probe reuse and native layout separately.

Baseline generation already includes the timing-scope extraction that repairs mrbc's local-variable limit.
That earlier baseline still could not complete its native build because direct optional-block calls omitted
keyword ABI slots. A whole-pipeline before/after speedup is therefore not claimed.

The final current-source image completes the CRuby 4 + YJIT / nfcxx build, installs 4,943 translated methods and
retains 396 VM fallbacks. Strict fresh C++/bytecode parity and generated-program runtime checks pass, including
binary strings and exceptions. The compiled compiler also matches CRuby's main C++, shard C++ and bytecode
with oversized-owner splitting both disabled and enabled. This verifies the default owner layout as well as
the self-build layout.

## Optimized native debug information

The runner's GCC toolchain supplied `-g` even with `BC2CPP_RUNNER_OPT=1`. Optimized runner builds now omit
that default for C and C++, retaining `-O2` and exception support. Ordinary debug builds keep `-g3 -O0`
and `MRB_DEBUG`; explicit `CFLAGS`/`CXXFLAGS` retain the caller's debug options (including `-g3`, `-ggdb`
and `-g0`). For example, `CXXFLAGS='-g -Wall -Wundef'` restores native debug information in an optimized build.

A fixed captured compiler shard built through the nfcxx GCC backend had identical disassembly and identical
text/data/BSS sizes with and without `-g`. The object shrank from 23,592,160 to 3,341,528 bytes; peak compiler
RSS fell from about 847 to 609 MiB. A sequential repeat measured 42.52 to 24.82 seconds wall time and 41.20
to 23.98 seconds user CPU. An earlier pair measured 31.83 to 23.19 seconds (those processes briefly overlapped).
These are individual shard measurements, not a whole-build speedup claim. The principal saving is skipping
DWARF generation for the lowered compiler bodies, without changing their executable instructions.

## Binary symbol-cache scans

SymbolCache already scans a binary view of generated C++, but its regular expressions still requested UTF-8
offsets from mruby-onig. Byte-oriented patterns avoid converting each match position by rescanning its prefix.
Two alternating pairs of 100 rewrites of a 200-send function measured 0.856/0.861 seconds before and
0.749/0.744 seconds after in the mruby runtime. UTF-8 comments, receivers and method literals retain their
bytes and the original result encoding in the regression checks.

This is a local helper improvement: a warm 96-method native compiler smoke measured 6.04 seconds before and
6.06/6.07 seconds after, so it does not establish a whole-compiler runtime gain. The smoke's generated C++ and
bytecode hashes matched in every run. The initial cold scan-cache run is excluded from that warm comparison.

## Indexed instance-variable writes

A subsequent StackProf wall profile attributed 22.0 seconds (7.8% of samples) to
`YieldReach#compute_proc_free_ivar`. It rescanned every instruction in every irep for each queried ivar name.
A lazy index now records SETIV sites once per analysis, preserving their original order; proofs still visit
every matching write and retain the same cycle and dynamic-write refusals.

On the same captured self-compilation input, with StackProf enabled in both runs, logged generation phases
fell from 248.269 to 213.518 seconds (14%). Global facts and annotations fell from 34.204 to 10.768 seconds;
method compilation fell from 180.798 to 169.651 seconds. Whole process wall time, including exit handlers
and profile serialization, fell from 291.74 to 252.21 seconds. These are one paired profiled measurement,
not an unprofiled throughput guarantee. All 20 generated C++, header and bytecode artifacts were byte-identical.

Existing IR block checks cover writes across classes, unrelated ivars, chained reads, nested Proc writes,
cycles, unwritten ivars and unlisted dynamic writes.

## Native namespace scopes

A 96-method compiled-compiler profile attributed 13.0% of sampled CPU to `onig_byte_to_char`, largely beneath
`UniqueClassNames.native_module_binding`. Each namespace query scanned function headers again from the start
of its C/C++ source. The namespace and constant-binding analyses now share a per-analysis header index, use
binary search for the enclosing function and retain its body boundary. Match positions and captures are saved
as values, avoiding mruby-onig's reused scan region; UTF-8 character offsets keep their existing meaning.

On 20 real namespace queries over the fixture's 79 native sources, alternating baseline/indexed runs measured
0.376/0.353 versus 0.038/0.043 seconds on CRuby 4/YJIT, and 0.631/0.619 versus 0.127/0.126 seconds in the
mruby interpreter. Every answer matched. The interpreter baseline copies retained MatchData to repair the
same scan-region compatibility issue, so this compares two correct implementations; it is not a whole-compiler
runtime speedup claim. Scope checks also cover UTF-8 prefixes, interleaved queries into different functions,
out-of-function positions and both definition-only and lookup policies sharing one header index.

## Rescue-aware writer walks

Writer queries with arbitrary barrier predicates still inspect every instruction. Three hot callers whose
predicates only reject RESCUE can now declare that opcode: the walk merges leading-register writer positions
with RESCUE positions, including its second-register write, and skips unrelated instructions.

On 396,194 queries captured from real self-compilation bytecode, alternating warm primitive measurements fell
from about 0.559 to 0.241 seconds CPU, with identical answers. The differential fixture covers 29,952 combinations
of barriers, MOVE chains and budgets, skipped opcodes, missing registers, exhausted callbacks and traversal order.
All 20 generated artifacts also match byte-for-byte on the frozen self-compilation graph. The full replays ran
under different external load and do not establish a whole-generation speedup. The walker remains a VM fallback
in the current self image; this change improves its algorithm rather than changing its translation status.
