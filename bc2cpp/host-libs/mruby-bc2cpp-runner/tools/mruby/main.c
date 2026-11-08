/* The bc2cpp command as a C program: boots the mruby state, sets ARGV and runs BC2CPPRunner.run (the baked bc2cpp entry).
   There is no script to read: the entry is bytecode in this binary (mruby-bc2cpp-sources), so the build needs neither the
   mruby command (mruby-bin-mruby) nor eval.

   The command line is bc2cpp's own. The two script names the callers use are still accepted as a first argument and
   skipped, so `BC2CPP_MRUBY_RUNNER` and tools/bc2cpp/mruby-ruby launch this binary as they launched bin/mruby:
     bc2cpp_main.rb ARGS...   run bc2cpp with ARGS
     mruby_tool.rb TOOL ARGS  run a baked tool (BC2CPPRunner.run_tool)
     ARGS...                  run bc2cpp with ARGS */
#include <mruby.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

static int
has_suffix(const char *s, const char *suffix)
{
  size_t n = strlen(s), m = strlen(suffix);
  return n >= m && strcmp(s + n - m, suffix) == 0 && (n == m || s[n - m - 1] == '/');
}

int
main(int argc, char **argv)
{
  mrb_state *mrb = mrb_open();
  const char *entry = "run";
  int first = 1;

  if (!mrb) {
    fputs("bc2cpp: cannot open an mruby state\n", stderr);
    return EXIT_FAILURE;
  }

  if (argc > 1 && has_suffix(argv[1], "bc2cpp_main.rb")) {
    first = 2;
  }
  else if (argc > 1 && has_suffix(argv[1], "mruby_tool.rb")) {
    first = 2;
    entry = "run_tool";
  }

  /* bc2cpp keeps a heap of 1-2 GB live; mruby's default (collect at twice the live size) spends most of the run in the
     collector. BC2CPP_GC_INTERVAL overrides the ratio (percent). */
  mrb->gc.interval_ratio = getenv("BC2CPP_GC_INTERVAL") ? atoi(getenv("BC2CPP_GC_INTERVAL")) : 400;
  int ai = mrb_gc_arena_save(mrb);
  mrb_value args = mrb_ary_new_capa(mrb, argc);
  for (int i = first; i < argc; i++) {
    mrb_ary_push(mrb, args, mrb_str_new_cstr(mrb, argv[i]));
  }
  mrb_define_global_const(mrb, "ARGV", args);
  mrb_gv_set(mrb, mrb_intern_lit(mrb, "$0"), mrb_str_new_cstr(mrb, "bc2cpp"));
  mrb_gc_arena_restore(mrb, ai);

  int status = EXIT_SUCCESS;
  struct RClass *runner = mrb_module_get(mrb, "BC2CPPRunner");
  mrb_funcall(mrb, mrb_obj_value(runner), entry, 0);
  if (mrb->exc) {
    MRB_EXC_CHECK_EXIT(mrb, mrb->exc);
    mrb_print_error(mrb);
    status = EXIT_FAILURE;
  }
  mrb_close(mrb);
  return status;
}
