#include <ruby.h>

/* Q constants as constant values: a static local's initializer and a file-scope table entry. The fork's mrb_value is a word
   (word boxing) or a struct (no boxing), so the literal is written with the layout of the boxing the build selects. */
struct entry { const char *name; VALUE value; };
static struct entry table[] = { { "nil", Qnil }, { "true", Qtrue }, { "false", Qfalse } };

static VALUE pick(int i) {
  static VALUE pat = Qnil;
  if (i > 0) pat = Qtrue;
  return i > 1 ? pat : table[i].value;
}

void Init_api_qconst_box(void) {
  VALUE v = pick(1);
  (void)v;
}
