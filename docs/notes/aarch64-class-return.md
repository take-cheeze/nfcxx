# Class results of library functions on AArch64

AArch64 (macOS and Linux) returns a class with a non-trivial copy constructor or destructor through an address in **x8**.
EDG lowers such a return to a hidden first parameter (x0), which is also the x86-64 convention. A call to a library
function that returns a class (`std::to_string`, `std::filesystem::current_path`, `file_status` from `status`, ...) therefore
used to hand the callee a garbage x8.

The fix is in `3rd/edg/src/c_gen_be.c`, `dump_call`. For a direct call to a routine that is declared in a system header, has no
body in the unit, is not inline and not variadic, EDG writes

    *(T *)dest = ((T (*)(args))f)(args)

instead of `f(&dest, args)`, so the C compiler passes the result address in x8. A class of 16 bytes or less would be returned in
registers by a C function, so the cast's result type is padded: `struct { T v; char p[16]; }`, and the call takes `.v`.

- The path is on when the EDG build runs on an AArch64 host or targets arm64 macOS. `NFCXX_NO_X8_SRET=1` turns it off.
- `current_exception`, `__from_native_exception_pointer` and `nested_ptr` are skipped: `lib/ehshim` defines them with the lowered
  convention.
- A padded (small) result is copied bitwise out of the temporary. That is right for libc++'s small classes; a small class with a
  self-pointing member would need another approach.
- Path B does not use this: its `(sret ...)` form already puts the address in x8.

`tests/sret` covers it (path, file_status, strings, wstrings, exceptions).
