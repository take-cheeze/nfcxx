# AddressSanitizer (`nfcxx -fsanitize=address`)

`nfcxx -fsanitize=address x.cpp -o x` builds a program whose memory errors are reported by gcc's AddressSanitizer
(libasan): heap, stack and global buffer overflows, use after free, use after scope, double free, `new[]`/`delete`
mismatch, and (LeakSanitizer, on by default in libasan) leaks at exit. The report names the C++ source line, since
EDG's generated C carries `#line` directives. `ASAN_OPTIONS` works as usual (`detect_leaks=0`, `abort_on_error=1`, ...).

## qbe backend (default)

`nfcxx -fsanitize=address` on the default backend (qbe) sets `NFCXX_ASAN=1`. cproc, patched by
the `nfcxx-asan` branch of take-cheeze/cproc, which `3rd/cproc` is pinned to, then
puts a call of `__asan_load{1,2,4,8}` / `__asan_store{1,2,4,8}` before every load and store it emits (`funcinst`, the
one chokepoint). `qbe-cc` links with `-fsanitize=address`. Covered by `ASAN_BACKEND=qbe tests/asan/run.sh` (CI):
heap overflow, use after free, double free, alloc/dealloc mismatch, leak, exceptions and containers clean, the C input.
Stack objects get redzones (`asanalloc` in cproc's `funcalloc`): 32 bytes on each side, allocated in the entry block,
poisoned at the declaration and unpoisoned in `funcret`. Globals get a trailing redzone: `emitdata` writes the rest of the
object's 8-byte granule and 32 zero bytes into the same data item, and the unit's constructor (`emitasanctor`, in
`.init_array`) poisons them. Both use `__asan_poison_memory_region`, so the report says `use-after-poison` where gcc says
`stack-buffer-overflow` or `global-buffer-overflow` (the tests accept both spellings on qbe, `ASAN-QBE:`). Limits: the
object's size is rounded up to 8 bytes, so bytes between its size and the rounding are not covered; globals have no
leading redzone (an access before the object is not reported); thread-local globals get none; objects over 16-byte
alignment get no redzones (variable-length arrays and `alloca`: see Dynamic allocations). Not yet: use-after-scope and use-after-return (the
`ASAN-ONLY: gcc` case skips on qbe), and volatile (qbe rejects volatile stores, a known limit). Block copies and `va_arg` loads are checked as ordinary accesses.

Source lines: with `NFCXX_ASAN=1`, `qbe-cc` keeps the preprocessor's line markers (no `-P`), cproc records the location of each
expression (`struct expr` `loc`) and emits `dbgloc N` before each check, and a `dbgfile` names the file of the function.
QBE turns those into `.loc` lines, so libasan's report names `file:line` like the gcc backend. The line is the expression's
start token, so a multi-line expression may name a line inside it; `qbe-prep.rb` skips the markers as comments.

## Dynamic allocations (qbe)

`alloca` (`__builtin_alloca`) and the variable-length arrays of C input get redzones like a stack object
(`asandynalloc` in cproc's `qbe.c`). The block is `round8(size) + 2 * 32` bytes from QBE's `alloc16`, at the place of the
call or declaration: the whole block is unpoisoned, then the two redzones are poisoned, so a return before a declaration
never poisons it. QBE does not release a dynamic allocation before the function returns (`subq` on `rsp`; a loop
allocates again on each pass), so the blocks stay until then. The entry block keeps two slots, the lowest base and the
highest end of the function's dynamic blocks (QBE moves the stack down, so the latest base is the lowest). `asandynret`
adds, to each return block, a test of the lowest base: if a dynamic block was allocated on this path, it unpoisons
[lowest, highest) before the `ret`. Returns that run before any dynamic allocation (a return before a declaration, or
earlier in a loop body) skip the call. A function without a dynamic allocation is emitted as before.
`tests/asan/cases/alloca_*.cpp`, `vla_*.c`: an overflow past the block (`use-after-poison` on qbe), an alloca loop that
stays in bounds, and returns before and inside a loop after a VLA, followed by a check that its redzones are addressable.

Limits: a C++ variable-length array does not use this. EDG lowers it to `__vla_alloc` (`3rd/edg/lib_src/vla_alloc.c`),
which carves VLAs out of shared 32 KB blocks (a VLA of 4096 bytes or more has its own malloc block), so no redzone
separates two VLAs of one C++ function, and gcc misses that overflow too. Removing it needs EDG's lowering or runtime
(the investigation found no way inside cproc). The size is rounded up to 8 bytes as for stack objects, so bytes between
the size and the rounding are not covered; `alloca(0)` returns the start of the right redzone (it cannot be dereferenced).
Alignments over 16 get no redzone. A block is not released at the end of its scope, so a pointer to a VLA or alloca block
used after its loop pass or after the function returned is not reported (no use-after-scope or use-after-return here).

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

qbe: cproc checks every load and store, and stack, dynamic (alloca, C-input VLA) and global objects get redzones (take-cheeze/cproc `nfcxx-asan`, applied by `scripts/setup-qbe.sh`; `NFCXX_ASAN=1` selects it). Path B and wasm: planned, not built (`asan-plan.md`).

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
then link, and a `.c` input in the same program.
