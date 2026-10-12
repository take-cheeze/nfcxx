# AddressSanitizer (`nfcxx -fsanitize=address`)

`nfcxx -fsanitize=address x.cpp -o x` builds a program whose memory errors are reported by gcc's AddressSanitizer
(libasan): heap, stack and global buffer overflows, use after free, use after scope, double free, `new[]`/`delete`
mismatch, and (LeakSanitizer, on by default in libasan) leaks at exit. The report names the C++ source line, since
EDG's generated C carries `#line` directives. `ASAN_OPTIONS` works as usual (`detect_leaks=0`, `abort_on_error=1`, ...).

## How it works

The instrumentation is gcc's, applied to the C that EDG generates, so only the gcc backend can do it. The driver:

- passes `-fsanitize=address -fno-omit-frame-pointer` to every C compile and to the link (`--c_to_obj_option` for
  `eccp`, directly to `gcc` for `.c` inputs and the C-only link), so `-c` objects and the final link agree;
- selects the gcc backend when the backend was only the default (`qbe`); with an explicit `--backend=qbe` it is an
  error, and so is `NFCXX_PATH=b` (Path B), because cproc/QBE and the Path B emitter have no instrumentation;
- accepts `-fno-sanitize=address` (turns it off again) and `-fno-omit-frame-pointer`/`-fomit-frame-pointer`;
  every other `-fsanitize=...` value is refused (`nfcc` still refuses all of them).

Link the objects of one program with the same option: an object built with the flag and one built without can be
mixed, but memory errors are only found in the instrumented code.

Other backends: planned, not built (`asan-plan.md`).

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
