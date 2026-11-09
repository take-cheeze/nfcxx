// LIT_SYM: the symbol of a string literal, interned once per call site
// instead of hashed on every call (the resumable and Fiber runtimes ask for
// the same few names on every step). A cached symbol is reused only while it
// is a presym (its id is fixed at build time) or while this state's symbol of
// that id has this literal's name: a symbol is unique by name in a state, so a
// symbol cached from another mrb_state is never returned.
#pragma once

#include <mruby.h>
#include <mruby/presym.h>
#include <stddef.h>
#include <string.h>

#ifndef BC2CPP_LIT_SYM
static inline mrb_sym bc2cpp_lit_sym(mrb_state* M,
                                     mrb_sym& cache,
                                     const char* lit,
                                     size_t len) {
  if (cache) {
#if defined(MRB_PRESYM_MAX) && !defined(MRB_NO_PRESYM)
    if (cache <= MRB_PRESYM_MAX)
      return cache;
#endif
    mrb_int n = 0;
    const char* name = mrb_sym_name_len(M, cache, &n);
    if (name && (size_t)n == len && memcmp(name, lit, len) == 0)
      return cache;
  }
  return cache = mrb_intern_static(M, lit, len);
}
#define BC2CPP_LIT_SYM(M, lit)                                   \
  ([](mrb_state* bc2cpp_lit_m) -> mrb_sym {                      \
    static mrb_sym bc2cpp_lit_cache = 0;                         \
    return bc2cpp_lit_sym(bc2cpp_lit_m, bc2cpp_lit_cache, (lit), \
                          sizeof(lit) - 1);                      \
  }(M))
#endif
