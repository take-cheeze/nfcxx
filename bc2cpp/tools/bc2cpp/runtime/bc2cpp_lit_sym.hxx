// LIT_SYM: the symbol of a string literal, interned once per call site
// instead of hashed on every call (the resumable and Fiber runtimes ask for
// the same few names on every step).
#pragma once

#include <mruby.h>
#include <mruby/presym.h>
#include <stddef.h>
#include <string.h>

// STATE_EPOCH: a per-state cache key. The first state to ask gets a
// generation, which mrb_close ends (mrb_state_atexit). A value cached under a
// generation is that state's for as long as the generation is current, so it
// is never handed to a later state, even one allocated at the same address.
// Any other state open at the same time gets 0 and caches nothing.
struct Bc2cppStateEpoch {
  mrb_state* state;
  unsigned gen;
};
inline Bc2cppStateEpoch bc2cpp_state_epoch = {nullptr, 0};

static void bc2cpp_state_epoch_close(mrb_state* M) {
  if (bc2cpp_state_epoch.state == M) {
    bc2cpp_state_epoch.state = nullptr;
    ++bc2cpp_state_epoch.gen;
  }
}

[[maybe_unused]] static inline unsigned bc2cpp_state_gen(mrb_state* M) {
  if (bc2cpp_state_epoch.state == M)
    return bc2cpp_state_epoch.gen;
  if (bc2cpp_state_epoch.state)
    return 0;
  mrb_state_atexit(M, bc2cpp_state_epoch_close);
  bc2cpp_state_epoch.state = M;
  return ++bc2cpp_state_epoch.gen;
}

#ifndef BC2CPP_LIT_SYM
struct Bc2cppLitSymCache {
  mrb_sym sym;
  unsigned gen;
};

// Without a generation (a second open state), a cached symbol is reused only
// while it is a presym (its id is fixed at build time) or while this state's
// symbol of that id has this literal's name.
static inline mrb_sym bc2cpp_lit_sym(mrb_state* M,
                                     Bc2cppLitSymCache& cache,
                                     const char* lit,
                                     size_t len) {
  const unsigned gen = bc2cpp_state_gen(M);
  if (gen && cache.gen == gen)
    return cache.sym;
  if (cache.sym && !gen) {
#if defined(MRB_PRESYM_MAX) && !defined(MRB_NO_PRESYM)
    if (cache.sym <= MRB_PRESYM_MAX)
      return cache.sym;
#endif
    mrb_int n = 0;
    const char* name = mrb_sym_name_len(M, cache.sym, &n);
    if (name && (size_t)n == len && memcmp(name, lit, len) == 0)
      return cache.sym;
  }
  cache.sym = mrb_intern_static(M, lit, len);
  cache.gen = gen;
  return cache.sym;
}
#define BC2CPP_LIT_SYM(M, lit)                                   \
  ([](mrb_state* bc2cpp_lit_m) -> mrb_sym {                      \
    static Bc2cppLitSymCache bc2cpp_lit_cache = {0, 0};          \
    return bc2cpp_lit_sym(bc2cpp_lit_m, bc2cpp_lit_cache, (lit), \
                          sizeof(lit) - 1);                      \
  }(M))
#endif
