/*
** mruby_prism.c: the mruby face of the Prism parser (vendor/prism).
**
** Prism::Native.parse_serialized(source) parses a Ruby source string and returns Prism's binary serialization
** of the AST, as pm_serialize_parse writes it. The Ruby side decodes it.
*/

#include <mruby.h>
#include <mruby/error.h>
#include <mruby/string.h>

#include <prism.h>

static mrb_value
mrb_prism_native_parse_serialized(mrb_state *mrb, mrb_value self)
{
  mrb_value source;
  mrb_get_args(mrb, "S", &source);

  pm_buffer_t buffer;
  if (!pm_buffer_init(&buffer)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "prism: cannot allocate the serialization buffer");
  }

  /* NULL options: the parser's defaults, as the prism gem uses for a plain parse. */
  pm_serialize_parse(&buffer, (const uint8_t *)RSTRING_PTR(source), (size_t)RSTRING_LEN(source), NULL);

  mrb_value out = mrb_str_new(mrb, pm_buffer_value(&buffer), (mrb_int)pm_buffer_length(&buffer));
  pm_buffer_free(&buffer);
  return out;
}

static mrb_value
mrb_prism_native_lex_serialized(mrb_state *mrb, mrb_value self)
{
  mrb_value source;
  mrb_get_args(mrb, "S", &source);

  pm_buffer_t buffer;
  if (!pm_buffer_init(&buffer)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "prism: cannot allocate the serialization buffer");
  }

  /* Tokens, comments and diagnostics of the source, as Prism.lex reports them (pm_serialize_lex). */
  pm_serialize_lex(&buffer, (const uint8_t *)RSTRING_PTR(source), (size_t)RSTRING_LEN(source), NULL);

  mrb_value out = mrb_str_new(mrb, pm_buffer_value(&buffer), (mrb_int)pm_buffer_length(&buffer));
  pm_buffer_free(&buffer);
  return out;
}

void
mrb_mruby_prism_gem_init(mrb_state *mrb)
{
  struct RClass *prism = mrb_define_module(mrb, "Prism");
  struct RClass *native = mrb_define_module_under(mrb, prism, "Native");
  mrb_define_module_function(mrb, native, "parse_serialized", mrb_prism_native_parse_serialized, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, native, "lex_serialized", mrb_prism_native_lex_serialized, MRB_ARGS_REQ(1));
}

void
mrb_mruby_prism_gem_final(mrb_state *mrb)
{
}
