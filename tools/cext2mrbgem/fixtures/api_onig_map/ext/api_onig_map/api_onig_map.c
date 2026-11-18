#include <ruby.h>
#include <ruby/re.h>

/* CRuby's Onigmo API: a Regexp test (RB_TYPE_P with T_REGEXP), the compiled regex of a Regexp (RREGEXP_PTR), and a match
   region initialised and freed with the library's calls */
static VALUE
om_is_regexp(VALUE self, VALUE v)
{
    return RB_TYPE_P(v, T_REGEXP) ? Qtrue : Qfalse;
}

static VALUE
om_match(VALUE self, VALUE re, VALUE str)
{
    struct re_registers regs;
    OnigPosition pos;
    onig_region_init(&regs);
    pos = onig_search(RREGEXP_PTR(re), (UChar *)RSTRING_PTR(str), (UChar *)(RSTRING_PTR(str) + RSTRING_LEN(str)),
                      (UChar *)RSTRING_PTR(str), (UChar *)(RSTRING_PTR(str) + RSTRING_LEN(str)), &regs, ONIG_OPTION_NONE);
    onig_region_free(&regs, 0);
    return pos >= 0 ? Qtrue : Qfalse;
}

void
Init_api_onig_map(void)
{
    VALUE m = rb_define_module("OnigMap");
    rb_define_module_function(m, "regexp?", om_is_regexp, 1);
    rb_define_module_function(m, "match?", om_match, 2);
}
