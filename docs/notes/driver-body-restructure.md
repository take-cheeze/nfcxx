
## Scope of B4 (found while reading the driver)

- `cu_prepare` (nfcxx, the function after the `.cu` cache setup) reads and writes `srcs`, `files`, `cflags`, `cudatmp`
  and the cache directory, and calls scripts/nfcxx-cuda-device.rb twice (`--cu-dir`, `--cu-prepare`).
- `cpp2_prepare` does the same for `.cpp2` inputs: it writes `srcs`, `files`, `cflags` and the cache, and calls
  scripts/nfcxx-cpp2.rb `--prepare`.
- `mod_build_program` runs scripts/nfcxx-modules.rb `build` after `cu_prepare`'s cleanup and `trace_finish`.

So B4 cannot move these calls to Ruby one function at a time: each one mutates the arrays the rest of the bash flow
reads. The Ruby flow must own `srcs`, `files`, `cflags`, the temp directories and the cache directory before B4 can
call them. That is step 1 of the order above (the flow skeleton), and it's what the next PR should do.
