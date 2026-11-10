# Resumable block argument profiling

Fixed zero- and one-argument resumable block calls now use the frame's existing
GC-visible value slot instead of allocating a packed Array on each suspension.
Multiple arguments and splats retain their Array representation. `Frame#value`
still returns a packed Array for block calls, materializing it once on demand;
repeated reads preserve the same Array object.

On Linux, Ryzen AI MAX+ 395, GCC 15.2, CRuby 3.3.8, and the pinned Optcarrot world:

| Five alternating release runs, 1800 frames | Baseline | Scalar arguments |
| --- | ---: | ---: |
| Median wall time, including startup | 3.785 s | 3.584 s |
| Range | 3.744–3.825 s | 3.510–3.629 s |

This is a 5.3% reduction in local runtime, not a CI threshold. Every run produced
checksum `60838`; the ordinary 180-frame runner produced `59662`. A fresh release
build of baseline `569a71ce` has byte-identical `.text` to the measured baseline.
Both runtime binaries use original CPU dispatch, Fiber PPU, and compiled core
mrblib; compiler-profile and native build time are excluded.

Separate 1800-frame gprof runs (`GPROF=1 GPROF_INLINE=1`) recorded:

| Calls | Baseline | Scalar arguments |
| --- | ---: | ---: |
| `mrb_ary_new_from_values` | 17,535,701 | 185,149 |
| `mrb_obj_alloc` | 19,540,867 | 2,190,315 |
| `incremental_gc` | 6,375 | 1,641 |

Use uninstrumented release binaries for timing; profiling changes call overhead.
The remaining sampled runtime costs include PPU pixel/tile work, GC rooting,
and native resumable frame dispatch.

`resumable_rest_check.rb` also runs the generic scalar-argument cases in
`resumable_scalar_args_cases.rb`: zero versus nil, a single Array argument and
destructuring, multiple arguments, splats, interleaved fibers, full GC, direct
calls from C, and repeated `Frame#value` identity. The existing registered suite
provides the required full-core library and C++ compiler. These cases and the
existing resumable block/argument checks pass with the stress library.
