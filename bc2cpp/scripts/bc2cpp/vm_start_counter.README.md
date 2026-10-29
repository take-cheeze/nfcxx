# VM-start counter (measurement patch)

`vm_start_counter.patch` is a diff against the mruby fork (`3rd/mruby`, pin in `.gitmodules`) that counts each
bytecode body the VM starts, at five sites: C entry (`mrb_vm_exec`), `OP_SEND`, `OP_CALL`, `OP_BLKCALL`, `OP_EXEC`.
It is not applied by any build; it is a local measurement tool and is never committed to the fork.

Apply and use:

    git -C 3rd/mruby apply ../../scripts/bc2cpp/vm_start_counter.patch
    BC2CPP_VMCNT_OUT=/tmp/counts.tsv scripts/bc2cpp/trace_host.bash build-closed-bc2cpp

Each run appends `count<TAB>kind<TAB>owner#method` rows at exit. Anonymous class addresses differ between
processes, so normalize `#<Class:0x...>` before summing across runs. Revert with `git -C 3rd/mruby checkout -- src/vm.c`.
