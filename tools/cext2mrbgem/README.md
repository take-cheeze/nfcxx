# cext2mrbgem: CRuby C extension to mrbgem converter

`convert_mrbgem.rb [--name GEM] <cext_dir> <out_dir>` reads a CRuby extension directory
(`ext/<name>/*.c`, `*.h`, `extconf.rb`) as text and writes an mruby mrbgem directory:
`mrbgem.rake`, `src/*.c`, `src/gem_init.c`, `include/*.h`, plus `REFUSALS.txt`,
`WARNINGS.txt` and `conversion_log.json`.

The input is never compiled, loaded or executed. Nothing the converter writes has been
compiled either: the output is text for review, and a directory with refusals is marked
`NOT_BUILDABLE`.

## Run

The converter is CRuby code and needs only the standard library (`json`, `fileutils`, `set`, and `fiddle` for the
libclang scanner). It was tested with Ruby 3.3 and Ruby 4.0:

```
ruby tools/cext2mrbgem/convert_mrbgem.rb [--name GEM] [--scanner auto|libclang|regex] [--define NAME[=VALUE]]... <cext_dir> <out_dir>
```

`--name` sets the gem name (default: the name of `<cext_dir>`). Exit status: 0 converted with no refusals;
2 refusals recorded (the output is marked `NOT_BUILDABLE`); 1 usage or input error.

## Declaration scanner

The function declarations and definitions are found by one of two scanners, recorded as `"scanner"` in
`conversion_log.json`:

- `regex`: the `DEF_RE` regex over the text (the original scan).
- `libclang`: `decl_scan.rb` loads `libclang-edg.so` (`lib/libclang-edg`, built by `scripts/build-libclang-edg.sh`)
  through Fiddle and walks each file's declarations with `clang_visitChildren`. The library gives each function's
  name position; storage, return type, parameters and braces are read from the text with the regex scan's rules.
  C sources go through `libclang-cursors-c` (`LIBCLANG_EDG_RUNNER`), which runs `scripts/libclang-cursors --c`.
- `auto` (the default) uses libclang when the library loads, and the regex otherwise.

Environment: `CEXT_LIBCLANG` (the library; relative paths are from the repository root, default
`build/libclang-edg/libclang-edg.so`), `CEXT_RUBY_INCLUDE` (colon-separated Ruby header directories for a file that
includes `ruby.h`; default: this Ruby's own), `CEXT_LIBCLANG_LOG` (a file for the front end's diagnostics; they are
discarded otherwise). The input is never compiled or run: the front end only parses it.

What differs from the regex scan, and why:

- A file the front end cannot parse is read by the regex scan, and listed in `scanner_fallback`. Headers that are
  not self-contained (`date_tmx.h`, `crypt.h`) and sources that need extconf's `HAVE_*` results are such files.
  `--define` passes `-D` to the front end; the converter never runs `extconf.rb`, so it does not know those results.
- The front end honours `#if`: code the configuration excludes is not a declaration. A registration (`rb_define_method`)
  is still found by text, so one whose function is excluded is refused with "no active definition" instead of being
  converted.
- A prototype with a definition later in the same file is listed by the library only at the definition; the
  prototype is taken from the text.
- Declarations inside function bodies are not listed (the library gives statements no cursors).

## Behaviour

- Calls and macros are mapped through `api_map.json`. Any CRuby-looking identifier without
  an entry is refused: a marker comment is left in the output and the item is listed in
  `REFUSALS.txt`. Exit status 2 means refusals were recorded.
- Some mappings are lossy. Those carry a `caveat`, logged with each rewrite (for example
  `StringValuePtr` assumes an existing String).
- `rb_ext_ractor_safe` and the `ruby/util.h` include are dropped with a warning
  (`WARNINGS.txt`, printed to stderr). Dropped items never make the output buildable by
  themselves.
- `rb_thread_call_without_gvl` is modelled on mruby-uv: `include/nfcx_uv_thread.h` runs the
  function on the libuv thread pool and runs the loop until it finishes. The gem then
  depends on `mruby-uv`.
- A variadic method (`rb_define_method(..., -1)`, C signature `(int argc, VALUE *argv, VALUE self)`) is
  defined with `MRB_ARGS_ANY()`. The converted function takes `(mrb_state *mrb, mrb_value self)` and reads the
  arguments back with `mrb_get_args(mrb, "*", ...)` into locals named as in the original. The array form
  (`argc -2`) is refused.
- `rb_scan_args(argc, argv, "<lead><optional>", &v...)` inside a variadic method becomes
  `mrb_get_args(mrb, "o|o", &v...)`, with optional outputs set to nil first. Only as a statement and only on the
  method's own argc and argv. Rest (`*`), keyword (`:`), block and fixed-arity forms are refused.
- `rb_define_module_function(mod, "name", fn, argc)` becomes `mrb_define_module_function`, which defines the
  singleton and private instance method as CRuby does. `rb_define_const(klass, "NAME", v)` becomes
  `mrb_define_const(mrb, klass, "NAME", v)`. Both need the receiver to be a tracked class or module variable (a
  `struct RClass *`) or `rb_cObject`; a `VALUE` parameter or local is refused, since it would need an unchecked
  `mrb_class_ptr`.
- `rb_const_get(klass, id)` becomes `mrb_const_get(mrb, klass, id)`. A module receiver does not fall back to
  `Object` in mruby, and there is no autoload; both are recorded as caveats. `rb_const_get_at` is refused: no mruby
  function looks up only the receiver.
- A helper that needs the mruby state gets an `mrb_state *mrb` parameter in its definition, in every prototype (the
  `.c` and `.h` files are both scanned) and at every call site. This needs a unique definition, and every use must be
  a direct call inside a function body whose name is not shadowed there. A use as a value (a function pointer) or at
  file scope is refused. A non-static helper is threaded with a caveat, since its signature changes. Any function
  that calls a helper which is not threaded is refused, so no call is left passing an `mrb` that is not in scope.
- `RB_GC_GUARD(x)` becomes `mrb_gc_protect(mrb, x)` inside a function that has an mrb_state.
  Values that must outlive a call need `mrb_gc_register`, which is not converted.
- `RB_LIKELY(x)` and `RB_UNLIKELY(x)` become `!!(x)`: the branch hint is dropped and the 0 or 1 value is kept.
- `RB_TYPE_P(obj, T_X)` becomes `(mrb_type(obj) == MRB_TT_X)` when `T_X` maps exactly to an `MRB_TT_` type with no
  caveat, and `obj` is a plain local. `T_DATA` (TypedData is not RData), `T_NIL`, `T_FIXNUM` and nested objects are refused.
- `rb_gc_register_mark_object(v)` becomes `mrb_gc_register(mrb, v)`: mruby keeps the value in its root table
  (`src/gc.c`) until the state is closed, as CRuby keeps it. `rb_gc_start()` as a statement becomes
  `mrb_full_gc(mrb)`; CRuby's nil return value is not produced, so a used value is refused. `rb_gc_writebarrier(a, b)`
  as a statement on plain locals becomes an immediate-guarded `mrb_field_write_barrier_value`. These stay refused:
  address registration (`rb_gc_register_address`, `rb_global_variable`: mruby roots values, not variables),
  `rb_gc_enable` and `rb_gc_disable` (no mruby function; the flag is `gc.disabled`), and `rb_gc_mark` and
  `rb_gc_mark_movable` (`mrb_data_type` has no mark callback, so a mark function would never run).
- Refusals are written in a stable order. Registered-method checks visit the function names in sorted order; the
  former Python converter iterated a set there, so its refusal order changed between runs.
- The Init entry is the `Init_<name>` that `extconf.rb` passes to `create_makefile`. Other
  `Init_` functions are kept under `#if 0`, because CRuby never calls them.
- `RB_GC_GUARD` outside a function with an mrb_state, `NUM2ULONG`-style signedness, and
  similar cases are refused or noted in the caveat; see `api_map.json`.

## Tests

`tests/cext2mrbgem/run.sh` runs the converter (`RUBY` selects the interpreter, default `ruby`) on the in-repo fixtures and checks the exit
status and key output, once with `--scanner regex` and once with `--scanner libclang` (printed as SKIP when the library does
not load). It also converts `bcrypt-ruby` at a pinned commit (fetched to
`build/cext2mrbgem/`; set `BCRYPT_DIR` to use an existing checkout) and checks that the
conversion has no refusals, the entry function is `mrb_bcrypt_gem_init`, and the two
expected warnings are recorded. None of the outputs are compiled by the test.

## Known gap: helper threading and exceptions

Helpers that need the mruby state read a file-scope global `<funcname>_bc2_mrb`. Each
wrapped method saves the previous value on entry and restores it on exit. mruby raises
exceptions by longjmp, so when an exception unwinds through a wrapped method the
restore is skipped. The global can then hold a stale state for code that runs later.
Nothing in the converter or its tests detects this, and the generated C has not been
compiled. Restoring at each call boundary, or refusing helpers that run after a call
which may raise, would close the gap. Until then, treat the helper path as unverified.
