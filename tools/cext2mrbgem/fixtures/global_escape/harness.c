/* Runs the converted global_escape gem in two mruby states (linked by tests/cext2mrbgem/run.sh against a built libmruby):
 * an exception escapes GlobalEscape.call in state a (the Ruby rescue catches it in the VM), after which the global must hold
 * no state; state a is closed, then state b is initialised and called, which must not abort on a stale state.
 * Exit 0 when all of it holds, 1 when the global is left set, 2 for a wrong result. */
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <stdio.h>
#include <string.h>

extern struct mrb_state *global_escape_bc2_mrb;
void mrb_global_escape_gem_init(mrb_state *mrb);

static int want_string(mrb_value r, const char *want) {
    return mrb_string_p(r) && strcmp(RSTRING_PTR(r), want) == 0;
}

int main(void) {
    mrb_state *a = mrb_open();
    mrb_global_escape_gem_init(a);
    mrb_value r = mrb_load_string(a, "begin; GlobalEscape.call(BasicObject.new); rescue NoMethodError; 'rescued'; end");
    if (!want_string(r, "rescued")) { fprintf(stderr, "no escape from GlobalEscape.call\n"); return 2; }
    if (global_escape_bc2_mrb != NULL) { fprintf(stderr, "global left set after an escaped exception\n"); return 1; }
    mrb_close(a);

    mrb_state *b = mrb_open();
    mrb_global_escape_gem_init(b);
    r = mrb_load_string(b, "GlobalEscape.call(:sym)");
    if (!want_string(r, "sym")) { fprintf(stderr, "call on a new state gave the wrong result\n"); return 2; }
    if (global_escape_bc2_mrb != NULL) { fprintf(stderr, "global left set after a normal return\n"); return 1; }
    mrb_close(b);
    printf("ok\n");
    return 0;
}
