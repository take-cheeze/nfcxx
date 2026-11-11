# Inline arena roots

The generated `bc2cpp_root` now appends directly to an arena that has room,
matching `mrb_gc_protect` in the pinned mruby fork. Persistent red objects
need no root. Arena growth and fixed-arena overflow still call
`mrb_gc_protect`; libraries without `MRB_GC_RED` retain the API path. The
consecutive-root check reads the current arena after every restore.

An 1800-frame gprof run of the baseline recorded 150,355,558 calls to
`mrb_gc_protect`. Avoiding the call for an ordinary arena append benefits
all compiled methods, without changing the Optcarrot sources or dispatch.

Local measurements against `f616df10`, Linux, Ryzen AI MAX+ 395, GCC 15.2,
Ruby 3.3.8, and the pinned Optcarrot world:

| Median of five alternating release runs | Baseline | Inline arena roots |
| --- | ---: | ---: |
| 1800 frames, wall time including startup | 3.702 s | 3.633 s |
| Hot-path frames per second | 495.0 | 505.7 |

Hot-path FPS is `(1800 - 180) / (time(1800) - time(180))`, using a separate
180-frame run for each measurement. This is about 2.2% higher FPS on a shared
host, not a performance threshold. All long runs produced checksum `60838`;
all short runs produced `59662`. The baseline was freshly rebuilt from the
original sources. Both builds use upstream CPU dispatch,
Fiber PPU and compiled core mrblib. Native compilation and compiler generation
are excluded; this change improves generated runtime code, not compiler latency.

`gc_root_check.rb` passes all 24 checks with both ordinary and `MRB_GC_STRESS`
libraries. Its arena scenario now also checks red objects and arena growth:
root more distinct strings than the original capacity, remove their container's
references, force a full collection, then read every retained string. Existing
checks cover duplicate roots, arena restores, and values unlinked from
containers. `gc_stress_roots_check.rb` also passes with the stress library,
as does the ordinary 180-frame comparative runner.

Reproduce the release build with:

```sh
export BC2CPP_WORLD_ROOT="$PWD/build/bc2cpp/rpg-maker-clone"
ruby bc2cpp/tools/optcarrot_probe/compiled_run.rb 180
```

Preserve the baseline and changed sealed binaries and alternate direct runs of
each binary with `3rd/optcarrot/examples/Lan_Master.nes 1800` and `180`. Use
release binaries without `GPROF`. Local raw timings are in
`build/bc2cpp/perf-fresh-runtime-ab.json`.
