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

## Next optimization profile (062f75bc, November 21)

Profiled the frozen 331-file self input on CRuby 4.0.5 with YJIT, using StackProf CPU sampling at 1 ms
and a separate allocation run sampling every 2,000 allocations. These are profiled generation runs,
not measurements of the compiled compiler's execution speed. Local artifacts and reproduction scripts
are under `build/bench/self-profile-current` and `build/bench/profile-self-*.rb` (ignored build outputs).

Generation took 301.7 seconds, including exit handlers: method compilation accounted for 243.9 seconds.
There were 580.2 million allocations and 55.0 seconds of GC. Inclusive call-tree costs below overlap
and must not be added together. The next candidates, in suggested order, are:

1. **Avoid unconditional reaching-definition bit masks.** In `compute_reaching_definitions`, line 274
   computes `1 << here.reg.to_i` before testing `here.op == :EXCEPT`. Allocation samples attribute
   34,979 of 290,014 samples to this expression, approximately 70 million allocations (12.1%).
   Test the opcode first, then the mask; consider skipping the mask when `nil_regs` is zero.
   Validate exception-edge answers and byte-identical generated output. The entire reaching-definitions
   API costs 21.2 seconds CPU inclusive; its compute loop costs 15.2 seconds.
2. **Stop compiling a dynamic regexp per fallback site.** The regexp construction in
   `OutsideOwnerCall#guarded_fallback_line`, line 120, costs 6.1 seconds self CPU.
   Use structured fallback results or exact token matching, preserving the replacement's semantics.
3. **Reuse fallback target decisions.** The outside-owner fallback tree costs 46.0 seconds inclusive,
   with singleton-arm planning around 30.7 seconds. The context-lifted second fallback call repeats
   substantial analysis. Reuse immutable target plans while retaining layout, probe and cycle context;
   emitted C++ strings cannot safely be cached without accounting for those inputs.
4. **Split the giant send emitter and measure native shard costs.** A fresh native build of 16 units
   with eight workers took 114.4 seconds; all units compiled successfully. The main registration unit
   took 49.0 seconds, while shard 3 took 70.2 seconds. Equal source bytes do not imply equal compile cost.
   `CodeGen_compile_send_site_body_impl` occupies 19,235 lines / 910,325 bytes in shard 3.
   In sequential isolated compilations with otherwise identical flags, the original unit took 55.21 seconds;
   replacing only that method body with a nil return took 26.33 seconds, reducing peak RSS from
   1,164,836 to 693,876 KiB. This deliberately incorrect ablation was never linked and establishes
   an upper bound on removable cost, not the speedup from extracting helpers. Smaller helpers and
   finer compile-cost-aware shards need separate validation. Merely ordering units longest-first
   simulates at 112.7 seconds with the observed costs, so scheduling alone has little headroom.

`ShardOutput.scan_lines` still accounts for about 11.3% of allocation samples, but only 3.7 seconds
inclusive CPU after its earlier optimization. Prioritize the reaching-definition mask before further
scanner work. Allocation reductions may reduce GC, but the profile does not establish how much of
the 55 seconds of GC any individual change will recover. No compiler implementation changed in this
profiling pass.

## Avoid irrelevant reaching-definition masks

The EXCEPT nil-path check now tests the opcode and a nonzero nil-register state before constructing
the register mask. This preserves the exception-edge decision while avoiding large Integer allocations
for unrelated instructions and states. Low and high exception-register fixtures check both incoming
paths before RAISEIF and the normal-only path after it.

On 593,352 sampled queries from the frozen self bytecode, including handler policies and refusal
diagnostics, all answers matched the previous guard. Alternating warm runs measured baseline CPU
1.274/1.233 seconds versus 1.171/1.178 seconds; allocations fell from 5.36M to 4.12M. These sampled
instruction queries are a differential workload, not a recording of the compiler's actual query mix.

Replaying the full 331-file generation with the same CPU profiler reduced allocations from 580.18M
to 525.78M (9.4%). The reaching-definition compute loop fell from 15.184 to 9.537 seconds sampled CPU;
Integer shifts fell from 1.966 seconds to 0.001 seconds. Whole profiled generation measured
301.704 to 291.237 seconds, with GC 55.000 to 51.875 seconds. This is one before/after pair with other
phase variation, not a stable throughput guarantee. All 20 C++, header and bytecode artifacts matched
byte-for-byte. Local results are in `build/bench/self-profile-current/mask-optimized`.

## Reuse the outside-owner fallback marker matcher

`OutsideOwnerCall#guarded_fallback_line` used to compile a regexp containing the destination,
receiver and method name at each site, then match it twice when replacing the proven nomethod branch.
It now locates that literal call prefix with `String#index` and matches the trailing marker once
with a shared regexp anchored at the suffix position. A failed candidate continues searching, and
only the first valid branch is replaced. The end offset is saved before emitting the owner call:
mruby-onig may reuse its MatchData region during calls made by that emission.

The current-main baseline (0f9c7bfea, including the mask optimization) invoked this path 384,547 times
on the frozen self input. Replaying its first 20,000 calls in alternating warm CRuby 4/YJIT runs
measured 0.242/0.226 seconds CPU with the original matcher versus 0.063/0.047 seconds with the shared
matcher. Allocations fell from about 625K to 316K. The fixture isolates replacement by using a fixed
owner-call result; these are matcher timings, not whole-generation or compiled-compiler throughput.
All results matched on CRuby and mruby-onig. Another 576 comparisons cover multiple candidates,
failed matches, argument lists, regexp metacharacters, UTF-8 offsets and match-region reuse.
These comparisons run inside the already-registered `helper_owner_call_check.rb`; adding a separate
check requires a matching entry in the pinned world's check policy.

Full CPU-profiled generation with the same bounded capture hook in both runs measured 336.644 versus
322.041 seconds. This method's self CPU fell from 7.021 to 0.413 seconds; its inclusive tree fell
from 53.173 to 44.310 seconds. Allocations fell from 528.25M to 523.31M and GC from 58.461 to
54.634 seconds. All 20 C++, header and bytecode artifacts matched byte-for-byte. The whole-generation
times are one before/after pair with profiling/capture overhead and other phase variation, not a
throughput guarantee. These runs use a newer generator than the earlier mask measurements and must
not be used to infer a cumulative speedup. Local artifacts are under
`build/bench/self-profile-current/fallback-{baseline,optimized}`. Helper owner calls, direct owner calls,
static owner dispatch and method-missing arms also pass their generated-program runtime checks.

## Skip empty prepend traversals

`prepended_override?` now returns before allocating a Set or duplicating a work list when the owner
has no recorded prepended modules. Unknown owners still refuse first. Nonempty inputs retain the
same normalization, cycle handling, nested included/prepended walks and registry lookup; no decision
cache or context-dependent result is introduced.

A capture at 89a710184 recorded 9,883,208 queries across 5,182 distinct analysis/owner/name combinations;
9,863,575 queries (99.8%) had an empty prepend list. Replaying those combinations with their recorded
frequencies on CRuby 4/YJIT preserved every answer. Alternating warm baseline CPU was 2.606/2.568 seconds
versus 0.627/0.627 seconds; allocations fell from 30.58M to 0.99M. The replay reconstructs the captured
analysis tables and measures this helper, not whole-compiler throughput.

The existing registered prepend check now covers absent and empty lists, unknown owners, nested modules,
cycles, unrelated included modules and frozen inputs, as well as compiled-program dispatch parity.
The optimized helper itself also compiles and matches eight interpreted answers in an isolated native
fixture. That fixture must include the full-core Set native-source metadata: the canonical world used
by ordinary fixtures does not include mruby-set, while the full-core library used for this experiment does.

Full self generation with identical CPU profiling/query-capture hooks allocated 521.03M versus 491.65M
objects (5.6% fewer). The helper's inclusive sampled CPU fell from 4.457 to 0.954 seconds; GC measured
48.900 versus 46.681 seconds. Whole wall time was 274.484 versus 279.600 seconds, so this pair does not
establish a whole-generation speedup. All 20 C++, header and bytecode artifacts matched byte-for-byte.
Local captures and metrics are under `build/bench/self-profile-current/prepend-{baseline,optimized}`;
the weighted query results are `prepend-query-results.json` in that parent directory.

## Check the constant path before scanning branch prefixes

`straight_line_constant_name` now finds the receiver's textual constant path before collecting preceding
branch edges. Ordinary receivers return nil immediately. A constant candidate still needs the same
resolved-target, bypass-edge and reaching-definition proofs, including JMPUW and handler edges.

At 494253a9a the frozen self input made 946,815 queries across 44,721 distinct label/index/register/policy
combinations. Only 106,873 queries (11.3%) had a constant path requiring the branch scan. Both full runs
captured identical query lists and frequencies. Weighted warm CRuby 4/YJIT replays preserved every answer:
baseline CPU was 7.205/6.983 seconds versus 1.874/2.026 seconds, with allocations 22.69M versus 5.99M.
Alias ireps share their source instructions; the replay uses those original bodies for the six alias labels.

Full CPU-profiled generation with the same capture hook allocated 495.21M versus 478.61M objects.
The branch collector's inclusive CPU fell from 11.320 to 1.660 seconds, and the constant-name helper
from 13.669 to 4.170 seconds. Whole generation measured 327.430 versus 317.774 seconds. The two runs
overlapped on separate processes, and these are single profiled observations rather than a stable
throughput guarantee. All 20 C++, header and bytecode artifacts matched byte-for-byte.

The registered constant-proofs check passes 49 cases, including parameter receivers, forward bypasses,
loop back-edges, rescue ranges, unresolved jumps and JMPUW bypasses. Class-object argument/constructor
and singleton-owner checks pass; Array.new block behavior matches interpreted execution (73 output lines).
The pinned-world registry audit has zero unclassified checks. Local artifacts are under
`build/bench/self-profile-current/constant-path-{baseline,optimized}`, with the weighted replay in
`constant-path-query-results.json` in that parent directory.

## Guard shard-scanner delimiter slices

The full lexical path in `ShardOutput.scan_lines` now checks the current character before slicing for
`/*`, `//`, `*/` or a raw-string terminator (which always starts with `)`). This preserves character
indexing and avoids temporary substrings when the first character cannot match. Carried comments,
raw strings, quoted strings and the existing plain-line fast path keep their behavior.

On the same 47,670,380-byte raw compiler capture used by the earlier shard measurements, all 933,143
scanner records matched. Alternating complete 16-shard rewrites on CRuby 4/YJIT measured:

| Layout | Baseline wall | Updated wall | Baseline / updated allocations |
| --- | --- | --- | --- |
| Default owner grouping | 5.75 / 5.91 s | 5.41 / 5.29 s | 53.86M / 37.61M |
| Oversized-owner splitting | 5.97 / 5.93 s | 5.29 / 5.20 s | 53.86M / 37.62M |

Every main/shard file hash and tier assignment matched in every run. This is about 30% fewer allocations
in the measured sharding phase, not a whole self-compilation speedup claim. The existing registered
shard check passes 55 cases, including linked generated-code/runtime parity and new UTF-8, partial
delimiter, empty raw-tag and division/comment cases. The scanner also produces identical records on
33,294 prelude/edge-case lines in mruby-onig. The current pinned-world registry audit passes.
Local measurements and file hashes are in `build/bench/shard-delimiters/results.json`.

## Raise the self-build probe depth to 16

Probe counts on the current-main self input (CRuby 4 + YJIT, `BC2CPP_PROBE_DEPTH=4`
as the self build sets) showed 242,315 `probe_clean` calls for 5,305 distinct
labels: 132,114 calls (64%) refused at the depth limit, and each refusal poisoned
its whole tree's memoization under the global guard-generation counter, so every
outermost probe recompiled its reachable set (~46 probes per label, 8,257
outermost probes).

Depth 8 is slower than 4 (deeper per-probe compiles without enough memoization
payoff: 233.7s vs 205.9s compile-all). Depth 16 and 32 both plateau at ~98s.
The self build now defaults to 16, far below the interpreter-stack concern that
motivates the limit (self-generation always runs on CRuby 4 + YJIT):

| Depth | Compile all methods | Wall | Allocations |
| --- | ---: | ---: | ---: |
| 4 | 205.9s | 257.5s | 384.6M |
| 8 | 233.7s | 282.3s | 309.7M |
| 16 | 97.4s | 138.6s | 234.5M |
| 32 | 98.2s | 139.7s | (same input) |

Single-pair alternating runs, not a statistical guarantee; depth 4 vs 16 was
also confirmed end to end (261.9s vs 120.5s compile-all on the newer base,
6,139 translated methods). The depth-16 output devirtualizes slightly more
(25,082 vs 25,086 `_impl`, 45 fewer dispatches); headers, entry and bytecode
are identical. A full self pipeline at 16 (bootstrap, generation, native
build) plus the `runner_generation` C++/bytecode parity and runtime-behavior
check passes.

## Byte-oriented identifier scans in the shard pipeline

Identifier scans (`String#scan` with a capture group) allocated a MatchData
per identifier plus result arrays: on the 82 MB current-main self-generation
capture the shard phase spent 82.0M allocations, 46.8M in `ShardColocate`
(index + scan) and 35.2M in `ShardOutput.rewrite` alone. `each_identifier`
and `each_delimited_identifier` (in `shard_output.rb`) scan bytes directly on
ASCII-only lines — byte and character offsets coincide there — and fall back
to the original expressions otherwise. The byte loops replicate their
expression's edge rules exactly, including `$` handling: the delimited form
matches `ShardColocate::IDENT` (no `$` start, no adjacent word char or `$`),
the plain form matches `ShardOutput::IDENT`. Both forms were verified
identifier-for-identifier and offset-for-offset against the regex on all
1,560,268 capture lines (zero non-ASCII lines) plus the check fixtures'
non-ASCII cases. The rewrite prelude/shard scans, the shared-prelude
fixpoint (which also memoizes each body's identifier set instead of
rescanning it every round), and the colocate index/scan/outside-names scans
all use them; the shared-prelude per-body scan keeps its own `word`-boundary
expression, and the join for colocate `ids` is unchanged.

Per-phase allocations on the identical 82 MB input:

| Phase | Before | After |
| --- | ---: | ---: |
| colocate index | 21.64M | 16.49M |
| colocate scan | 23.33M | 5.36M |
| rewrite | 35.17M | 35.03M |
| shared prelude | 9.22M | 9.08M |
| shard phase total | 82.02M | 58.26M (-29%) |

Full-generation A/B at the depth-16 default: 236.6M vs 228.4M total
allocations; every main/shard/header/entry/bytecode artifact is
byte-identical. The registered shard check passes, including the non-ASCII
identifier, prelude/edge-case, colocate linkage and runtime-parity cases.

## Profile after dense traversal and primitive-send extraction (November 26)

Profiled PR #1757 at `d3a1ddd08`, with world `fd3221cccc08d3d7fdf38ed37892fe1d81542dba`,
on CRuby 4.0.5 + YJIT. The normal self-build baked the current source graph: 395 Ruby inputs and
6,395 translated methods. StackProf sampled CPU at 1 ms in the generation subprocess, including
the output passes run by exit handlers. A separate replay sampled every 2,000 allocations on the
same inputs. All 20 C++, header and bytecode artifacts match between the two runs.

| Measurement | CPU profile | Allocation profile |
| --- | ---: | ---: |
| Whole generation wall time, including exit handlers | 190.06 s | 211.55 s |
| Process user + system CPU | 189.89 s | 210.19 s |
| Allocations | 261.45M | 245.34M |
| GC time | 49.28 s | 51.82 s |

The first run used the existing disk cache without clearing it; the replay could reuse entries
the first run populated. Native compilation and unrelated host work overlapped parts of these runs.
These are diagnostic observations with different sampling overhead and cache state, not an A/B
speedup measurement. The CPU sample miss rate was 2.68%; GC accounted for 26.7% of CPU samples.

The CPU-profiled driver's logged phases took 140.03 s through diagnostics: method compilation
68.93 s, mrbc_rb/irep decoding/registry 17.52 s, global facts and annotations 17.04 s, final
return/fixnum proofs and ivars 11.21 s, C++ emission and symbol rewrite 10.07 s. The remaining
elapsed time includes exit-handler output passes and their GC. It must not be attributed to
sharding alone.

Next candidates, based on sampled call trees (inclusive costs overlap):

1. **KeepSummary's generated-text scans.** `KeepSummary.rewrite` accounts for 12.98 s sampled CPU
   and approximately 25.20M sampled allocations. `Unit#own_effects` accounts for 6.28 s, including
   the call scan and `store_kind`'s assignment scans. Investigate avoiding repeated regex scans
   of statements and carrying immutable parsed facts between summary consumers. Preserve the
   conservative treatment of unknown calls and pointer/member stores; output parity is required.
2. **Shard and shared-prelude identifier allocation.** The sharding exit handler accounts for
   16.33 s sampled CPU and approximately 49.82M allocations. Its rewrite takes 10.21 s and
   colocate 6.02 s. `shared_prelude_items` still scans the whole code with a capturing regex;
   `each_delimited_identifier` accounts for approximately 9.87M allocations itself. Investigate
   reusing identifier sets and avoiding fresh identifier slices while preserving each scanner's
   different boundary rules. The earlier ASCII and delimiter improvements are already present.
3. **YieldReach's received-block fixed point.** `compute_received` takes 5.13 s sampled CPU;
   4.92 s is in `Set#merge`. Consider a changed-node worklist or delta propagation instead of
   repeatedly merging unchanged sets across all forwarding edges. Allocation samples attribute
   only about 1.00M objects to this subtree: this is primarily a CPU candidate.
4. **mrbc_rb annotation construction.** `Annotations.canonical` accounts for approximately
   11.50M inclusive allocations, although only 1.58 s sampled CPU. Investigate sharing immutable
   annotation values if later profiles confirm allocation pressure. Keep the linked-source scan
   on the default Ruby emitter; reverting it to native mrbc would reintroduce the parser failure.

Reaching-definition queries now account for 5.53 s sampled CPU (the compute loop 3.78 s), versus
the larger text passes above. The base guarded-fallback method accounts for only 0.57 s inclusive;
its prepend wrappers overlap, and none exceeded 1.16 s. The old fallback-plan and dataflow rankings
should therefore not be carried forward unchanged.

A separate no-object-cache native compilation of all 16 units with eight workers succeeds:
74.89 s wall, 554.38 s aggregate user + system CPU. The slowest units are shards 13 (42.34 s),
10 (41.65 s), and 14 (40.53 s), each about 4.82 MB; registration takes 36.57 s. The nfcxx timing
log records 546.47 s across its combined front-end/C-compile/link spans. It does not separate
EDG from backend C compilation, so these results do not justify tuning either component alone.
An initial attempt with GCC's `-ftime-report` was rejected by the frontend; the successful run
omits that flag. These measurements are not directly comparable to the earlier frozen-input build.

The rebuilt compiled compiler also passes a 96-method fixture's C++ and bytecode parity check,
executing 2,613,394 translated-method calls. Its perf-sampled run takes 20.37 s wall and 20.33 s
user + system CPU. Self samples include `mrb_vm_exec` 25.5%, `get_args_v` 6.1%,
`funcall_with_block_m` 5.7%, and Oniguruma `match_at` 3.7%; `onig_byte_to_char` is now 1.4%.
This is a small compiled-compiler workload, not a full 395-input self-hosted generation profile.
It suggests investigating interpreted work and argument/block dispatch next for compiled runtime
performance, rather than assuming the earlier regexp byte-offset bottleneck still dominates.
`runner_generation.rb` additionally passes native-oracle verification, generated C++/bytecode
parity and linked runtime behavior, with 932,521 translated-method calls.

Local ignored artifacts, input hashes, profiling drivers and reports are under
`build/bench/profile-1757` and `build/bench/profile-1757-*.rb`. The CPU and allocation dumps,
native per-unit results and timing log, perf capture, artifact comparison, and runner log are
retained there; no Python was used.
