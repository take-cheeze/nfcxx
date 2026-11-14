# bc2cpp shard tiers (first step of a tiered build)

Idea from makepad/relax (its `#[relax(O3)]` per-function level and its interpreter-then-O3 tiers): not every generated
method needs the optimizer's full effort. bc2cpp already splits a gem's output into `BC2CPP_SHARDS` translation units
(`tools/bc2cpp/shard_output.rb`, docs/bc2cpp-shards.md). This step lets the caller say which shards compile at a lower
level, and which owners must stay at the build's own level.

- `BC2CPP_SHARD_COLD_OPT=O1` (also O0, O2, O3, Os, Oz): every non-empty shard other than the main file starts with
  `#pragma GCC optimize ("O1")`. The pragma precedes the include of the main file, so it covers the prelude and the
  methods of that translation unit. GCC only: clang ignores it.
- `BC2CPP_SHARD_HOT_OWNERS=<file>`: one owner per line (`#` starts a comment). Those owners' methods all go to the main
  file, which keeps the build's flags. Read only when a tier is set, so the default split is unchanged.
- Placement: hot owners first into shard 0, then the cold owners spread over the lightest shards, as before.

Checked: the `-- tiers` section of `scripts/bc2cpp/shard_output_check.rb` (11 checks; folded in because the CI check registry requires every `*_check.rb` to be classified, and that classification lives in the rpg-maker-clone world). Without a tier there is no pragma and the hot list is
ignored; with a tier, the pragma heads every non-empty shard but the main file, hot owners are defined only in the main
file, and a split program compiles warning-free at `-O2 -Werror`, links, and prints what the untiered split prints.
`scripts/bc2cpp/shard_output_check.rb` passes 26 checks here (15 existing, 11 tier); its generated-code part needs a host mrbc.

Not done, and why:
- No profile yet. The hot list is the caller's. Producing it from a gprof or prof_stream run of the optcarrot world is
  the next step.
- No measurement of compile time or run time on the optcarrot world. Its runner needs Ruby 4.0 (the probe's README and
  `tests/bc2cpp/run_optcarrot.sh` skip without it), and the local host has Ruby 3.3.6.
- rpg-maker-clone's rake build (`tools/bc2cpp/compiled_gems.rb`) does not change. The pragma carries the level inside the
  generated file, so the rake rules need no per-object flags.
