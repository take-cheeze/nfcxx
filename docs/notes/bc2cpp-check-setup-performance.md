# Sharing setup in slow bc2cpp checks

`constant_typing_check.rb` and `owner_set_direct_check.rb` repeatedly load the same
fixture and native inputs while varying compiler switches. They now share that
setup through private forks, preserving all 72 and 60 assertions respectively.
Different source programs and method redefinitions still run independently.
The constant check retains its baseline end-to-end `type_check.rb` invocation.

The owner check reduces compiler setup invocations from ten to seven. Its four
one-switch-off variants fork before inference: emission switches also influence
embedding probes in `CodeGen.new`, so sharing completed inference would be unsafe.
Environment guards reject reads of varied controls before the fork. Plans must
explicitly supply every varied control for every unit, including unset values.
Ordinary owner-only generation keeps its existing later fork boundary.

## Local measurements

Single runs on a Ryzen AI MAX+ 395, Ruby 3.3.8 and GCC 15.2, against compiler base
`83e86cce`, with the CI world pinned at
`616273c39fdf20646c510bd3c17fcf8a1cd627cd` and mruby at
`7389050fd38ece95a5ef91d3c653e6a64f1d9cf7`:

| Check | Before | Shared setup |
| --- | ---: | ---: |
| Constant typing | 171.30 s | 148.32 s |
| Owner direct dispatch | 126.87 s | 76.85 s |

The initial baseline enabled phase timing and parent-process subprocess logging.
An additional uninstrumented owner run with shared emission disabled took
109.58 s; its entire assertion transcript matched the shared run. These are local
single-run observations, not hosted CI wall-time guarantees. There is no change
to CI sharding, concurrency, or the number of tested variants.

## Validation and reproduction

With the pinned world's full library built, set `MRBC` to its host `bin/mrbc`,
`BC2CPP_WORLD_ROOT` to the world checkout, and `BC2CPP_MRUBY_FULL` to the full build's
host directory. Run:

```sh
ruby bc2cpp/scripts/bc2cpp/constant_typing_check.rb
ruby bc2cpp/scripts/bc2cpp/owner_set_direct_check.rb
ruby bc2cpp/scripts/bc2cpp/shared_generation_check.rb
ruby bc2cpp/scripts/bc2cpp/type_check_variants_cases.rb
ruby bc2cpp/scripts/bc2cpp/ir_context_results_check.rb
```

The shared-generation check compares stdout, stderr, declaration headers and
bytecode against fresh compiler invocations, including embedding, constructors
and each registered emission control. Protocol checks cover guarded reads,
incomplete plans, private forks and failure propagation. Complete inference
reports for the two new constant-control variants were also compared with fresh
invocations locally.

Set `BC2CPP_FIXTURE_SHARED_EMISSION=0` to run emission variants separately, or
`BC2CPP_FIXTURE_SHARED_SETUP=0` for inference variants. Separate invocation is
also used automatically for these fixture variants when fork is unavailable or
`RUBYOPT` contains preloads. No Python dependency is introduced.
