# Optcarrot and bc2cpp profiling

Measured against `60452642` on Linux, Ryzen AI MAX+ 395, GCC 15.2,
CRuby 3.3.8 with Prism 1.9.0, RBS 4.2.0 and StackProf 0.2.28.
The world is the pin in `tests/bc2cpp/fetch.sh`.
Runtime GC-root changes are in [PR #828](https://github.com/take-cheeze/nfcxx/pull/828);
the scanner/cache changes and this report are submitted separately.

| Measurement | Before | After |
| --- | ---: | ---: |
| Optcarrot, 1800 frames, median of five alternating release runs | 5.04 s | 4.45 s |
| Compiler, median of four alternating runs, warm scan cache | 6.17 s | 5.54 s |
| Compiler allocated objects, median | 5,005,507 | 4,936,865 |

These are local shared-host measurements, not performance thresholds. Runtime
fell about 12%; compiler time fell about 10%, with 68,642 fewer allocations.
Compiler measurements use `compiler_profile.rb --optcarrot` (the sealed bundle,
with core mrblib scanned as outside Ruby). They exclude native compilation and
workload preparation. Runtime measurements include startup and use the ordinary
sealed build with compiled core mrblib, upstream CPU dispatch, Fiber PPU and LUTs.
All 180-frame checksums were `59662`; all ten 1800-frame checksums were `60838`.

The initial instrumented runtime recorded 21,680,538 calls to `mrb_gc_protect`
over 180 frames. Consecutive roots now reuse the arena's existing top slot.
The check reads the current arena after every restore, so it cannot suppress a
required root using a stale cached pointer. GC regression tests pass with both
ordinary and `MRB_GC_STRESS` libraries, including arena restores and full GC.

StackProf attributed 6% of initial compiler CPU samples to `String#scan`.
Singleton registration tables now use the existing source-digested disk cache;
both cache layers include sibling sources used to resolve parameter owners.
Function-name scans also start at word boundaries to avoid retrying identifier
suffixes. Registration tests cover disk hits, binding and sibling changes,
subsecond timestamps, and unaccounted spellings that must refuse dispatch.
Generated C++ is unchanged apart from temporary source paths and the root helper.
Numeric dataflow and GC remain visible compiler costs.

Validation: native registration (33 checks), singleton owner resolution (5),
scan-cache tests, and GC root tests (24, also under `MRB_GC_STRESS`) pass.
`gc_stress_roots_check.rb` also passes with the stress library.
`native_owner_map_check.rb` has the same seven generated-code assertion failures
on both the baseline and changed trees.

From the repository root, after fetching the world and building its probe mrbc:

```sh
export BC2CPP_WORLD_ROOT="$PWD/build/bc2cpp/rpg-maker-clone"
export MRBC="$BC2CPP_WORLD_ROOT/3rd/mruby/bin/mrbc"
SKIP_UNSUPPORTED=1 ruby bc2cpp/scripts/bc2cpp/compiler_profile.rb \
  --out "$PWD/build/bc2cpp/compiler" --mode cpu --optcarrot \
  > build/bc2cpp/compiler.cpp 2> build/bc2cpp/compiler.log
GPROF=1 GPROF_INLINE=1 GPROF_OUTPUT="$PWD/build/bc2cpp/runtime" \
  ruby bc2cpp/tools/optcarrot_probe/compiled_run.rb 180
ruby bc2cpp/tools/optcarrot_probe/compiled_run.rb 180
```

Use `--mode none` for compiler timing comparisons. Runtime comparisons must use
release binaries without `GPROF`; alternate baseline and changed binaries over
multiple runs. Profiles and raw measurements from this run are in
`build/bc2cpp/` (ignored build artifacts).
