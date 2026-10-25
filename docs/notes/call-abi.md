# Classes in calls: registers or a hidden pointer

The IA-64 C++ ABI passes and returns a class object in registers, like a C struct, unless the class is "non-trivial for
the purposes of calls": it has a non-trivial eligible copy constructor, move constructor or destructor, or all of its
copy and move constructors are deleted. Such a class goes through memory: the caller passes the address of a temporary
(for a return value, a hidden first argument). nfcxx code calls, and is called by, code that g++ compiled (libstdc++,
libtorch, any C++ library on the system), so EDG has to answer as g++ does for every class; when it does not, one side
writes the value where the other does not read it.

EDG makes the choice in `type_returned_by_cctor` (`src/il.c`) from the class flags that `check_special_member_functions`
(`src/class_decl.c`) computes when the class is completed. The generated C then has either a struct return or a
`void f(struct S *)` with the result written through the pointer, and the C compiler (gcc or cproc/QBE) passes a struct
in registers as the C ABI says.

## The bugs

**C++20 conditionally trivial special members (P0848).** A class template may declare two copy constructors, one
constrained and defaulted, one user-provided:

```cpp
template<class T> struct _Optional_base {   // libstdc++ 15, <optional>, C++20
  _Optional_base(const _Optional_base& o) : _M_payload(...) {}                       // user-provided
  _Optional_base(const _Optional_base&) requires is_trivially_copy_constructible_v<T> = default;
  ...
};
```

Only the eligible one counts ([special]/6): one whose constraints are satisfied and than which no other satisfied one
of the same kind and parameter type is more constrained. For `T = int` both are satisfied and the defaulted one is more
constrained, so it is the eligible one, `std::optional<int>` is trivially copyable and g++ returns it in `rax`. EDG set
`has_user_provided_copy_constructor` for the user-provided one as soon as it was declared
(`check_member_decl_is_copy_constructor`) and never looked at eligibility, so for EDG `std::optional<int>` was not
bitwise copyable and went through memory. A gcc-built `std::optional<E> f()` read in nfcxx code was empty;
libtorch's `at::getAccelerator()` returns `std::optional<c10::DeviceType>`, so `torch::manual_seed` found no
accelerator and threw (`docs/notes/bundle.md`, "libtorch with CUDA"). The same held for move constructors, and for the
type traits (`std::is_trivially_copyable_v<std::optional<int>>` was false).

Fix (`discount_ineligible_copy_and_move_ctors`, called from `check_special_member_functions` when concepts are
enabled): before the user-provided flags clear `construction_by_bitwise_copy_allowed`, they are recomputed from the
eligible user-provided copy and move constructors only. A constructor is ineligible when `is_ineligible` says its
trailing requires-clause is not satisfied, or when another satisfied copy (or move) constructor with the same parameter
qualifiers is more constrained (`compare_constraints`, as the prospective destructors already do).

**A deleted copy constructor beside a trivial move constructor.** `type_returned_by_cctor` sent any class with a
deleted copy or move constructor (`has_deleted_copy_or_move_constructor`) through memory. The ABI asks for all of them
deleted: `struct M { M(const M&) = delete; M(M&&) = default; int v; };` travels in registers with g++ and clang. Now
`all_copy_and_move_ctors_deleted` checks that every eligible copy and move constructor is deleted.

Both changes are on the EDG fork (https://github.com/take-cheeze/edg-compiler, branch `nfcxx/p0848-call-abi`, on top of
`nfcxx/cwg2082b-pass`); `3rd/edg` points at it (`eval-order.md` describes the arrangement).

## Test (`tests/call-abi/run.sh`)

`abi.h` declares functions that return and take `std::optional` of a one-byte enum, `int`, `long` and `std::string`,
two-constructor classes in each combination (complementary constraints, unconstrained user-provided beside a
constrained default, the move constructor pair), a class with such a member, and a move-only class with a trivial move
constructor. `lib.cpp` defines them and `main.cpp` calls them; both directions are built (a g++ library called by the
nfcxx program, an nfcxx library called by the g++ program) on both backends, and each must print what the all-g++ build
prints. Before the fix all four failed (`optional::operator*` asserting on an empty value, garbage `int`s).
