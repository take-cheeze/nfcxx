// SEND_COUNTER: counts the by-name sends and method searches a closed bc2cpp host makes, per call site. Linked into
// the headless host by send_counter.bash (`ld --wrap` on each function below), read by send_counter_report.rb.
//
// Each wrapper records (kind, method name, the first DEPTH return addresses of the caller chain) and calls the real
// function. A call is seen only where it crosses a translation unit: the linker rewrites references to an undefined
// symbol, so a call inside class.c to mrb_method_search_vm, or inside vm_frames.cxx from mrb_funcall_send to
// mrb_funcall_with_method, is not (the report drops the latter by its caller).
//
// Off unless BC2CPP_SENDCNT_OUT names a file (BC2CPP_SENDCNT_DETAIL=1 adds the lookup's class and cache slot to a search's name); the counts are written there at exit, one row per distinct
// (kind, name, chain): kind TAB name TAB count TAB hex,hex,... (return addresses, innermost first).
#include <execinfo.h>
#include <mruby.h>
#include <mruby/class.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

namespace {

constexpr int DEPTH = 5;  // return addresses kept per call, the wrapper's own frame excluded
constexpr int FUNCALL_ARGC_MAX = 16;  // mruby's own limit, as vm_frames.cxx

enum Kind {
  FUNCALL,
  FUNCALL_ID,
  FUNCALL_ARGV,
  FUNCALL_WITH_BLOCK,
  FUNCALL_SEND,
  FUNCALL_WITH_METHOD,
  FUNCALL_SEND_WITH_METHOD,
  YIELD,
  YIELD_ARGV,
  YIELD_WITH_CLASS,
  METHOD_SEARCH,
  METHOD_MEMO,
  RESPOND_TO,
  OBJ_RESPOND_TO,
  VM_FIND_METHOD,
  METHOD_SEARCH_PLAIN,
  KIND_COUNT
};
const char* const kind_name[KIND_COUNT] = {
    "funcall",        "funcall_id",       "funcall_argv",   "funcall_with_block", "funcall_send",
    "funcall_with_method", "funcall_send_with_method", "yield",         "yield_argv",
    "yield_with_class", "method_search",  "method_memo",    "respond_to",         "obj_respond_to",
    "vm_find_method", "method_search_plain"};

struct Key {
  int kind;
  mrb_sym mid;
  void* pc[DEPTH];
  void* klass;      // detail mode: the class a lookup was for
  mrb_sym occ_mid;  // detail mode: what the method cache slot held before the lookup
  void* occ_klass;
  bool operator==(const Key& o) const {
    return kind == o.kind && mid == o.mid && klass == o.klass && occ_mid == o.occ_mid && occ_klass == o.occ_klass &&
           std::memcmp(pc, o.pc, sizeof pc) == 0;
  }
};
struct KeyHash {
  size_t operator()(const Key& k) const {
    size_t h = (size_t)k.kind * 1000003u ^ (size_t)k.mid * 40503u;
    for (void* p : k.pc) h = h * 1099511628211ull ^ (size_t)p;
    h = h * 1099511628211ull ^ (size_t)k.klass ^ ((size_t)k.occ_mid << 7) ^ (size_t)k.occ_klass;
    return h;
  }
};
struct Entry {
  unsigned long long n = 0;
  std::string name;
};

std::mutex lock;
bool detail;  // BC2CPP_SENDCNT_DETAIL=1: searches also record the class and the cache slot's occupant
std::unordered_map<Key, Entry, KeyHash>* table;
const char* out_path;

void dump() {
  FILE* f = fopen(out_path, "w");
  if (!f) {
    fprintf(stderr, "send_counter: cannot write %s\n", out_path);
    return;
  }
  for (auto& [key, e] : *table) {
    fprintf(f, "%s\t%s\t%llu\t", kind_name[key.kind], e.name.c_str(), e.n);
    for (int i = 0; i < DEPTH; ++i) fprintf(f, i ? ",%lx" : "%lx", (unsigned long)key.pc[i]);
    fputc('\n', f);
  }
  fclose(f);
}

struct Init {
  Init() {
    out_path = getenv("BC2CPP_SENDCNT_OUT");
    if (!out_path || !*out_path) {
      out_path = nullptr;
      return;
    }
    table = new std::unordered_map<Key, Entry, KeyHash>();
    detail = getenv("BC2CPP_SENDCNT_DETAIL") != nullptr;
    atexit(dump);
  }
} init;

// Inlined into each wrapper so frame 0 of the backtrace is the wrapper and frame 1 the call site. `c` is the class a
// lookup is for (detail mode records it, the slot of mruby's direct-mapped method cache it hashes to, and which method
// the slot held: two hot (class, name) pairs on one slot evict each other and search on every call).
__attribute__((always_inline)) inline void note(mrb_state* mrb, int kind, mrb_sym mid, struct RClass* c = nullptr) {
  if (!out_path) return;
  void* bt[DEPTH + 1];
  int n = backtrace(bt, DEPTH + 1);
  Key key{};
  key.kind = kind;
  key.mid = mid;
  for (int i = 1; i < n; ++i) key.pc[i - 1] = bt[i];
  int slot = -1;
#ifndef MRB_NO_METHOD_CACHE
  if (detail && c) {
    slot = mrb_int_hash_func(mrb, ((intptr_t)c) ^ mid) & (MRB_METHOD_CACHE_SIZE - 1);
    key.klass = c;
    key.occ_mid = mrb->cache[slot].mid;
    key.occ_klass = mrb->cache[slot].c;
  }
#endif
  std::lock_guard<std::mutex> g(lock);
  Entry& e = (*table)[key];
  if (e.n++ == 0 && mid) {
    mrb_int len = 0;
    const char* s = mrb_sym_name_len(mrb, mid, &len);
    if (s) e.name.assign(s, (size_t)len);
    if (slot >= 0) {
      char buf[96];
      snprintf(buf, sizeof buf, "|c=%lx|slot=%d|occ=", (unsigned long)c, slot);
      e.name += buf;
      const char* o = key.occ_mid ? mrb_sym_name_len(mrb, key.occ_mid, &len) : nullptr;
      if (o) e.name.append(o, (size_t)len);
      snprintf(buf, sizeof buf, "@%lx|m=%u,%u", (unsigned long)key.occ_klass, (unsigned)mid, (unsigned)key.occ_mid);
      e.name += buf;
    }
  }
}

}  // namespace

extern "C" {

#ifdef SC_HAVE_mrb_funcall
// A variadic cannot be forwarded, so this is mrb_funcall's own body (vm_frames.cxx) with the count added.
mrb_value __real_mrb_funcall_argv(mrb_state*, mrb_value, mrb_sym, mrb_int, const mrb_value*);
mrb_value __wrap_mrb_funcall(mrb_state* mrb, mrb_value self, const char* name, mrb_int argc, ...) {
  mrb_value argv[FUNCALL_ARGC_MAX];
  mrb_sym mid = mrb_intern_cstr(mrb, name);
  if (argc > FUNCALL_ARGC_MAX) mrb_raise(mrb, E_ARGUMENT_ERROR, "Too long arguments. (limit=16)");
  va_list ap;
  va_start(ap, argc);
  for (mrb_int i = 0; i < argc; i++) argv[i] = va_arg(ap, mrb_value);
  va_end(ap);
  note(mrb, FUNCALL, mid);
  return __real_mrb_funcall_argv(mrb, self, mid, argc, argv);
}
#endif

#ifdef SC_HAVE_mrb_funcall_id
mrb_value __wrap_mrb_funcall_id(mrb_state* mrb, mrb_value self, mrb_sym mid, mrb_int argc, ...) {
  mrb_value argv[FUNCALL_ARGC_MAX];
  if (argc > FUNCALL_ARGC_MAX) mrb_raise(mrb, E_ARGUMENT_ERROR, "Too long arguments. (limit=16)");
  va_list ap;
  va_start(ap, argc);
  for (mrb_int i = 0; i < argc; i++) argv[i] = va_arg(ap, mrb_value);
  va_end(ap);
  note(mrb, FUNCALL_ID, mid);
  return __real_mrb_funcall_argv(mrb, self, mid, argc, argv);
}
#endif

#ifdef SC_HAVE_mrb_funcall_argv
mrb_value __real_mrb_funcall_argv(mrb_state*, mrb_value, mrb_sym, mrb_int, const mrb_value*);
mrb_value __wrap_mrb_funcall_argv(mrb_state* mrb, mrb_value self, mrb_sym mid, mrb_int argc, const mrb_value* argv) {
  note(mrb, FUNCALL_ARGV, mid);
  return __real_mrb_funcall_argv(mrb, self, mid, argc, argv);
}
#endif

#ifdef SC_HAVE_mrb_funcall_with_block
mrb_value __real_mrb_funcall_with_block(mrb_state*, mrb_value, mrb_sym, mrb_int, const mrb_value*, mrb_value);
mrb_value __wrap_mrb_funcall_with_block(mrb_state* mrb, mrb_value self, mrb_sym mid, mrb_int argc,
                                        const mrb_value* argv, mrb_value blk) {
  note(mrb, FUNCALL_WITH_BLOCK, mid);
  return __real_mrb_funcall_with_block(mrb, self, mid, argc, argv, blk);
}
#endif

#ifdef SC_HAVE_mrb_funcall_send
mrb_value __real_mrb_funcall_send(mrb_state*, mrb_value, mrb_sym, mrb_int, const mrb_value*, mrb_value, mrb_value);
mrb_value __wrap_mrb_funcall_send(mrb_state* mrb, mrb_value self, mrb_sym mid, mrb_int argc, const mrb_value* argv,
                                  mrb_value kdict, mrb_value blk) {
  note(mrb, FUNCALL_SEND, mid);
  return __real_mrb_funcall_send(mrb, self, mid, argc, argv, kdict, blk);
}
#endif

#ifdef SC_HAVE_mrb_funcall_with_method
mrb_value __real_mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int,
                                         const mrb_value*, mrb_value);
mrb_value __wrap_mrb_funcall_with_method(mrb_state* mrb, mrb_value self, mrb_sym mid, const mrb_method_t* m,
                                         struct RClass* owner, mrb_int argc, const mrb_value* argv, mrb_value blk) {
  note(mrb, FUNCALL_WITH_METHOD, mid);
  return __real_mrb_funcall_with_method(mrb, self, mid, m, owner, argc, argv, blk);
}
#endif

#ifdef SC_HAVE_mrb_funcall_send_with_method
mrb_value __real_mrb_funcall_send_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*,
                                              mrb_int, const mrb_value*, mrb_value, mrb_value);
mrb_value __wrap_mrb_funcall_send_with_method(mrb_state* mrb, mrb_value self, mrb_sym mid, const mrb_method_t* m,
                                              struct RClass* owner, mrb_int argc, const mrb_value* argv,
                                              mrb_value kdict, mrb_value blk) {
  note(mrb, FUNCALL_SEND_WITH_METHOD, mid);
  return __real_mrb_funcall_send_with_method(mrb, self, mid, m, owner, argc, argv, kdict, blk);
}
#endif

#ifdef SC_HAVE_mrb_yield
mrb_value __real_mrb_yield(mrb_state*, mrb_value, mrb_value);
mrb_value __wrap_mrb_yield(mrb_state* mrb, mrb_value b, mrb_value arg) {
  note(mrb, YIELD, 0);
  return __real_mrb_yield(mrb, b, arg);
}
#endif

#ifdef SC_HAVE_mrb_yield_argv
mrb_value __real_mrb_yield_argv(mrb_state*, mrb_value, mrb_int, const mrb_value*);
mrb_value __wrap_mrb_yield_argv(mrb_state* mrb, mrb_value b, mrb_int argc, const mrb_value* argv) {
  note(mrb, YIELD_ARGV, 0);
  return __real_mrb_yield_argv(mrb, b, argc, argv);
}
#endif

#ifdef SC_HAVE_mrb_yield_with_class
mrb_value __real_mrb_yield_with_class(mrb_state*, mrb_value, mrb_int, const mrb_value*, mrb_value, struct RClass*);
mrb_value __wrap_mrb_yield_with_class(mrb_state* mrb, mrb_value b, mrb_int argc, const mrb_value* argv, mrb_value self,
                                      struct RClass* c) {
  note(mrb, YIELD_WITH_CLASS, 0);
  return __real_mrb_yield_with_class(mrb, b, argc, argv, self, c);
}
#endif

#ifdef SC_HAVE_mrb_method_search_vm
mrb_method_t __real_mrb_method_search_vm(mrb_state*, struct RClass**, mrb_sym);
mrb_method_t __wrap_mrb_method_search_vm(mrb_state* mrb, struct RClass** cp, mrb_sym mid) {
  note(mrb, METHOD_SEARCH, mid, *cp);
  return __real_mrb_method_search_vm(mrb, cp, mid);
}
#endif

#ifdef SC_HAVE_mrb_vm_find_method
// The lookup OP_SEND and every by-name send (vm_frames.cxx funcall_with_block_m) make, through the method cache.
mrb_method_t __real_mrb_vm_find_method(mrb_state*, struct RClass*, struct RClass**, mrb_sym);
mrb_method_t __wrap_mrb_vm_find_method(mrb_state* mrb, struct RClass* c, struct RClass** cp, mrb_sym mid) {
  note(mrb, VM_FIND_METHOD, mid, c);
  return __real_mrb_vm_find_method(mrb, c, cp, mid);
}
#endif

#ifdef SC_HAVE_mrb_method_search
mrb_method_t __real_mrb_method_search(mrb_state*, struct RClass*, mrb_sym);
mrb_method_t __wrap_mrb_method_search(mrb_state* mrb, struct RClass* c, mrb_sym mid) {
  note(mrb, METHOD_SEARCH_PLAIN, mid, c);
  return __real_mrb_method_search(mrb, c, mid);
}
#endif

#ifdef SC_HAVE_mrb_method_memo
struct mrb_cfunc_memo;
const struct mrb_cfunc_memo* __real_mrb_method_memo(mrb_state*, mrb_value, mrb_sym, int);
const struct mrb_cfunc_memo* __wrap_mrb_method_memo(mrb_state* mrb, mrb_value obj, mrb_sym mid, int slot) {
  note(mrb, METHOD_MEMO, mid);
  return __real_mrb_method_memo(mrb, obj, mid, slot);
}
#endif

#ifdef SC_HAVE_mrb_respond_to
mrb_bool __real_mrb_respond_to(mrb_state*, mrb_value, mrb_sym);
mrb_bool __wrap_mrb_respond_to(mrb_state* mrb, mrb_value obj, mrb_sym mid) {
  note(mrb, RESPOND_TO, mid);
  return __real_mrb_respond_to(mrb, obj, mid);
}
#endif

#ifdef SC_HAVE_mrb_obj_respond_to
mrb_bool __real_mrb_obj_respond_to(mrb_state*, struct RClass*, mrb_sym);
mrb_bool __wrap_mrb_obj_respond_to(mrb_state* mrb, struct RClass* c, mrb_sym mid) {
  note(mrb, OBJ_RESPOND_TO, mid);
  return __real_mrb_obj_respond_to(mrb, c, mid);
}
#endif

}  // extern "C"
