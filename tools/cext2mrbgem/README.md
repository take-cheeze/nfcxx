# cext2mrbgem: CRuby C extension to mrbgem converter

`convert_mrbgem.py [--name GEM] <cext_dir> <out_dir>` reads a CRuby extension directory
(`ext/<name>/*.c`, `*.h`, `extconf.rb`) as text and writes an mruby mrbgem directory:
`mrbgem.rake`, `src/*.c`, `src/gem_init.c`, `include/*.h`, plus `REFUSALS.txt`,
`WARNINGS.txt` and `conversion_log.json`.

The input is never compiled, loaded or executed. Nothing the converter writes has been
compiled either: the output is text for review, and a directory with refusals is marked
`NOT_BUILDABLE`.

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
- `RB_GC_GUARD(x)` becomes `mrb_gc_protect(mrb, x)` inside a function that has an mrb_state.
  Values that must outlive a call need `mrb_gc_register`, which is not converted.
- The Init entry is the `Init_<name>` that `extconf.rb` passes to `create_makefile`. Other
  `Init_` functions are kept under `#if 0`, because CRuby never calls them.
- `RB_GC_GUARD` outside a function with an mrb_state, `NUM2ULONG`-style signedness, and
  similar cases are refused or noted in the caveat; see `api_map.json`.

## Tests

`tests/cext2mrbgem/run.sh` runs the converter on the in-repo fixtures and checks the exit
status and key output. It also converts `bcrypt-ruby` at a pinned commit (fetched to
`build/cext2mrbgem/`; set `BCRYPT_DIR` to use an existing checkout) and checks that the
conversion has no refusals, the entry function is `mrb_bcrypt_gem_init`, and the two
expected warnings are recorded. None of the outputs are compiled by the test.
