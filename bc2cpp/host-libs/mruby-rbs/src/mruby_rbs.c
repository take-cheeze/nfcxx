/*
 * mruby glue for the RBS C core: RBS::Native.parse_signature(source) -> binary serialization.
 * The binary is decoded by lib/rbs/wasm/deserializer.rb. Parse errors raise RBS::Native::ParseError.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include "rbs/ast.h"
#include "rbs/parser.h"
#include "rbs/serialize.h"
#include "rbs/string.h"
#include "rbs/util/rbs_allocator.h"
#include "rbs/util/rbs_constant_pool.h"
#include "rbs/util/rbs_encoding.h"

static mrb_value mruby_rbs_parse_signature(mrb_state *mrb, mrb_value self) {
  mrb_value source;
  mrb_get_args(mrb, "S", &source);

  const char *start = RSTRING_PTR(source);
  const char *end = start + RSTRING_LEN(source);
  rbs_string_t string = rbs_string_new(start, end);
  const rbs_encoding_t *encoding = &rbs_encodings[RBS_ENCODING_UTF_8];

  rbs_parser_t *parser = rbs_parser_new(string, encoding, 0, (int)RSTRING_LEN(source));
  rbs_signature_t *signature = NULL;
  bool ok = rbs_parse_signature(parser, &signature);

  if (!ok || parser->error) {
    const char *message = parser->error ? parser->error->message : "RBS parse failed";
    mrb_value text = mrb_str_new_cstr(mrb, message);
    rbs_parser_free(parser);
    mrb_value klass = mrb_const_get(mrb, mrb_obj_value(mrb_module_get(mrb, "RBS")), mrb_intern_lit(mrb, "Native"));
    mrb_value error_class = mrb_const_get(mrb, klass, mrb_intern_lit(mrb, "ParseError"));
    mrb_exc_raise(mrb, mrb_obj_new(mrb, mrb_class_ptr(error_class), 1, &text));
  }

  rbs_string_t binary = rbs_serialize_node(parser->allocator, &parser->constant_pool, (rbs_node_t *)signature);
  mrb_value out = mrb_str_new(mrb, binary.start, (mrb_int)(binary.end - binary.start));
  rbs_parser_free(parser);
  return out;
}

void mrb_mruby_rbs_gem_init(mrb_state *mrb) {
  struct RClass *rbs = mrb_define_module(mrb, "RBS");
  struct RClass *native = mrb_define_module_under(mrb, rbs, "Native");
  mrb_define_class_under(mrb, native, "ParseError", mrb->eStandardError_class);
  mrb_define_module_function(mrb, native, "parse_signature", mruby_rbs_parse_signature, MRB_ARGS_REQ(1));
}

void mrb_mruby_rbs_gem_final(mrb_state *mrb) {
  (void)mrb;
}
