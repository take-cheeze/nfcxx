// ALLOC_COUNTER: counts the heap objects and malloc bytes a closed bc2cpp host allocates, per call chain. Linked into
// the headless host by alloc_counter.bash (`ld --wrap=mrb_obj_alloc,mrb_basic_alloc_func`), read by
// alloc_counter_report.rb. Host-only instrumentation: nothing here reaches a device build.
//
// Off unless BC2CPP_ALLOCCNT_OUT names a file; the counts are written there at exit, one row per distinct
// (kind, type, class, chain): kind TAB tt TAB class TAB count TAB bytes TAB hex,hex,... (return addresses, innermost
// first). kind is `obj` (a heap slot from mrb_obj_alloc; bytes 0, the slot size is the target's) or `malloc` (a new block or a
// growing realloc through mrb_basic_alloc_func; bytes = the growth). A call is seen only where it crosses a
// translation unit, which both functions do: every allocation in libmruby reaches them from another file.
#include <execinfo.h>
#include <malloc.h>
#include <mruby.h>
#include <mruby/class.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>

namespace {

constexpr int DEPTH = 8;  // return addresses kept per allocation, the wrapper's own frame excluded

struct Key {
  int kind;  // 0 obj, 1 malloc
  int tt;
  struct RClass* cls;
  void* pc[DEPTH];
  bool operator==(const Key& o) const {
    return kind == o.kind && tt == o.tt && cls == o.cls && std::memcmp(pc, o.pc, sizeof pc) == 0;
  }
};
struct KeyHash {
  size_t operator()(const Key& k) const {
    size_t h = (size_t)k.kind * 1000003u ^ (size_t)k.tt * 40503u ^ (size_t)k.cls;
    for (void* p : k.pc) h = h * 1099511628211ull ^ (size_t)p;
    return h;
  }
};
struct Entry {
  unsigned long long n = 0;
  unsigned long long bytes = 0;
};

std::unordered_map<Key, Entry, KeyHash>* table;
const char* out_path;
mrb_state* last_mrb;
bool busy;  // the table's own allocations go through malloc, not mrb_basic_alloc_func; this guards backtrace()

void dump() {
  FILE* f = fopen(out_path, "w");
  if (!f) {
    fprintf(stderr, "alloc_counter: cannot write %s\n", out_path);
    return;
  }
  busy = true;
  for (auto& [key, e] : *table) {
    const char* name = key.cls && last_mrb ? mrb_class_name(last_mrb, key.cls) : nullptr;
    fprintf(f, "%s\t%d\t%s\t%llu\t%llu\t", key.kind ? "malloc" : "obj", key.tt, name ? name : "-", e.n, e.bytes);
    for (int i = 0; i < DEPTH; ++i) fprintf(f, i ? ",%lx" : "%lx", (unsigned long)key.pc[i]);
    fputc('\n', f);
  }
  fclose(f);
}

struct Init {
  Init() {
    out_path = getenv("BC2CPP_ALLOCCNT_OUT");
    if (!out_path || !*out_path) {
      out_path = nullptr;
      return;
    }
    table = new std::unordered_map<Key, Entry, KeyHash>();
    atexit(dump);
  }
} init;

__attribute__((always_inline)) inline void note(int kind, int tt, struct RClass* cls, size_t bytes) {
  if (!out_path || busy) return;
  busy = true;
  void* bt[DEPTH + 1];
  int n = backtrace(bt, DEPTH + 1);
  Key key{};
  key.kind = kind;
  key.tt = tt;
  key.cls = cls;
  for (int i = 1; i < n; ++i) key.pc[i - 1] = bt[i];
  Entry& e = (*table)[key];
  e.n++;
  e.bytes += bytes;
  busy = false;
}

}  // namespace

extern "C" {

struct RBasic* __real_mrb_obj_alloc(mrb_state*, enum mrb_vtype, struct RClass*);
struct RBasic* __wrap_mrb_obj_alloc(mrb_state* mrb, enum mrb_vtype tt, struct RClass* cls) {
  last_mrb = mrb;
  note(0, (int)tt, cls, 0);
  return __real_mrb_obj_alloc(mrb, tt, cls);
}

void* __real_mrb_basic_alloc_func(void*, size_t);
void* __wrap_mrb_basic_alloc_func(void* p, size_t len) {
  if (len > 0) {
    size_t old = p ? malloc_usable_size(p) : 0;
    if (len > old) note(1, 0, nullptr, len - old);
  }
  return __real_mrb_basic_alloc_func(p, len);
}

}  // extern "C"
