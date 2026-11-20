#include <mruby.h>
static int dispatches = 0;
// Every dynamic dispatch the compiled bodies make.
#define mrb_funcall_argv(M, ...) (++dispatches, (mrb_funcall_argv)(M, __VA_ARGS__))
#define mrb_funcall_id(M, ...) (++dispatches, (mrb_funcall_id)(M, __VA_ARGS__))
#define mrb_funcall(M, ...) (++dispatches, (mrb_funcall)(M, __VA_ARGS__))
#include "fixture_gen.cpp"
#include <mruby/irep.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

static void show(mrb_state* M, const char* label, mrb_value v) {
  mrb_value s = mrb_inspect(M, v);
  std::printf("%s => %.*s\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
}
static void show_exc(mrb_state* M, const char* label) {
  mrb_value e = mrb_obj_value(M->exc);
  M->exc = nullptr;
  mrb_value cls = mrb_str_new_cstr(M, mrb_obj_classname(M, e));
  std::printf("%s => raised %.*s\n", label, (int)RSTRING_LEN(cls), RSTRING_PTR(cls));
}
// Calls obj.meth(*args) and shows its value or the exception class.
// A compiled run also prints, indented, how many dynamic dispatches the call made.
static bool compiled = false;
static mrb_value call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                      const mrb_value* argv = nullptr) {
  dispatches = 0;
  mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
  int made = dispatches;
  if (M->exc) show_exc(M, label); else show(M, label, r);
  if (compiled) std::printf("  dispatches=%d\n", made);
  return M->exc ? mrb_nil_value() : r;
}
static int scenario(mrb_state* M) {
  mrb_value menu = mrb_obj_new(M, mrb_class_get(M, "Menu"), 0, nullptr);
  call(M, "run", menu, "run");
  call(M, "wrong pick", menu, "wrong");
  call(M, "wrong add", menu, "wrong_add");
  call(M, "wrong sorted", menu, "wrong_sorted");
  return 0;
}

static int run_vm(const std::vector<uint8_t>& bin, bool with_compiled) {
  mrb_state* M = mrb_open();
  mrb_load_irep_buf(M, bin.data(), bin.size());
  if (M->exc) { mrb_print_error(M); return 2; }
  compiled = with_compiled;
  if (with_compiled) {
    bc2cpp_gem_init(M);
    bc2cpp_set_instance_tts(M);
  mrb_define_private_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Foo"))), "initialize", Foo_initialize, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Foo"))), "size2", Foo_size2, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "pick", Menu_pick, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "add", Menu_add, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "computed", Menu_computed, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "later", Menu_later, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "loose", Menu_loose, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "sorted", Menu_sorted, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "keys_of", Menu_keys_of, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "shout", Menu_shout, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "run", Menu_run, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "wrong_sorted", Menu_wrong_sorted, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "wrong", Menu_wrong, MRB_ARGS_ANY());
  mrb_define_method(M, mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, "Menu"))), "wrong_add", Menu_wrong_add, MRB_ARGS_ANY());
  }
  int rc = scenario(M);
  mrb_close(M);
  // As each compiled gem's gem_final: the next VM may reuse this one's mrb_state address, which the
  // symbol and constant-site caches key on.
  bc2cpp_reset_symbol_cache();
  bc2cpp_reset_const_site_cache();
  if (with_compiled) bc2cpp_reset_owner_classes();
  return rc;
}
int main(int, char** argv) {
  std::ifstream in(argv[1], std::ios::binary);
  std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  for (int vm = 0; vm < 2; ++vm) {
    static const bool modes[] = { false, true };
    std::printf("== %s\n", modes[vm] ? "compiled" : "interpreted");
    if (int rc = run_vm(bin, modes[vm])) return rc;
  }
  return 0;
}
