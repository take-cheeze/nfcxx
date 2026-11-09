# VM-start counter

The counter lives in the mruby fork (`3rd/mruby`, pinned to `93b8ad5`, branch `claude/vm-start-counter-p4w8`). It counts
each bytecode body the VM starts, at five sites: C entry (`mrb_vm_exec`), `OP_SEND`, `OP_CALL`, `OP_BLKCALL`, `OP_EXEC`.

It is compiled in only with `-DBC2CPP_VM_START_COUNTER`. `build_config.rb` adds that define when
`BC2CPP_VM_START_COUNTER=1`, so a normal build has no counter code.

Use:

    BC2CPP_VM_START_COUNTER=1 scripts/bc2cpp/closed_build.bash
    BC2CPP_VMCNT_OUT=/tmp/counts.tsv scripts/bc2cpp/trace_host.bash build-closed-bc2cpp

Each process appends `count<TAB>kind<TAB>owner#method` rows at exit. Anonymous class addresses differ between
processes, so normalize `#<Class:0x...>` before summing across runs.
