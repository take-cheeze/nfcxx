#include <ruby.h>
#include <string.h>
RUBY_EXTERN unsigned long ruby_scan_digits(const char *str, ssize_t len, int base, size_t *retlen, int *overflow);
static VALUE mScanDigits;
static VALUE sd_value(VALUE self, VALUE s) {
    const char *p = StringValueCStr(s);
    size_t n = strlen(p);
    int ov;
    unsigned long v = ruby_scan_digits(p, (ssize_t)n, 10, &n, &ov);
    return ov ? Qnil : ULONG2NUM(v);
}
void Init_api_scan_digits(void) {
    mScanDigits = rb_define_module("ScanDigits");
    rb_define_module_function(mScanDigits, "value", sd_value, 1);
}
