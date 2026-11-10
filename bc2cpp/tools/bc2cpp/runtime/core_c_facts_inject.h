/* Force-included (-include) into the mruby core's hash.c by the closed build, after bc2cpp wrote the facts header
 * (BC2CPP_CORE_C_FACTS, core_c_facts.rb) that BC2CPP_CORE_C_FACTS_H names. A fact the closed world proves replaces the core's
 * method-table lookup by its answer; without the fact, or in a world that can define the method at run time (eval, a
 * C gem installing it late), nothing changes. Sound only for a sealed build: bc2cpp's owner sets are closed by the same
 * condition. */
#ifndef BC2CPP_CORE_C_FACTS_INJECT_H
#define BC2CPP_CORE_C_FACTS_INJECT_H
/* hash.c's own include list, so that the macro below follows every declaration of mrb_method_memo */
#include <string.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/proc.h>
#include <mruby/internal.h>
#include BC2CPP_CORE_C_FACTS_H

#ifdef BC2CPP_CW_ONLY_default
static mrb_value mrb_hash_default(mrb_state *mrb, mrb_value hash); /* hash.c's own, defined further down */
/* Hash#default has no other definer: mrb_hash_get's memo of it would always answer mrb_hash_default. */
#define mrb_method_memo(mrb, obj, mid, slot) \
  ((slot) == MRB_MEMO_DEFAULT ? &(const struct mrb_cfunc_memo){.f = mrb_hash_default} : mrb_method_memo(mrb, obj, mid, slot))
#endif
#endif
