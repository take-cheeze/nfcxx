# SYCL kernel-info builtins in the front end

The real oneAPI `<sycl/sycl.hpp>` headers name kernels and describe their parameters through `__builtin_sycl_*`
builtins (`sycl/detail/kernel_desc.hpp`, `sycl/detail/compile_time_kernel_info.hpp`). `__has_builtin` must report
them, or the headers fall back to integration headers that a host compile does not have. The builtins live in the
EDG fork (3rd/edg, branch `nfcxx/sycl-kernel-builtins`); this note records what each one yields for nfcxx.

Every builtin takes `KernelIdentity<K>()` (a value of the header's `sycl::detail::KernelIdentity<K>` class, only its
type is used, the expression is not evaluated). `K` is the kernel object type, e.g. a lambda's closure type.

| builtin | yields | status |
| --- | --- | --- |
| `__builtin_sycl_unique_stable_name(T)` | `const char *`: the mangled name of the type (`mangled_typeinfo_string`) | done; a dependent `T` folds at instantiation |
| `__builtin_sycl_kernel_name(KI<K>())` | `sycl::detail::string_view` of the mangled name of `K` | done, constant expressions (the headers' `constexpr` info) |
| `__builtin_sycl_kernel_file_name(KI<K>())` | `string_view` of the file of `K`'s declaration | done, constant expressions |
| `__builtin_sycl_kernel_function_name(KI<K>())` | `string_view`, always `""` | placeholder: the enclosing function is not recorded yet |
| `__builtin_sycl_kernel_line_number(KI<K>())` / `_column_number` | `unsigned`: line and column of `K`'s declaration | done |
| `__builtin_sycl_kernel_param_count(KI<K>())` | `unsigned`: the non-static data members of `K` | done for classes; lambdas see no fields (below) |
| `__builtin_sycl_kernel_param_kind(KI<K>(), I)` | `sycl::detail::kernel_param_kind_t` (`int` without the headers) | done for a constant `I`: pointer = `kind_pointer`, standard layout = `kind_std_layout`; other captures are an error |
| `__builtin_sycl_kernel_param_size(KI<K>(), I)` / `_offset` | `int`: size and byte offset of member `I` | done for a constant `I` |
| `__builtin_sycl_kernel_param_access_target(KI<K>(), I)` | `int` | `0`; only accessors have one, and accessor captures are not supported |

The string builtins have a class type, so the front end evaluates them with the interpreter (`interpret.c`,
`do_constexpr_sycl_kernel_info`), the way `std::source_location` values are built; the scan-time fold therefore
leaves them to the interpreter. Used outside a constant expression they are not lowered yet (internal error).

## Known limits

- **Lambda captures.** Closure fields are created lazily (`field_for_lambda_capture`, class_decl.c), so the field list
  is not reliable when the builtins fold. A capturing lambda reports zero parameters. Fixing this needs the closure's
  capture list.
- **Run-time parameter index.** `__builtin_sycl_kernel_param_*` with an index that is not a constant (the headers'
  `getKernelParamDesc`) is written by the C back end as a conditional over the parameters. The class's fields are
  gone by then, so the back end stops with an internal error. The table has to be taken earlier, at lowering.
- **Kernel name and the header's size check.** The oneAPI `StoreLambda` checks `sizeof(KernelType) == Info.KernelSize`
  unless `Info.Name` is empty. The builtin path of `CompileTimeKernelInfo` passes `KernelSize` as 0, so a non-empty
  name fails that `static_assert` (`handler.hpp`, "Unexpected kernel lambda size"). Real clang never gets there: its
  host pass uses integration headers. Passing that check needs either an empty name (which the header's own runtime
  `assert(Info.Name != "")` rejects) or the integration-header path, a design decision still open.

## Regression cases

`tests/cases/sycl_unique_stable_name.cpp` and `tests/cases/sycl_kernel_*.cpp`, one per builtin. Each declares the
oneAPI namespace layout (`sycl::_V1::detail`) it needs, so it runs without the SYCL headers.
