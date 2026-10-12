// nfcast: State::load, the standard library (base without files and without coroutines, string with Lua patterns and
// format, table, math). Behavior and messages follow Lua 5.4.
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>

#include "nfcast_impl.hpp"

namespace nfcast {

Closure* State::load(std::string_view code, const std::string& chunkname, std::string* err) {
  Proto* p = parse_chunk(*this, code, chunkname, err);
  if (!p) return nullptr;
  Closure* cl = new_closure(*this, p, 0);
  p->release();  // the closure holds the only reference now
  return cl;
}

void register_function(State& S, Table* t, const char* prefix, const char* name, NativeFn fn) {
  std::string qualified = std::string(prefix) + name;
  Native* n = S.new_native(fn, S.keep_name(qualified));
  t->set_str(S, S.str(name), Value::function(n));
}

namespace {

// ---- argument checking (messages as luaL_check*) ----------------------------------------------------------------------
[[noreturn]] void type_err(State& S, Args a, int i, const char* fname, const char* expected) {
  const char* got = i > a.n ? "no value" : State::type_name(a.v[i - 1]);
  S.arg_error(i, fname, std::string(expected) + " expected, got " + got);
}

std::int64_t check_int(State& S, Args a, int i, const char* fname) {
  if (i <= a.n) {
    Value n;
    const Value& v = a.v[i - 1];
    if (v.t == T_INT) return v.i;
    if (to_number(v, &n)) {
      if (n.t == T_INT) return n.i;
      std::int64_t r;
      if (float_to_integer(n.d, &r)) return r;
      S.arg_error(i, fname, "number has no integer representation");
    }
  }
  type_err(S, a, i, fname, "number");
}

std::int64_t opt_int(State& S, Args a, int i, const char* fname, std::int64_t def) {
  if (i > a.n || a.v[i - 1].is_nil()) return def;
  return check_int(S, a, i, fname);
}

double check_num(State& S, Args a, int i, const char* fname) {
  if (i <= a.n) {
    Value n;
    if (to_number(a.v[i - 1], &n)) return n.t == T_INT ? static_cast<double>(n.i) : n.d;
  }
  type_err(S, a, i, fname, "number");
}

// A string argument; a number is converted in place.
String* check_str(State& S, Args a, int i, const char* fname) {
  if (i <= a.n) {
    Value& v = a.v[i - 1];
    if (v.t == T_STR) return v.s();
    if (v.is_number()) {
      v = Value::str(S.str(number_to_string(v)));
      return v.s();
    }
  }
  type_err(S, a, i, fname, "string");
}

Table* check_table(State& S, Args a, int i, const char* fname) {
  if (i <= a.n && a.v[i - 1].t == T_TAB) return a.v[i - 1].tab();
  type_err(S, a, i, fname, "table");
}

void check_any(State& S, Args a, int i, const char* fname) {
  if (i > a.n) S.arg_error(i, fname, "value expected");
}

// The position "chunk:line:" of the function at LEVEL on the call stack as Lua counts it: level 1 is the caller of the running
// native function, and a native function in between (pcall calling a function) takes a level and has no position.
std::string where(State& S, int level) {
  Frame* f = S.cur;
  int lvl = 1;
  if (S.nfn) {
    if (level == 1) return "";
    lvl = 2;
  }
  while (f) {
    if (lvl == level) return f->cl->proto->chunk + ":" + std::to_string(f->line) + ": ";
    ++lvl;
    if (f->native_below) {
      if (lvl == level) return "";
      ++lvl;
    }
    f = f->prev;
  }
  return "";
}

// ==================================================================================================================
// base library
// ==================================================================================================================
void b_print(State& S, Args a, Rets& r, Native&) {
  (void)r;
  std::string out;
  for (int i = 0; i < a.n; ++i) {
    if (i) out += '\t';
    out += S.tostring(a.v[i]);
  }
  out += '\n';
  std::fwrite(out.data(), 1, out.size(), stdout);
}

void b_type(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "type");
  r.push(S.strv(State::type_name(a.v[0])));
}

void b_tostring(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "tostring");
  if (a.v[0].t == T_STR) {
    r.push(a.v[0]);
    return;
  }
  r.push(S.strv(S.tostring(a.v[0])));
}

void b_tonumber(State& S, Args a, Rets& r, Native&) {
  if (a.n < 2 || a.v[1].is_nil()) {
    check_any(S, a, 1, "tonumber");
    Value out;
    if (a.v[0].is_number()) {
      r.push(a.v[0]);
    } else if (a.v[0].t == T_STR && string_to_number(a.v[0].s()->view(), &out)) {
      r.push(out);
    } else {
      r.push(Value());
    }
    return;
  }
  std::int64_t base = check_int(S, a, 2, "tonumber");
  if (a.v[0].t != T_STR) type_err(S, a, 1, "tonumber", "string");
  if (base < 2 || base > 36) S.arg_error(2, "tonumber", "base out of range");
  std::string_view sv = a.v[0].s()->view();
  std::size_t i = 0;
  while (i < sv.size() && std::isspace(static_cast<unsigned char>(sv[i]))) ++i;
  bool neg = false;
  if (i < sv.size() && sv[i] == '-') {
    neg = true;
    ++i;
  } else if (i < sv.size() && sv[i] == '+') {
    ++i;
  }
  if (i >= sv.size() || !std::isalnum(static_cast<unsigned char>(sv[i]))) {
    r.push(Value());
    return;
  }
  std::uint64_t n = 0;
  for (; i < sv.size() && std::isalnum(static_cast<unsigned char>(sv[i])); ++i) {
    int c = static_cast<unsigned char>(sv[i]);
    int d = std::isdigit(c) ? c - '0' : std::toupper(c) - 'A' + 10;
    if (d >= base) {
      r.push(Value());
      return;
    }
    n = n * static_cast<std::uint64_t>(base) + static_cast<std::uint64_t>(d);
  }
  while (i < sv.size() && std::isspace(static_cast<unsigned char>(sv[i]))) ++i;
  if (i != sv.size()) {
    r.push(Value());
    return;
  }
  r.push(Value::integer(static_cast<std::int64_t>(neg ? 0u - n : n)));
}

void b_next(State& S, Args a, Rets& r, Native&) {
  Table* t = check_table(S, a, 1, "next");
  Value k = a[1], v;
  if (t->next(S, k, v)) {
    r.push(k);
    r.push(v);
  } else {
    r.push(Value());
  }
}

void b_ipairs_iter(State& S, Args a, Rets& r, Native&) {
  std::int64_t i = check_int(S, a, 2, "ipairs") + 1;
  Value v;
  if (a.v[0].t == T_TAB) {
    v = a.v[0].tab()->get_int(i);
    if (v.is_nil() && a.v[0].tab()->meta) v = index_slow(S, a.v[0], Value::integer(i), nullptr);
  } else {
    v = index_slow(S, a.v[0], Value::integer(i), nullptr);
  }
  if (v.is_nil()) {
    r.push(Value());
    return;
  }
  r.push(Value::integer(i));
  r.push(v);
}

void b_ipairs(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "ipairs");
  r.push(Value::function(S.ipairs_iter));
  r.push(a.v[0]);
  r.push(Value::integer(0));
}

void b_pairs(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "pairs");
  Value mm = tm_value(S, a.v[0], TM_PAIRS);
  if (!mm.is_nil()) {
    Rets res;
    Value args1[1] = {a.v[0]};
    S.call(mm, args1, 1, res);
    for (int i = 0; i < 3; ++i) r.push(i < res.n ? res.p[i] : Value());
    return;
  }
  check_table(S, a, 1, "pairs");
  r.push(Value::function(S.next_fn));
  r.push(a.v[0]);
  r.push(Value());
}

void b_rawget(State& S, Args a, Rets& r, Native&) {
  Table* t = check_table(S, a, 1, "rawget");
  check_any(S, a, 2, "rawget");
  r.push(t->get(a.v[1]));
}

void b_rawset(State& S, Args a, Rets& r, Native&) {
  Table* t = check_table(S, a, 1, "rawset");
  check_any(S, a, 2, "rawset");
  check_any(S, a, 3, "rawset");
  if (a.v[1].is_nil()) S.rt_error("table index is nil");
  if (a.v[1].t == T_FLT && a.v[1].d != a.v[1].d) S.rt_error("table index is NaN");
  t->set(S, a.v[1], a.v[2]);
  r.push(a.v[0]);
}

void b_rawequal(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "rawequal");
  check_any(S, a, 2, "rawequal");
  r.push(Value::boolean(raw_equal(a.v[0], a.v[1])));
}

void b_rawlen(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_TAB) r.push(Value::integer(a.v[0].tab()->length()));
  else if (a.n >= 1 && a.v[0].t == T_STR) r.push(Value::integer(a.v[0].s()->len));
  else S.arg_error(1, "rawlen", "table or string expected");
}

void b_setmetatable(State& S, Args a, Rets& r, Native&) {
  Table* t = check_table(S, a, 1, "setmetatable");
  if (a.n < 2 || !(a.v[1].is_nil() || a.v[1].t == T_TAB)) type_err(S, a, 2, "setmetatable", "nil or table");
  if (t->meta && !t->meta->get_str(tm_string(S, TM_METATABLE)).is_nil()) S.rt_error("cannot change a protected metatable");
  t->meta = a.v[1].is_nil() ? nullptr : a.v[1].tab();
  r.push(a.v[0]);
}

void b_getmetatable(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "getmetatable");
  Table* mt = get_metatable(S, a.v[0]);
  if (!mt) {
    r.push(Value());
    return;
  }
  Value prot = mt->get_str(tm_string(S, TM_METATABLE));
  r.push(prot.is_nil() ? Value::table(mt) : prot);
}

void b_assert(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "assert");
  if (a.v[0].truthy()) {
    for (int i = 0; i < a.n; ++i) r.push(a.v[i]);
    return;
  }
  if (a.n >= 2) S.error(a.v[1]);
  S.rt_error("assertion failed!");
}

void b_error(State& S, Args a, Rets&, Native&) {
  Value msg = a[0];
  std::int64_t level = opt_int(S, a, 2, "error", 1);
  if (msg.t == T_STR && level > 0) msg = S.strv(where(S, static_cast<int>(level)) + std::string(msg.s()->view()));
  S.error(msg);
}

void b_pcall(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "pcall");
  Frame* saved_cur = S.cur;
  int saved_depth = S.depth, saved_pcall = S.pcall_depth;
  Value* saved_top = S.top;
  Node* saved_where = S.call_where;
  Native* saved_native = S.cur_native;
  bool saved_nfn = S.nfn;
  Rets inner;
  ++S.pcall_depth;
  try {
    call_value(S, a.v[0], a.v + 1, a.n - 1, inner, nullptr);
  } catch (Thrown& t) {
    S.cur = saved_cur;
    S.depth = saved_depth;
    S.pcall_depth = saved_pcall;
    S.top = saved_top;
    S.call_where = saved_where;
    S.cur_native = saved_native;
    S.nfn = saved_nfn;
    r.push(Value::boolean(false));
    r.push(t.v);
    return;
  }
  S.pcall_depth = saved_pcall;
  r.push(Value::boolean(true));
  for (int i = 0; i < inner.n; ++i) r.push(inner.p[i]);
}

void b_xpcall(State& S, Args a, Rets& r, Native&) {
  if (a.n < 2) S.arg_error(2, "xpcall", "value expected");
  Frame* saved_cur = S.cur;
  int saved_depth = S.depth, saved_pcall = S.pcall_depth;
  Value* saved_top = S.top;
  Node* saved_where = S.call_where;
  Native* saved_native = S.cur_native;
  bool saved_nfn = S.nfn;
  Rets inner;
  ++S.pcall_depth;
  Value fn = a.v[0], handler = a.v[1];
  // the callee must sit just before its arguments: put it over the handler's slot, and root the handler elsewhere
  a.v[1] = fn;
  S.extra_roots.push_back(handler);
  struct Unroot {
    State& S;
    ~Unroot() { S.extra_roots.pop_back(); }
  } unroot{S};
  try {
    call_value(S, fn, a.v + 2, a.n - 2, inner, nullptr);
  } catch (Thrown& t) {
    S.cur = saved_cur;
    S.depth = saved_depth;
    S.pcall_depth = saved_pcall;
    S.top = saved_top;
    S.call_where = saved_where;
    S.cur_native = saved_native;
    S.nfn = saved_nfn;
    Value ev = t.v;
    Rets hr;
    S.call(handler, &ev, 1, hr);  // the handler runs after unwinding (no stack for it to inspect)
    r.push(Value::boolean(false));
    for (int i = 0; i < hr.n; ++i) r.push(hr.p[i]);
    return;
  }
  S.pcall_depth = saved_pcall;
  r.push(Value::boolean(true));
  for (int i = 0; i < inner.n; ++i) r.push(inner.p[i]);
}

void b_select(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_STR && a.v[0].s()->len == 1 && a.v[0].s()->data()[0] == '#') {
    r.push(Value::integer(a.n - 1));
    return;
  }
  std::int64_t n = check_int(S, a, 1, "select");
  std::int64_t cnt = a.n - 1;  // the values after the selector sit at a.v[1..cnt]
  if (n < 0) n = cnt + 1 + n;
  else if (n > cnt) n = cnt + 1;
  if (n < 1) S.arg_error(1, "select", "index out of range");
  for (std::int64_t i = n; i <= cnt; ++i) r.push(a.v[i]);
}

void b_collectgarbage(State& S, Args a, Rets& r, Native&) {
  std::string opt = a.n >= 1 && a.v[0].t == T_STR ? std::string(a.v[0].s()->view()) : "collect";
  if (opt == "collect") {
    S.collect();
    r.push(Value::integer(0));
  } else if (opt == "count") {
    r.push(Value::number(static_cast<double>(S.gc_bytes()) / 1024.0));
  } else if (opt == "step") {
    S.collect();
    r.push(Value::boolean(true));
  } else if (opt == "isrunning") {
    r.push(Value::boolean(true));
  } else if (opt == "incremental" || opt == "generational") {
    r.push(S.strv("incremental"));
  } else if (opt == "stop" || opt == "restart" || opt == "setpause" || opt == "setstepmul") {
    r.push(Value::integer(0));
  } else {
    S.arg_error(1, "collectgarbage", "invalid option '" + opt + "'");
  }
}

std::string chunk_id(const std::string& source) {
  if (!source.empty() && (source[0] == '=' || source[0] == '@')) return source.substr(1);
  std::size_t nl = source.find('\n');
  const std::size_t bufflen = 45;
  std::string out = "[string \"";
  if (source.size() < bufflen && nl == std::string::npos) {
    out += source;
  } else {
    std::size_t n = nl != std::string::npos ? nl : source.size();
    if (n > bufflen) n = bufflen;
    out += source.substr(0, n) + "...";
  }
  return out + "\"]";
}

void b_load(State& S, Args a, Rets& r, Native&) {
  if (a.n < 1 || a.v[0].t != T_STR) type_err(S, a, 1, "load", "string");  // only string chunks
  std::string code(a.v[0].s()->view());
  std::string name = chunk_id(a.n >= 2 && a.v[1].t == T_STR ? std::string(a.v[1].s()->view()) : code);
  if (a.n >= 4 && !a.v[3].is_nil()) S.rt_error("load: a custom environment is not supported");
  std::string err;
  Closure* cl = S.load(code, name, &err);
  if (!cl) {
    r.push(Value());
    r.push(S.strv(err));
    return;
  }
  r.push(Value::function(cl));
}

// ==================================================================================================================
// string library
// ==================================================================================================================
std::int64_t posrelat_start(std::int64_t pos, std::size_t len) {
  if (pos > 0) return pos;
  if (pos == 0) return 1;
  if (pos < -static_cast<std::int64_t>(len)) return 1;
  return static_cast<std::int64_t>(len) + pos + 1;
}

std::int64_t getendpos(std::int64_t pos, std::size_t len) {
  if (pos > static_cast<std::int64_t>(len)) return static_cast<std::int64_t>(len);
  if (pos >= 0) return pos;
  if (pos < -static_cast<std::int64_t>(len)) return 0;
  return static_cast<std::int64_t>(len) + pos + 1;
}

void s_len(State& S, Args a, Rets& r, Native&) { r.push(Value::integer(check_str(S, a, 1, "len")->len)); }

void s_sub(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "sub");
  std::int64_t i = posrelat_start(check_int(S, a, 2, "sub"), s->len);
  std::int64_t j = getendpos(opt_int(S, a, 3, "sub", -1), s->len);
  if (i <= j) r.push(S.strv(std::string_view(s->data() + i - 1, static_cast<std::size_t>(j - i + 1))));
  else r.push(S.strv(""));
}

void s_upper(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "upper");
  std::string out(s->view());
  for (char& c : out) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
  r.push(S.strv(out));
}

void s_lower(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "lower");
  std::string out(s->view());
  for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  r.push(S.strv(out));
}

void s_reverse(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "reverse");
  std::string out(s->view());
  std::reverse(out.begin(), out.end());
  r.push(S.strv(out));
}

void s_rep(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "rep");
  std::int64_t n = check_int(S, a, 2, "rep");
  std::string sep = a.n >= 3 && !a.v[2].is_nil() ? std::string(check_str(S, a, 3, "rep")->view()) : "";
  if (n <= 0) {
    r.push(S.strv(""));
    return;
  }
  std::uint64_t total = (static_cast<std::uint64_t>(s->len) + sep.size()) * static_cast<std::uint64_t>(n);
  if (total > (1ull << 31)) S.rt_error("resulting string too large");
  std::string out;
  out.reserve(static_cast<std::size_t>(total));
  for (std::int64_t i = 0; i < n; ++i) {
    out.append(s->data(), s->len);
    if (i + 1 < n) out += sep;
  }
  r.push(S.strv(out));
}

void s_byte(State& S, Args a, Rets& r, Native&) {
  String* s = check_str(S, a, 1, "byte");
  std::int64_t pi = opt_int(S, a, 2, "byte", 1);
  std::int64_t i = posrelat_start(pi, s->len);
  std::int64_t j = getendpos(opt_int(S, a, 3, "byte", pi), s->len);
  for (std::int64_t k = i; k <= j; ++k) r.push(Value::integer(static_cast<unsigned char>(s->data()[k - 1])));
}

void s_char(State& S, Args a, Rets& r, Native&) {
  std::string out;
  for (int i = 1; i <= a.n; ++i) {
    std::int64_t c = check_int(S, a, i, "char");
    if (static_cast<std::uint64_t>(c) > 255) S.arg_error(i, "char", "value out of range");
    out.push_back(static_cast<char>(c));
  }
  r.push(S.strv(out));
}

// ---- patterns (a port of lstrlib's matcher) ----
const int kMaxCaptures = 32;
const int kCapUnfinished = -1;
const int kCapPosition = -2;
const int kMaxCCalls = 200;
const char kEsc = '%';

struct MatchState {
  State* S;
  const char* src_init;
  const char* src_end;
  const char* p_end;
  int matchdepth;
  int level;
  struct {
    const char* init;
    std::ptrdiff_t len;
  } capture[kMaxCaptures];
};

inline int uchar(char c) { return static_cast<unsigned char>(c); }

const char* match(MatchState* ms, const char* s, const char* p);

int check_capture(MatchState* ms, int l) {
  l -= '1';
  if (l < 0 || l >= ms->level || ms->capture[l].len == kCapUnfinished) ms->S->rt_error("invalid capture index %" + std::to_string(l + 1));
  return l;
}

int capture_to_close(MatchState* ms) {
  int level = ms->level;
  for (level--; level >= 0; level--)
    if (ms->capture[level].len == kCapUnfinished) return level;
  ms->S->rt_error("invalid pattern capture");
}

const char* class_end(MatchState* ms, const char* p) {
  if (p == ms->p_end) ms->S->rt_error("malformed pattern (ends with '%')");
  switch (*p++) {
    case kEsc:
      if (p == ms->p_end) ms->S->rt_error("malformed pattern (ends with '%')");
      return p + 1;
    case '[':
      if (*p == '^') p++;
      do {
        if (p == ms->p_end) ms->S->rt_error("malformed pattern (missing ']')");
        if (*(p++) == kEsc && p < ms->p_end) p++;
      } while (*p != ']');
      return p + 1;
    default: return p;
  }
}

int match_class(int c, int cl) {
  int res;
  switch (std::tolower(cl)) {
    case 'a': res = std::isalpha(c); break;
    case 'c': res = std::iscntrl(c); break;
    case 'd': res = std::isdigit(c); break;
    case 'g': res = std::isgraph(c); break;
    case 'l': res = std::islower(c); break;
    case 'p': res = std::ispunct(c); break;
    case 's': res = std::isspace(c); break;
    case 'u': res = std::isupper(c); break;
    case 'w': res = std::isalnum(c); break;
    case 'x': res = std::isxdigit(c); break;
    default: return cl == c;
  }
  if (std::isupper(cl)) res = !res;
  return res;
}

int match_bracket_class(int c, const char* p, const char* ec) {
  int sig = 1;
  if (*(p + 1) == '^') {
    sig = 0;
    p++;
  }
  while (++p < ec) {
    if (*p == kEsc) {
      p++;
      if (match_class(c, uchar(*p))) return sig;
    } else if (*(p + 1) == '-' && (p + 2 < ec)) {
      p += 2;
      if (uchar(*(p - 2)) <= c && c <= uchar(*p)) return sig;
    } else if (uchar(*p) == c) {
      return sig;
    }
  }
  return !sig;
}

int single_match(MatchState* ms, const char* s, const char* p, const char* ep) {
  if (s >= ms->src_end) return 0;
  int c = uchar(*s);
  switch (*p) {
    case '.': return 1;
    case kEsc: return match_class(c, uchar(*(p + 1)));
    case '[': return match_bracket_class(c, p, ep - 1);
    default: return uchar(*p) == c;
  }
}

const char* match_balance(MatchState* ms, const char* s, const char* p) {
  if (p >= ms->p_end - 1) ms->S->rt_error("malformed pattern (missing arguments to '%b')");
  if (*s != *p) return nullptr;
  int b = *p, e = *(p + 1), cont = 1;
  while (++s < ms->src_end) {
    if (*s == e) {
      if (--cont == 0) return s + 1;
    } else if (*s == b) {
      cont++;
    }
  }
  return nullptr;
}

const char* max_expand(MatchState* ms, const char* s, const char* p, const char* ep) {
  std::ptrdiff_t i = 0;
  while (single_match(ms, s + i, p, ep)) i++;
  while (i >= 0) {
    const char* res = match(ms, s + i, ep + 1);
    if (res) return res;
    i--;
  }
  return nullptr;
}

const char* min_expand(MatchState* ms, const char* s, const char* p, const char* ep) {
  for (;;) {
    const char* res = match(ms, s, ep + 1);
    if (res != nullptr) return res;
    if (single_match(ms, s, p, ep)) s++;
    else return nullptr;
  }
}

const char* start_capture(MatchState* ms, const char* s, const char* p, int what) {
  int level = ms->level;
  if (level >= kMaxCaptures) ms->S->rt_error("too many captures");
  ms->capture[level].init = s;
  ms->capture[level].len = what;
  ms->level = level + 1;
  const char* res = match(ms, s, p);
  if (res == nullptr) ms->level--;
  return res;
}

const char* end_capture(MatchState* ms, const char* s, const char* p) {
  int l = capture_to_close(ms);
  ms->capture[l].len = s - ms->capture[l].init;
  const char* res = match(ms, s, p);
  if (res == nullptr) ms->capture[l].len = kCapUnfinished;
  return res;
}

const char* match_capture(MatchState* ms, const char* s, int l) {
  l = check_capture(ms, l);
  std::size_t len = static_cast<std::size_t>(ms->capture[l].len);
  if (static_cast<std::size_t>(ms->src_end - s) >= len && std::memcmp(ms->capture[l].init, s, len) == 0) return s + len;
  return nullptr;
}

const char* match(MatchState* ms, const char* s, const char* p) {
  if (ms->matchdepth-- == 0) ms->S->rt_error("pattern too complex");
init:
  if (p != ms->p_end) {
    switch (*p) {
      case '(':
        if (*(p + 1) == ')') s = start_capture(ms, s, p + 2, kCapPosition);
        else s = start_capture(ms, s, p + 1, kCapUnfinished);
        break;
      case ')': s = end_capture(ms, s, p + 1); break;
      case '$':
        if ((p + 1) != ms->p_end) goto dflt;
        s = (s == ms->src_end) ? s : nullptr;
        break;
      case kEsc:
        switch (*(p + 1)) {
          case 'b':
            s = match_balance(ms, s, p + 2);
            if (s != nullptr) {
              p += 4;
              goto init;
            }
            break;
          case 'f': {
            p += 2;
            if (*p != '[') ms->S->rt_error("missing '[' after '%f' in pattern");
            const char* ep = class_end(ms, p);
            char previous = (s == ms->src_init) ? '\0' : *(s - 1);
            if (!match_bracket_class(uchar(previous), p, ep - 1) && match_bracket_class(uchar(*s), p, ep - 1)) {
              p = ep;
              goto init;
            }
            s = nullptr;
            break;
          }
          case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9':
            s = match_capture(ms, s, uchar(*(p + 1)));
            if (s != nullptr) {
              p += 2;
              goto init;
            }
            break;
          default: goto dflt;
        }
        break;
      default:
      dflt: {
        const char* ep = class_end(ms, p);
        if (!single_match(ms, s, p, ep)) {
          if (*ep == '*' || *ep == '?' || *ep == '-') {
            p = ep + 1;
            goto init;
          }
          s = nullptr;
        } else {
          switch (*ep) {
            case '?': {
              const char* res = match(ms, s + 1, ep + 1);
              if (res != nullptr) {
                s = res;
              } else {
                p = ep + 1;
                goto init;
              }
              break;
            }
            case '+': s++; s = max_expand(ms, s, p, ep); break;
            case '*': s = max_expand(ms, s, p, ep); break;
            case '-': s = min_expand(ms, s, p, ep); break;
            default:
              s++;
              p = ep;
              goto init;
          }
        }
        break;
      }
    }
  }
  ms->matchdepth++;
  return s;
}

Value get_one_capture(MatchState* ms, int l, const char* s, const char* e) {
  if (l >= ms->level) {
    if (l != 0) ms->S->rt_error("invalid capture index %" + std::to_string(l + 1));
    return ms->S->strv(std::string_view(s, static_cast<std::size_t>(e - s)));
  }
  std::ptrdiff_t capl = ms->capture[l].len;
  if (capl == kCapUnfinished) ms->S->rt_error("unfinished capture");
  if (capl == kCapPosition) return Value::integer(ms->capture[l].init - ms->src_init + 1);
  return ms->S->strv(std::string_view(ms->capture[l].init, static_cast<std::size_t>(capl)));
}

int push_captures(MatchState* ms, const char* s, const char* e, Rets& r) {
  int nlevels = (ms->level == 0 && s) ? 1 : ms->level;
  for (int i = 0; i < nlevels; ++i) r.push(get_one_capture(ms, i, s, e));
  return nlevels;
}

void prep_state(MatchState* ms, State* S, const char* s, std::size_t ls, const char* p, std::size_t lp) {
  ms->S = S;
  ms->matchdepth = kMaxCCalls;
  ms->src_init = s;
  ms->src_end = s + ls;
  ms->p_end = p + lp;
  ms->level = 0;
}

bool no_specials(const char* p, std::size_t l) {
  for (std::size_t i = 0; i < l; ++i)
    if (std::strchr("^$*+?.([%-", p[i]) && p[i] != '\0') return false;
  return true;
}

const char* mem_find(const char* s1, std::size_t l1, const char* s2, std::size_t l2) {
  if (l2 == 0) return s1;
  if (l2 > l1) return nullptr;
  const char* init;
  l2--;
  l1 = l1 - l2;
  while (l1 > 0 && (init = static_cast<const char*>(std::memchr(s1, *s2, l1))) != nullptr) {
    init++;
    if (std::memcmp(init, s2 + 1, l2) == 0) return init - 1;
    l1 -= static_cast<std::size_t>(init - s1);
    s1 = init;
  }
  return nullptr;
}

void str_find_aux(State& S, Args a, Rets& r, bool find) {
  const char* fname = find ? "find" : "match";
  String* ss = check_str(S, a, 1, fname);
  String* ps = check_str(S, a, 2, fname);
  const char *s = ss->data(), *p = ps->data();
  std::size_t ls = ss->len, lp = ps->len;
  std::int64_t init = posrelat_start(opt_int(S, a, 3, fname, 1), ls) - 1;
  if (init > static_cast<std::int64_t>(ls)) {
    r.push(Value());
    return;
  }
  if (find && ((a.n >= 4 && a.v[3].truthy()) || no_specials(p, lp))) {
    const char* s2 = mem_find(s + init, ls - static_cast<std::size_t>(init), p, lp);
    if (s2) {
      r.push(Value::integer(s2 - s + 1));
      r.push(Value::integer(static_cast<std::int64_t>(s2 - s + static_cast<std::ptrdiff_t>(lp))));
      return;
    }
  } else {
    MatchState ms;
    const char* s1 = s + init;
    bool anchor = *p == '^';
    if (anchor) {
      p++;
      lp--;
    }
    prep_state(&ms, &S, s, ls, p, lp);
    do {
      ms.level = 0;
      ms.matchdepth = kMaxCCalls;
      const char* e = match(&ms, s1, p);
      if (e != nullptr) {
        if (find) {
          r.push(Value::integer(s1 - s + 1));
          r.push(Value::integer(e - s));
          push_captures(&ms, nullptr, nullptr, r);
        } else {
          push_captures(&ms, s1, e, r);
        }
        return;
      }
    } while (s1++ < ms.src_end && !anchor);
  }
  r.push(Value());
}

void s_find(State& S, Args a, Rets& r, Native&) { str_find_aux(S, a, r, true); }
void s_match(State& S, Args a, Rets& r, Native&) { str_find_aux(S, a, r, false); }

// gmatch keeps its state in a table held as the iterator's upvalue: [1] subject, [2] pattern, [3] position, [4] last match
void gmatch_iter(State& S, Args, Rets& r, Native& self) {
  Table* st = self.up.tab();
  String* ss = st->get_int(1).s();
  String* ps = st->get_int(2).s();
  std::int64_t pos = st->get_int(3).i, last = st->get_int(4).i;
  MatchState ms;
  prep_state(&ms, &S, ss->data(), ss->len, ps->data(), ps->len);
  for (const char* src = ss->data() + pos; src <= ms.src_end; src++) {
    ms.level = 0;
    ms.matchdepth = kMaxCCalls;
    const char* e = match(&ms, src, ps->data());
    if (e != nullptr && (e - ss->data()) != last) {
      std::int64_t np = e - ss->data();
      st->set_int(S, 3, Value::integer(np));
      st->set_int(S, 4, Value::integer(np));
      push_captures(&ms, src, e, r);
      return;
    }
  }
  st->set_int(S, 3, Value::integer(static_cast<std::int64_t>(ss->len) + 1));
  r.push(Value());
}

void s_gmatch(State& S, Args a, Rets& r, Native&) {
  String* ss = check_str(S, a, 1, "gmatch");
  String* ps = check_str(S, a, 2, "gmatch");
  std::int64_t init = posrelat_start(opt_int(S, a, 3, "gmatch", 1), ss->len) - 1;
  if (init > static_cast<std::int64_t>(ss->len)) init = static_cast<std::int64_t>(ss->len) + 1;
  Table* st = S.new_table(4, 0);
  Value stv = Value::table(st);
  st->set_int(S, 1, Value::str(ss));
  st->set_int(S, 2, Value::str(ps));
  st->set_int(S, 3, Value::integer(init));
  st->set_int(S, 4, Value::integer(-1));
  r.push(Value::function(S.new_native(gmatch_iter, "gmatch_iter", nullptr, stv)));
}

void add_s(MatchState* ms, std::string& b, const char* s, const char* e, String* news) {
  const char* p = news->data();
  std::size_t l = news->len;
  for (std::size_t i = 0; i < l; ++i) {
    if (p[i] != kEsc) {
      b.push_back(p[i]);
      continue;
    }
    ++i;
    if (p[i] == kEsc) {
      b.push_back(kEsc);
    } else if (p[i] == '0') {
      b.append(s, static_cast<std::size_t>(e - s));
    } else if (std::isdigit(uchar(p[i]))) {
      Value v = get_one_capture(ms, p[i] - '1', s, e);
      if (v.t == T_STR) b.append(v.s()->data(), v.s()->len);
      else b += number_to_string(v);
    } else {
      ms->S->rt_error("invalid use of '%' in replacement string");
    }
  }
}

void s_gsub(State& S, Args a, Rets& r, Native&) {
  String* srcs = check_str(S, a, 1, "gsub");
  String* ps = check_str(S, a, 2, "gsub");
  const char* src = srcs->data();
  const char* p = ps->data();
  std::size_t srcl = srcs->len, lp = ps->len;
  const char* lastmatch = nullptr;
  Value repl = a[2];
  if (!(repl.t == T_STR || repl.is_number() || repl.t == T_TAB || repl.t == T_FUN)) type_err(S, a, 3, "gsub", "string/function/table");
  if (repl.is_number()) {
    a.v[2] = Value::str(S.str(number_to_string(repl)));
    repl = a.v[2];
  }
  std::int64_t max_s = opt_int(S, a, 4, "gsub", static_cast<std::int64_t>(srcl) + 1);
  bool anchor = *p == '^';
  if (anchor) {
    p++;
    lp--;
  }
  std::int64_t n = 0;
  std::string b;
  MatchState ms;
  prep_state(&ms, &S, src, srcl, p, lp);
  while (n < max_s) {
    ms.level = 0;
    ms.matchdepth = kMaxCCalls;
    const char* e = match(&ms, src, p);
    if (e != nullptr && e != lastmatch) {
      n++;
      // the replacement value for this match
      if (repl.t == T_STR) {
        add_s(&ms, b, src, e, repl.s());
      } else {
        Value result;
        if (repl.t == T_FUN) {
          Rets caps;
          push_captures(&ms, src, e, caps);
          Rets res;
          S.call(repl, caps.p, caps.n, res);
          result = res.first();
        } else {
          Value key = get_one_capture(&ms, 0, src, e);
          result = repl.tab()->get(key);
          if (result.is_nil() && repl.tab()->meta) result = index_slow(S, repl, key, nullptr);
        }
        if (!result.truthy()) {
          b.append(src, static_cast<std::size_t>(e - src));
        } else if (result.t == T_STR) {
          b.append(result.s()->data(), result.s()->len);
        } else if (result.is_number()) {
          b += number_to_string(result);
        } else {
          S.rt_error(std::string("invalid replacement value (a ") + State::type_name(result) + ")");
        }
      }
      src = lastmatch = e;
    } else if (src < ms.src_end) {
      b.push_back(*src++);
    } else {
      break;
    }
    if (anchor) break;
  }
  b.append(src, static_cast<std::size_t>(ms.src_end - src));
  r.push(S.strv(b));
  r.push(Value::integer(n));
}

// ---- string.format ----
const char* const kFmtFlagsF = "-+#0 ";
const char* const kFmtFlagsX = "-#0";
const char* const kFmtFlagsI = "-+0 ";
const char* const kFmtFlagsU = "-0";
const char* const kFmtFlagsC = "-";

const char* get2digits(const char* s) {
  if (std::isdigit(uchar(*s))) {
    s++;
    if (std::isdigit(uchar(*s))) s++;
  }
  return s;
}

void check_format(State& S, const char* form, const char* flags, bool precision) {
  const char* spec = form + 1;
  spec += std::strspn(spec, flags);
  if (*spec != '0') {
    spec = get2digits(spec);
    if (*spec == '.' && precision) {
      spec++;
      spec = get2digits(spec);
    }
  }
  if (!std::isalpha(uchar(*spec))) S.rt_error(std::string("invalid conversion specification: '") + form + "'");
}

void add_quoted(std::string& b, const char* s, std::size_t len) {
  b.push_back('"');
  while (len--) {
    if (*s == '"' || *s == '\\' || *s == '\n') {
      b.push_back('\\');
      b.push_back(*s);
    } else if (std::iscntrl(uchar(*s))) {
      char buff[10];
      if (!std::isdigit(uchar(*(s + 1)))) std::snprintf(buff, sizeof buff, "\\%d", uchar(*s));
      else std::snprintf(buff, sizeof buff, "\\%03d", uchar(*s));
      b += buff;
    } else {
      b.push_back(*s);
    }
    s++;
  }
  b.push_back('"');
}

void s_format(State& S, Args a, Rets& r, Native&) {
  String* fs = check_str(S, a, 1, "format");
  const char* strfrmt = fs->data();
  const char* strfrmt_end = strfrmt + fs->len;
  int arg = 1;
  std::string b;
  while (strfrmt < strfrmt_end) {
    if (*strfrmt != kEsc) {
      b.push_back(*strfrmt++);
    } else if (*++strfrmt == kEsc) {
      b.push_back(*strfrmt++);
    } else {
      char form[32];
      char buff[512];
      int nb = 0;
      if (++arg > a.n) S.arg_error(arg, "format", "no value");
      std::size_t len = std::strspn(strfrmt, "-+#0 123456789.");
      len++;
      if (len >= 32 - 10) S.rt_error("invalid format (too long)");
      form[0] = '%';
      std::memcpy(form + 1, strfrmt, len);
      form[len + 1] = '\0';
      strfrmt += len - 1;
      char spec = *strfrmt++;
      auto addlen = [&](const char* lenmod) {
        std::size_t l = std::strlen(form);
        std::size_t lm = std::strlen(lenmod);
        char sp = form[l - 1];
        std::strcpy(form + l - 1, lenmod);
        form[l + lm - 1] = sp;
        form[l + lm] = '\0';
      };
      switch (spec) {
        case 'c':
          check_format(S, form, kFmtFlagsC, false);
          nb = std::snprintf(buff, sizeof buff, form, static_cast<int>(check_int(S, a, arg, "format")));
          break;
        case 'd': case 'i': case 'u': case 'o': case 'x': case 'X': {
          const char* flags = (spec == 'd' || spec == 'i') ? kFmtFlagsI : (spec == 'u') ? kFmtFlagsU : kFmtFlagsX;
          std::int64_t n = check_int(S, a, arg, "format");
          check_format(S, form, flags, true);
          addlen("ll");
          nb = std::snprintf(buff, sizeof buff, form, static_cast<long long>(n));
          break;
        }
        case 'a': case 'A':
          check_format(S, form, kFmtFlagsF, true);
          nb = std::snprintf(buff, sizeof buff, form, check_num(S, a, arg, "format"));
          break;
        case 'f': case 'e': case 'E': case 'g': case 'G': {
          double n = check_num(S, a, arg, "format");
          check_format(S, form, kFmtFlagsF, true);
          if (spec == 'f') {
            std::vector<char> big(420 + 32);
            nb = std::snprintf(big.data(), big.size(), form, n);
            b.append(big.data(), static_cast<std::size_t>(nb));
            nb = 0;
          } else {
            nb = std::snprintf(buff, sizeof buff, form, n);
          }
          break;
        }
        case 'p': {
          check_format(S, form, kFmtFlagsC, false);
          const void* p = a.v[arg - 1].is_gc() ? static_cast<const void*>(a.v[arg - 1].o) : nullptr;
          if (p == nullptr) {
            form[std::strlen(form) - 1] = 's';
            nb = std::snprintf(buff, sizeof buff, form, "(null)");
          } else {
            nb = std::snprintf(buff, sizeof buff, form, p);
          }
          break;
        }
        case 'q': {
          if (form[2] != '\0') S.rt_error("specifier '%q' cannot have modifiers");
          const Value& v = a.v[arg - 1];
          if (v.t == T_STR) {
            add_quoted(b, v.s()->data(), v.s()->len);
          } else if (v.t == T_INT) {
            if (v.i == INT64_MIN) b += "0x8000000000000000";
            else b += std::to_string(v.i);
          } else if (v.t == T_FLT) {
            if (v.d == HUGE_VAL) b += "1e9999";
            else if (v.d == -HUGE_VAL) b += "-1e9999";
            else if (v.d != v.d) b += "(0/0)";
            else nb = std::snprintf(buff, sizeof buff, "%a", v.d);
          } else if (v.t == T_NIL || v.is_bool()) {
            b += S.tostring(v);
          } else {
            S.arg_error(arg, "format", "value has no literal form");
          }
          break;
        }
        case 's': {
          std::string str = S.tostring(a.v[arg - 1]);
          if (form[2] == '\0') {
            b += str;
          } else {
            if (str.find('\0') != std::string::npos) S.arg_error(arg, "format", "string contains zeros");
            check_format(S, form, kFmtFlagsC, true);
            if (std::strchr(form, '.') == nullptr && str.size() >= 100) {
              b += str;
            } else {
              std::vector<char> big(str.size() + 128);
              nb = std::snprintf(big.data(), big.size(), form, str.c_str());
              b.append(big.data(), static_cast<std::size_t>(nb));
              nb = 0;
            }
          }
          break;
        }
        default: S.rt_error(std::string("invalid conversion '") + form + "' to 'format'");
      }
      if (nb > 0) b.append(buff, static_cast<std::size_t>(nb));
    }
  }
  r.push(S.strv(b));
}

// ==================================================================================================================
// table library
// ==================================================================================================================
std::int64_t len_of(State& S, Args a, int i, const char* fname) {
  Table* t = check_table(S, a, i, fname);
  if (!t->meta) return t->length();
  Value n = len_slow(S, a.v[i - 1], nullptr);
  if (n.t != T_INT) S.rt_error("object length is not an integer");
  return n.i;
}

Value geti(State& S, const Value& t, std::int64_t i) {
  Table* tb = t.tab();
  Value v = tb->get_int(i);
  if (v.is_nil() && tb->meta) return index_slow(S, t, Value::integer(i), nullptr);
  return v;
}

void seti(State& S, const Value& t, std::int64_t i, const Value& v) {
  Table* tb = t.tab();
  if (tb->meta) setindex_slow(S, t, Value::integer(i), v, nullptr);
  else tb->set_int(S, i, v);
}

void t_insert(State& S, Args a, Rets&, Native&) {
  std::int64_t e = len_of(S, a, 1, "insert") + 1;
  std::int64_t pos;
  switch (a.n) {
    case 2: pos = e; break;
    case 3: {
      pos = check_int(S, a, 2, "insert");
      if (static_cast<std::uint64_t>(pos) - 1u >= static_cast<std::uint64_t>(e)) S.arg_error(2, "insert", "position out of bounds");
      for (std::int64_t i = e; i > pos; --i) seti(S, a.v[0], i, geti(S, a.v[0], i - 1));
      break;
    }
    default: S.rt_error("wrong number of arguments to 'insert'");
  }
  seti(S, a.v[0], pos, a.v[a.n - 1]);
}

void t_remove(State& S, Args a, Rets& r, Native&) {
  std::int64_t size = len_of(S, a, 1, "remove");
  std::int64_t pos = opt_int(S, a, 2, "remove", size);
  if (a.n >= 2 && pos != size && static_cast<std::uint64_t>(pos) - 1u > static_cast<std::uint64_t>(size))
    S.arg_error(2, "remove", "position out of bounds");
  Value res = geti(S, a.v[0], pos);
  r.push(res);
  for (; pos < size; ++pos) seti(S, a.v[0], pos, geti(S, a.v[0], pos + 1));
  seti(S, a.v[0], pos, Value());
}

void t_concat(State& S, Args a, Rets& r, Native&) {
  std::int64_t last = len_of(S, a, 1, "concat");
  std::string sep = a.n >= 2 && !a.v[1].is_nil() ? std::string(check_str(S, a, 2, "concat")->view()) : "";
  std::int64_t i = opt_int(S, a, 3, "concat", 1);
  std::int64_t j = opt_int(S, a, 4, "concat", last);
  std::string b;
  for (; i <= j; ++i) {
    Value v = geti(S, a.v[0], i);
    if (v.t == T_STR) b.append(v.s()->data(), v.s()->len);
    else if (v.is_number()) b += number_to_string(v);
    else S.rt_error(std::string("invalid value (") + State::type_name(v) + ") at index " + std::to_string(i) + " in table for 'concat'");
    if (i != j) b += sep;
  }
  r.push(S.strv(b));
}

void t_unpack(State& S, Args a, Rets& r, Native&) {
  Value t = a[0];
  std::int64_t i = opt_int(S, a, 2, "unpack", 1);
  std::int64_t e = a.n >= 3 && !a.v[2].is_nil() ? check_int(S, a, 3, "unpack") : (t.t == T_TAB ? len_of(S, a, 1, "unpack") : 0);
  if (t.t != T_TAB && !(t.t == T_STR)) type_err(S, a, 1, "unpack", "table");
  if (i > e) return;
  std::uint64_t n = static_cast<std::uint64_t>(e) - static_cast<std::uint64_t>(i);
  if (n >= 1000000u) S.rt_error("too many results to unpack");
  for (std::int64_t k = i; k <= e; ++k) r.push(t.t == T_TAB ? geti(S, t, k) : Value());
}

void t_pack(State& S, Args a, Rets& r, Native&) {
  Table* t = S.new_table(static_cast<std::uint32_t>(a.n), 1);
  for (int i = 0; i < a.n; ++i) t->set_int(S, i + 1, a.v[i]);
  t->set_str(S, S.str("n"), Value::integer(a.n));
  r.push(Value::table(t));
}

void t_move(State& S, Args a, Rets& r, Native&) {
  check_table(S, a, 1, "move");
  std::int64_t f = check_int(S, a, 2, "move");
  std::int64_t e = check_int(S, a, 3, "move");
  std::int64_t t = check_int(S, a, 4, "move");
  int tt = a.n >= 5 && !a.v[4].is_nil() ? 5 : 1;
  check_table(S, a, tt, "move");
  if (e >= f) {
    if (!(f > 0 || e < INT64_MAX + f)) S.arg_error(3, "move", "too many elements to move");
    if (t > INT64_MAX - (e - f)) S.arg_error(4, "move", "destination wrap around");
    if (t > e || t <= f || (tt != 1 && !raw_equal(a.v[0], a.v[tt - 1]))) {
      for (std::int64_t i = 0; i <= e - f; ++i) seti(S, a.v[tt - 1], t + i, geti(S, a.v[0], f + i));
    } else {
      for (std::int64_t i = e - f; i >= 0; --i) seti(S, a.v[tt - 1], t + i, geti(S, a.v[0], f + i));
    }
  }
  r.push(a.v[tt - 1]);
}

// A merge sort: it never reads out of bounds, whatever the comparison function does (an inconsistent one just gives some
// order). Elements are rooted while the comparison function (script code) runs.
struct Sorter {
  State& S;
  Value cmp;
  bool has_cmp;
  bool less(const Value& x, const Value& y) {
    if (!has_cmp) return less_slow(S, x, y);
    Value args[2] = {x, y};
    Rets res;
    S.call(cmp, args, 2, res);
    return res.first().truthy();
  }
  void sort(std::vector<Value>& v) {
    std::vector<Value> tmp(v.size());
    msort(v, tmp, 0, v.size());
  }
  void msort(std::vector<Value>& v, std::vector<Value>& tmp, std::size_t lo, std::size_t hi) {
    if (hi - lo < 2) return;
    std::size_t mid = lo + (hi - lo) / 2;
    msort(v, tmp, lo, mid);
    msort(v, tmp, mid, hi);
    std::size_t i = lo, j = mid, k = lo;
    while (i < mid && j < hi) {
      if (less(v[j], v[i])) tmp[k++] = v[j++];
      else tmp[k++] = v[i++];
    }
    while (i < mid) tmp[k++] = v[i++];
    while (j < hi) tmp[k++] = v[j++];
    for (k = lo; k < hi; ++k) v[k] = tmp[k];
  }
};

void t_sort(State& S, Args a, Rets&, Native&) {
  std::int64_t n = len_of(S, a, 1, "sort");
  if (n < 2) return;
  if (n >= INT32_MAX) S.arg_error(1, "sort", "array too big");
  Sorter so{S, Value(), false};
  if (a.n >= 2 && !a.v[1].is_nil()) {
    if (a.v[1].t != T_FUN) type_err(S, a, 2, "sort", "function");
    so.cmp = a.v[1];
    so.has_cmp = true;
  }
  std::vector<Value> v;
  v.reserve(static_cast<std::size_t>(n));
  for (std::int64_t i = 1; i <= n; ++i) v.push_back(geti(S, a.v[0], i));
  std::size_t root_base = S.extra_roots.size();
  S.extra_roots.insert(S.extra_roots.end(), v.begin(), v.end());
  struct Unroot {
    State& S;
    std::size_t base;
    ~Unroot() { S.extra_roots.resize(base); }
  } unroot{S, root_base};
  so.sort(v);
  for (std::int64_t i = 1; i <= n; ++i) seti(S, a.v[0], i, v[static_cast<std::size_t>(i - 1)]);
}

// ==================================================================================================================
// math library
// ==================================================================================================================
void push_numint(Rets& r, double d) {
  std::int64_t n;
  if (float_to_integer(d, &n)) r.push(Value::integer(n));
  else r.push(Value::number(d));
}

void m_floor(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_INT) {
    r.push(a.v[0]);
    return;
  }
  push_numint(r, std::floor(check_num(S, a, 1, "floor")));
}

void m_ceil(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_INT) {
    r.push(a.v[0]);
    return;
  }
  push_numint(r, std::ceil(check_num(S, a, 1, "ceil")));
}

void m_abs(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_INT) {
    std::int64_t n = a.v[0].i;
    if (n < 0) n = static_cast<std::int64_t>(0u - static_cast<std::uint64_t>(n));
    r.push(Value::integer(n));
  } else {
    r.push(Value::number(std::fabs(check_num(S, a, 1, "abs"))));
  }
}

void m_fmod(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 2 && a.v[0].t == T_INT && a.v[1].t == T_INT) {
    std::int64_t d = a.v[1].i;
    if (static_cast<std::uint64_t>(d) + 1u <= 1u) {
      if (d == 0) S.arg_error(2, "fmod", "zero");
      r.push(Value::integer(0));
    } else {
      r.push(Value::integer(a.v[0].i % d));
    }
  } else {
    r.push(Value::number(std::fmod(check_num(S, a, 1, "fmod"), check_num(S, a, 2, "fmod"))));
  }
}

void m_modf(State& S, Args a, Rets& r, Native&) {
  if (a.n >= 1 && a.v[0].t == T_INT) {
    r.push(a.v[0]);
    r.push(Value::number(0));
    return;
  }
  double n = check_num(S, a, 1, "modf");
  double ip = n < 0 ? std::ceil(n) : std::floor(n);
  push_numint(r, ip);
  r.push(Value::number(n == ip ? 0.0 : n - ip));
}

void m_sqrt(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::sqrt(check_num(S, a, 1, "sqrt")))); }
void m_sin(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::sin(check_num(S, a, 1, "sin")))); }
void m_cos(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::cos(check_num(S, a, 1, "cos")))); }
void m_tan(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::tan(check_num(S, a, 1, "tan")))); }
void m_asin(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::asin(check_num(S, a, 1, "asin")))); }
void m_acos(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::acos(check_num(S, a, 1, "acos")))); }
void m_exp(State& S, Args a, Rets& r, Native&) { r.push(Value::number(std::exp(check_num(S, a, 1, "exp")))); }

void m_atan(State& S, Args a, Rets& r, Native&) {
  double y = check_num(S, a, 1, "atan");
  double x = a.n >= 2 && !a.v[1].is_nil() ? check_num(S, a, 2, "atan") : 1.0;
  r.push(Value::number(std::atan2(y, x)));
}

void m_log(State& S, Args a, Rets& r, Native&) {
  double x = check_num(S, a, 1, "log");
  double res;
  if (a.n < 2 || a.v[1].is_nil()) {
    res = std::log(x);
  } else {
    double base = check_num(S, a, 2, "log");
    if (base == 2.0) res = std::log2(x);
    else if (base == 10.0) res = std::log10(x);
    else res = std::log(x) / std::log(base);
  }
  r.push(Value::number(res));
}

void m_tointeger(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "tointeger");
  std::int64_t n;
  if (a.v[0].is_number() || a.v[0].t == T_STR) {
    if (to_integer(a.v[0], &n)) {
      r.push(Value::integer(n));
      return;
    }
  }
  r.push(Value());
}

void m_type(State& S, Args a, Rets& r, Native&) {
  check_any(S, a, 1, "type");
  if (a.v[0].t == T_INT) r.push(S.strv("integer"));
  else if (a.v[0].t == T_FLT) r.push(S.strv("float"));
  else r.push(Value());
}

void m_max(State& S, Args a, Rets& r, Native&) {
  check_num(S, a, 1, "max");
  Value best;
  to_number(a.v[0], &best);
  for (int i = 2; i <= a.n; ++i) {
    check_num(S, a, i, "max");
    Value v;
    to_number(a.v[i - 1], &v);
    if (less_slow(S, best, v)) best = v;
  }
  r.push(best);
}

void m_min(State& S, Args a, Rets& r, Native&) {
  check_num(S, a, 1, "min");
  Value best;
  to_number(a.v[0], &best);
  for (int i = 2; i <= a.n; ++i) {
    check_num(S, a, i, "min");
    Value v;
    to_number(a.v[i - 1], &v);
    if (less_slow(S, v, best)) best = v;
  }
  r.push(best);
}

void m_ult(State& S, Args a, Rets& r, Native&) {
  r.push(Value::boolean(static_cast<std::uint64_t>(check_int(S, a, 1, "ult")) < static_cast<std::uint64_t>(check_int(S, a, 2, "ult"))));
}

// xoshiro256** exactly as Lua 5.4 does it, so that a seeded sequence equals Lua's.
std::uint64_t g_rand_state[4];

std::uint64_t rotl64(std::uint64_t x, int n) { return (x << n) | (x >> (64 - n)); }

std::uint64_t next_rand(std::uint64_t* state) {
  std::uint64_t state0 = state[0];
  std::uint64_t state1 = state[1];
  std::uint64_t state2 = state[2] ^ state0;
  std::uint64_t state3 = state[3] ^ state1;
  std::uint64_t res = rotl64(state1 * 5, 7) * 9;
  state[0] = state0 ^ state3;
  state[1] = state1 ^ state2;
  state[2] = state2 ^ (state1 << 17);
  state[3] = rotl64(state3, 45);
  return res;
}

void set_seed(std::uint64_t* state, std::uint64_t n1, std::uint64_t n2) {
  state[0] = n1;
  state[1] = 0xff;
  state[2] = n2;
  state[3] = 0;
  for (int i = 0; i < 16; i++) next_rand(state);
}

std::uint64_t project(std::uint64_t ran, std::uint64_t n, std::uint64_t* state) {
  if ((n & (n + 1)) == 0) return ran & n;
  std::uint64_t lim = n;
  lim |= (lim >> 1);
  lim |= (lim >> 2);
  lim |= (lim >> 4);
  lim |= (lim >> 8);
  lim |= (lim >> 16);
  lim |= (lim >> 32);
  while ((ran &= lim) > n) ran = next_rand(state);
  return ran;
}

void m_random(State& S, Args a, Rets& r, Native&) {
  std::int64_t low, up;
  std::uint64_t rv = next_rand(g_rand_state);
  switch (a.n) {
    case 0: r.push(Value::number(static_cast<double>(rv >> 11) * (0.5 / static_cast<double>(1ull << 52)))); return;
    case 1:
      low = 1;
      up = check_int(S, a, 1, "random");
      if (up == 0) {
        r.push(Value::integer(static_cast<std::int64_t>(rv)));
        return;
      }
      break;
    case 2:
      low = check_int(S, a, 1, "random");
      up = check_int(S, a, 2, "random");
      break;
    default: S.rt_error("wrong number of arguments");
  }
  if (low > up) S.arg_error(1, "random", "interval is empty");
  std::uint64_t p = project(rv, static_cast<std::uint64_t>(up) - static_cast<std::uint64_t>(low), g_rand_state);
  r.push(Value::integer(static_cast<std::int64_t>(p + static_cast<std::uint64_t>(low))));
}

void m_randomseed(State& S, Args a, Rets& r, Native&) {
  std::uint64_t n1, n2;
  if (a.n == 0) {
    n1 = static_cast<std::uint64_t>(std::time(nullptr));
    n2 = reinterpret_cast<std::uintptr_t>(&S);
  } else {
    n1 = static_cast<std::uint64_t>(check_int(S, a, 1, "randomseed"));
    n2 = static_cast<std::uint64_t>(opt_int(S, a, 2, "randomseed", 0));
  }
  set_seed(g_rand_state, n1, n2);
  r.push(Value::integer(static_cast<std::int64_t>(n1)));
  r.push(Value::integer(static_cast<std::int64_t>(n2)));
}

}  // namespace

// ---- opening ----------------------------------------------------------------------------------------------------------
void open_base(State& S) {
  Table* g = S.globals;
  g->set_str(S, S.str("_G"), Value::table(g));
  g->set_str(S, S.str("_VERSION"), S.strv("Lua 5.4"));
  register_function(S, g, "", "print", b_print);
  register_function(S, g, "", "type", b_type);
  register_function(S, g, "", "tostring", b_tostring);
  register_function(S, g, "", "tonumber", b_tonumber);
  register_function(S, g, "", "ipairs", b_ipairs);
  register_function(S, g, "", "pairs", b_pairs);
  register_function(S, g, "", "rawget", b_rawget);
  register_function(S, g, "", "rawset", b_rawset);
  register_function(S, g, "", "rawequal", b_rawequal);
  register_function(S, g, "", "rawlen", b_rawlen);
  register_function(S, g, "", "setmetatable", b_setmetatable);
  register_function(S, g, "", "getmetatable", b_getmetatable);
  register_function(S, g, "", "assert", b_assert);
  register_function(S, g, "", "error", b_error);
  register_function(S, g, "", "pcall", b_pcall);
  register_function(S, g, "", "xpcall", b_xpcall);
  register_function(S, g, "", "select", b_select);
  register_function(S, g, "", "collectgarbage", b_collectgarbage);
  register_function(S, g, "", "load", b_load);
  S.next_fn = S.new_native(b_next, "next");
  g->set_str(S, S.str("next"), Value::function(S.next_fn));
  S.ipairs_iter = S.new_native(b_ipairs_iter, "ipairs_iter");
  set_seed(g_rand_state, static_cast<std::uint64_t>(std::time(nullptr)), reinterpret_cast<std::uintptr_t>(&S));
}

void open_string(State& S) {
  Table* t = S.new_table();
  S.globals->set_str(S, S.str("string"), Value::table(t));
  register_function(S, t, "string.", "len", s_len);
  register_function(S, t, "string.", "sub", s_sub);
  register_function(S, t, "string.", "upper", s_upper);
  register_function(S, t, "string.", "lower", s_lower);
  register_function(S, t, "string.", "reverse", s_reverse);
  register_function(S, t, "string.", "rep", s_rep);
  register_function(S, t, "string.", "byte", s_byte);
  register_function(S, t, "string.", "char", s_char);
  register_function(S, t, "string.", "find", s_find);
  register_function(S, t, "string.", "match", s_match);
  register_function(S, t, "string.", "gmatch", s_gmatch);
  register_function(S, t, "string.", "gsub", s_gsub);
  register_function(S, t, "string.", "format", s_format);
  Table* meta = S.new_table();
  meta->set_str(S, tm_string(S, TM_INDEX), Value::table(t));
  S.string_meta = meta;
}

void open_table(State& S) {
  Table* t = S.new_table();
  S.globals->set_str(S, S.str("table"), Value::table(t));
  register_function(S, t, "table.", "insert", t_insert);
  register_function(S, t, "table.", "remove", t_remove);
  register_function(S, t, "table.", "concat", t_concat);
  register_function(S, t, "table.", "unpack", t_unpack);
  register_function(S, t, "table.", "pack", t_pack);
  register_function(S, t, "table.", "move", t_move);
  register_function(S, t, "table.", "sort", t_sort);
}

void open_math(State& S) {
  Table* t = S.new_table();
  S.globals->set_str(S, S.str("math"), Value::table(t));
  register_function(S, t, "math.", "floor", m_floor);
  register_function(S, t, "math.", "ceil", m_ceil);
  register_function(S, t, "math.", "abs", m_abs);
  register_function(S, t, "math.", "fmod", m_fmod);
  register_function(S, t, "math.", "modf", m_modf);
  register_function(S, t, "math.", "sqrt", m_sqrt);
  register_function(S, t, "math.", "sin", m_sin);
  register_function(S, t, "math.", "cos", m_cos);
  register_function(S, t, "math.", "tan", m_tan);
  register_function(S, t, "math.", "asin", m_asin);
  register_function(S, t, "math.", "acos", m_acos);
  register_function(S, t, "math.", "atan", m_atan);
  register_function(S, t, "math.", "exp", m_exp);
  register_function(S, t, "math.", "log", m_log);
  register_function(S, t, "math.", "tointeger", m_tointeger);
  register_function(S, t, "math.", "type", m_type);
  register_function(S, t, "math.", "max", m_max);
  register_function(S, t, "math.", "min", m_min);
  register_function(S, t, "math.", "ult", m_ult);
  register_function(S, t, "math.", "random", m_random);
  register_function(S, t, "math.", "randomseed", m_randomseed);
  t->set_str(S, S.str("pi"), Value::number(3.141592653589793238462643383279502884));
  t->set_str(S, S.str("huge"), Value::number(HUGE_VAL));
  t->set_str(S, S.str("maxinteger"), Value::integer(INT64_MAX));
  t->set_str(S, S.str("mininteger"), Value::integer(INT64_MIN));
}

void State::open_libs() {
  open_base(*this);
  open_string(*this);
  open_table(*this);
  open_math(*this);
}

}  // namespace nfcast
