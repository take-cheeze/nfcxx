# bc2cpp shard tiers (first step of a tiered build)

Idea from makepad/relax (its `#[relax(O3)]` per-function level and its interpreter-then-O3 tiers): not every generated
method needs the optimizer's full effort. bc2cpp already splits a gem's output into `BC2CPP_SHARDS` translation units
(`tools/bc2cpp/shard_output.rb`, docs/bc2cpp-shards.md). This step lets the caller say which shards compile at a lower
level, and which owners must stay at the build's own level.

- `--shard-cold-opt=O1` (also O0, O2, O3, Os, Oz): every non-empty shard other than the main file starts with
  `#pragma GCC optimize ("O1")`. The pragma precedes the include of the main file, so it covers the prelude and the
  methods of that translation unit. GCC only: clang ignores it.
- `--shard-hot-owners=<file>`: one owner per line (`#` starts a comment). Those owners' methods all go to the main
  file, which keeps the build's flags. Read only when a tier is set, so the default split is unchanged.
- Placement: hot owners first into shard 0, then the cold owners spread over the lightest shards, as before.

Set on the bc2cpp command line, not by environment variables: `take_argv!` takes both flags out of argv in the main
block (`tools/bc2cpp/bc2cpp.rb`), and a refused combination aborts. `--shard-hot-owners` without `--shard-cold-opt`
is an error, and so is a level other than O0, O1, O2, O3, Os or Oz. The same level and owners reach
`ShardOutput.split` as arguments, so the split has no hidden state.

Checked: the `-- tiers` section of `scripts/bc2cpp/shard_output_check.rb` (14 checks): flags parsed out of argv and
refused when wrong; without a tier there is no pragma and the hot owners are ignored; with a tier the pragma heads every
non-empty shard but the main file, hot owners are defined only in the main file, and a split program compiles
warning-free at `-O2 -Werror`, links, and prints what the untiered split prints. The check sits in the existing
`shard_output_check.rb` because the CI registry requires every `*_check.rb` to be classified, and that classification
lives in the rpg-maker-clone world. `shard_output_check.rb` passes 29 checks here (15 existing, 14 tier); its
generated-code part needs a host mrbc.

Measured on the optcarrot world (180 frames, Ruby 4.0.9 from nix, Linux, shared host; `tools/optcarrot_probe/compiled_run.rb`):

- Hot owners from one gprof run: `Optcarrot::PPU` and `Optcarrot::CPU` (`--shard-hot-owners`). The profile is coarse
  (about 0.36 s of samples). The tier applied as designed: PPU and CPU in the main file, APU in a shard at -O1.
- Sealed build (rake, -j4), three interleaved pairs, seconds: baseline 96.6, 95.8, 94.6; tiered (`--shard-cold-opt=O1`)
  104.0, 100.6, 100.1. The tiered build was about 6% slower to compile, outside the range of the baseline runs.
- Hot-path fps, mruby + bc2cpp (sealed): baseline 373, 366, 427; tiered 360, 378, 350. The spread is wider than the
  difference of the medians (373 vs 360), so no runtime change is established.
- Checksum 59662 (180 frames) and 38895 (18 frames) on every run of both configurations.

So the first tier does not pay off on this world: cold code is too small a share of the work to save compile time, and
the extra shard preludes cost more than the -O1 saves. Per-shard levels may still matter on a larger closed world.

Not done, and why:
- A hot list from a finer profile (the gprof run has too few samples to rank owners reliably) or from prof_stream.
- Per-function levels (`#[relax(O3)]`-style): not attempted.
- The rpg-maker-clone rake build (`tools/bc2cpp/compiled_gems.rb`) does not change. The pragma carries the level inside the
  generated file, so the rake rules need no per-object flags.
