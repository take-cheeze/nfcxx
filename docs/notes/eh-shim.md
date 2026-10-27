# Exceptions thrown by libstdc++: the EH shim

Programs that include the host C++ headers (`nfcxx` hosted mode, Path A with either backend and Path B) call libstdc++.so, and
libstdc++.so throws. `std::vector::at`, `std::stoi`, an empty `std::function`, `std::string::_M_create`, `std::thread::join`,
`std::promise` and the rest call `std::__throw_out_of_range_fmt`, `std::__throw_invalid_argument`, `std::__throw_bad_function_call`, ...
(`<bits/functexcept.h>`), which are compiled by gcc and throw with the Itanium ABI: `__cxa_throw`, the system unwinder, `.eh_frame`.
EDG lowers `try`/`catch`/`throw` to its own ABI instead: setjmp/longjmp and a stack of try blocks in `libC.a`
(`lib_src/throw.c`; `pathb-stage3.md`, "C++ exceptions"). A `catch` compiled by EDG never sees a `__cxa_throw`; the unwinder finds
no handler, and the program ends in `terminate` / `abort`. `std::current_exception` and `std::exception_ptr` fail the same way: they
read the Itanium ABI's list of caught exceptions, which is empty when the exception was thrown by EDG's runtime.

## What the shim is

`lib/ehshim/nfcxx_eh_shim.cpp` is a C++ file compiled by nfcxx itself (EDG front end, gcc backend, so its `throw` statements are EDG
throws) into `build/ehshim/nfcxx_eh_shim-<gnu version>.o` by `scripts/ehshim`, on first use. The driver (`nfcxx`, both paths) and the
Path B harness (`tests/pathb-qbe/run.sh`) link that object into every hosted program, ahead of libstdc++. It defines

- every `std::__throw_*` function of libstdc++ (`bad_exception`, `bad_alloc`, `bad_array_new_length`, `bad_cast`, `bad_typeid`,
  `logic_error`, `domain_error`, `invalid_argument`, `length_error`, `out_of_range`, `out_of_range_fmt`, `runtime_error`,
  `range_error`, `overflow_error`, `underflow_error`, `ios_failure` (both overloads), `system_error`, `future_error`,
  `bad_function_call`, `regex_error`), throwing the same classes with the same messages;
- `std::current_exception`, `std::rethrow_exception`, and the out-of-line members of `std::exception_ptr`
  (`_M_addref`, `_M_release`, `_M_get`, `__cxa_exception_type`, `exception_ptr(void*)`).

The executable's definitions win over libstdc++.so's, including for calls made from inside libstdc++.so (`std::string::at` is
compiled into the library): the symbols are exported from the executable because the library refers to them, and the dynamic linker
binds the library's calls to them. The classes themselves (`std::out_of_range`, `std::bad_function_call`, ...) and their type_info
are libstdc++'s, which is what EDG's `catch` clauses match by name; `std::exception`, `bad_alloc`, `bad_cast` and `bad_typeid` come
from `libC.a`.

`std::nested_exception`, `std::throw_with_nested`, `std::rethrow_if_nested`, `std::make_exception_ptr`, `std::promise::set_exception`,
`std::future::get`, `std::packaged_task` work through those: they are inline code or libstdc++ code that calls the functions above.
`std::make_exception_ptr` uses libstdc++'s `__cxa_allocate_exception`/`__cxa_init_primary_exception` for the object and its destructor
(they are not replaced); `exception_ptr(void*)` asks the library for the type and hands the object to the EDG runtime, whose "destructor"
for it is the library's release.

### The runtime side: `exception_ptr` needs hooks in `libC.a`

EDG's runtime allocates a thrown object on a stack and destroys it when its handler ends; nothing can keep it. `exception_ptr` is
therefore built on a patch of the runtime, `lib_src/throw.c` of the fork take-cheeze/edg-compiler (the submodule `3rd/edg`; branch
`nfcxx/exception-ptr`): the use count of a throw entry also counts the `exception_ptr`s that name it, so the object is destroyed when
the last handler or pointer is gone and the entry stays on the throw stack until then.

| function | does |
| --- | --- |
| `__eh_pin_current()` | a reference on the exception being handled (`current_exception`); NULL outside a handler |
| `__eh_make_detached(type, dtor, flags, ptr_flags, object, free)` | an entry for an object that lives in memory the caller owns (`make_exception_ptr`); `malloc`ed, not on the throw stack |
| `__eh_pin(h)`, `__eh_unpin(h)` | copy / release of an `exception_ptr`; the last release calls the destructor |
| `__eh_pinned_object(h)`, `__eh_pinned_type(h)` | object address and `type_info` |
| `__eh_rethrow_pinned(h)` | throw it again as a rethrow of the primary entry (`rethrow_exception`) |
| `__eh_find_destination(type, flags, object)` | the EH stack entry a throw of the object would stop at, or NULL; nothing changes (`__cxa_throw`, branch `nfcxx/foreign-eh`) |
| `__eh_throw_detached(h)` | throw a detached entry, passing the caller's reference on to the throw (`__cxa_throw`, `__cxa_rethrow`) |

Also in `throw.c`: a handler that ends clears the entry's `in_handler` (a later `throw;` never picks an entry that only a pointer keeps),
`throw;` inside the handler of a rethrow finds the primary entry through `primary_entry`, and the free loop of `__free_thrown_object`
is a function (`free_discarded_entries`) that stops at an entry that is still referenced. Nothing else of the runtime changed.

The references to these functions in the shim are weak. With a `libC.a` that predates them the `__throw_*` functions still work,
`std::current_exception()` returns an empty pointer, `std::make_exception_ptr` too, and `std::rethrow_exception` of an empty pointer
terminates. `tests/cases/eh_exception_ptr.cpp` notices (an empty `current_exception()` inside a handler) and reports SKIP.

## Exceptions thrown by gcc-compiled code (`__cxa_throw`)

A plain `throw` in gcc-compiled code (libtorch's `c10::Error`, the rest of libstdc++, any C++ library on the system) calls
`__cxa_throw`, and `throw;` calls `__cxa_rethrow`. The shim defines both, and they win over libstdc++'s as the `__throw_*` functions
do. Each decides who handles the exception, as the two-phase unwinder would if EDG's handlers were in its tables:

1. EDG's runtime names the entry of its EH stack at which its handler search would stop (`__eh_find_destination`, the first pass of
   `__throw` without side effects): a try block with a matching catch, or a noexcept or throw specification that ends in terminate.
   None: libstdc++'s throw, as before.
2. That entry lies in the frame of the EDG function that holds it, so the frames between the throw and it have their CFA below the
   entry. Each is asked what the unwinder's search phase asks (its personality routine, read from the CIE of its FDE, with
   `_UA_SEARCH_PHASE`). A handler of gcc-compiled code there (or a noexcept function, which terminates) keeps the exception with
   libstdc++, and so does a stack that never reaches the entry: another thread's (EDG's EH stack is a process global).
3. Otherwise the object, which libstdc++ allocated and initialized (`__cxa_init_primary_exception`), becomes a detached EDG entry
   as for `std::make_exception_ptr` and is thrown as a rethrow of it (`__eh_throw_detached`, which passes the shim's reference on to
   the throw). Its destructor and storage go back to libstdc++ when the last handler or `exception_ptr` lets it go. For
   `__cxa_rethrow` the library's handler is ended first (`__cxa_end_catch`, which its frame would call on the way out), unless the
   program is built with `NFCXX_EH_UNWIND=1`, where the unwinder runs that frame's cleanup.

So `catch (const c10::Error&)`, `catch (const std::exception&)` (EDG's runtime walks the base classes of the library's
`type_info`), `catch (int)`, `catch (...)` with `throw;`, `std::current_exception` and `std::rethrow_exception` all work on them,
and a library that catches its own exceptions keeps doing so, also inside a try block of the program. The frames of `__cxa_throw`
and `__cxa_rethrow` keep off EDG's EH stack (no local objects with destructors, no function-local statics): libstdc++'s unwinder
leaves them when the library keeps the exception, which would leave a stale entry on EDG's stack.

### The vtables of the type_info classes

`libC.a` defines the `type_info` objects of the fundamental types, of pointers to them and of `std::exception` and the classes around
it, and the executable exports them, since libstdc++ and every C++ library refer to them: one object per type, which EDG's handlers
need (`matching_type_info` compares name pointers). Their vtables were EDG's, with the two destructors only. libstdc++ calls
`__do_catch`, `__do_upcast` and the class ones through those vtables when gcc-compiled code catches or `dynamic_cast`s through one of
these types (a library's own `catch (int)`, or `catch (std::exception&)` of a class derived from it), and it jumped past their end:
a crash, with or without the shim's `__cxa_throw`. The shim defines the ten `__cxxabiv1` vtables as libstdc++ has them, slot for slot,
naming libstdc++'s functions; they replace `libC.a`'s weak ones. The `type_info` layouts are the IA-64 ABI's in both. Freestanding
programs link `libC.a` without the shim and keep EDG's tables.

## Link order change (Path A)

`eccp` links `-lstdc++` before `-lC`, so on Path A `operator new` came from libstdc++.so, and `new` of a huge size threw a gcc-ABI
`std::bad_alloc` that EDG's handlers cannot catch (the bug found by `hosted_new.cpp`, `pathb-hosted.md`). The driver now puts `-lC` ahead
of libstdc++ on a hosted link, as Path B always did. `hosted_new.cpp` is compared with the gcc backend now. One visible difference:
EDG's `std::bad_alloc::what()` is `""`, libstdc++'s is `"std::bad_alloc"`.

## Using it

- `nfcxx` links the shim into hosted programs it links (not with `-c`, `-shared`, `--freestanding`). `NFCXX_EHSHIM=0` leaves it out;
  `NFCXX_EHSHIM_DIR` moves the object. If it cannot be built (`scripts/ehshim` prints why) the program is linked without it.
- `scripts/ehshim` prints the object's path and builds it when the source is newer. It runs `nfcxx --backend=gcc -c` (it unsets
  `NFCXX_PATH`, `NFCXX_BACKEND`, `NFCXX_CC`: the shim is always built by the gcc backend, because cproc drops `weak`).
- Programs linked by hand: add the object before `-lC -lstdc++` (`tests/pathb-qbe/run.sh` does).

## Tests

| test | covers |
| --- | --- |
| `tests/cases/eh_libstdcxx_throw.cpp` | the `__throw_*` paths from inline library code and from inside libstdc++.so: `at()` of vector/string/array/deque/map/string_view, `stoi`/`stod`, `bitset`, `reserve`, `std::function`, `optional`, `variant`, destructors on the way, `catch (...)`, rethrow, 2000 throws in a row, `new` failure, `bad_cast`. Runs on both Path A backends and Path B (`tests/run.sh`, `NFCXX_PATH=b tests/run.sh`, `tests/pathb-qbe/run.sh`) |
| `tests/cases/eh_exception_ptr.cpp` | `current_exception`, `rethrow_exception`, copies and moves, lifetime of the exception object, objects with pointers into themselves, pointers and scalars, `make_exception_ptr`, `throw_with_nested`, `rethrow_if_nested`, hundreds of pointers released in any order; same runners |
| `tests/pathb-qbe/cases/hosted_eh_system.cpp` | `std::system_error` from `std::thread::join`, `std::ios_base::failure` |
| `tests/pathb-qbe/cases/hosted_new.cpp` | `new` of a huge size (EDG's `operator new` through the new link order), compared with the gcc backend since the link order change |
| `tests/eval/host.cpp` | a libstdc++ exception inside an nfceval snippet, caught by the snippet or returned as `RuntimeError` |
| `tests/ehshim/run.sh` | programs that cproc or Path B cannot compile (`<future>`, `<regex>`; `__atomic_test_and_set`): `future_promise.cpp`, `regex_error.cpp` on the gcc backend; `exception_ptr_fuzz.cpp` (random mixes of throws, nested handlers, `throw;`, stored pointers) on gcc, qbe and Path B. Each backend's output and exit code must equal the same program built by the host g++ |
| `tests/ehshim/eh_threads.cpp` | eight threads at once each constructing objects with destructors and throwing and catching `std::runtime_error` and `int` in a loop, `std::uncaught_exceptions` in between, then output flushed at exit; gcc, qbe and Path B |
| `tests/ehshim/foreign` (in `tests/ehshim/run.sh`) | a library built by g++ that throws with plain `throw`, called by a program built by nfcxx (gcc, qbe, and gcc with `NFCXX_EH_UNWIND=1`): `std::runtime_error`, a class derived from it caught exactly and as `std::exception`, `int`, `const char*`, `catch (...)` and `throw;`, `exception_ptr`, `throw;` inside the library, the library's own handlers inside the program's try block and beyond a frame of the program, a second thread, each object destroyed once; output equal to the all-g++ build |
| `tests/bundle/torch.sh` | `c10::Error` from libc10 (a bad `reshape`, a CUDA tensor without a GPU), by hand |

## Limits

- The library's own `terminate` handlers and `std::uncaught_exceptions` are untouched: the count is libstdc++'s and does not see an
  exception on its way to an EDG handler. A thrown multi-level pointer or pointer to member stays with libstdc++ (the runtime's
  `ptr_flags` array is not built), so EDG's handlers do not see it.
- EDG's `longjmp` skips the destructors of gcc-compiled frames between the throw and the handler: an exception out of
  `std::string::append`, `std::thread`, libtorch and such can leak what those frames own. User frames are cleaned up. With
  `NFCXX_EH_UNWIND=1` the unwinder runs those destructors too.
- A frame of EDG-compiled code between a gcc-compiled throw and a gcc-compiled handler (a callback the library calls inside its try
  block) must not have objects with destructors: libstdc++'s unwinder leaves it without popping its entry on EDG's stack.
- EDG's EH state (the stack of EH entries the generated code pushes, `__curr_eh_stack_entry` and its neighbours, and the
  runtime's throw in progress and exception memory) is thread-local on Linux targets: the runtime defines it `__thread`
  (`lib_src/config.h`, `RUNTIME_EH_TLS`), and the front end declares it so under `--nfcxx_eh_thread_local`, which the driver and
  `scripts/pathb-dump` pass when `scripts/setup-edg.sh` found the runtime built that way (its `eh-tls` marker). Before, it was one
  global: threads running code with destructors or try blocks at the same time pushed and popped each other's entries (ggml's CPU
  worker threads left a dead one, and libstdc++'s exit-time flush crashed in `std::uncaught_exceptions`). macOS keeps the
  global (its front end has no `__thread`): exceptions there are safe in one thread at a time, and a task that throws in a
  `std::async` thread is not supported. An object compiled before this change does not link with the new runtime (`bad
  value`: a plain reference to a TLS symbol), so build directories need a rebuild.
- Shared objects loaded by a program (`nfcxx -shared`, nfceval snippets) get the shim from the executable, which must be linked by
  `nfcxx` and export its symbols (`-rdynamic`, as nfceval requires); the shared object itself is built without the shim
  (`tests/eval/host.cpp`). A shared object loaded by a program that was not built this way aborts as before.
- `std::make_exception_ptr` of a multi-level pointer or a pointer to member gives an empty `exception_ptr` (the runtime's
  `ptr_flags` array is not built); single-level pointers work (`eh_exception_ptr.cpp`).
- Hexagon is not covered.
