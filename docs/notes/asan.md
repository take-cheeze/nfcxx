# AddressSanitizer (`nfcxx -fsanitize=address`)

`nfcxx -fsanitize=address x.cpp -o x` builds a program whose memory errors are reported by gcc's AddressSanitizer
(libasan): heap, stack and global buffer overflows, use after free, use after scope, double free, `new[]`/`delete`
mismatch, and (LeakSanitizer, on by default in libasan) leaks at exit. The report names the C++ source line, since
EDG's generated C carries `#line` directives. `ASAN_OPTIONS` works as usual (`detect_leaks=0`, `abort_on_error=1`, ...).

## qbe backend (default)

`nfcxx -fsanitize=address` on the default backend (qbe) sets `NFCXX_ASAN=1`. cproc, patched by
the `nfcxx-asan-unwind` branch of take-cheeze/cproc (on top of `nfcxx-asan`), which `3rd/cproc` is pinned to, then
puts a call of `__asan_load{1,2,4,8}` / `__asan_store{1,2,4,8}` before every load and store it emits (`funcinst`, the
one chokepoint). `qbe-cc` links with `-fsanitize=address`. Covered by `ASAN_BACKEND=qbe tests/asan/run.sh` (CI):
heap overflow, use after free, double free, alloc/dealloc mismatch, leak, exceptions and containers clean, the C input.
Stack objects get redzones (`asanalloc` in cproc's `funcalloc`): 32 bytes on each side, allocated in the entry block,
poisoned on entry and unpoisoned in `funcret`. Globals get a trailing redzone: `emitdata` writes the rest of the
object's 8-byte granule and 32 zero bytes into the same data item, and the unit's constructor (`emitasanctor`, in
`.init_array`) poisons them. Both use `__asan_poison_memory_region`, so the report says `use-after-poison` where gcc says
`stack-buffer-overflow` or `global-buffer-overflow` (the tests accept both spellings on qbe, `ASAN-QBE:`). Limits: the
object's size is rounded up to 8 bytes, so bytes between its size and the rounding are not covered; globals have no
leading redzone (an access before the object is not reported); thread-local globals get none. Objects over 16-byte alignment,
C-input VLAs, `alloca` and C++ VLAs (own section below) have redzones. Use after scope is covered (next section). Not yet:
use-after-return (the `ASAN-ONLY: gcc` case skips on qbe), and volatile (qbe rejects volatile stores, a known limit). Block
copies and `va_arg` loads are checked as ordinary accesses.

## Use after scope (qbe)

A block-scoped stack object (a local, a for-init declaration, a compound literal) is poisoned when its block is left and
unpoisoned again when its declaration runs, so a loop that enters the block again is addressable each time. The poison is
`__asan_poison_stack_memory`, the marker gcc's own instrumentation uses, so the report is `stack-use-after-scope` on both
backends and the tests need no `ASAN-QBE:` line. Covered ways out of a block (cproc, take-cheeze/cproc `nfcxx-asan-unwind`, `qbe.c`):

- the normal end, after the join point and before the scope is deleted (`asanend`);
- `break` and `continue` of C input, cproc's own statements (`asanleave`: the objects the loop or switch body has declared);
- `goto`: a backward goto poisons the objects of the blocks it leaves; a forward goto records the blocks open at it, and its
  label poisons the ones it leaves (`asangoto`, `asanlabel`). EDG lowers every C++ `break`, `continue` and switch exit to a
  `goto __Tn` to a label after the statement, so C++ takes this path, not `asanleave`.
- a `setjmp` call (`setjmp`, `_setjmp`, `sigsetjmp`, `__sigsetjmp`, the names glibc and EDG use): the call returns twice, and a
  longjmp to it skips the blocks between the two. The longjmp is not seen, so the return is where the skipped objects are
  poisoned: the call's block is split, and a pad block that both returns pass through poisons every object of the function
  whose block is not open at the call (`asansetjmp`, filled by `asanfinish` once all objects are known). Such an object is out
  of scope at the call (a block's objects are out of scope outside it), so no live object is poisoned, and the open blocks are
  left alone. A block entered again unpoisons its objects at their declaration. EDG lowers a C++ `try` to a `_setjmp` and a
  `throw` to a longjmp to it. The poison is at the return and not at the throw because EDG's runtime runs the destructors of
  the objects being left while it unwinds, and they still use them. A longjmp or throw from a called function that lands in
  this frame is covered for this frame's objects too (not in the test suite).

Jumps into a block unpoison the objects of the blocks they enter, since C++ allows a jump past a declaration without an
initializer and the block may have been left by an earlier pass: a goto's label and a `case` or `default` label
(`asancase`, `asanswitch`) do this. A return poisons nothing: `funcret` unpoisons the frame and nothing of it runs after.

Tests: `tests/asan/cases/use_after_scope.cpp`, `scope_break_escape.cpp`, `scope_goto_escape.cpp`,
`scope_continue_escape.cpp`, `scope_compound_escape.cpp` (reports, with the gcc wording), and the `CLEAN` cases
`scope_reenter.cpp` (a block entered again), `scope_break.cpp` (break, continue, do/while), `scope_return.cpp`,
`scope_goto.cpp` (backward and forward goto, a jump into a block past a declaration) and `scope_switch.cpp` (a case label
past a declaration of the switch body). The setjmp return: `scope_throw_escape.cpp` (a C++ throw in the same frame, report
`ASAN-ONLY: qbe`: gcc reports nothing, since its scope poison does not run on the EDG setjmp/longjmp path) and
`scope_longjmp_escape.c` (a C longjmp, `ASAN-ONLY: qbe` for the same reason, gcc's poison does not run on a longjmp); the
`CLEAN` cases `scope_throw_clean.cpp` (a destructor of a left object runs during the unwinding, an object of the enclosing
block is read in the handler), `scope_throw_nomatch.cpp` (an inner catch that does not match, the outer one runs),
`scope_longjmp_clean.c` (the block a longjmp leaves, the enclosing block read after the landing) and `scope_longjmp_vla.c`
(a VLA and a switch case around a setjmp in a loop).

Limits, all false negatives (nothing is reported that is valid, the missing check is what can be missed):

- A longjmp or a C++ throw that leaves a block to a `setjmp` in the same frame is covered only on the qbe backend (above);
  the false negatives left are these, all of them unreported accesses through a pointer kept from an object that was
  out of scope:
  - an exit that leaves a called function's frame (a longjmp or a throw from a callee): the callee's objects are not
    poisoned, since libasan unpoisons the stack a longjmp skips (above). Checked: a pointer to a callee's local, read after
    the landing, is not reported (cross-frame, out of scope). The landing frame's own objects are covered (the setjmp return
    does not depend on where the longjmp came from).
  - a `setjmp` under another name (through a function pointer, `__builtin_setjmp`, a wrapper): there is no pad, so the blocks
    an exit to it leaves are not poisoned.
  - a `setjmp` on the gcc backend: gcc's scope poison does not run on these paths (`ASAN-ONLY: qbe`).
- Use after return (a pointer to a local of a block that `return` left, read after the function returned) needs a fake
  stack; not done. `return` itself poisons nothing.
- C++ variable-length arrays are not poisoned where their scope ends: their block is freed there instead, so a read after
  the scope is a heap-use-after-free (section below).
- `alloca` has redzones but no scope poison, on purpose: C keeps its memory until the function returns, so a read after its
  block is valid. C-input VLAs are scope objects (poisoned where their block ends, from entry-block slots).

The default (non-ASan) output is byte-identical: every hook is gated on `asanon`, and the scope fields are only set and read
under it.

Source lines: with `NFCXX_ASAN=1`, `qbe-cc` keeps the preprocessor's line markers (no `-P`), cproc records the location of each
expression (`struct expr` `loc`) and emits `dbgloc N` before each check, and a `dbgfile` names the file of the function.
QBE turns those into `.loc` lines, so libasan's report names `file:line` like the gcc backend. The line is the expression's
start token, so a multi-line expression may name a line inside it; `qbe-prep.rb` skips the markers as comments.

## C++ variable-length arrays

EDG lowers a C++ VLA to `__vla_alloc`, `__vla_dealloc` and `__vla_dealloc_eh` (3rd/edg/lib_src/vla_alloc.c, in libC.a).
That allocator serves a VLA under 4096 bytes from one shared 32700-byte block, so two such VLAs have no redzone between
them and an overflow of one writes into the next. With `-fsanitize=address` the driver links `lib/asan/nfcxx_vla_asan.c`
(built by `scripts/asan-vla`, gcc with `-fsanitize=address`) ahead of libC.a. It defines the same entry points, so
libC.a's allocator is not linked. Each VLA is a malloc block of exactly the requested size: an overflow is a
`heap-buffer-overflow` in the block's redzone, and the block is freed where the VLA's scope ends, so a pointer kept past
the scope is a `heap-use-after-free`. Both backends use it. The frame markers, the record stack and the longjmp cleanup
(`free_dead`) are EDG's, and the records are per thread (EDG's pool is shared by all threads and not thread-safe).

Tests: `tests/asan/cases/cxx_vla_overflow.cpp`, `cxx_vla_scope_escape.cpp` (reports), `cxx_vla_clean.cpp` (loops left by
break, continue and return, large VLAs, exceptions out of VLA blocks caught in the same function and in a caller), and the
live-allocation counts of `tests/pathb-qbe/cases/vla_scope.cpp`, run under the flag by `tests/asan/run.sh`.

Cost and limits: a VLA is a malloc call each (EDG's pool avoided that), in ASan builds only; the object is linked only
under `-fsanitize=address`, so the default output is unchanged. A block of a VLA that a longjmp left is freed by the
next `__vla_alloc` that finds its frame dead, not at the jump, so an access through it in between is not reported (the
same as EDG's pool, which keeps it too).

## How it works

The instrumentation is gcc's, applied to the C that EDG generates, so only the gcc backend can do it. The driver:

- passes `-fsanitize=address -fno-omit-frame-pointer` to every C compile and to the link (`--c_to_obj_option` for
  `eccp`, directly to `gcc` for `.c` inputs and the C-only link), so `-c` objects and the final link agree;
- links the C++ VLA runtime (`lib/asan/nfcxx_vla_asan.c`, built by `scripts/asan-vla`) ahead of libC.a on a hosted link,
  with either backend (section "C++ variable-length arrays");
- selects the gcc backend when the backend was only the default (`qbe`); with an explicit `--backend=qbe` it is an
  Path B (`NFCXX_PATH=b` or `--backend=pathb`) is an error: its emitter has no instrumentation yet;
- accepts `-fno-sanitize=address` (turns it off again) and `-fno-omit-frame-pointer`/`-fomit-frame-pointer`;
  every other `-fsanitize=...` value is refused (`nfcc` still refuses all of them).

Link the objects of one program with the same option: an object built with the flag and one built without can be
mixed, but memory errors are only found in the instrumented code.

qbe: cproc checks every load and store, and stack and global objects get redzones (take-cheeze/cproc `nfcxx-asan-unwind`, applied by `scripts/setup-qbe.sh`; `NFCXX_ASAN=1` selects it). Path B and wasm: planned, not built (`asan-plan.md`).

## Limits

- EDG's runtime (`libC.a`: `operator new/delete`, the exception runtime) is not instrumented; its C++ VLA allocator is
  replaced under the flag (section "C++ variable-length arrays"). `operator new` ends in
  `malloc`, which libasan intercepts, so heap errors are found; stack objects of the runtime are not checked.
- Exceptions use EDG's setjmp/longjmp ABI; libasan unpoisons the stack on `longjmp`, `tests/asan/cases/clean.cpp`
  throws through frames with `std::string` locals.
- Container overflow annotations of libstdc++ (`_GLIBCXX_SANITIZE_VECTOR`) are not enabled; an overflow inside the
  capacity of a `std::vector` is not reported, one past the allocation is (`std_containers.cpp`).
- Leak checking needs `ptrace`; where it is blocked, LeakSanitizer reports that and `tests/asan/run.sh` prints SKIP.

## Test

`tests/asan/run.sh` (CI: `ci.yml`): one program per error class with the expected report text, a clean program with
exceptions and containers, the source line in the report, the flag-off cases, backend selection and refusals, `-c`
then link, and a `.c` input in the same program.

A mixed program also works: `tests/poly/asan-go.sh` builds the nfcpoly Go host with `-fsanitize=address` on both back ends and links it
with the uninstrumented Go runtime (`libnfcgo.so`, a cgo library); heap errors and leaks of the C++ side are found, the Go side is not
instrumented (`poly.md`, "Sanitizers and valgrind").
