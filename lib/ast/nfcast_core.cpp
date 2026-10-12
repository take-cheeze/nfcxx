// nfcast: values, interned strings, tables, the heap and its collector, the State, errors and conversions.
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <new>

#include "nfcast_impl.hpp"

namespace nfcast {

namespace {

const std::size_t kStackSlots = 1u << 17;
const std::uint32_t kMaxShortString = 40;

inline std::uint32_t mix64(std::uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  x *= 0xc4ceb9fe1a85ec53ULL;
  x ^= x >> 33;
  return static_cast<std::uint32_t>(x);
}

std::uint32_t hash_bytes(const char* s, std::size_t n) {
  std::uint32_t h = 2166136261u;
  for (std::size_t i = 0; i < n; ++i) h = (h ^ static_cast<unsigned char>(s[i])) * 16777619u;
  return h;
}

}  // namespace

// ---- State::Impl --------------------------------------------------------------------------------------------------------
struct State::Impl {
  std::vector<String*> strtab;  // intern table: chains through String::hnext
  std::size_t strcount = 0;
  std::vector<GCObject*> gray;
  std::uint32_t epoch = 0;
  bool collecting = false;
  String* tmname[TM_N];
  std::deque<std::string> names;
};

// ---- Value helpers ------------------------------------------------------------------------------------------------------
bool float_to_integer(double d, std::int64_t* out) { return nfcr_f2i(d, out) != 0; }

bool str_equal(const String* a, const String* b) {
  if (a == b) return true;
  if (a->interned && b->interned) return false;
  return a->len == b->len && a->hash == b->hash && std::memcmp(a->data(), b->data(), a->len) == 0;
}

bool raw_equal(const Value& a, const Value& b) {
  if (a.t != b.t) {
    std::int64_t k;
    if (a.t == T_INT && b.t == T_FLT) return float_to_integer(b.d, &k) && k == a.i;
    if (a.t == T_FLT && b.t == T_INT) return float_to_integer(a.d, &k) && k == b.i;
    return false;
  }
  switch (a.t) {
    case T_NIL:
    case T_FALSE:
    case T_TRUE: return true;
    case T_INT: return a.i == b.i;
    case T_FLT: return a.d == b.d;
    case T_STR: return str_equal(a.s(), b.s());
    default: return a.o == b.o;
  }
}

std::uint32_t hash_value(const Value& v) {
  switch (v.t) {
    case T_INT: return mix64(static_cast<std::uint64_t>(v.i));
    case T_FLT: {
      std::uint64_t bits;
      std::memcpy(&bits, &v.d, sizeof bits);
      return mix64(bits ^ 0x9e3779b97f4a7c15ULL);
    }
    case T_STR: return v.s()->hash;
    case T_FALSE: return 0x1234567u;
    case T_TRUE: return 0x7654321u;
    default: return mix64(reinterpret_cast<std::uintptr_t>(v.o));
  }
}

void Rets::grow() {
  int ncap = cap * 2;
  Value* np = static_cast<Value*>(std::malloc(static_cast<std::size_t>(ncap) * sizeof(Value)));
  for (int i = 0; i < n; ++i) np[i] = p[i];
  if (p != reinterpret_cast<Value*>(buf)) std::free(p);
  p = np;
  cap = ncap;
}

// ---- allocation -----------------------------------------------------------------------------------------------------------
static GCObject* gc_alloc(State& S, std::size_t size, GCType t) {
  void* p = std::malloc(size);
  if (!p) throw std::bad_alloc();
  GCObject* o = static_cast<GCObject*>(p);
  o->gctype = t;
  o->marked = 0;
  o->gcnext = S.all;
  S.all = o;
  S.bytes += size;
  return o;
}

String* State::str(std::string_view s) {
  std::uint32_t h = hash_bytes(s.data(), s.size());
  bool shortstr = s.size() <= kMaxShortString;
  if (shortstr) {
    std::size_t idx = h & (impl->strtab.size() - 1);
    for (String* p = impl->strtab[idx]; p; p = p->hnext)
      if (p->hash == h && p->len == s.size() && std::memcmp(p->data(), s.data(), s.size()) == 0) return p;
  }
  String* r = static_cast<String*>(gc_alloc(*this, sizeof(String) + s.size() + 1, G_STRING));
  r->hash = h;
  r->len = static_cast<std::uint32_t>(s.size());
  r->hnext = nullptr;
  r->interned = shortstr;
  if (s.size()) std::memcpy(r->mdata(), s.data(), s.size());
  r->mdata()[s.size()] = '\0';
  if (shortstr) {
    if (impl->strcount >= impl->strtab.size()) {  // grow the intern table
      std::vector<String*> nt(impl->strtab.size() * 2, nullptr);
      for (String* head : impl->strtab)
        for (String* p = head; p;) {
          String* nx = p->hnext;
          std::size_t i = p->hash & (nt.size() - 1);
          p->hnext = nt[i];
          nt[i] = p;
          p = nx;
        }
      impl->strtab.swap(nt);
    }
    std::size_t idx = h & (impl->strtab.size() - 1);
    r->hnext = impl->strtab[idx];
    impl->strtab[idx] = r;
    ++impl->strcount;
  }
  return r;
}

Table* State::new_table(std::uint32_t narr, std::uint32_t nhash) {
  Table* t = static_cast<Table*>(gc_alloc(*this, sizeof(Table), G_TABLE));
  t->arr = nullptr;
  t->asize = t->acap = 0;
  t->nodes = nullptr;
  t->hcap = t->hused = 0;
  t->meta = nullptr;
  t->absent = 0;
  if (narr) t->reserve_array(*this, narr);
  if (nhash) {
    std::uint32_t cap = 4;
    while (cap * 3 < nhash * 4 + 3) cap *= 2;
    t->nodes = static_cast<TNode*>(std::calloc(cap, sizeof(TNode)));
    t->hcap = cap;
    bytes += static_cast<std::size_t>(cap) * sizeof(TNode);
  }
  return t;
}

Native* State::new_native(NativeFn fn, const char* name, void* data, const Value& up) {
  Native* n = static_cast<Native*>(gc_alloc(*this, sizeof(Native), G_NATIVE));
  n->fn = fn;
  n->name = name;
  n->data = data;
  n->up = up;
  return n;
}

Cell* new_cell(State& S, const Value& v) {
  Cell* c = static_cast<Cell*>(gc_alloc(S, sizeof(Cell), G_CELL));
  c->v = v;
  return c;
}

Closure* new_closure(State& S, Proto* p, std::uint32_t nup) {
  Closure* c = static_cast<Closure*>(gc_alloc(S, sizeof(Closure) + nup * sizeof(Cell*), G_CLOSURE));
  c->proto = p;
  p->retain();
  c->nup = nup;
  c->up = reinterpret_cast<Cell**>(c + 1);
  for (std::uint32_t i = 0; i < nup; ++i) c->up[i] = nullptr;
  return c;
}

void State::link_host(HostObject* h) {
  h->gctype = G_HOST;
  h->marked = 0;
  h->gcnext = all;
  all = h;
  bytes += 64;
}

// ---- tables ---------------------------------------------------------------------------------------------------------------
static inline bool key_equal(const Value& a, const Value& b) {
  if (a.t != b.t) return false;
  switch (a.t) {
    case T_INT: return a.i == b.i;
    case T_FLT: return a.d == b.d;
    case T_STR: return str_equal(a.s(), b.s());
    case T_FALSE:
    case T_TRUE: return true;
    default: return a.o == b.o;
  }
}

// The node holding key K, or -1. K is normalized (a float with an integer value is an integer).
static long find_node(const Table* t, const Value& k) {
  if (!t->hcap) return -1;
  std::uint32_t mask = t->hcap - 1, i = hash_value(k) & mask;
  for (;;) {
    const TNode& n = t->nodes[i];
    if (n.key.t == T_NIL) return -1;
    if (key_equal(n.key, k)) return static_cast<long>(i);
    i = (i + 1) & mask;
  }
}

long Table::find_str(const String* k) const {
  if (!hcap) return -1;
  std::uint32_t mask = hcap - 1, i = k->hash & mask;
  if (k->interned) {
    for (;;) {
      const TNode& n = nodes[i];
      if (n.key.t == T_NIL) return -1;
      if (n.key.t == T_STR && n.key.o == reinterpret_cast<const GCObject*>(k)) return static_cast<long>(i);
      i = (i + 1) & mask;
    }
  }
  for (;;) {
    const TNode& n = nodes[i];
    if (n.key.t == T_NIL) return -1;
    if (n.key.t == T_STR && str_equal(n.key.s(), k)) return static_cast<long>(i);
    i = (i + 1) & mask;
  }
}

Value Table::get_str(const String* k) const {
  long i = find_str(k);
  return i < 0 ? Value() : nodes[i].val;
}

Value Table::get_int_hash(std::int64_t k) const {
  long i = find_node(this, Value::integer(k));
  return i < 0 ? Value() : nodes[i].val;
}

Value Table::get(const Value& k) const {
  switch (k.t) {
    case T_NIL: return Value();
    case T_INT: return get_int(k.i);
    case T_STR: return get_str(k.s());
    case T_FLT: {
      std::int64_t i;
      if (float_to_integer(k.d, &i)) return get_int(i);
      break;
    }
    default: break;
  }
  long i = find_node(this, k);
  return i < 0 ? Value() : nodes[i].val;
}

void Table::reserve_array(State& S, std::uint32_t n) {
  if (n <= acap) return;
  std::uint32_t ncap = acap ? acap : 4;
  while (ncap < n) ncap *= 2;
  Value* na = static_cast<Value*>(std::realloc(arr, static_cast<std::size_t>(ncap) * sizeof(Value)));
  if (!na) throw std::bad_alloc();
  S.bytes += static_cast<std::size_t>(ncap - acap) * sizeof(Value);
  arr = na;
  acap = ncap;
}

static void rehash(State& S, Table* t, std::uint32_t extra) {
  std::uint32_t live = extra;
  for (std::uint32_t i = 0; i < t->hcap; ++i)
    if (!t->nodes[i].val.is_nil()) ++live;
  std::uint32_t cap = 4;
  while (cap * 3 < live * 4 + 3) cap *= 2;
  TNode* nn = static_cast<TNode*>(std::calloc(cap, sizeof(TNode)));
  if (!nn) throw std::bad_alloc();
  std::uint32_t mask = cap - 1, used = 0;
  for (std::uint32_t i = 0; i < t->hcap; ++i) {
    const TNode& o = t->nodes[i];
    if (o.val.is_nil()) continue;
    std::uint32_t j = hash_value(o.key) & mask;
    while (nn[j].key.t != T_NIL) j = (j + 1) & mask;
    nn[j] = o;
    ++used;
  }
  S.bytes += static_cast<std::size_t>(cap) * sizeof(TNode);
  S.bytes -= static_cast<std::size_t>(t->hcap) * sizeof(TNode);
  std::free(t->nodes);
  t->nodes = nn;
  t->hcap = cap;
  t->hused = used;
}

static void hash_insert(State& S, Table* t, const Value& k, const Value& v) {  // K is not in the table; V is not nil
  if ((t->hused + 1) * 4 > t->hcap * 3) rehash(S, t, 1);
  std::uint32_t mask = t->hcap - 1, i = hash_value(k) & mask;
  while (t->nodes[i].key.t != T_NIL) i = (i + 1) & mask;
  t->nodes[i].key = k;
  t->nodes[i].val = v;
  ++t->hused;
}

void Table::set_int(State& S, std::int64_t k, const Value& v) {
  absent = 0;
  if (static_cast<std::uint64_t>(k) - 1u < asize) {
    arr[k - 1] = v;
    return;
  }
  if (k == static_cast<std::int64_t>(asize) + 1) {
    if (v.is_nil()) return;  // the hash part never holds the key asize+1
    reserve_array(S, asize + 1);
    arr[asize++] = v;
    absorb(S);
    return;
  }
  Value key = Value::integer(k);
  long n = find_node(this, key);
  if (n >= 0) nodes[n].val = v;
  else if (!v.is_nil()) hash_insert(S, this, key, v);
}

void Table::absorb(State& S) {
  // Keys that were waiting in the hash part for the array to reach them move over.
  while (hused) {
    Value key = Value::integer(static_cast<std::int64_t>(asize) + 1);
    long n = find_node(this, key);
    if (n < 0 || nodes[n].val.is_nil()) break;
    reserve_array(S, asize + 1);
    arr[asize++] = nodes[n].val;
    nodes[n].val = Value();
  }
}

void Table::set_str(State& S, String* k, const Value& v) {
  absent = 0;
  long n = find_str(k);
  if (n >= 0) nodes[n].val = v;
  else if (!v.is_nil()) hash_insert(S, this, Value::str(k), v);
}

void Table::set(State& S, const Value& k0, const Value& v) {
  Value k = k0;
  if (k.t == T_FLT) {
    std::int64_t i;
    if (float_to_integer(k.d, &i)) k = Value::integer(i);
  }
  if (k.t == T_INT) {
    set_int(S, k.i, v);
    return;
  }
  absent = 0;
  long n = find_node(this, k);
  if (n >= 0) nodes[n].val = v;
  else if (!v.is_nil()) hash_insert(S, this, k, v);
}

std::int64_t Table::length() const {
  if (asize > 0 && arr[asize - 1].is_nil()) {
    std::uint32_t lo = 0, hi = asize;  // arr[lo-1] is non-nil or lo == 0; arr[hi-1] is nil
    while (hi - lo > 1) {
      std::uint32_t m = lo + (hi - lo) / 2;
      if (arr[m - 1].is_nil()) hi = m;
      else lo = m;
    }
    return lo;
  }
  return asize;
}

bool Table::next(State& S, Value& key, Value& val) const {
  std::uint32_t idx = 0;  // the position after KEY: 0..asize-1 the array part, then the nodes
  if (!key.is_nil()) {
    Value k = key;
    if (k.t == T_FLT) {
      std::int64_t i;
      if (float_to_integer(k.d, &i)) k = Value::integer(i);
    }
    if (k.t == T_INT && static_cast<std::uint64_t>(k.i) - 1u < asize) {
      idx = static_cast<std::uint32_t>(k.i);
    } else {
      long n = -1;
      if (hcap) {
        std::uint32_t mask = hcap - 1, i = hash_value(k) & mask;
        for (;;) {
          const TNode& nd = nodes[i];
          if (nd.key.t == T_NIL) break;
          if (key_equal(nd.key, k) || (nd.key.t == T_DEAD && k.is_gc() && nd.key.o == k.o)) {
            n = static_cast<long>(i);
            break;
          }
          i = (i + 1) & mask;
        }
      }
      if (n < 0) S.rt_error("invalid key to 'next'");
      idx = asize + static_cast<std::uint32_t>(n) + 1;
    }
  }
  for (; idx < asize; ++idx)
    if (!arr[idx].is_nil()) {
      key = Value::integer(static_cast<std::int64_t>(idx) + 1);
      val = arr[idx];
      return true;
    }
  for (std::uint32_t j = idx - asize; j < hcap; ++j)
    if (!nodes[j].val.is_nil()) {
      key = nodes[j].key;
      val = nodes[j].val;
      return true;
    }
  return false;
}

// ---- the State ------------------------------------------------------------------------------------------------------------
State::State() : impl(new Impl) {
  stack = new Value[kStackSlots];
  stack_end = stack + kStackSlots;
  top = stack;
  impl->strtab.assign(256, nullptr);
  if (const char* e = std::getenv("NFCAST_GC_STRESS")) gc_stress = e[0] == '1';
  if (const char* e = std::getenv("NFCAST_INLINE")) inlining = e[0] != '0';
  if (const char* e = std::getenv("NFCAST_INLINE_WARM")) inline_warm = static_cast<unsigned>(std::atoi(e));
  for (int i = 0; i < TM_N; ++i) impl->tmname[i] = nullptr;
  for (int i = 0; i < TM_N; ++i) impl->tmname[i] = str(tm_name(static_cast<TM>(i)));
  globals = new_table();
}

static void free_object(State& S, GCObject* o);

State::~State() {
  GCObject* o = all;
  while (o) {
    GCObject* nx = o->gcnext;
    free_object(*this, o);
    o = nx;
  }
  all = nullptr;
  delete[] stack;
  delete impl;
}

const char* tm_name(TM ev) {
  static const char* const names[TM_N] = {"__index", "__newindex", "__eq", "__len", "__call", "__lt", "__le", "__concat",
                                          "__unm", "__bnot", "__add", "__sub", "__mul", "__mod", "__pow", "__div",
                                          "__idiv", "__band", "__bor", "__bxor", "__shl", "__shr", "__tostring", "__name",
                                          "__metatable", "__pairs"};
  return names[ev];
}

String* tm_string(State& S, TM ev) { return S.impl->tmname[ev]; }

int State::pin(const Value& v) {
  if (!free_pins.empty()) {
    int id = free_pins.back();
    free_pins.pop_back();
    pins[static_cast<std::size_t>(id)] = v;
    return id;
  }
  pins.push_back(v);
  return static_cast<int>(pins.size()) - 1;
}

void State::unpin(int id) {
  pins[static_cast<std::size_t>(id)] = Value();
  free_pins.push_back(id);
}

// ---- the collector ----------------------------------------------------------------------------------------------------------
static void mark_obj(State::Impl* I, GCObject* o) {
  if (o->marked) return;
  o->marked = 1;
  if (o->gctype != G_STRING) I->gray.push_back(o);
}

static inline void mark_val(State::Impl* I, const Value& v) {
  if (v.is_gc() && v.t != T_DEAD) mark_obj(I, v.o);
}

// The constants of a function and of every function nested in it: the nodes of the whole tree refer to them, whether or not a
// closure of the inner function exists yet.
static void mark_proto_consts(State::Impl* I, Proto* p) {
  if (p->mark_epoch == I->epoch) return;
  p->mark_epoch = I->epoch;
  for (String* s : p->consts) mark_obj(I, s);
  for (Proto* c : p->children) mark_proto_consts(I, c);
}

static void traverse(State::Impl* I, GCObject* o) {
  switch (o->gctype) {
    case G_TABLE: {
      Table* t = static_cast<Table*>(o);
      if (t->meta) mark_obj(I, t->meta);
      for (std::uint32_t i = 0; i < t->asize; ++i) mark_val(I, t->arr[i]);
      for (std::uint32_t i = 0; i < t->hcap; ++i) {
        TNode& n = t->nodes[i];
        if (n.val.is_nil()) {
          if (n.key.is_gc() && n.key.t != T_DEAD) n.key.t = T_DEAD;  // a removed key: kept for `next`, never dereferenced
        } else {
          mark_val(I, n.key);
          mark_val(I, n.val);
        }
      }
      break;
    }
    case G_CLOSURE: {
      Closure* c = static_cast<Closure*>(o);
      mark_proto_consts(I, c->proto);
      for (std::uint32_t i = 0; i < c->nup; ++i)
        if (c->up[i]) mark_obj(I, c->up[i]);
      break;
    }
    case G_NATIVE: mark_val(I, static_cast<Native*>(o)->up); break;
    case G_CELL: mark_val(I, static_cast<Cell*>(o)->v); break;
    default: break;
  }
}

static void free_object(State& S, GCObject* o) {
  switch (o->gctype) {
    case G_STRING: {
      String* s = static_cast<String*>(o);
      if (s->interned && S.impl->strtab.size()) {
        String** pp = &S.impl->strtab[s->hash & (S.impl->strtab.size() - 1)];
        while (*pp && *pp != s) pp = &(*pp)->hnext;
        if (*pp) {
          *pp = s->hnext;
          --S.impl->strcount;
        }
      }
      S.bytes -= sizeof(String) + s->len + 1;
      std::free(s);
      break;
    }
    case G_TABLE: {
      Table* t = static_cast<Table*>(o);
      S.bytes -= sizeof(Table) + static_cast<std::size_t>(t->acap) * sizeof(Value) + static_cast<std::size_t>(t->hcap) * sizeof(TNode);
      std::free(t->arr);
      std::free(t->nodes);
      std::free(t);
      break;
    }
    case G_CLOSURE: {
      Closure* c = static_cast<Closure*>(o);
      S.bytes -= sizeof(Closure) + c->nup * sizeof(Cell*);
      c->proto->release();
      std::free(c);
      break;
    }
    case G_NATIVE: S.bytes -= sizeof(Native); std::free(o); break;
    case G_CELL: S.bytes -= sizeof(Cell); std::free(o); break;
    case G_HOST: {
      S.bytes -= 64;
      delete static_cast<HostObject*>(o);
      break;
    }
  }
}

void State::collect() {
  State::Impl* I = impl;
  if (I->collecting) return;
  I->collecting = true;
  ++stats.gc_cycles;
  ++I->epoch;
  // roots
  mark_obj(I, globals);
  if (string_meta) mark_obj(I, string_meta);
  if (next_fn) mark_obj(I, next_fn);
  if (ipairs_iter) mark_obj(I, ipairs_iter);
  mark_val(I, pending);
  for (int i = 0; i < TM_N; ++i) mark_obj(I, I->tmname[i]);
  for (const Value& v : pins) mark_val(I, v);
  for (const Value& v : extra_roots) mark_val(I, v);
  for (Value* p = stack; p < top; ++p) mark_val(I, *p);
  while (!I->gray.empty()) {
    GCObject* o = I->gray.back();
    I->gray.pop_back();
    traverse(I, o);
  }
  // sweep
  GCObject** pp = &all;
  while (*pp) {
    GCObject* o = *pp;
    if (o->marked) {
      o->marked = 0;
      pp = &o->gcnext;
    } else {
      *pp = o->gcnext;
      free_object(*this, o);
    }
  }
  gc_threshold = bytes * 2 > (1u << 20) ? bytes * 2 : (1u << 20);
  I->collecting = false;
}

// ---- errors ---------------------------------------------------------------------------------------------------------------
std::vector<std::string> State::traceback() const {
  std::vector<std::string> out;
  for (const Frame* f = cur; f; f = f->prev) {
    const Proto* p = f->cl->proto;
    out.push_back(p->chunk + ":" + std::to_string(f->line) + ": in " + p->name);
  }
  return out;
}

void State::error(const Value& v) {
  pending = v;
  Thrown t;
  t.v = v;
  if (pcall_depth == 0) t.trace = traceback();
  throw t;
}

const char* State::keep_name(const std::string& s) {
  impl->names.push_back(s);
  return impl->names.back().c_str();
}

void State::rt_error(const std::string& msg) {
  std::string full;
  if (cur && !nfn) full = cur->cl->proto->chunk + ":" + std::to_string(cur->line) + ": ";
  full += msg;
  error(strv(full));
}

void State::arg_error(int argn, const char* fname, const std::string& msg) {
  std::string name = cur_native ? cur_native->name : fname;
  int arg = argn;
  if (!nfn && call_where) {  // called from script code: the name used at the call site, and `obj:m()` does not count obj
    std::string d;
    call_where->describe(d);
    std::size_t q1 = d.find('\''), q2 = d.rfind('\'');
    if (q1 != std::string::npos && q2 > q1) {
      std::string kind = d.substr(0, d.find(' '));
      name = d.substr(q1 + 1, q2 - q1 - 1);
      if (kind == "method") {
        --arg;
        if (arg == 0) rt_error("calling '" + name + "' on bad self (" + msg + ")");
      }
    }
  }
  rt_error("bad argument #" + std::to_string(arg) + " to '" + name + "' (" + msg + ")");
}

// ---- conversions ------------------------------------------------------------------------------------------------------------
std::string number_to_string(const Value& v) {
  char buf[64];
  if (v.t == T_INT) {
    std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(v.i));
    return buf;
  }
  std::snprintf(buf, sizeof buf, "%.14g", v.d);
  if (buf[std::strspn(buf, "-0123456789")] == '\0') std::strcat(buf, ".0");  // looks like an integer: keep it a float
  return buf;
}

static bool is_space(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static bool str_to_int(const std::string& s, std::int64_t* out) {
  const char* p = s.c_str();
  while (is_space(*p)) ++p;
  bool neg = false;
  if (*p == '-') {
    ++p;
    neg = true;
  } else if (*p == '+') {
    ++p;
  }
  std::uint64_t a = 0;
  bool empty = true;
  if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
    p += 2;
    for (; std::isxdigit(static_cast<unsigned char>(*p)); ++p) {
      int d = *p <= '9' ? *p - '0' : (*p | 0x20) - 'a' + 10;
      a = a * 16 + static_cast<unsigned>(d);
      empty = false;
    }
  } else {
    for (; *p >= '0' && *p <= '9'; ++p) {
      int d = *p - '0';
      if (a > 922337203685477580ULL || (a == 922337203685477580ULL && d > 7 + (neg ? 1 : 0))) return false;  // does not fit
      a = a * 10 + static_cast<unsigned>(d);
      empty = false;
    }
  }
  while (is_space(*p)) ++p;
  if (empty || *p != '\0') return false;
  *out = static_cast<std::int64_t>(neg ? 0u - a : a);
  return true;
}

bool string_to_number(std::string_view sv, Value* out) {
  std::string s(sv);
  if (s.find('\0') != std::string::npos) return false;
  std::int64_t i;
  if (str_to_int(s, &i)) {
    *out = Value::integer(i);
    return true;
  }
  if (s.find_first_of("nN") != std::string::npos) return false;  // reject 'inf' and 'nan'
  char* end = nullptr;
  double d = std::strtod(s.c_str(), &end);
  if (end == s.c_str()) return false;
  while (is_space(*end)) ++end;
  if (*end != '\0') return false;
  *out = Value::number(d);
  return true;
}

const char* State::type_name(const Value& v) {
  switch (v.t) {
    case T_NIL: return "nil";
    case T_FALSE:
    case T_TRUE: return "boolean";
    case T_INT:
    case T_FLT: return "number";
    case T_STR: return "string";
    case T_TAB: return "table";
    case T_FUN: return "function";
    case T_HOST: return "userdata";
    default: return "?";
  }
}

std::string State::tostring(const Value& v) {
  switch (v.t) {
    case T_NIL: return "nil";
    case T_FALSE: return "false";
    case T_TRUE: return "true";
    case T_INT:
    case T_FLT: return number_to_string(v);
    case T_STR: return std::string(v.s()->view());
    default: break;
  }
  Value tm = tm_value(*this, v, TM_TOSTRING);
  if (!tm.is_nil()) {
    Value* base = top;
    base[0] = tm;
    base[1] = v;
    top = base + 2;
    Rets r;
    call_value(*this, tm, base + 1, 1, r, nullptr);
    top = base;
    Value res = r.first();
    if (res.t != T_STR) {
      if (res.is_number()) return number_to_string(res);
      rt_error("'__tostring' must return a string");
    }
    return std::string(res.s()->view());
  }
  char buf[64];
  std::string name = type_name(v);
  if (v.t == T_HOST) {
    std::string d = v.hostobj()->describe();
    return d;
  }
  Value nm = tm_value(*this, v, TM_NAME);
  if (nm.t == T_STR) name = std::string(nm.s()->view());
  std::snprintf(buf, sizeof buf, ": %p", static_cast<void*>(v.o));
  return name + buf;
}

}  // namespace nfcast
