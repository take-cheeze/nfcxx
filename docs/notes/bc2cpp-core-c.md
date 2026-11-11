# bc2cpp: mruby's core C built by nfcxx, and closed-world facts for it

Status, 2026-11-10: prototype (draft PR). Question: can the C that mruby's core is written in (`hash.c`, `kernel.c`,
`object.c`, `class.c`, ...) be compiled with nfcxx, so that the closed-world facts bc2cpp holds can specialize it
(its method-table lookups, the memos of by-name callers, [bc2cpp-epoch-method-table.md](bc2cpp-epoch-method-table.md))?

Setup: the optcarrot world (`tests/bc2cpp/run_optcarrot.sh`, rpg-maker-clone `7099960`, mruby fork `15f679a`), sealed
build, 4 cores shared with other jobs. fps is the benchmark binary's own report, 8 runs alternating the binaries.

## 1. Does the core build with nfcxx?

`tests/bc2cpp/corec_cc.sh` is a `CC=` wrapper for the probe's rake build: the core `src/*.c` of the compiled build go to
`nfcc`, everything else to gcc (`COREC_FILES="hash.c kernel.c"` or `ALL`; `COREC_BACKEND=qbe|gcc`).

| What | Result |
| --- | --- |
| nfcc `--backend=gcc` | the same objects as gcc (it hands the C to gcc); nothing to learn |
| nfcc QBE (cproc), `hash.c` only | builds, links, checksum 59662 |
| nfcc QBE, all 30 core C files (`src/*.c`, not the gems) | builds, links, checksum 59662; 224 fps against 252 fps with gcc (-11%); text +0.9% |
| the 3 C-as-C++ units (`error`, `gc`, `vm_frames`: `src/*-cxx.o`) through `nfcxx` | EDG compiles them (needs `NFCXX_CXX=/usr/bin/g++`; the Nix g++ has no headers EDG finds), but the link fails on EDG's exception lowering (`__throw`, `__eh_curr_region`, ...): mruby's `MRB_USE_CXX_EXCEPTION` build needs nfcxx's EH runtime (`lib/ehshim`, `NFCXX_EH_UNWIND=1`), not wired into this link. Not tried further |
| Path B on `hash.c` compiled as C++ | EDG accepts it. The default SSA route stops in QBE (`invalid type for first operand %ck10 in cugel`); `NFCXX_PATHB_EMITTER=mruby` emits a 127 KB object. Not linked or run. Path B takes C++ only, so it would mean building the whole core as C++ |

So the C core is compilable by nfcc today (QBE), at a cost in speed; gcc stays the faster compiler.

## 2. Feeding the facts in

Chosen: a generated header of owner sets, read by the core C as compile-time constants (`-include`). The facts already
exist in the code generator: `CodeGen#name_owner_set(name)` is every class whose definition a lookup can find, nil when
it cannot be named (`respond_to_missing?`, a `method_missing` class, a possible singleton). `tools/bc2cpp/core_c_facts.rb`
prints them to bc2cpp's stderr (`== core C facts`; the probe shows only part of it) and, with `BC2CPP_CORE_C_FACTS=path`, writes the header. A fact is "core only" when no class
or module on the lookup path of the receiver class and its subclasses defines the name but the core's own.
`runtime/core_c_facts_inject.h` is force-included into `hash.c` (`COREC_FACTS=path` in the wrapper) and replaces
`mrb_method_memo(..., MRB_MEMO_DEFAULT)` by the known answer, `mrb_hash_default`.

Why not an IR pass (option b): the callee is a run-time table lookup (`mrb_method_memo`), so an IR pass has nothing to
fold without the same facts; and Path B does not take C. The header works with any compiler.

Soundness: only for a sealed build, the condition bc2cpp's owner sets already rely on (nothing defines methods at run time:
no `eval`, `define_method` or late C install). Nothing guards it at run time.

Facts of the optcarrot world (owner sets): `default`: Hash, Numeric, Proc, String and their singletons (core only: the others
are not on a Hash's path); `eql?`: 14 classes (Array, Data, Hash, Kernel, Method, Numeric, Proc, Range, Set, String, Struct,
Time, UnboundMethod, ...); `hash`: 15; `==`: 26; `initialize_copy`: 16; `respond_to_missing?`: not nameable. Only `default` is a
single-owner fact.

## 3. Prototype and result

`mrb_hash_get`'s `default` memo, compiled by nfcc QBE with the fact: the object has no `mrb_method_memo` call for that slot.
Checksum 59662; 251.7 fps with the fact, 253.6 without: no difference. That matches the counts: with the stage-5 fork,
`default` made 550 method searches over the whole Nepheshel sweep (down from 6.16M), so there is nothing left to remove.
The sweep itself was not re-run (it needs a full rpg-maker-clone closed build).

## Recommendation

For speed it does not pay: the memos hit almost always, and the larger owner sets (`eql?`, `hash`, `==`) would turn into a
per-class switch, which is a method table again. If the aim is to drop mruby's method tables and the VM, the way is open in
this order: build the core with nfcc QBE (works; wire in the EH runtime for the three C++ units), then move one lookup at a
time from memos to facts where the owner set is one class, and a class-id switch with an `mt_epoch`-free sealed-world
guarantee for the rest. Each step needs the sweep to be re-run before it counts.
