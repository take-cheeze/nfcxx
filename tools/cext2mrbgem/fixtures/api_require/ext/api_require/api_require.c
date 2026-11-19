#include <ruby.h>

/* rb_require of a literal feature maps to the fork's require: time (mruby-time) and stringio (mruby-stringio) are provided by
   a build gem, so they become dependencies; a non-literal name cannot be checked and stays a stuck point */
void
Init_api_require(void)
{
    rb_require("time");
    rb_require("stringio");
    { const char *feat = "time"; rb_require(feat); }
    VALUE m = rb_define_module("RequireFixture");
    rb_define_module_function(m, "ok", NULL, 0);
}
