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
