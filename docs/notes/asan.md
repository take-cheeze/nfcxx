# AddressSanitizer (`nfcxx -fsanitize=address`)

`nfcxx -fsanitize=address x.cpp -o x` builds a program whose memory errors are reported by gcc's AddressSanitizer
(libasan): heap, stack and global buffer overflows, use after free, use after scope, double free, `new[]`/`delete`
mismatch, and (LeakSanitizer, on by default in libasan) leaks at exit. The report names the C++ source line, since
EDG's generated C carries `#line` directives. `ASAN_OPTIONS` works as usual (`detect_leaks=0`, `abort_on_error=1`, ...).

## qbe backend (default)

`nfcxx -fsanitize=address` on the default backend (qbe) sets `NFCXX_ASAN=1`. cproc, patched by
`scripts/cproc-asan.patch` (applied to the build copy by `scripts/setup-qbe.sh`, so the submodule stays clean), then
puts a call of `__asan_load{1,2,4,8}` / `__asan_store{1,2,4,8}` before every load and store it emits (`funcinst`, the
one chokepoint). `qbe-cc` links with `-fsanitize=address`. Covered by `ASAN_BACKEND=qbe tests/asan/run.sh` (CI):
heap overflow, use after free, double free, alloc/dealloc mismatch, leak, exceptions and containers clean, the C input.
Stack objects get redzones (`asanalloc` in cproc's `funcalloc`): 32 bytes on each side, allocated in the entry block,
poisoned on entry and unpoisoned in `funcret`. Globals get a trailing redzone: `emitdata` writes the rest of the
object's 8-byte granule and 32 zero bytes into the same data item, and the unit's constructor (`emitasanctor`, in
`.init_array`) poisons them. Both use `__asan_poison_memory_region`, so the report says `use-after-poison` where gcc says
`stack-buffer-overflow` or `global-buffer-overflow` (the tests accept both spellings on qbe, `ASAN-QBE:`). Limits: the
object's size is rounded up to 8 bytes, so bytes between its size and the rounding are not covered; globals have no
leading redzone (an access before the object is not reported); thread-local globals get none; objects over 16-byte
alignment, variable-length arrays and `alloca` get no redzones. Not yet: use-after-scope and use-after-return (the
`ASAN-ONLY: gcc` case skips on qbe), the report's source line, and volatile (qbe rejects volatile stores, a known limit). Block copies and `va_arg` loads are checked as ordinary accesses.

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

qbe: cproc checks every load and store, and stack and global objects get redzones (`scripts/cproc-asan.patch`, applied by `scripts/setup-qbe.sh`; `NFCXX_ASAN=1` selects it). Path B and wasm: planned, not built (`asan-plan.md`).

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
