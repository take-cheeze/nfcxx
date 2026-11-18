#include <ruby.h>

/* require of a feature the build provides (time: mruby-time) maps to the fork's require; one it does not (stringio) stays a
   stuck point, as does a feature name that is not a literal */
void
Init_api_require(void)
{
    rb_require("time");
    rb_require("stringio");
    { const char *feat = "time"; rb_require(feat); }
    VALUE m = rb_define_module("RequireFixture");
    rb_define_module_function(m, "ok", NULL, 0);
}
