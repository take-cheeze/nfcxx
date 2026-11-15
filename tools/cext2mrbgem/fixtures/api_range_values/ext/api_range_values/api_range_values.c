#include <ruby.h>
static VALUE mRangeValues;
static VALUE rv_span(VALUE self, VALUE r) {
    VALUE beg, end;
    int excl;
    if (!rb_range_values(r, &beg, &end, &excl)) return Qnil;
    return excl ? beg : end;
}
void Init_api_range_values(void) {
    mRangeValues = rb_define_module("RangeValues");
    rb_define_module_function(mRangeValues, "span", rv_span, 1);
}
