# CALL_INLINE measurement

CALL_INLINE (`bc2cpp/tools/bc2cpp/codegen_call_inline.rb`, PR #941) replaces the direct call a statically bound send
already compiles to with the callee's own instructions, when the callee is a small register-only body. This note records
what it did on the two worlds that exercise it. `BC2CPP_INLINE_CALLS=0` is the off switch, `BC2CPP_INLINE_REPORT=<file>`
lists the inlined sites.

World: rpg-maker-clone at the pin in `tests/bc2cpp/fetch.sh` (`b4074c5`). Linux, shared host, so wall-clock times are
noisy; the instruction counts are callgrind's and repeat exactly.

## nfcxx script world: `scripts/pathb-qbe-emit.rb`

Input `tests/pathb-ir/eh_libstdcxx_throw.ir` (3.4 MB). Both builds give the interpreter's stdout, stderr and exit status
on all 920 cases of `tests/bc2cpp/run_pathb_qbe_emit.sh`.

| | Inliner off | Inliner on | Change |
| --- | ---: | ---: | ---: |
| Callgrind instructions | 2,530,011,236 | 2,434,630,776 | -3.8% |
| Wall time, best of 15 interleaved runs | 0.318 s | 0.280 s | -12% |
| Wall time, median of 15 interleaved runs | 0.362 s | 0.359 s | -0.7% |

28 call sites are inlined, all in the tokenizer's per-byte loop: `digit_byte?` (12), `space_byte?` (8), `octal?` (8).
The best-of and median wall times disagree, so the instruction count is the figure to read; the compiled build was
already about 4.3x the interpreter before this.

## optcarrot

267 sites in 18 callees (`Optcarrot::APU::Mixer#reset`, `CPU#current_clock`, `CPU#steal_clocks`, ...). Checksums are
unchanged (`4096` at 6 frames, `59662` at 180). Callgrind over 20 frames: 1,879,264,019 instructions off, 1,861,197,963
on (-1.0%).

## What it does not do

The inlined callees allocate nothing, so no heap object disappears: the gain is the removed call and the callee's
constants visible to the C++ compiler. A callee with a send, a block, a rescue, a constant or an optional argument keeps its
call. Inlining callees that allocate, so that escape analysis could see their temporaries, is not done.

## Reproducing

```sh
# off
BC2CPP_INLINE_CALLS=0 ruby bc2cpp/tools/script_world/compiled_run.rb --script scripts/pathb-qbe-emit.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases <cases> --bench <ir> --chdir .
# on: the same without BC2CPP_INLINE_CALLS (add BC2CPP_INLINE_REPORT=/tmp/sites.txt to list the sites)
```

`compiled_run.rb` leaves the sealed binary at `3rd/mruby/build/scriptcompiled/bin/script` in the world; copy it between
the two runs, then `valgrind --tool=callgrind --callgrind-out-file=/dev/null <binary> <ir>` for the instruction count.
For optcarrot: `ruby bc2cpp/tools/optcarrot_probe/compiled_run.rb 60` from the world root, the binary is
`3rd/mruby/build/optcarrotcompiledreleasegray16384sealed/bin/optcarrot`, run as `<binary> 3rd/optcarrot/examples/Lan_Master.nes 20`.
