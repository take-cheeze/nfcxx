# Porting scripts/cuda-rewrite.rb to C++

Status: complete. `tools/cuda-rewrite/cuda_rewrite.cpp` implements every pass of the Ruby script, in the Ruby order, with
the same names and comments. The embedded prelude and builtin tables (`tables.inc`) are generated from the Ruby text by
`tools/cuda-rewrite/gen-tables.sh`, so they are byte-identical by construction.

The driver (`nfcxx`, `cu_rewrite`) runs the C++ tool by default; `NFCXX_CUDA_REWRITER=ruby` runs the Ruby reference
(`scripts/cuda-rewrite.rb`, kept unchanged).

Check that the two agree: `tools/cuda-rewrite/diff-ruby-cxx.sh` compares stdout, stderr and exit code of both, in host
and `--device` mode, over the test corpus or the files given.

Ruby semantics kept on purpose:
- Strings are byte strings; `s[i]` past the end is nil (`ch()` returns -1).
- `String#index`/`rindex` with a negative position count from the end (`rindex_from`).
- `split` drops trailing empty fields (`ruby_split_nl`); `split("\n", -1)` keeps them (`split_lines_keep`).
- `Hash` iteration is insertion order (the tables and `$sites`).
- `blank_comments` is the later Ruby definition (line 3337); the earlier one (line 2533) is overridden and not ported.
- The `enclosing_block` index and scan give the same answers; both are ported (the index for texts of 4000 bytes or more).

Known gaps (none affect the corpus checks so far):
- Integers in the `#if` evaluator are 64-bit; Ruby's are arbitrary precision (only oversized shifts differ).
- A missing `--kernels` directory or an unreadable input gives the C++ message, not Ruby's exception text.
