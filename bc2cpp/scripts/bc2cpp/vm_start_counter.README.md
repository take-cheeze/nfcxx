# VM-start counter (measurement patch, v2)

`vm_start_counter.patch` is a diff against the mruby fork (`3rd/mruby`, pin in `.gitmodules`). It counts each
bytecode body the VM starts, at five sites: C entry (`mrb_vm_exec`), `OP_SEND`, `OP_CALL`, `OP_BLKCALL`, `OP_EXEC`.

v2 changes from v1:
- The counter is compile-time. The helper is under `#ifdef BC2CPP_VM_START_COUNTER`; without it the five call sites
  compile to nothing, so a normal build has no counter code and no extra includes.
- `build_config.rb` adds `-DBC2CPP_VM_START_COUNTER` to the mruby C defines when `BC2CPP_VM_START_COUNTER=1`.
  This is the only change outside the fork; it is off by default.

It is never committed to the fork and no build applies it by default.

Use:

    git -C 3rd/mruby apply ../../scripts/bc2cpp/vm_start_counter.patch
    BC2CPP_VM_START_COUNTER=1 scripts/bc2cpp/closed_build.bash
    BC2CPP_VMCNT_OUT=/tmp/counts.tsv scripts/bc2cpp/trace_host.bash build-closed-bc2cpp

Each process appends `count<TAB>kind<TAB>owner#method` rows at exit. Anonymous class addresses differ between
processes, so normalize `#<Class:0x...>` before summing across runs. Revert the fork with
`git -C 3rd/mruby checkout -- src/vm.c`.
