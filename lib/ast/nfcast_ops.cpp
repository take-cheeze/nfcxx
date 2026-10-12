// nfcast: metatables, the slow paths of the operators (what a specialized node falls back to), and calls.
#include <cmath>

#include "nfcast_impl.hpp"

namespace nfcast {

// ---- metatables --------------------------------------------------------------------------------------------------------
Table* get_metatable(State& S, const Value& v) {
  switch (v.t) {
    case T_TAB: return v.tab()->meta;
    case T_STR: return S.string_meta;
    default: return nullptr;
  }
}

Value tm_of_table(State& S, Table* mt, TM ev) {
  if (!mt) return Value();
  if (ev < 8 && (mt->absent & (1u << ev))) return Value();
  Value v = mt->get_str(tm_string(S, ev));
  if (v.is_nil() && ev < 8) mt->absent = static_cast<std::uint8_t>(mt->absent | (1u << ev));
  return v;
}

Value tm_value(State& S, const Value& v, TM ev) { return tm_of_table(S, get_metatable(S, v), ev); }

Table* State::metatable_of(const Value& v) const { return get_metatable(*const_cast<State*>(this), v); }

Value State::metamethod(const Value& v, const char* event) {
  Table* mt = get_metatable(*this, v);
  if (!mt) return Value();
  return mt->get_str(str(event));
}

std::string var_info(Node* n) {
  if (!n) return "";
  std::string d;
  n->describe(d);
  return d.empty() ? "" : " (" + d + ")";
}

[[noreturn]] static void type_error(State& S, const Value& v, const char* op, Node* where) {
  S.rt_error(std::string("attempt to ") + op + " a " + State::type_name(v) + " value" + var_info(where));
}

// The "caller" recorded for a metamethod call: the VM (the Lua function running the operator), not a native function.
struct MetaCaller : Node {
  Value eval(Frame&) override { return Value(); }
};
static MetaCaller g_meta_caller;

// Calls the metamethod TM with 2 or 3 arguments and returns its first result. The arguments go on the stack, so they
// are roots for as long as the call runs.
static Value call_tm(State& S, const Value& tm, const Value& a, const Value& b, const Value* c) {
  Value* base = S.top;
  if (base + 8 > S.stack_end) S.rt_error("stack overflow");
  base[0] = tm;
  base[1] = a;
  base[2] = b;
  int n = 2;
  if (c) {
    base[3] = *c;
    n = 3;
  }
  S.top = base + 1 + n;
  Rets r;
  call_value(S, tm, base + 1, n, r, &g_meta_caller);
  S.top = base;
  return r.first();
}

// ---- indexing ----------------------------------------------------------------------------------------------------------
Value index_slow(State& S, const Value& obj, const Value& key, Node* where) {
  ++S.stats.generic_ops;
  Value cur = obj;
  for (int loop = 0; loop < 2000; ++loop) {
    Value tm;
    if (cur.t == T_TAB) {
      Table* t = cur.tab();
      Value v = t->get(key);
      if (!v.is_nil()) return v;
      tm = tm_of_table(S, t->meta, TM_INDEX);
      if (tm.is_nil()) return Value();
    } else if (cur.t == T_HOST) {
      HostObject* h = cur.hostobj();
      if (key.t != T_STR) return Value();
      HostMember* m = h->member(S, key.s());
      if (!m) return Value();
      return m->get(S, h);
    } else {
      tm = tm_value(S, cur, TM_INDEX);
      if (tm.is_nil()) type_error(S, cur, "index", loop == 0 ? where : nullptr);
    }
    if (tm.t == T_FUN) return call_tm(S, tm, cur, key, nullptr);
    cur = tm;
  }
  S.rt_error("'__index' chain too long; possible loop");
}

static void raw_set_checked(State& S, Table* t, const Value& key, const Value& val) {
  if (key.t == T_NIL) S.rt_error("table index is nil");
  if (key.t == T_FLT && key.d != key.d) S.rt_error("table index is NaN");
  t->set(S, key, val);
}

void setindex_slow(State& S, const Value& obj, const Value& key, const Value& val, Node* where) {
  ++S.stats.generic_ops;
  Value cur = obj;
  for (int loop = 0; loop < 2000; ++loop) {
    Value tm;
    if (cur.t == T_TAB) {
      Table* t = cur.tab();
      if (!t->get(key).is_nil()) {
        t->set(S, key, val);
        return;
      }
      tm = tm_of_table(S, t->meta, TM_NEWINDEX);
      if (tm.is_nil()) {
        raw_set_checked(S, t, key, val);
        return;
      }
    } else if (cur.t == T_HOST) {
      HostObject* h = cur.hostobj();
      HostMember* m = key.t == T_STR ? h->member(S, key.s()) : nullptr;
      if (!m || m->is_method) S.rt_error("cannot assign to field '" + S.tostring(key) + "' of " + h->describe());
      m->set(S, h, val);
      return;
    } else {
      tm = tm_value(S, cur, TM_NEWINDEX);
      if (tm.is_nil()) type_error(S, cur, "index", loop == 0 ? where : nullptr);
    }
    if (tm.t == T_FUN) {
      call_tm(S, tm, cur, key, &val);
      return;
    }
    cur = tm;
  }
  S.rt_error("'__newindex' chain too long; possible loop");
}

// ---- numbers -----------------------------------------------------------------------------------------------------------
bool to_number(const Value& v, Value* out) {
  if (v.is_number()) {
    *out = v;
    return true;
  }
  if (v.t == T_STR) return string_to_number(v.s()->view(), out);
  return false;
}

bool to_integer(const Value& v, std::int64_t* out) {
  Value n;
  if (!to_number(v, &n)) return false;
  if (n.t == T_INT) {
    *out = n.i;
    return true;
  }
  return float_to_integer(n.d, out);
}

// A number (not a string) as an integer: an integer, or a float with an integer value.
static bool num_to_int(const Value& v, std::int64_t* out) {
  if (v.t == T_INT) {
    *out = v.i;
    return true;
  }
  return v.t == T_FLT && float_to_integer(v.d, out);
}

static inline double as_double(const Value& v) { return v.t == T_INT ? static_cast<double>(v.i) : v.d; }

// Arithmetic on two numbers (integers or floats). BAND..SHR need integers and are not handled here.
static Value arith_numbers(State& S, int op, const Value& a, const Value& b) {
  if (a.t == T_INT && b.t == T_INT) {
    std::uint64_t x = static_cast<std::uint64_t>(a.i), y = static_cast<std::uint64_t>(b.i);
    switch (op) {
      case AR_ADD: return Value::integer(static_cast<std::int64_t>(x + y));
      case AR_SUB: return Value::integer(static_cast<std::int64_t>(x - y));
      case AR_MUL: return Value::integer(static_cast<std::int64_t>(x * y));
      case AR_MOD: return Value::integer(int_mod(S, a.i, b.i));
      case AR_IDIV: return Value::integer(int_floordiv(S, a.i, b.i));
      case AR_UNM: return Value::integer(static_cast<std::int64_t>(0u - x));
      default: break;
    }
  }
  double x = as_double(a), y = as_double(b);
  switch (op) {
    case AR_ADD: return Value::number(x + y);
    case AR_SUB: return Value::number(x - y);
    case AR_MUL: return Value::number(x * y);
    case AR_DIV: return Value::number(x / y);
    case AR_POW: return Value::number(flt_pow(x, y));
    case AR_MOD: return Value::number(flt_mod(x, y));
    case AR_IDIV: return Value::number(std::floor(x / y));
    case AR_UNM: return Value::number(-x);
    default: return Value();
  }
}

bool fold_arith(int op, const Value& a, const Value& b, Value* out) {
  if (!a.is_number() || !b.is_number()) return false;
  std::int64_t x, y;
  switch (op) {
    case AR_BAND: case AR_BOR: case AR_BXOR: case AR_SHL: case AR_SHR: case AR_BNOT:
      if (!num_to_int(a, &x) || !num_to_int(b, &y)) return false;
      switch (op) {
        case AR_BAND: *out = Value::integer(x & y); break;
        case AR_BOR: *out = Value::integer(x | y); break;
        case AR_BXOR: *out = Value::integer(x ^ y); break;
        case AR_SHL: *out = Value::integer(shift_left(x, y)); break;
        case AR_SHR: *out = Value::integer(shift_left(x, static_cast<std::int64_t>(0u - static_cast<std::uint64_t>(y)))); break;
        default: *out = Value::integer(~x); break;
      }
      return true;
    case AR_DIV: case AR_IDIV: case AR_MOD:
      if ((b.t == T_INT ? b.i == 0 : b.d == 0)) return false;  // a division by zero is left to the run time
      break;
    default: break;
  }
  if (a.t == T_INT && b.t == T_INT && op != AR_DIV && op != AR_POW) {
    std::uint64_t ux = static_cast<std::uint64_t>(a.i), uy = static_cast<std::uint64_t>(b.i);
    switch (op) {
      case AR_ADD: *out = Value::integer(static_cast<std::int64_t>(ux + uy)); return true;
      case AR_SUB: *out = Value::integer(static_cast<std::int64_t>(ux - uy)); return true;
      case AR_MUL: *out = Value::integer(static_cast<std::int64_t>(ux * uy)); return true;
      case AR_UNM: *out = Value::integer(static_cast<std::int64_t>(0u - ux)); return true;
      case AR_MOD:
        if (static_cast<std::uint64_t>(b.i) + 1u <= 1u) *out = Value::integer(0);
        else {
          std::int64_t r = a.i % b.i;
          if (r != 0 && (r ^ b.i) < 0) r += b.i;
          *out = Value::integer(r);
        }
        return true;
      case AR_IDIV:
        if (static_cast<std::uint64_t>(b.i) + 1u <= 1u) *out = Value::integer(static_cast<std::int64_t>(0u - ux));
        else {
          std::int64_t q = a.i / b.i;
          if ((a.i ^ b.i) < 0 && a.i % b.i != 0) --q;
          *out = Value::integer(q);
        }
        return true;
      default: return false;
    }
  }
  double dx = as_double(a), dy = as_double(b), r;
  switch (op) {
    case AR_ADD: r = dx + dy; break;
    case AR_SUB: r = dx - dy; break;
    case AR_MUL: r = dx * dy; break;
    case AR_DIV: r = dx / dy; break;
    case AR_POW: r = flt_pow(dx, dy); break;
    case AR_MOD: r = flt_mod(dx, dy); break;
    case AR_IDIV: r = std::floor(dx / dy); break;
    case AR_UNM: r = -dx; break;
    default: return false;
  }
  if (r != r || r == 0) return false;  // neither NaN nor 0.0 (to avoid problems with -0.0)
  *out = Value::number(r);
  return true;
}

static const char* const kOpVerb[] = {"add", "sub", "mul", "mod", "pow", "div", "idiv", "band", "bor", "bxor", "shl", "shr", "unm", "bnot"};

Value arith_slow(State& S, int op, const Value& a, const Value& b, Node* na, Node* nb) {
  ++S.stats.generic_ops;
  bool bitwise = op == AR_BAND || op == AR_BOR || op == AR_BXOR || op == AR_SHL || op == AR_SHR || op == AR_BNOT;
  if (!bitwise && a.is_number() && b.is_number()) return arith_numbers(S, op, a, b);
  if (bitwise) {
    std::int64_t x, y;
    if (num_to_int(a, &x) && num_to_int(b, &y)) {  // numbers only: Lua 5.4 does not coerce strings in bitwise operators
      switch (op) {
        case AR_BAND: return Value::integer(x & y);
        case AR_BOR: return Value::integer(x | y);
        case AR_BXOR: return Value::integer(x ^ y);
        case AR_SHL: return Value::integer(shift_left(x, y));
        case AR_SHR: return Value::integer(shift_left(x, static_cast<std::int64_t>(0u - static_cast<std::uint64_t>(y))));
        case AR_BNOT: return Value::integer(~x);
        default: break;
      }
    }
  }
  TM ev = static_cast<TM>(op == AR_BNOT ? TM_BNOT : op == AR_UNM ? TM_UNM : TM_ADD + (op - AR_ADD));
  // A metamethod of a non-string operand first (a string's own "metamethods" are the numeric coercion below).
  Value tm;
  if (a.t != T_STR) tm = tm_value(S, a, ev);
  if (tm.is_nil() && b.t != T_STR) tm = tm_value(S, b, ev);
  if (!tm.is_nil()) return call_tm(S, tm, a, b, nullptr);
  if (!bitwise && (a.t == T_STR || b.t == T_STR)) {
    Value x, y;
    if (to_number(a, &x) && to_number(b, &y)) return arith_numbers(S, op, x, y);
    S.rt_error(std::string("attempt to ") + kOpVerb[op] + " a '" + State::type_name(a) + "' with a '" + State::type_name(b) + "'");
  }
  if (bitwise) {
    if (a.is_number() && b.is_number()) {  // a float without an integer value
      std::int64_t tmp;
      bool a_ok = num_to_int(a, &tmp);
      S.rt_error("number" + var_info(a_ok ? nb : na) + " has no integer representation");
    }
    bool a_bad = !a.is_number();
    type_error(S, a_bad ? a : b, "perform bitwise operation on", a_bad ? na : nb);
  }
  const Value& bad = a.is_number() ? b : a;
  type_error(S, bad, "perform arithmetic on", a.is_number() ? nb : na);
}

// ---- comparison --------------------------------------------------------------------------------------------------------
static bool flt_to_int_mode(double f, bool ceil_mode, std::int64_t* out) {
  double fl = std::floor(f);
  if (fl != f && ceil_mode) fl += 1;
  if (fl >= -9223372036854775808.0 && fl < 9223372036854775808.0) {
    *out = static_cast<std::int64_t>(fl);
    return true;
  }
  return false;
}

static inline bool fits_double(std::int64_t i) { return -(1LL << 53) <= i && i <= (1LL << 53); }

static bool lt_num(const Value& a, const Value& b) {
  if (a.t == T_INT) {
    if (b.t == T_INT) return a.i < b.i;
    if (fits_double(a.i)) return static_cast<double>(a.i) < b.d;
    std::int64_t fi;
    if (flt_to_int_mode(b.d, true, &fi)) return a.i < fi;
    return b.d > 0;
  }
  if (b.t == T_FLT) return a.d < b.d;
  if (fits_double(b.i)) return a.d < static_cast<double>(b.i);
  std::int64_t fi;
  if (flt_to_int_mode(a.d, false, &fi)) return fi < b.i;
  return a.d < 0;
}

static bool le_num(const Value& a, const Value& b) {
  if (a.t == T_INT) {
    if (b.t == T_INT) return a.i <= b.i;
    if (fits_double(a.i)) return static_cast<double>(a.i) <= b.d;
    std::int64_t fi;
    if (flt_to_int_mode(b.d, false, &fi)) return a.i <= fi;
    return b.d > 0;
  }
  if (b.t == T_FLT) return a.d <= b.d;
  if (fits_double(b.i)) return a.d <= static_cast<double>(b.i);
  std::int64_t fi;
  if (flt_to_int_mode(a.d, true, &fi)) return fi <= b.i;
  return a.d < 0;
}

static int str_compare(const String* a, const String* b) {
  std::size_t n = a->len < b->len ? a->len : b->len;
  int c = n ? std::memcmp(a->data(), b->data(), n) : 0;
  if (c) return c;
  return a->len == b->len ? 0 : (a->len < b->len ? -1 : 1);
}

[[noreturn]] static void order_error(State& S, const Value& a, const Value& b) {
  const char* t1 = State::type_name(a);
  const char* t2 = State::type_name(b);
  if (std::strcmp(t1, t2) == 0) S.rt_error(std::string("attempt to compare two ") + t1 + " values");
  S.rt_error(std::string("attempt to compare ") + t1 + " with " + t2);
}

bool less_slow(State& S, const Value& a, const Value& b) {
  ++S.stats.generic_ops;
  if (a.is_number() && b.is_number()) return lt_num(a, b);
  if (a.t == T_STR && b.t == T_STR) return str_compare(a.s(), b.s()) < 0;
  Value tm = tm_value(S, a, TM_LT);
  if (tm.is_nil()) tm = tm_value(S, b, TM_LT);
  if (tm.is_nil()) order_error(S, a, b);
  return call_tm(S, tm, a, b, nullptr).truthy();
}

bool lesseq_slow(State& S, const Value& a, const Value& b) {
  ++S.stats.generic_ops;
  if (a.is_number() && b.is_number()) return le_num(a, b);
  if (a.t == T_STR && b.t == T_STR) return str_compare(a.s(), b.s()) <= 0;
  Value tm = tm_value(S, a, TM_LE);
  if (tm.is_nil()) tm = tm_value(S, b, TM_LE);
  if (tm.is_nil()) order_error(S, a, b);
  return call_tm(S, tm, a, b, nullptr).truthy();
}

bool equals_slow(State& S, const Value& a, const Value& b) {
  if (raw_equal(a, b)) return true;
  if (a.t != b.t) return false;
  if (a.t == T_HOST) return a.hostobj()->same_as(b.hostobj());
  if (a.t != T_TAB) return false;
  ++S.stats.generic_ops;
  Value tm = tm_value(S, a, TM_EQ);
  if (tm.is_nil()) tm = tm_value(S, b, TM_EQ);
  if (tm.is_nil()) return false;
  return call_tm(S, tm, a, b, nullptr).truthy();
}

// ---- length and concatenation -------------------------------------------------------------------------------------------
Value len_slow(State& S, const Value& v, Node* where) {
  ++S.stats.generic_ops;
  if (v.t == T_STR) return Value::integer(v.s()->len);
  Value tm = tm_value(S, v, TM_LEN);
  if (!tm.is_nil()) return call_tm(S, tm, v, v, nullptr);
  if (v.t == T_TAB) return Value::integer(v.tab()->length());
  type_error(S, v, "get length of", where);
}

static inline bool str_or_num(const Value& v) { return v.t == T_STR || v.is_number(); }

static void append_piece(std::string& out, const Value& v) {
  if (v.t == T_STR) out.append(v.s()->data(), v.s()->len);
  else out += number_to_string(v);
}

Value concat_slow(State& S, Value* vals, int n, Node** nodes) {
  ++S.stats.generic_ops;
  bool all = true;
  for (int i = 0; i < n; ++i)
    if (!str_or_num(vals[i])) {
      all = false;
      break;
    }
  if (all) {
    std::string buf;
    for (int i = 0; i < n; ++i) append_piece(buf, vals[i]);
    return S.strv(buf);
  }
  // Right to left, pairwise, as Lua does; the accumulator lives in the slot of the operand it replaces.
  for (int i = n - 2; i >= 0; --i) {
    Value a = vals[i], b = vals[i + 1];
    if (str_or_num(a) && str_or_num(b)) {
      std::string buf;
      append_piece(buf, a);
      append_piece(buf, b);
      vals[i] = S.strv(buf);
      continue;
    }
    Value tm = tm_value(S, a, TM_CONCAT);
    if (tm.is_nil()) tm = tm_value(S, b, TM_CONCAT);
    if (tm.is_nil()) {
      bool a_bad = !str_or_num(a);
      type_error(S, a_bad ? a : b, "concatenate", nodes ? (a_bad ? nodes[i] : nodes[i + 1]) : nullptr);
    }
    vals[i] = call_tm(S, tm, a, b, nullptr);
  }
  return vals[0];
}

// ---- calls ---------------------------------------------------------------------------------------------------------------
void call_closure(State& S, Closure* cl, Value* args, int n, Rets& out, bool from_native) {
  Proto* p = cl->proto;
  if (S.depth >= S.max_depth) S.rt_error("stack overflow");
  Value* base = args;
  int nslots = p->nslots, np = p->nparams;
  Value* va = nullptr;
  int nva = 0;
  Value* newtop;
  if (p->vararg) {
    nva = n > np ? n - np : 0;
    Value* vbase = base + (nslots > n ? nslots : n);
    if (vbase + nva + 128 > S.stack_end) S.rt_error("stack overflow");
    for (int k = 0; k < nva; ++k) vbase[k] = base[np + k];
    va = vbase;
    newtop = vbase + nva;
  } else {
    if (base + nslots + 128 > S.stack_end) S.rt_error("stack overflow");
    newtop = base + nslots;
  }
  for (int k = n < np ? n : np; k < nslots; ++k) base[k] = Value();
  for (int slot : p->captured_params) base[slot] = Value::object(T_CELL, new_cell(S, base[slot]));
  S.top = newtop;
  Frame fr;
  fr.S = &S;
  fr.cl = cl;
  fr.base = base;
  fr.va = va;
  fr.nva = nva;
  fr.rets = &out;
  fr.prev = S.cur;
  fr.native_below = from_native;
  fr.inlined = false;
  fr.line = p->linedefined;
  S.cur = &fr;
  ++S.depth;
  bool saved_nfn = S.nfn;
  S.nfn = false;
  safepoint(S);
  p->body->exec(fr);
  S.nfn = saved_nfn;
  S.cur = fr.prev;
  --S.depth;
}

void call_value(State& S, const Value& fn, Value* args, int n, Rets& out, Node* where) {
  if (fn.t == T_FUN) {
    if (fn.o->gctype == G_CLOSURE) {
      call_closure(S, fn.closure(), args, n, out, where == nullptr);
    } else {
      invoke_native(S, fn.native(), args, n, out, where);
    }
    return;
  }
  Value tm = tm_value(S, fn, TM_CALL);
  if (tm.is_nil()) type_error(S, fn, "call", where);
  if (args + n + 130 > S.stack_end) S.rt_error("stack overflow");
  for (int k = n; k > 0; --k) args[k] = args[k - 1];  // the called object becomes the first argument
  args[0] = fn;
  args[-1] = tm;
  S.top = args + n + 1;
  call_value(S, tm, args, n + 1, out, where);
}

Value State::index(const Value& obj, const Value& key) { return index_slow(*this, obj, key, nullptr); }
void State::setindex(const Value& obj, const Value& key, const Value& val) { setindex_slow(*this, obj, key, val, nullptr); }

void State::call(const Value& fn, const Value* args, int n, Rets& out) {
  Value* base = top;
  if (base + n + 256 > stack_end) rt_error("stack overflow");
  base[0] = fn;
  for (int k = 0; k < n; ++k) base[1 + k] = args[k];
  top = base + 1 + n;
  Frame* saved_cur = cur;
  int saved_depth = depth, saved_pcall = pcall_depth;
  Node* saved_where = call_where;
  Native* saved_native = cur_native;
  bool saved_nfn = nfn;
  try {
    call_value(*this, fn, base + 1, n, out, nullptr);
  } catch (...) {
    cur = saved_cur;
    depth = saved_depth;
    pcall_depth = saved_pcall;
    call_where = saved_where;
    cur_native = saved_native;
    nfn = saved_nfn;
    top = base;
    throw;
  }
  top = base;
}

}  // namespace nfcast
