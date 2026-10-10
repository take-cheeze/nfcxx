# Several translation units

Programs made of more than one nfcxx-compiled `.cpp` that use libstdc++ templates (`std::string`, `std::vector`,
`std::map`, ...) link, both as one command (`nfcxx a.cpp b.cpp -o x`) and as separate objects
(`nfcxx -c a.cpp -o a.o`, `nfcxx a.o b.o -o x`). Test: `tests/multi-tu/run.sh` (both backends; sources:
`tests/multi-tu/*.cpp`). It used to fail: two files that each `#include <string>` reported duplicate
`std::allocator<char>` members on gcc, and duplicate `__cmp_cat_id` / `std::numbers::*_v` /
`basic_string::_M_create` literals / `std::allocator<char>` members on qbe.

## Root cause

Every TU gets its own copy of the entities C++ says the link must merge. The front end tags them in the generated C
and the back ends have to turn the tags into weak symbols:

| entity in the generated C | gcc backend | qbe backend (cproc drops attributes) |
|---|---|---|
| inline functions, template instantiations: `__attribute__((__weak__))` | weak, merged | `.weak` by `scripts/weak-symbols.rb` (already) |
| COMDAT **data**: variable templates, `__cmp_cat_id<>`, `std::numbers::pi_v<>`, static data members of templates, string literals and statics of inline functions: `__attribute__((__weak__))` on a data object | weak, merged | was strong: duplicate definitions (the script looked only for a function name) |
| inline members of a class under `extern template` (`std::allocator<char>`): emitted as `extern __inline__` with a body and **no** weak tag | strong, because gcc's default C99 inline rules make an `extern inline` definition an external definition | strong, same reason (cproc is C11) |
| a function returning a pointer to function (`void (**name(args))(void *)`, e.g. `std::get<1>` of a `unique_ptr` deleter) | weak | the script took the type `void` for the name, so the function stayed strong |

The third row is a GNU89 meaning: EDG expects `extern inline` to give an inlinable body and no out-of-line symbol
(the out-of-line copy lives in the TU that explicitly instantiates the template: libstdc++ itself for
`std::allocator<char>`, `c.cpp` for `Box<long>` in the test).

## Fix

- gcc: the driver passes `-fgnu89-inline` to the C compiler step, so an `extern inline` definition is never emitted
  out of line and the call binds to the instantiating TU.
- qbe: `scripts/weak-symbols.rb` (and its Python oracle `tests/mruby/oracle/weak-symbols.py`) marks, in addition to
  `__weak__` functions, `__weak__` data objects (every identifier before the `=` is a candidate; only labels the
  assembly defines get `.weak`) and any function declared `extern` with `__inline__` (a weak copy per object is a
  superset of the GNU89 behaviour: it merges, and a strong definition elsewhere still wins). `.c` inputs
  (`--c-input`) keep the C99 meaning of `extern inline`. The function name is the first word followed by `(` that
  does not open a grouping declarator `(*`.
- driver: `.o` files are accepted as the only inputs (`nfcxx a.o b.o -o x` links with the C++ runtime of the
  selected backend); `-c` already worked.

Entities that must be unique stay strong: ordinary functions and variables, and `static` / anonymous-namespace
objects (one per TU). `tests/multi-tu/main.cpp` checks one `next_id()` counter (a local static of an inline
function), one inline variable, one `Stats<int>::count`, separate `per_tu` copies, a polymorphic class used from
two TUs, `extern template` with a single explicit instantiation, and an exception thrown in one TU and caught in
another. No linker option that ignores duplicate definitions is used.

## Known front end limitation seen on the way

The operands of an overloaded `operator<<` chain are not evaluated left to right in the generated C
(`os << f() << x` may read `x` before calling `f()`), unlike C++17. The test avoids relying on it.
