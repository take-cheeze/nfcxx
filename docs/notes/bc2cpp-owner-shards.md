# Balancing large owners in generated C++

The normal shard placement keeps an owner's methods together for cross-method inlining. With the explicit
`BC2CPP_SHARD_SPLIT_OWNERS=1` opt-in, owners fitting the fair share of method bytes
(`total method bytes / number of useful shards`) still stay together. Owners larger than that budget are
distributed as individual method units, largest first, across the lightest shards. A unit includes the method's
helper definitions, so the splitter never cuts a function or its local state in half. Source order is retained
within each resulting shard, and equal-sized units have deterministic placement.

Self-compilation enables the opt-in for the compiler build's generation only. Ordinary programs, including
Optcarrot, retain their existing grouping unless they explicitly request it; their hot-owner inlining tradeoff
is independent of the compiler's native build time.

This handles a self-compiled compiler's large `CodeGen` class: the old owner grouping placed 1,375 translated
entries in one 18 MB main file, while the largest other shard was 2.9 MB. With eight workers that main compilation
alone took 177 seconds of a 193-second native build. Increasing the shard count could not divide that owner.

The existing declaration rewrite promotes method-section references crossing shards, including references
between methods of the same owner. Mutable shared variables lose `static` on their single definition; const
shared variables receive explicit external linkage. Other shards see declarations, and the generated prelude
still shares its inline state and function-local statics across all translation units.

An owner explicitly selected by `--shard-hot-owners` remains wholly in the main file. Each method's tier report
continues to reflect its actual placement. Owners fitting the budget retain owner-level grouping, and programs
below the existing minimum shard-size threshold still produce their unchanged single-file output.

`bc2cpp/scripts/bc2cpp/shard_output_check.rb` checks deterministic balancing, complete method placement, pinned hot
owners and per-unit tier reporting. Its linked same-owner fixture exercises cross-shard static helper calls,
mutable and const method-section state, prelude state and function-local statics with `-O2 -Wall -Werror`.
