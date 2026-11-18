/* Ruby-level probes of a converted gem. Opens mruby, runs the gem's init (GEM_INIT, a -D define), then reads probe lines from
 * argv[1]. Each line is "expression<TAB>expected": expected is the to_s of the value, or "!ClassName" when the expression must
 * raise an exception of that class (a stub for a stuck point raises NotImplementedError). Prints ok/FAIL per line; exit 1 on any FAIL. */
#include <stdio.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
void GEM_INIT(mrb_state *mrb);
void mrb_init_mrbgems(mrb_state *mrb); /* the real one, from the gems archive: loads the mruby gems (Time, IO, ...) */
int main(int argc, char **argv) {
  FILE *f = argc > 1 ? fopen(argv[1], "r") : NULL;
  if (!f) { puts("usage: probes FILE"); return 2; }
  mrb_state *mrb = mrb_open();
  if (!mrb) { puts("mrb_open failed"); return 2; }
  mrb_init_mrbgems(mrb);
  GEM_INIT(mrb);
  char line[4096];
  int pass = 0, fail = 0;
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\r\n")] = 0;
    if (!line[0] || line[0] == '#') continue;
    char *tab = strchr(line, '\t');
    if (!tab) continue;
    *tab = 0;
    const char *expr = line, *expected = tab + 1;
    int want_raise = expected[0] == '!';
    char code[4200];
    snprintf(code, sizeof code, "(%s).to_s", expr);
    mrb->exc = NULL;
    mrb_value r = mrb_load_string(mrb, code);
    if (mrb->exc) {
      const char *cls = mrb_obj_classname(mrb, mrb_obj_value(mrb->exc));
      mrb_value m = mrb_funcall(mrb, mrb_obj_value(mrb->exc), "message", 0);
      mrb->exc = NULL;
      if (want_raise && strcmp(cls, expected + 1) == 0) { pass++; printf("ok   %s  (raises %s)\n", expr, cls); }
      else { fail++; printf("FAIL %s\n     exception %s: %s\n     expected %s\n", expr, cls, mrb_string_value_ptr(mrb, m), expected); }
      continue;
    }
    const char *got = mrb_string_value_ptr(mrb, r);
    if (!want_raise && strcmp(got, expected) == 0) { pass++; printf("ok   %s\n", expr); }
    else { fail++; printf("FAIL %s\n     got      %s\n     expected %s\n", expr, got, expected); }
  }
  fclose(f);
  printf("%d passed, %d failed\n", pass, fail);
  mrb_close(mrb);
  return fail ? 1 : 0;
}
