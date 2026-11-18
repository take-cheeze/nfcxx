/* smoke test: open mruby, run the converted gem's init, then evaluate each snippet and report its value or exception */
#include <stdio.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
void mrb_unf_ext_gem_init(mrb_state *mrb);

void mrb_init_mrbgems(mrb_state *mrb) { (void)mrb; }
static void eval_step(mrb_state *mrb, const char *label, const char *code) {
  mrb->exc = NULL;
  mrb_value r = mrb_load_string(mrb, code);
  if (mrb->exc) {
    mrb_value m = mrb_funcall(mrb, mrb_obj_value(mrb->exc), "message", 0);
    printf("%s: exception %s: %s\n", label, mrb_obj_classname(mrb, mrb_obj_value(mrb->exc)), mrb_string_value_ptr(mrb, m));
    mrb->exc = NULL;
  } else if (mrb_fixnum_p(r)) {
    printf("%s: fixnum %d\n", label, (int)mrb_fixnum(r));
  } else {
    printf("%s: type %d\n", label, (int)mrb_type(r));
  }
}
int main(void) {
  mrb_state *mrb = mrb_open();
  if (!mrb) { puts("mrb_open failed"); return 1; }
  mrb_unf_ext_gem_init(mrb);
  eval_step(mrb, "module", "UNF");
  eval_step(mrb, "class", "UNF::Normalizer");
  eval_step(mrb, "new", "UNF::Normalizer.new; 1");
  eval_step(mrb, "ascii nfc", "n = UNF::Normalizer.new; n.normalize(\"abc\", :nfc).bytesize");
  eval_step(mrb, "empty nfc", "n = UNF::Normalizer.new; n.normalize(\"\", :nfc).bytesize");
  eval_step(mrb, "ascii nfd", "n = UNF::Normalizer.new; n.normalize(\"abc\", :nfd).bytesize");
  eval_step(mrb, "bad form", "n = UNF::Normalizer.new; n.normalize(\"abc\", :zzz).bytesize");
  eval_step(mrb, "nfc of e+acute (expect 2)", "n = UNF::Normalizer.new; n.normalize(\"e\\xcc\\x81\", :nfc).bytesize");
  eval_step(mrb, "nfd of e-acute (expect 3)", "n = UNF::Normalizer.new; n.normalize(\"\\xc3\\xa9\", :nfd).bytesize");
  eval_step(mrb, "nfc content: first byte of e-acute (expect 195)", "n = UNF::Normalizer.new; n.normalize(\"e\\xcc\\x81\", :nfc).getbyte(0)");
  eval_step(mrb, "symbol", ":nfc");
  eval_step(mrb, "core nomethod", "nil.no_such_method");
  eval_step(mrb, "core zerodiv", "1/0");
  eval_step(mrb, "core raise", "raise \"x\"");
  eval_step(mrb, "arity", "n = UNF::Normalizer.new; n.normalize(1)");
  eval_step(mrb, "type", "n = UNF::Normalizer.new; n.normalize(1, :nfc)");
  mrb_close(mrb);
  return 0;
}
