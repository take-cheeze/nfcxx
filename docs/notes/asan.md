# AddressSanitizer (`nfcxx -fsanitize=address`)

`nfcxx -fsanitize=address x.cpp -o x` builds a program whose memory errors are reported by gcc's AddressSanitizer
(libasan): heap, stack and global buffer overflows, use after free, use after scope, double free, `new[]`/`delete`
mismatch, and (LeakSanitizer, on by default in libasan) leaks at exit. The report names the C++ source line, since
EDG's generated C carries `#line` directives. `ASAN_OPTIONS` works as usual (`detect_leaks=0`, `abort_on_error=1`, ...).

## qbe backend (default)

`nfcxx -fsanitize=address` on the default backend (qbe) sets `NFCXX_ASAN=1`. cproc, patched by
the `nfcxx-asan-uar` branch of take-cheeze/cproc (`nfcxx-asan` plus use after return), which `3rd/cproc` is pinned to, then
puts a call of `__asan_load{1,2,4,8}` / `__asan_store{1,2,4,8}` before every load and store it emits (`funcinst`, the
one chokepoint). `qbe-cc` links with `-fsanitize=address`. Covered by `ASAN_BACKEND=qbe tests/asan/run.sh` (CI):
heap overflow, use after free, double free, alloc/dealloc mismatch, leak, exceptions and containers clean, the C input.
Stack objects get redzones (`asanalloc` in cproc's `funcalloc`): 32 bytes on each side, allocated in the entry block,
their redzones poisoned at the declaration and the whole object unpoisoned in `funcret`. The object is in a fake frame
(use after return, below). Variable-length arrays and `alloca` get redzones too (`asandynalloc`), not a fake frame. Globals get a trailing redzone: `emitdata` writes the rest of the
object's 8-byte granule and 32 zero bytes into the same data item, and the unit's constructor (`emitasanctor`, in
`.init_array`) poisons them. Both use `__asan_poison_memory_region`, so the report says `use-after-poison` where gcc says
`stack-buffer-overflow` or `global-buffer-overflow` (the tests accept both spellings on qbe, `ASAN-QBE:`). Limits: the
object's size is rounded up to 8 bytes, so bytes between its size and the rounding are not covered; globals have no
leading redzone (an access before the object is not reported); thread-local globals get none. Use after scope and use
after return are covered (next two sections). Not yet: volatile (qbe rejects volatile stores, a known limit). Block
copies and `va_arg` loads are checked as ordinary accesses.

## Use after scope (qbe)

A block-scoped stack object (a local, a for-init declaration, a compound literal) is poisoned when its block is left and
unpoisoned again when its declaration runs, so a loop that enters the block again is addressable each time. The poison is
`__asan_poison_stack_memory`, the marker gcc's own instrumentation uses, so the report is `stack-use-after-scope` on both
backends and the tests need no `ASAN-QBE:` line. Covered ways out of a block (cproc, take-cheeze/cproc `nfcxx-asan`, `qbe.c`):

- the normal end, after the join point and before the scope is deleted (`asanend`);
- `break` and `continue` of C input, cproc's own statements (`asanleave`: the objects the loop or switch body has declared);
- `goto`: a backward goto poisons the objects of the blocks it leaves; a forward goto records the blocks open at it, and its
  label poisons the ones it leaves (`asangoto`, `asanlabel`). EDG lowers every C++ `break`, `continue` and switch exit to a
  `goto __Tn` to a label after the statement, so C++ takes this path, not `asanleave`.

Jumps into a block unpoison the objects of the blocks they enter, since C++ allows a jump past a declaration without an
initializer and the block may have been left by an earlier pass: a goto's label and a `case` or `default` label
(`asancase`, `asanswitch`) do this. A return poisons nothing: `funcret` unpoisons the frame and nothing of it runs after.

Tests: `tests/asan/cases/use_after_scope.cpp`, `scope_break_escape.cpp`, `scope_goto_escape.cpp`,
`scope_continue_escape.cpp`, `scope_compound_escape.cpp` (reports, with the gcc wording), and the `CLEAN` cases
`scope_reenter.cpp` (a block entered again), `scope_break.cpp` (break, continue, do/while), `scope_return.cpp`,
`scope_goto.cpp` (backward and forward goto, a jump into a block past a declaration) and `scope_switch.cpp` (a case label
past a declaration of the switch body).

Limits, all false negatives (nothing is reported that is valid, the missing check is what can be missed):

- A longjmp or a C++ throw (EDG's setjmp ABI) that leaves a block to a handler in the same frame runs no poison, so an access
  through a pointer kept from that block is not reported.
- Use after return is the next section. `return` itself poisons nothing here: funcret gives the fake frames back.
- `alloca` lives until its function returns, as C requires, so it has no scope poison.

The default (non-ASan) output is byte-identical: every hook is gated on `asanon`, and the scope fields are only set and read
under it.

Source lines: with `NFCXX_ASAN=1`, `qbe-cc` keeps the preprocessor's line markers (no `-P`), cproc records the location of each
expression (`struct expr` `loc`) and emits `dbgloc N` before each check, and a `dbgfile` names the file of the function.
QBE turns those into `.loc` lines, so libasan's report names `file:line` like the gcc backend. The line is the expression's
start token, so a multi-line expression may name a line inside it; `qbe-prep.rb` skips the markers as comments.

## Use after return (qbe)

A pointer to a local of a function, read after that function returned, is reported as `stack-use-after-return`, the gcc
wording (`tests/asan/cases/use_after_return.cpp`, the same expected text on both backends). The object lives in a fake frame,
libasan's fake stack, as gcc's `-fsanitize=address` puts it. cproc (`asanalloc`, `asanselect`, `asanfree`, `qbe.c`):

- At the entry of the function, each object of the frame (a declaration, a parameter, a compound literal, of align 16 or less)
  gets `p = __asan_stack_malloc_N(frame)`, N the smallest class with `64 << N >= frame`, and `frame` the object's allocation
  (redzones included) rounded up to 64 bytes: `__asan_stack_malloc_0` with 64, `__asan_stack_malloc_2` with 192, as gcc
  passes them. It returns 0 when `detect_stack_use_after_return` is off or the class is full (`libasan`'s default is on here),
  and then the object stays in the real frame, which is always allocated too (`asanselect` picks the frame branch-free).
- The header is gcc's: magic `0x41B58AB3` at offset 0, the description at 8 (a data item, `asandesc.N`, with
  `1 32 SIZE NAMELEN NAME:LINE`, the object at offset 32 as in gcc; the line is the declarator's, `tok.loc` in `mkdecl`), the
  function's address (the pc, which names the frame) at 16. The header and the redzones are written by the same code as the real frame's.
- At each return, `__asan_stack_free_N(p, frame)` runs when `p` is not NULL (`asanfree`, before the dynamic-block unpoison of
  `asandynret`). libasan's free dereferences its pointer (`FakeStack::Deallocate` reads the frame's flag at offset 56, which
  its malloc wrote), so it is never called with NULL; it poisons the frame with 0xf5, the stack-after-return shadow, and so a
  later read of the object reports `stack-use-after-return`.

Symbols (libsanitizer on this machine, `/usr/lib/x86_64-linux-gnu/libasan.so.8`, `nm -D`): `__asan_stack_malloc_0` to
`_10`, `__asan_stack_free_0` to `_10`, and the flag `__asan_option_detect_stack_use_after_return` (a data symbol,
`cmpl $0` in gcc's output). `__asan_stack_malloc_always_N`, `__asan_get_current_fake_stack`,
`__asan_addr_is_in_fake_stack` and `__asan_handle_no_return` are not used. The public header
(`/usr/lib/gcc/x86_64-linux-gnu/13/include/sanitizer/asan_interface.h`) does not document the `_N` entry points: their
ABI is gcc's output, which is what the code copies.

Limits, all false negatives:

- One fake frame per object, not one per function: gcc's report lists every object of the frame ("This frame has N
  object(s)"), the qbe one lists the object it reports. Each call costs one `__asan_stack_malloc_N` and one `__asan_stack_free_N`
  per object.
- Objects over 16-byte alignment, variable-length arrays and `alloca` stay in the real frame: a pointer to one of them
  read after its function returned is not reported.
- A frame over 64 KiB (after the rounding) is not made, and when the thread's fake stack is full libasan returns 0: the
  object is in the real frame.
- A frame whose function leaves by longjmp or a C++ throw (EDG's setjmp ABI) is never freed; its shadow stays as it was,
  so reads through pointers into it are not reported, and its slot in the fake stack is not given back.
- Deep recursion uses the real stack for every frame as well (the real frame is still allocated); the fake frames add
  their own memory, so the real stack limit is the same as without the flag.

## How it works

The instrumentation is gcc's, applied to the C that EDG generates, so only the gcc backend can do it. The driver:

- passes `-fsanitize=address -fno-omit-frame-pointer` to every C compile and to the link (`--c_to_obj_option` for
  `eccp`, directly to `gcc` for `.c` inputs and the C-only link), so `-c` objects and the final link agree;
- selects the gcc backend when the backend was only the default (`qbe`); with an explicit `--backend=qbe` it is an
  Path B (`NFCXX_PATH=b` or `--backend=pathb`) is an error: its emitter has no instrumentation yet;
- accepts `-fno-sanitize=address` (turns it off again) and `-fno-omit-frame-pointer`/`-fomit-frame-pointer`;
  every other `-fsanitize=...` value is refused (`nfcc` still refuses all of them).

Link the objects of one program with the same option: an object built with the flag and one built without can be
mixed, but memory errors are only found in the instrumented code.

qbe: cproc checks every load and store, and stack and global objects get redzones (take-cheeze/cproc `nfcxx-asan-uar`, the pin of `3rd/cproc`; `NFCXX_ASAN=1` selects it). Path B and wasm: planned, not built (`asan-plan.md`).

## Limits

- EDG's runtime (`libC.a`: `operator new/delete`, the exception runtime) is not instrumented. `operator new` ends in
  `malloc`, which libasan intercepts, so heap errors are found; stack objects of the runtime are not checked.
- Exceptions use EDG's setjmp/longjmp ABI; libasan unpoisons the stack on `longjmp`, `tests/asan/cases/clean.cpp`
  throws through frames with `std::string` locals.
- Container overflow annotations of libstdc++ (`_GLIBCXX_SANITIZE_VECTOR`) are not enabled; an overflow inside the
  capacity of a `std::vector` is not reported, one past the allocation is (`std_containers.cpp`).
- Leak checking needs `ptrace`; where it is blocked, LeakSanitizer reports that and `tests/asan/run.sh` prints SKIP.

## Test

`tests/asan/run.sh` (CI: `ci.yml`): one program per error class with the expected report text, a clean program with
exceptions and containers, the source line in the report, the flag-off cases, backend selection and refusals, `-c`
then link, and a `.c` input in the same program. Use after return: `use_after_return.cpp` (a report), and the clean programs
`clean_return_heap.cpp` (pointers to heap and static data returned), `clean_recursive.cpp` and `clean_callee_return.cpp` (a
callee returns before the caller reads the local whose address it got).

A mixed program also works: `tests/poly/asan-go.sh` builds the nfcpoly Go host with `-fsanitize=address` on both back ends and links it
with the uninstrumented Go runtime (`libnfcgo.so`, a cgo library); heap errors and leaks of the C++ side are found, the Go side is not
instrumented (`poly.md`, "Sanitizers and valgrind").
