// The type, layout, immediate and constant-initializer helpers of scripts/pathb-ptx-emit.rb (phase 2 of the port). The
// order and the text of each result follow the Ruby functions, which are the reference (diff-lower-types.sh).
#include "lower_types.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "tables.inc"

namespace {

// Ruby's nil for a missing item: a null node. Items of a non-list are missing too.
const Node *at(const Node *n, size_t i) {
  if (!n || n->kind != Node::List || i >= n->items.size()) return nullptr;
  return &n->items[i];
}

// Ruby's `x.length` on a form (a missing or non-list form has no items here; a Ruby String length is not modeled).
size_t len(const Node *n) { return n && n->kind == Node::List ? n->items.size() : 0; }

// Ruby's head_of: the head atom of a non-empty list, or null.
const std::string *head_of(const Node *x) {
  if (!x || x->kind != Node::List || x->items.empty() || x->items[0].kind != Node::Atom) return nullptr;
  return &x->items[0].text;
}

bool head_is(const Node *x, const char *h) {
  const std::string *s = head_of(x);
  return s && *s == h;
}

// Ruby's `x.to_s` for the text of an atom or a string; nil gives "". Other forms are not modeled (they give "").
std::string to_s(const Node *x) {
  if (!x) return "";
  if (x->kind == Node::Atom || x->kind == Node::Str) return x->text;
  return "";
}

bool ends_with(const std::string &s, const char *suffix) {
  size_t n = std::strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

bool is_int(const Ty &t) { return t.kind == "int"; }
bool is_float(const Ty &t) { return t.kind == "float"; }
bool is_ptr(const Ty &t) { return t.kind == "ptr"; }

i128 pow2(int bits) { return static_cast<i128>(1) << bits; }

}  // namespace

std::string i128_text(i128 v) {
  if (v == 0) return "0";
  bool neg = v < 0;
  unsigned __int128 u = neg ? static_cast<unsigned __int128>(-(v + 1)) + 1 : static_cast<unsigned __int128>(v);
  std::string out;
  while (u > 0) {
    out.insert(out.begin(), static_cast<char>('0' + static_cast<int>(u % 10)));
    u /= 10;
  }
  return neg ? "-" + out : out;
}

i128 as_int(const Node *x) {
  if (!x || x->kind != Node::Atom || x->text.empty()) throw BadIR("expected an integer");
  const std::string &text = x->text;
  size_t pos = 0;
  bool neg = false;
  if (text[0] == '-') {
    neg = true;
    pos = 1;
  }
  std::string s = text.substr(pos);
  bool hex = s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X');
  if (hex) s = s.substr(2);
  if (s.empty()) throw BadIR("expected an integer, got " + text);
  int base = hex ? 16 : 10;
  i128 v = 0;
  for (char c : s) {
    int d;
    if (c >= '0' && c <= '9') {
      d = c - '0';
    } else if (hex && c >= 'a' && c <= 'f') {
      d = c - 'a' + 10;
    } else if (hex && c >= 'A' && c <= 'F') {
      d = c - 'A' + 10;
    } else {
      throw BadIR("expected an integer, got " + text);
    }
    v = v * base + d;
    // Values beyond 120 bits are not modeled (the IR's constants are at most 64 bits).
    if (v > (static_cast<i128>(1) << 120)) throw Refused("integer constant " + text + " is too large");
  }
  return neg ? -v : v;
}

i128 signed64(i128 n) {
  const i128 mask = (static_cast<i128>(1) << 64) - 1;
  n &= mask;
  return n >= (static_cast<i128>(1) << 63) ? n - (static_cast<i128>(1) << 64) : n;
}

Ty parse_type(const Node *x) {
  if (x && x->kind == Node::Atom) {
    if (x->text == "void") return Ty{"void", -1, false, false};
    for (size_t i = 0; i < SCALARS_N; i++) {
      const ScalarType &s = SCALARS[i];
      if (x->text != s.name) continue;
      if (s.arity == 2) return Ty{"float", s.size, false, false};
      return Ty{"int", s.size, s.is_signed, s.is_bool};
    }
    throw Refused("type " + x->text);
  }
  if (!x || x->kind != Node::List || x->items.empty()) throw BadIR("bad type form");
  if (head_is(x, "ptr")) return Ty{"ptr", -1, false, false};   // a pointer is 8 bytes whatever it points to
  if (head_is(x, "const") || head_is(x, "volatile")) return parse_type(at(x, 1));
  throw Refused("type form");
}

int type_size(const Ty &t) {
  if (is_ptr(t)) return 8;
  if (is_int(t) || is_float(t)) return t.size;
  throw Refused("size of " + t.kind);
}

std::string reg_class(const Ty &t) {
  if (is_int(t) && t.is_bool) return "p";
  if (is_ptr(t) || (is_int(t) && t.size == 8)) return "rd";
  if (is_int(t) && (t.size == 1 || t.size == 2 || t.size == 4)) return "r";
  if (is_float(t) && t.size == 4) return "f";
  if (is_float(t) && t.size == 8) return "fd";
  throw Refused("value of type " + t.kind);
}

bool asm_operand_ok(const Ty &t) {
  if (is_ptr(t)) return true;
  if (is_int(t) && !t.is_bool) return t.size == 2 || t.size == 4 || t.size == 8;
  if (is_float(t)) return t.size == 4 || t.size == 8;
  return false;
}

std::string asm_class(const Ty &t) { return is_int(t) && t.size == 2 ? "h" : reg_class(t); }

std::string ptx_type(const Ty &t) {
  if (is_ptr(t)) return "u64";
  if (is_float(t) && (t.size == 4 || t.size == 8)) return "f" + std::to_string(t.size * 8);
  if (is_int(t) && t.is_bool) throw Refused("bool in arithmetic or memory");
  if (is_int(t) && (t.size == 1 || t.size == 2)) return t.is_signed ? "s32" : "u32";
  if (!(is_int(t) && (t.size == 4 || t.size == 8))) throw Refused("integer of " + std::to_string(t.size) + " bytes");
  return std::string(t.is_signed ? "s" : "u") + std::to_string(t.size * 8);
}

std::string mem_type(const Ty &t) {
  if (is_int(t) && t.size == 1 && !t.is_bool) return t.is_signed ? "s8" : "u8";
  if (is_int(t) && t.size == 2 && !t.is_bool) return t.is_signed ? "s16" : "u16";
  return ptx_type(t);
}

std::string bits_type(const Ty &t) {
  bool ok = (is_int(t) && !t.is_bool && (t.size == 1 || t.size == 2 || t.size == 4 || t.size == 8)) || is_ptr(t);
  if (!ok) throw Refused("bitwise operation on " + t.kind);
  int bits = (is_int(t) && (t.size == 1 || t.size == 2)) ? 32 : type_size(t) * 8;
  return "b" + std::to_string(bits);
}

std::string ptx_sym(const std::string &name) {
  std::string out;
  for (unsigned char c : name) {
    if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_') {
      out += static_cast<char>(c);
    } else {
      char hex[4];
      std::snprintf(hex, sizeof hex, "%02x", static_cast<unsigned>(c));
      out += "_x";
      out += hex;
    }
  }
  return out;
}

std::string string_const_sym(const std::string &name) { return ptx_sym(STRING_PREFIX + name); }

std::string float_lit(const std::string &text, const Ty &t) {
  if (text == "+Infinity" || text == "Infinity") return t.size == 4 ? "0f7F800000" : "0d7FF0000000000000";
  if (text == "-Infinity") return t.size == 4 ? "0fFF800000" : "0dFFF0000000000000";
  // a decimal with a point and an optional exponent (what the IR prints)
  size_t points = 0, digits = 0;
  bool ok = true;
  for (char c : text) {
    if (c == '.') points++;
    if (c >= '0' && c <= '9') digits++;
    if (!std::strchr("0123456789.eE+-", c)) ok = false;
  }
  ok = ok && points == 1 && digits > 0;
  if (!ok) throw Refused("float constant " + text);
  return text;
}

std::string bool_const_setp(const std::string &t, const std::string &v) {
  if (v == "1" || v == "0x1") return "setp.eq.u32 " + t + ", 0, 0;";
  if (v == "0" || v == "0x0") return "setp.ne.u32 " + t + ", 0, 0;";
  throw Refused("bool constant " + v);
}

// Ruby's String#to_f for the forms the IR prints: optional sign, digits with underscores between them, an optional
// fraction, an optional exponent; anything else after the number is ignored; no number gives 0.0.
static double ruby_to_f(const std::string &s) {
  size_t i = 0;
  while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f' || s[i] == '\v')) i++;
  std::string num;
  if (i < s.size() && (s[i] == '+' || s[i] == '-')) num += s[i++];
  auto digits = [&](std::string &out) {
    bool any = false;
    while (i < s.size()) {
      if (s[i] >= '0' && s[i] <= '9') {
        out += s[i++];
        any = true;
      } else if (s[i] == '_' && any && i + 1 < s.size() && s[i + 1] >= '0' && s[i + 1] <= '9') {
        i++;
      } else {
        break;
      }
    }
    return any;
  };
  bool int_part = digits(num);
  bool frac_part = false;
  if (i + 1 < s.size() && s[i] == '.' && s[i + 1] >= '0' && s[i + 1] <= '9') {
    num += s[i++];
    frac_part = digits(num);
  }
  if (!int_part && !frac_part) return 0.0;
  if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
    size_t save = i;
    std::string exp = "e";
    i++;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) exp += s[i++];
    if (digits(exp) && exp.size() > 1) {
      num += exp;
    } else {
      i = save;
    }
  }
  return std::strtod(num.c_str(), nullptr);
}

std::optional<uint64_t> float32_bits(const std::string &text) {
  double x = ruby_to_f(text);
  if (std::isnan(x) || std::isinf(x)) return std::nullopt;
  uint64_t sign = (x < 0 || (x == 0 && !text.empty() && text[0] == '-')) ? 0x80000000ULL : 0;
  x = std::fabs(x);
  if (x == 0) return sign;
  int e = 0;
  while (x >= 2.0) {
    x = x / 2.0;
    e += 1;
    if (e > 200) return std::nullopt;
  }
  while (x < 1.0) {
    x = x * 2.0;
    e -= 1;
    if (e < -200) return std::nullopt;
  }
  double frac = (x - 1.0) * 8388608.0;
  if (frac != std::floor(frac)) return std::nullopt;
  int exp = e + 127;
  if (exp < 1 || exp > 254) return std::nullopt;
  return sign | (static_cast<uint64_t>(exp) << 23) | static_cast<uint64_t>(frac);
}

std::optional<std::vector<std::string>> scalar_const_init(const Node *init, const std::string &name, i128 size) {
  if (!init || len(init) != 2 || !head_is(at(init, 1), "scalar")) return std::nullopt;
  const Node *s = at(init, 1);
  if (len(s) != 4 || !head_is(at(s, 3), "const")) return std::nullopt;
  Ty t = parse_type(at(s, 2));
  std::string text = to_s(at(at(s, 3), 2));
  if (is_float(t)) {
    if (!(t.size == 4 || t.size == 8)) throw Refused("global " + name + ": a float constant is not lowered");
    return std::vector<std::string>{ptx_type(t), float_lit(text, t)};
  }
  if (!is_int(t)) throw Refused("global " + name + ": constant is not lowered");
  if (static_cast<i128>(t.size) != size) throw Refused("global " + name + ": initializer size differs from the global");
  if (t.is_bool) return std::vector<std::string>{"u8", ends_with(text, "1") ? "1" : "0"};
  if (!(t.size == 4 || t.size == 8)) throw Refused("global " + name + ": integer constant is not lowered");
  return std::vector<std::string>{ptx_type(t), i128_text(as_int(at(at(s, 3), 2)))};
}

std::optional<ArrInit> scalar_const_array_init(const Node *ty, const Node *init, const std::string &name, i128 size) {
  if (!init || !head_is(ty, "const") || len(ty) != 2 || !head_is(at(ty, 1), "array")) return std::nullopt;
  i128 count = as_int(at(at(ty, 1), 1));
  if (!(count > 0) || size % count != 0) return std::nullopt;
  i128 esize = size / count;
  size_t n = len(init);
  if (static_cast<i128>(n - 1) != count) return std::nullopt;
  for (size_t i = 1; i < n; i++)
    if (!head_is(at(init, i), "scalar")) return std::nullopt;
  std::string ptype;
  bool have = false;
  std::string body = "{";
  for (size_t i = 1; i < n; i++) {
    const Node *e = at(init, i);
    if (len(e) != 4 || !head_is(at(e, 3), "const")) return std::nullopt;
    Ty t = parse_type(at(e, 2));
    std::string text = to_s(at(at(e, 3), 2));
    std::string ctype, cval;
    if (is_float(t)) {
      if (!(t.size == 4 || t.size == 8)) throw Refused("global " + name + ": a float constant is not lowered");
      ctype = "f" + std::to_string(t.size * 8);
      cval = float_lit(text, t);
    } else {
      if (!is_int(t)) throw Refused("global " + name + ": element is not lowered");
      if (static_cast<i128>(t.size) != esize) throw Refused("global " + name + ": element size differs from the array's");
      if (t.is_bool) {
        ctype = "u8";
        cval = ends_with(text, "1") ? "1" : "0";
      } else {
        ctype = std::string(t.is_signed ? "s" : "u") + std::to_string(t.size * 8);
        cval = i128_text(as_int(at(at(e, 3), 2)));
      }
    }
    if (have && ptype != ctype) throw Refused("global " + name + ": mixed element types");
    ptype = ctype;
    have = true;
    if (i > 1) body += ",";
    body += cval;
  }
  body += "}";
  return ArrInit{ptype, body, count};
}

std::optional<ByteInit> byte_const_init(const Node *init, const std::string &name, i128 size) {
  if (!init || len(init) < 2 || !(size > 0)) return std::nullopt;
  size_t n = static_cast<size_t>(size);
  std::vector<unsigned> bytes(n, 0);
  std::vector<bool> covered(n, false);
  for (size_t i = 1; i < len(init); i++) {
    const Node *f = at(init, i);
    const std::string *h = head_of(f);
    if (h && *h == "scalar") {
      if (len(f) != 4 || !head_is(at(f, 3), "const")) return std::nullopt;
      i128 off = as_int(at(f, 1));
      Ty t = parse_type(at(f, 2));
      if (!(is_int(t) || is_float(t))) return std::nullopt;
      i128 cnt = t.size;
      if (!(cnt > 0) || !(off + cnt <= size)) return std::nullopt;
      // A negative offset is not modeled: Ruby indexes from the end there (the IR never writes one).
      if (off < 0) return std::nullopt;
      i128 v;
      if (is_float(t)) {
        if (cnt != 4) throw Refused("global " + name + ": a float constant is not lowered");
        auto bits = float32_bits(to_s(at(at(f, 3), 2)));
        if (!bits) throw Refused("global " + name + ": float constant is not exactly a 32-bit float");
        v = static_cast<i128>(*bits);
      } else {
        v = t.is_bool ? (ends_with(to_s(at(at(f, 3), 2)), "1") ? 1 : 0) : as_int(at(at(f, 3), 2));
      }
      for (i128 k = 0; k < cnt; k++) {
        size_t idx = static_cast<size_t>(off + k);
        if (covered[idx]) throw Refused("global " + name + ": initializer overlaps");
        bytes[idx] = static_cast<unsigned>((static_cast<unsigned __int128>(v) >> (8 * k)) & 0xff);
        covered[idx] = true;
      }
    } else if (h && *h == "zero") {
      i128 off = as_int(at(f, 1));
      i128 cnt = as_int(at(f, 2));
      if (!(off >= 0 && cnt >= 0 && off + cnt <= size)) return std::nullopt;
      for (i128 k = 0; k < cnt; k++) {
        size_t idx = static_cast<size_t>(off + k);
        if (covered[idx]) throw Refused("global " + name + ": initializer overlaps");
        covered[idx] = true;
      }
    } else {
      return std::nullopt;
    }
  }
  for (bool c : covered)
    if (!c) return std::nullopt;
  bool all_zero = true;
  for (unsigned b : bytes)
    if (b != 0) all_zero = false;
  if (all_zero) return std::nullopt;
  std::string body = "{";
  for (size_t i = 0; i < n; i++) {
    if (i) body += ",";
    body += std::to_string(bytes[i]);
  }
  body += "}";
  return ByteInit{".b8", body, size};
}

bool all_zero_init(const Node *init, i128 size) {
  if (!init || len(init) < 2 || !(size > 0)) return false;
  size_t n = static_cast<size_t>(size);
  std::vector<bool> covered(n, false);
  for (size_t i = 1; i < len(init); i++) {
    const Node *f = at(init, i);
    const std::string *h = head_of(f);
    if (h && *h == "scalar") {
      if (len(f) != 4 || !head_is(at(f, 3), "const")) return false;
      Ty t = parse_type(at(f, 2));
      if (!(is_int(t) || is_float(t))) return false;
      i128 off = as_int(at(f, 1));
      i128 cnt = t.size;
      if (!(cnt > 0) || !(off + cnt <= size)) return false;
      if (off < 0) return false;   // not modeled, see byte_const_init
      // the text is zero when it has only the characters of a zero literal (0, ., -, +, e, E)
      for (char c : to_s(at(at(f, 3), 2)))
        if (c != '0' && c != '.' && c != '-' && c != '+' && c != 'e' && c != 'E') return false;
      for (i128 k = 0; k < cnt; k++) covered[static_cast<size_t>(off + k)] = true;
    } else if (h && *h == "zero") {
      i128 off = as_int(at(f, 1));
      i128 cnt = as_int(at(f, 2));
      if (!(off >= 0 && cnt >= 0 && off + cnt <= size)) return false;
      for (i128 k = 0; k < cnt; k++) covered[static_cast<size_t>(off + k)] = true;
    } else {
      return false;
    }
  }
  for (bool c : covered)
    if (!c) return false;
  return true;
}

std::string imm(const Ty &t, i128 v) {
  if (is_ptr(t)) return "0";
  if (is_int(t) && t.is_bool) throw Refused("bool constant");
  if (!is_int(t)) throw Refused("constant of " + t.kind);
  int bits = t.size * 8;
  v &= pow2(bits) - 1;
  if (t.is_signed && v >= pow2(bits - 1)) v -= pow2(bits);
  return i128_text(v);
}
