// qbe-prep: rewrite EDG's preprocessed C so cproc accepts it, and emit the assembly the C cannot express.
// The C++ port of scripts/qbe-prep.rb, with the same output, stderr and exit status (tests/mruby/qbe-prep.sh compares
// it with the oracle tests/mruby/oracle/qbe-prep.rb). The forms it rewrites are listed in the oracle's header; the
// comments here say how, not why. The mruby script took 22 s on the 48 MB of C that ggml-cuda's binbcast.cu gives.
// Usage: qbe-prep [--c-input] [--macho] [--arm64] [--dce] PREPROCESSED_C REWRITTEN_C ASM_TAIL
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

using std::string;
using std::vector;

[[noreturn]] void die(const string &msg) {
  string m = msg + "\n";
  fwrite(m.data(), 1, m.size(), stderr);
  exit(1);
}

// ---- character classes (by byte value) --------------------------------------------------------------------------

bool space_b(int b) { return (b >= 9 && b <= 13) || (b >= 28 && b <= 32); }  // Python's \s
bool word_b(int b) { return (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 128; }
bool idstart_b(int b) { return (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 36; }
bool idcont_b(int b) { return word_b(b) || b == 36; }
bool digit_b(int b) { return b >= 48 && b <= 57; }

// The byte at k, or -1 past the end (getbyte's nil).
int at(const string &s, long k) { return k >= 0 && k < (long)s.size() ? (unsigned char)s[k] : -1; }

bool all_digits(const string &s, size_t from, size_t to) {
  if (from >= to) return false;
  for (size_t k = from; k < to; k++)
    if (!digit_b((unsigned char)s[k])) return false;
  return true;
}
bool all_digits(const string &s, size_t from = 0) { return all_digits(s, from, s.size()); }

bool starts_with(const string &s, const string &p) { return s.compare(0, p.size(), p) == 0; }
bool ends_with(const string &s, const string &p) {
  return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}

// Python's str.strip() on the bytes of an ASCII string.
string py_strip(const string &s) {
  size_t a = 0, b = s.size();
  while (a < b && space_b((unsigned char)s[a])) a++;
  while (b > a && space_b((unsigned char)s[b - 1])) b--;
  return s.substr(a, b - a);
}

// Ruby's String#split("\n"): the trailing empty fields are dropped.
vector<string> split_lines(const string &s) {
  vector<string> out;
  size_t pos = 0;
  while (true) {
    size_t nl = s.find('\n', pos);
    if (nl == string::npos) {
      out.push_back(s.substr(pos));
      break;
    }
    out.push_back(s.substr(pos, nl - pos));
    pos = nl + 1;
  }
  while (!out.empty() && out.back().empty()) out.pop_back();
  return out;
}

string join(const vector<string> &v, const string &sep) {
  string out;
  for (size_t i = 0; i < v.size(); i++) {
    if (i) out += sep;
    out += v[i];
  }
  return out;
}

// A Ruby Hash of strings: insertion order, and assigning an existing key keeps its place.
struct OrderedMap {
  vector<std::pair<string, string>> items;
  std::unordered_map<string, size_t> index;
  void set(const string &k, const string &v) {
    auto it = index.find(k);
    if (it != index.end()) {
      items[it->second].second = v;
    } else {
      index[k] = items.size();
      items.emplace_back(k, v);
    }
  }
  bool has(const string &k) const { return index.count(k) != 0; }
};

// ---- exact integers for the float literals (Ruby's Integer; the Python original used fractions.Fraction) ---------

struct Big {
  vector<uint32_t> w;  // little endian, no leading zero words
  void trim() {
    while (!w.empty() && w.back() == 0) w.pop_back();
  }
  bool zero() const { return w.empty(); }
  void mul_add(uint32_t m, uint32_t a) {
    uint64_t carry = a;
    for (auto &x : w) {
      uint64_t v = (uint64_t)x * m + carry;
      x = (uint32_t)v;
      carry = v >> 32;
    }
    if (carry) w.push_back((uint32_t)carry);
  }
  static Big from_decimal(const string &s) {
    Big b;
    for (char c : s) b.mul_add(10, c - '0');
    b.trim();
    return b;
  }
  static Big pow10(long e) {
    Big b;
    b.w.push_back(1);
    for (long i = 0; i < e; i++) b.mul_add(10, 0);
    return b;
  }
  static Big pow2(long e) {
    Big b;
    b.w.assign(e / 32 + 1, 0);
    b.w[e / 32] = 1u << (e % 32);
    return b;
  }
  long bit_length() const {
    if (w.empty()) return 0;
    long n = (long)(w.size() - 1) * 32;
    uint32_t t = w.back();
    while (t) {
      n++;
      t >>= 1;
    }
    return n;
  }
  bool bit(long i) const { return i / 32 < (long)w.size() && ((w[i / 32] >> (i % 32)) & 1); }
  Big shl(long s) const {
    Big r;
    if (w.empty()) return r;
    long words = s / 32, bits = s % 32;
    r.w.assign(w.size() + words + 1, 0);
    for (size_t i = 0; i < w.size(); i++) {
      uint64_t v = (uint64_t)w[i] << bits;
      r.w[i + words] |= (uint32_t)v;
      r.w[i + words + 1] |= (uint32_t)(v >> 32);
    }
    r.trim();
    return r;
  }
  static int cmp(const Big &a, const Big &b) {
    if (a.w.size() != b.w.size()) return a.w.size() < b.w.size() ? -1 : 1;
    for (size_t i = a.w.size(); i-- > 0;)
      if (a.w[i] != b.w[i]) return a.w[i] < b.w[i] ? -1 : 1;
    return 0;
  }
  void sub(const Big &b) {  // *this -= b, *this >= b
    int64_t borrow = 0;
    for (size_t i = 0; i < w.size(); i++) {
      int64_t v = (int64_t)w[i] - (i < b.w.size() ? b.w[i] : 0) - borrow;
      borrow = v < 0;
      w[i] = (uint32_t)(v + (borrow << 32));
    }
    trim();
  }
  static Big mul(const Big &a, const Big &b) {
    Big r;
    if (a.zero() || b.zero()) return r;
    r.w.assign(a.w.size() + b.w.size(), 0);
    for (size_t i = 0; i < a.w.size(); i++) {
      uint64_t carry = 0;
      for (size_t j = 0; j < b.w.size(); j++) {
        uint64_t v = (uint64_t)a.w[i] * b.w[j] + r.w[i + j] + carry;
        r.w[i + j] = (uint32_t)v;
        carry = v >> 32;
      }
      r.w[i + b.w.size()] += (uint32_t)carry;
    }
    r.trim();
    return r;
  }
  // q = n / d, r = n % d (binary long division; the quotients here have about 113 bits)
  static void divmod(const Big &n, const Big &d, Big &q, Big &r) {
    q = Big();
    r = Big();
    for (long i = n.bit_length() - 1; i >= 0; i--) {
      r = r.shl(1);
      if (n.bit(i)) {
        if (r.w.empty()) r.w.push_back(0);
        r.w[0] |= 1;
      }
      if (cmp(r, d) >= 0) {
        r.sub(d);
        if ((long)q.w.size() <= i / 32) q.w.resize(i / 32 + 1, 0);
        q.w[i / 32] |= 1u << (i % 32);
      }
    }
    q.trim();
  }
  unsigned __int128 low128() const {
    unsigned __int128 v = 0;
    for (size_t i = std::min<size_t>(w.size(), 4); i-- > 0;) v = (v << 32) | w[i];
    return v;
  }
};

const vector<string> FLOAT_SUFFIXES = {"f16", "f32", "f64", "f128", "f32x", "f64x", "f128x"};

// FLOAT_LIT.fullmatch: (\.?\d[\d.]*(?:[eE][+-]?\d+)?)(f16|f32|f64|f128|...) -> body and suffix.
bool float_lit(const string &text, string &body, string &suffix) {
  const string *suf = nullptr;
  for (const string &s : FLOAT_SUFFIXES)
    if (ends_with(text, s)) {
      suf = &s;
      break;
    }
  if (!suf) return false;
  size_t n = text.size() - suf->size(), k = 0;
  if (at(text, 0) == 46) k++;
  if (!(k < n && digit_b(at(text, k)))) return false;
  k++;
  while (k < n) {
    int b = at(text, k);
    if (!(digit_b(b) || b == 46)) break;
    k++;
  }
  if (k < n) {
    int b = at(text, k);
    if (!(b == 101 || b == 69)) return false;
    k++;
    b = at(text, k);
    if (b == 43 || b == 45) k++;
    if (!(k < n && all_digits(text, k, n))) return false;
  }
  body = text.substr(0, n);
  suffix = *suf;
  return true;
}

// Decimal literal text -> (integer, exponent10); value = integer * 10**exponent.
void parse_decimal(const string &lit, Big &value, long &exp10) {
  size_t n = lit.size(), k = 0;
  while (k < n && digit_b(at(lit, k))) k++;
  string digits = lit.substr(0, k), frac;
  if (k < n && at(lit, k) == 46) {
    k++;
    size_t f0 = k;
    while (k < n && digit_b(at(lit, k))) k++;
    frac = lit.substr(f0, k - f0);
  }
  long exp = 0;
  if (k < n && (at(lit, k) == 101 || at(lit, k) == 69)) {
    k++;
    long sign = 1;
    if (k < n && (at(lit, k) == 43 || at(lit, k) == 45)) {
      if (at(lit, k) == 45) sign = -1;
      k++;
    }
    size_t e0 = k;
    while (k < n && digit_b(at(lit, k))) k++;
    if (k == e0) die("qbe-prep: invalid literal " + lit);
    exp = sign * strtol(lit.substr(e0, k - e0).c_str(), nullptr, 10);
  }
  if (k != n || (digits.empty() && frac.empty())) die("qbe-prep: invalid literal " + lit);
  value = Big::from_decimal(digits + frac);
  exp10 = exp - (long)frac.size();
}

// 2**e > num/den
bool pow2_gt(long e, const Big &num, const Big &den) {
  return e >= 0 ? Big::cmp(den.shl(e), num) > 0 : Big::cmp(den, num.shl(-e)) > 0;
}

string hex_pad(uint64_t v, size_t width) {
  char buf[32];
  snprintf(buf, sizeof buf, "%llx", (unsigned long long)v);
  string s = buf;
  if (s.size() < width) s = string(width - s.size(), '0') + s;
  return s;
}

// Bit pattern of the decimal literal LIT in an IEEE binary format (round to nearest even), computed exactly.
unsigned __int128 ieee_bits(const string &lit, long mant, long ebits) {
  Big digits;
  long exp;
  parse_decimal(lit, digits, exp);
  long bias = (1L << (ebits - 1)) - 1;
  if (digits.zero()) return 0;
  Big num = exp >= 0 ? Big::mul(digits, Big::pow10(exp)) : digits;
  Big den = exp >= 0 ? Big::pow10(0) : Big::pow10(-exp);
  long e = num.bit_length() - den.bit_length();
  if (pow2_gt(e, num, den)) e--;
  if (!pow2_gt(e + 1, num, den)) e++;
  long sh = mant - e;
  Big n2 = sh >= 0 ? num.shl(sh) : num;
  Big d2 = sh >= 0 ? den : den.shl(-sh);
  Big m, r;
  Big::divmod(n2, d2, m, r);
  Big twice = r.shl(1);
  int c = Big::cmp(twice, d2);
  if (c > 0 || (c == 0 && m.bit(0))) m.mul_add(1, 1);
  if (Big::cmp(m, Big::pow2(mant + 1)) == 0) {
    m = Big::pow2(mant);
    e++;
  }
  if (e < 1 - bias || e + bias >= (1L << ebits) - 1)
    die("qbe-prep: literal " + lit + " is out of range for this format (subnormal or overflow)");
  unsigned __int128 mv = m.low128();
  unsigned __int128 one = 1;
  return ((unsigned __int128)(e + bias) << mant) | (mv - (one << mant));
}

// The value of a binary16 bit pattern as a C hexadecimal floating constant (exact).
string half_literal(unsigned bits) {
  unsigned e = (bits >> 10) & 31, m = bits & 1023, x = m << 2;
  const char *digits = "0123456789abcdef";
  string frac = {digits[x >> 8], digits[(x >> 4) & 15], digits[x & 15]};
  while (ends_with(frac, "0")) frac.pop_back();
  long ex = e == 0 ? -14 : (long)e - 15;
  return string(bits >> 15 == 1 ? "-" : "") + "0x" + (e == 0 ? "0" : "1") + (frac.empty() ? "" : "." + frac) + "p" +
         (ex < 0 ? "-" : "+") + std::to_string(ex < 0 ? -ex : ex);
}

// ---- tokens -----------------------------------------------------------------------------------------------------

const int ID_CODE = 256, NUM_CODE = 257, STR_CODE = 258, CHR_CODE = 259;

// 24 bytes a token: a 34 MB preprocessed file has about 9 million of them.
struct Tok {
  int32_t code;    // punctuation: its byte; else one of the codes above
  int32_t depth;   // braces open before the token
  int32_t pdepth;  // parentheses open before the token
  uint32_t start;  // byte offset (read_text refuses a file of 4 GB or more)
  uint32_t len;
  int32_t sym;     // identifier: index of its name
};

struct Toks {
  const string &src;
  vector<Tok> t;
  vector<string> names;
  bool balanced = false;
  explicit Toks(const string &s) : src(s) {}
  long size() const { return (long)t.size(); }
  // Code of token i, or -1 when i is out of range.
  int code(long i) const { return i >= 0 && i < size() ? t[i].code : -1; }
  size_t start(long i) const { return t[idx(i)].start; }
  size_t stop(long i) const { return t[idx(i)].start + t[idx(i)].len; }
  int sym(long i) const { return t[idx(i)].sym; }
  int depth(long i) const { return t[idx(i)].depth; }
  int pdepth(long i) const { return t[idx(i)].pdepth; }
  // Ruby's Array index: a negative index counts from the end.
  long idx(long i) const { return i < 0 ? i + size() : i; }
  string text(long i) const {
    long j = idx(i);
    int c = t[j].code;
    if (c == ID_CODE) return names[t[j].sym];
    if (c < 256) return string(1, (char)c);
    return src.substr(t[j].start, t[j].len);
  }
  bool punct(long i, char s) const {
    int c = code(i);
    return c >= 0 && c < 256 && c == (unsigned char)s;
  }
  bool id(long i, const char *s) const { return code(i) == ID_CODE && names[t[i].sym] == s; }
  bool text_is(long i, const char *s) const { return code(i) >= 0 && text(i) == s; }
  long name_index(const char *s) const {
    for (size_t k = 0; k < names.size(); k++)
      if (names[k] == s) return (long)k;
    return -1;
  }
};

// Scan a quoted literal whose opening quote is at q: the index just past the closing quote, or -1.
long scan_quoted(const string &src, size_t q, size_t n) {
  int quote = (unsigned char)src[q];
  size_t k = q + 1;
  while (k < n) {
    int b = (unsigned char)src[k];
    if (b == quote) return (long)k + 1;
    if (b == 92) {
      if (k + 1 >= n) return -1;
      k += 2;
    } else if (b == 10) {
      return -1;
    } else {
      k++;
    }
  }
  return -1;
}

// Whitespace, comments and preprocessor lines are dropped; then string, char literal, number, identifier, any byte.
void tokenize(Toks &tk) {
  const string &src = tk.src;
  size_t n = src.size(), i = 0;
  int braces = 0, parens = 0, min_braces = 0;
  std::unordered_map<string, int> syms;
  auto push = [&](int code, size_t start, size_t len, int sym) {
    tk.t.push_back(Tok{code, braces, parens, (uint32_t)start, (uint32_t)len, sym});
  };
  while (i < n) {
    int c = (unsigned char)src[i];
    if (space_b(c)) {
      i++;
      while (i < n && space_b((unsigned char)src[i])) i++;
      continue;
    }
    int c2 = at(src, i + 1);
    if (c == 35 && (i == 0 || src[i - 1] == '\n')) {
      size_t j = src.find('\n', i);
      i = j == string::npos ? n : j;
      continue;
    }
    if (c == 47 && c2 == 47) {
      size_t j = src.find('\n', i);
      i = j == string::npos ? n : j;
      continue;
    }
    if (c == 47 && c2 == 42) {
      size_t j = src.find("*/", i + 2);
      if (j != string::npos) {
        i = j + 2;
        continue;
      }
    }
    long q = -1;
    if (c == 34 || c == 39) {
      q = (long)i;
    } else if (c == 117 && c2 == 56 && at(src, i + 2) == 34) {
      q = (long)i + 2;
    } else if ((c == 117 || c == 76 || c == 85) && (c2 == 34 || c2 == 39)) {
      q = (long)i + 1;
    }
    if (q >= 0) {
      long stop = scan_quoted(src, q, n);
      if (stop >= 0) {
        push(src[q] == '"' ? STR_CODE : CHR_CODE, i, stop - i, 0);
        i = stop;
        continue;
      }
    }
    if (digit_b(c) || (c == 46 && digit_b(c2))) {
      size_t j = c == 46 ? i + 2 : i + 1;
      while (j < n) {
        int b = (unsigned char)src[j];
        int b1 = at(src, j + 1);
        if ((b == 101 || b == 69 || b == 112 || b == 80) && (b1 == 43 || b1 == 45)) {
          j += 2;
        } else if (word_b(b) || b == 46) {
          j++;
        } else {
          break;
        }
      }
      push(NUM_CODE, i, j - i, 0);
      i = j;
      continue;
    }
    if (idstart_b(c)) {
      size_t j = i + 1;
      while (j < n && idcont_b((unsigned char)src[j])) j++;
      string name = src.substr(i, j - i);
      auto it = syms.find(name);
      int sym;
      if (it == syms.end()) {
        sym = (int)tk.names.size();
        tk.names.push_back(name);
        syms.emplace(name, sym);
      } else {
        sym = it->second;
      }
      push(ID_CODE, i, j - i, sym);
      i = j;
      continue;
    }
    push(c, i, 1, 0);
    if (c == 123) {
      braces++;
    } else if (c == 125) {
      braces--;
      if (braces < min_braces) min_braces = braces;
    } else if (c == 40) {
      parens++;
    } else if (c == 41) {
      parens--;
    }
    i++;
  }
  tk.balanced = braces == 0 && min_braces == 0;
}

// Index of the token matching the close token at i, searching backwards; -1 if none.
long match_back(const Toks &tk, long i, char open, char close) {
  long level = 0;
  for (long j = i; j >= 0; j--) {
    if (tk.punct(j, close)) {
      level++;
    } else if (tk.punct(j, open)) {
      level--;
      if (level == 0) return j;
    }
  }
  return -1;
}

long match_fwd(const Toks &tk, long i, char open, char close) {
  long level = 0;
  for (long j = i; j < tk.size(); j++) {
    if (tk.punct(j, open)) {
      level++;
    } else if (tk.punct(j, close)) {
      level--;
      if (level == 0) return j;
    }
  }
  return -1;
}

// The statement starts at token i: nothing, or `;`, `{` or `}` before it.
bool stmt_ctx(const Toks &tk, long i) {
  int c = tk.code(i - 1);
  return c == -1 || c == 59 || c == 123 || c == 125;
}

// Python's int(text, 0): decimal, 0x, 0o, 0b, underscores between digits; anything else is a ValueError.
long long py_int0(const string &text) {
  string s = text;
  int base = 10;
  if (s.size() > 2 && s[0] == '0') {
    switch (s[1]) {
      case 'x': case 'X': base = 16; break;
      case 'o': case 'O': base = 8; break;
      case 'b': case 'B': base = 2; break;
    }
    if (base != 10) s = s.substr(2);
  }
  bool ok = !s.empty() && s[0] != '_' && s.back() != '_' && s.find("__") == string::npos;
  string digits;
  for (char ch : s)
    if (ch != '_') digits += ch;
  if (ok) {
    for (char ch : digits) {
      int b = (unsigned char)ch, v = 99;
      if (b >= 48 && b <= 57) v = b - 48;
      else if (b >= 97 && b <= 102) v = b - 87;
      else if (b >= 65 && b <= 70) v = b - 55;
      if (v >= base) {
        ok = false;
        break;
      }
    }
  }
  if (ok && base == 10 && digits.size() > 1 && digits[0] == '0' && digits.find_first_not_of('0') != string::npos) ok = false;
  if (!ok) die("ValueError: invalid literal for int() with base 0: '" + text + "'");
  return strtoll(digits.c_str(), nullptr, base);
}

// The struct body toks[o+1...close] starts with a member that is not a bit-field.
bool first_member_plain(const Toks &tk, long o, long close) {
  if (o + 1 >= close) return false;
  long depth = 0;
  for (long k = o + 1; k < close; k++) {
    int c = tk.code(k);
    if (c >= 0 && c < 256) {
      switch (c) {
        case '(': case '[': case '{': depth++; break;
        case ')': case ']': case '}': depth--; break;
        case ':': if (depth == 0) return false; break;
        case ';': if (depth == 0) return true; break;
      }
    }
  }
  return false;
}

// If toks[i] starts __attribute__((__aligned__(N))) (or a trailing comma inside): end index (exclusive) and N.
bool aligned_group(const Toks &tk, long i, long &end, long long &value) {
  if (i + 8 >= tk.size() || !tk.id(i, "__attribute__")) return false;
  if (!(tk.punct(i + 1, '(') && tk.punct(i + 2, '(') && tk.code(i + 3) == ID_CODE &&
        (tk.text(i + 3) == "__aligned__" || tk.text(i + 3) == "aligned") && tk.punct(i + 4, '(') &&
        tk.code(i + 5) == NUM_CODE && tk.punct(i + 6, ')')))
    return false;
  long j = i + 7;
  if (tk.punct(j, ',')) j++;
  if (!(j + 1 < tk.size() && tk.punct(j, ')') && tk.punct(j + 1, ')'))) return false;
  end = j + 2;
  value = py_int0(tk.text(i + 5));
  return true;
}

// `T x __attribute__((__aligned__(N)))` on a plain (non-array) object.
bool plain_aligned_object(const Toks &tk, long i) {
  if (!tk.id(i + 1, "__attribute__")) return false;
  long f;
  long long nn;
  if (!aligned_group(tk, i + 1, f, nn)) return false;
  if (!(tk.punct(f, ';') || tk.punct(f, ',') || tk.punct(f, '='))) return false;
  if (i == 0 || tk.code(i - 1) == -1 || tk.id(i - 1, "struct") || tk.id(i - 1, "union") || tk.id(i - 1, "enum"))
    return false;
  for (long k = i - 1; k >= 0; k--) {
    int c = tk.code(k);
    if (c == 59 || c == 123 || c == 125) break;
    if (tk.id(k, "typedef")) return false;
  }
  return true;
}

void utf8(string &out, unsigned v) {
  if (v < 0x80) {
    out += (char)v;
  } else if (v < 0x800) {
    out += (char)(0xc0 | (v >> 6));
    out += (char)(0x80 | (v & 63));
  } else if (v < 0x10000) {
    out += (char)(0xe0 | (v >> 12));
    out += (char)(0x80 | ((v >> 6) & 63));
    out += (char)(0x80 | (v & 63));
  } else {
    out += (char)(0xf0 | (v >> 18));
    out += (char)(0x80 | ((v >> 12) & 63));
    out += (char)(0x80 | ((v >> 6) & 63));
    out += (char)(0x80 | (v & 63));
  }
}

bool hex_digits(const string &h) {
  for (char d : h)
    if (!isxdigit((unsigned char)d)) return false;
  return true;
}

// unicode_escape decoding of the body of a string literal.
string decode_str(const string &lit) {
  size_t q = lit.find('"');
  string body = lit.substr(q + 1, lit.size() - q - 2);
  string out;
  size_t n = body.size(), k = 0;
  while (k < n) {
    int b = (unsigned char)body[k];
    if (b != 92) {
      out += (char)b;
      k++;
      continue;
    }
    k++;
    if (k >= n) die("UnicodeDecodeError: \\ at end of string");
    int e = (unsigned char)body[k];
    k++;
    switch (e) {
      case 10: break;
      case 92: out += '\\'; break;
      case 39: out += '\''; break;
      case 34: out += '"'; break;
      case 97: out += '\a'; break;
      case 98: out += '\b'; break;
      case 102: out += '\f'; break;
      case 110: out += '\n'; break;
      case 114: out += '\r'; break;
      case 116: out += '\t'; break;
      case 118: out += '\v'; break;
      case 48: case 49: case 50: case 51: case 52: case 53: case 54: case 55: {
        unsigned v = e - 48;
        for (int t = 0; t < 2; t++) {
          int d = at(body, k);
          if (!(d >= 48 && d <= 55)) break;
          v = v * 8 + (d - 48);
          k++;
        }
        if (v < 256) out += (char)v;
        else utf8(out, v);
        break;
      }
      case 120: case 117: case 85: {
        size_t w = e == 120 ? 2 : (e == 117 ? 4 : 8);
        string h = k < n ? body.substr(k, w) : "";
        if (!(h.size() == w && hex_digits(h))) die("UnicodeDecodeError: truncated escape");
        unsigned v = (unsigned)strtoul(h.c_str(), nullptr, 16);
        k += w;
        if (e == 120 && v < 256) out += (char)v;
        else utf8(out, v);
        break;
      }
      default:
        out += '\\';
        out += (char)e;
    }
  }
  return out;
}

const char *INT3_STUB =
    "\t.pushsection .text.__nfcxx_int3,\"ax\",@progbits\n"
    "\t.weak __nfcxx_int3\n"
    "\t.type __nfcxx_int3,@function\n"
    "__nfcxx_int3:\n"
    "\tint3\n"
    "\tret\n"
    "\t.popsection";
const char *FENCE_STUB =
    "\t.pushsection .text.__nfcxx_fence,\"ax\",@progbits\n"
    "\t.weak __nfcxx_fence\n"
    "\t.type __nfcxx_fence,@function\n"
    "__nfcxx_fence:\n"
    "\tmfence\n"
    "\tret\n"
    "\t.popsection";
const char *FENCE_STUB_ARM64 =
    "\t.pushsection .text.__nfcxx_fence,\"ax\",@progbits\n"
    "\t.weak __nfcxx_fence\n"
    "\t.type __nfcxx_fence,@function\n"
    "__nfcxx_fence:\n"
    "\tdmb ish\n"
    "\tret\n"
    "\t.popsection";

// ---- tables -----------------------------------------------------------------------------------------------------

std::map<string, string> FLOAT_TYPE = {
    {"_Float32", "float"},
    {"_Float64", "double"},
    {"__bf16", "struct __nfcxx_half16"},
    {"_Float128", "struct __nfcxx_float128"},
    {"_Float32x", "double"},
    {"_Float64x", "long double"},
    {"_Float128x", "struct __nfcxx_float128"},
};
std::map<string, string> FLOAT_DECL = {
    {"struct __nfcxx_half16", "struct __nfcxx_half16 { unsigned short bits; };"},
    {"struct __nfcxx_float128", "struct __nfcxx_float128 { _Alignas(16) unsigned long bits[2]; };"},
};

// builtin -> (libc function, prototype)
std::map<string, std::pair<string, string>> LIBC_BUILTINS;
// builtin -> (helper name, definition)
std::map<string, std::pair<string, string>> HELPER_BUILTINS;

void init_tables() {
  LIBC_BUILTINS = {
      {"__builtin_memcpy", {"memcpy", "void *memcpy(void *, const void *, unsigned long);"}},
      {"__builtin_memmove", {"memmove", "void *memmove(void *, const void *, unsigned long);"}},
      {"__builtin_memset", {"memset", "void *memset(void *, int, unsigned long);"}},
      {"__builtin_memcmp", {"memcmp", "int memcmp(const void *, const void *, unsigned long);"}},
      {"__builtin_memchr", {"memchr", "void *memchr(const void *, int, unsigned long);"}},
      {"__builtin_strlen", {"strlen", "unsigned long strlen(const char *);"}},
      {"__builtin_ldexp", {"ldexp", "double ldexp(double, int);"}},
      {"__builtin_strcmp", {"strcmp", "int strcmp(const char *, const char *);"}},
      {"__builtin_fabsf", {"fabsf", "float fabsf(float);"}},
      {"__builtin_fabs", {"fabs", "double fabs(double);"}},
  };
  for (const char *n : {"sqrt", "exp", "log", "sin", "cos", "tan", "floor", "ceil", "trunc", "round", "exp2", "log2",
                        "asin", "acos", "atan", "sinh", "cosh", "tanh", "log10"}) {
    string s = n;
    LIBC_BUILTINS["__builtin_" + s + "f"] = {s + "f", "float " + s + "f(float);"};
    LIBC_BUILTINS["__builtin_" + s] = {s, "double " + s + "(double);"};
  }
  for (const char *n : {"pow", "fmod", "atan2", "copysign", "fmin", "fmax", "hypot"}) {
    string s = n;
    LIBC_BUILTINS["__builtin_" + s + "f"] = {s + "f", "float " + s + "f(float, float);"};
    LIBC_BUILTINS["__builtin_" + s] = {s, "double " + s + "(double, double);"};
  }
  HELPER_BUILTINS = {
      {"__builtin_huge_val", {"__nfcxx_huge_val", "static double __nfcxx_huge_val(void) { return __builtin_inff(); }"}},
      {"__builtin_huge_valf", {"__builtin_inff", ""}},
      {"__builtin_nan", {"__nfcxx_nan", "static double __nfcxx_nan(const char *s) { return __builtin_nanf(\"\"); }"}},
      {"__builtin_signbit",
       {"__nfcxx_signbit",
        "static int __nfcxx_signbit(double x) { union { double d; unsigned long u; } v; v.d = x; return (int)(v.u >> 63); }"}},
  };
  for (int bytes : {4, 8}) {
    string t = bytes == 4 ? "unsigned int" : "unsigned long", b = std::to_string(bytes);
    for (auto [op, sym] : vector<std::pair<string, string>>{{"add", "+"}, {"sub", "-"}, {"and", "&"}, {"or", "|"}, {"xor", "^"}}) {
      string name = "__sync_" + op + "_and_fetch_" + b;
      HELPER_BUILTINS[name] = {"__nfcxx_" + name, "static " + t + " __nfcxx_" + name + "(void *p, " + t +
                                                      " v) { return __atomic_fetch_" + op + "((" + t + " *)p, v, 5) " +
                                                      sym + " v; }"};
    }
    string name = "__sync_val_compare_and_swap_" + b;
    HELPER_BUILTINS[name] = {"__nfcxx_" + name, "static " + t + " __nfcxx_" + name + "(void *p, " + t + " o, " + t +
                                                    " n) { __atomic_compare_exchange_n((" + t +
                                                    " *)p, &o, n, 0, 5, 5); return o; }"};
  }
  HELPER_BUILTINS["__builtin_ia32_pause"] = {"__nfcxx_pause", "static void __nfcxx_pause(void) { }"};
  HELPER_BUILTINS["__builtin_prefetch"] = {"__nfcxx_prefetch",
                                           "static void __nfcxx_prefetch(const void *p, ...) { (void)p; }"};
}

struct OvType {
  const char *ty, *suf, *u;  // u: the unsigned counterpart of a signed type, or null
};
const OvType OV_TYPES[] = {{"int", "i", "unsigned int"},        {"unsigned int", "u", nullptr},
                           {"long", "l", "unsigned long"},      {"unsigned long", "ul", nullptr},
                           {"long long", "ll", "unsigned long long"}, {"unsigned long long", "ull", nullptr}};
const string OV_BAD = "__nfcxx_overflow_unsupported_operand_types";
const std::map<string, string> OV_OPS = {
    {"__builtin_add_overflow", "add"}, {"__builtin_sub_overflow", "sub"}, {"__builtin_mul_overflow", "mul"}};
const std::map<string, string> G_OPS = {{"__builtin_clzg", "clz"}, {"__builtin_ctzg", "ctz"},
                                        {"__builtin_popcountg", "popcount"}, {"__builtin_parityg", "parity"}};
const string G_MASK = "unsigned long long m = bits == 64 ? (unsigned long long)-1 : (1ULL << bits) - 1; x &= m;";
const std::map<string, string> G_BODY = {
    {"clz", "if (x == 0) return d; int n = 0; while (!(x >> 63)) { x <<= 1; ++n; } return n - (64 - bits);"},
    {"ctz", "if (x == 0) return d; int n = 0; while (!(x & 1)) { x >>= 1; ++n; } return n;"},
    {"popcount", "int n = 0; while (x) { x &= x - 1; ++n; } return n;"},
    {"parity", "int n = 0; while (x) { x &= x - 1; ++n; } return n & 1;"},
};

// [name, definition] of the overflow helper for OP on type T; U is the unsigned counterpart of a signed T.
std::pair<string, string> ov_helper(const string &op, const string &t, const string &suf, const char *u) {
  string name = "__nfcxx_" + op + "ov_" + suf;
  string head = "static int " + name + "(" + t + " a, " + t + " b, " + t + " *r) { ";
  string body;
  if (!u) {
    if (op == "add") body = "*r = a + b; return *r < a;";
    else if (op == "sub") body = "*r = a - b; return a < b;";
    else body = "*r = a * b; return a != 0 && *r / a != b;";
  } else {
    string U = u;
    string mn = "((" + t + ")((" + U + ")1 << (sizeof(" + t + ") * 8 - 1)))";
    if (op == "add")
      body = U + " s = (" + U + ")a + (" + U + ")b; *r = (" + t + ")s; return ((a ^ (" + t + ")s) & (b ^ (" + t + ")s)) < 0;";
    else if (op == "sub")
      body = U + " s = (" + U + ")a - (" + U + ")b; *r = (" + t + ")s; return ((a ^ b) & (a ^ (" + t + ")s)) < 0;";
    else
      body = U + " p = (" + U + ")a * (" + U + ")b; *r = (" + t + ")p; if (a == 0 || b == 0) return 0;" +
             " if (a == -1) return b == " + mn + "; if (b == -1) return a == " + mn + "; return (" + t + ")p / a != b;";
  }
  return {name, head + body + " }"};
}

// Top-level argument token ranges of the call whose '(' is toks[lp]; false if it has no ')'.
bool split_args(const Toks &tk, long lp, vector<std::pair<long, long>> &ranges, long &rp) {
  rp = match_fwd(tk, lp, '(', ')');
  if (rp < 0) return false;
  ranges.clear();
  long start = lp + 1, level = 0;
  for (long k = lp + 1; k < rp; k++) {
    int c = tk.code(k);
    if (!(c >= 0 && c < 256)) continue;
    if (c == 40 || c == 91 || c == 123) {
      level++;
    } else if (c == 41 || c == 93 || c == 125) {
      level--;
    } else if (c == 44 && level == 0) {
      ranges.emplace_back(start, k);
      start = k + 1;
    }
  }
  ranges.emplace_back(start, rp);
  return true;
}

bool volatile_qual(const string &s) { return s == "volatile" || s == "__volatile__" || s == "__volatile"; }
const string KEEP_NAME = "__nfcxx_keep";
const string KEEP_DEF = "static __attribute__((noipa)) void " + KEEP_NAME + "(void *p) { }";

bool opener(char c) { return c == '(' || c == '[' || c == '{'; }
bool closer(char c) { return c == ')' || c == ']' || c == '}'; }

struct Edit {
  size_t s, e;
  string repl;
};

vector<Edit> volatile_locals_walk(const Toks &tk) {
  vector<Edit> edits;
  enum Kind { FUNC, BLOCK, OTHER };
  vector<Kind> stack;
  std::unordered_set<long> seen;
  long n = tk.size();
  for (long i = 0; i < n; i++) {
    int c = tk.code(i);
    if (c < 256) {
      if (c == 123) {
        if (stack.empty()) {
          stack.push_back(tk.punct(i - 1, ')') ? FUNC : OTHER);
        } else if (stack.back() == OTHER) {
          stack.push_back(OTHER);
        } else {
          int p = tk.code(i - 1);
          if (p == -1 || p == 59 || p == 123 || p == 125 || p == 41 || p == 58 || tk.id(i - 1, "else") || tk.id(i - 1, "do"))
            stack.push_back(BLOCK);
          else
            stack.push_back(OTHER);
        }
      } else if (c == 125 && !stack.empty()) {
        stack.pop_back();
      }
      continue;
    }
    if (!(c == ID_CODE && volatile_qual(tk.text(i)))) continue;
    if (stack.empty() || stack.back() == OTHER || tk.pdepth(i) != 0) continue;
    long s = i;
    while (s > 0) {
      int p = tk.code(s - 1);
      if (p == 59 || p == 123 || p == 125) break;
      s--;
    }
    if (seen.count(s)) continue;
    bool plain = true;
    for (long k = s; k < i; k++)
      if (!(tk.code(k) == ID_CODE || tk.punct(k, '*'))) {
        plain = false;
        break;
      }
    if (!plain) continue;
    seen.insert(s);
    long e = i, level = 0;
    while (e < n) {
      int x = tk.code(e);
      if (x < 256) {
        if (opener((char)x)) {
          level++;
        } else if (closer((char)x)) {
          level--;
          if (level < 0) break;
        } else if (x == ';' && level == 0) {
          break;
        }
      }
      e++;
    }
    if (e >= n || level < 0) continue;
    bool storage = false;
    for (long k = s; k < e; k++) {
      if (tk.code(k) != ID_CODE) continue;
      const string &w = tk.names[tk.sym(k)];
      if (w == "typedef" || w == "static" || w == "extern" || w == "register" || w == "_Thread_local" || w == "__thread") {
        storage = true;
        break;
      }
    }
    if (storage) continue;
    vector<vector<long>> pieces;
    vector<long> cur;
    level = 0;
    for (long k = s; k < e; k++) {
      int x = tk.code(k);
      if (x < 256) {
        if (opener((char)x)) {
          level++;
        } else if (closer((char)x)) {
          level--;
        } else if (x == ',' && level == 0) {
          pieces.push_back(cur);
          cur.clear();
          continue;
        }
      }
      cur.push_back(k);
    }
    pieces.push_back(cur);
    vector<string> names;
    bool base_vol = false;
    for (size_t idx = 0; idx < pieces.size(); idx++) {
      vector<long> decl;
      for (long k : pieces[idx]) {
        if (tk.punct(k, '=')) break;
        decl.push_back(k);
      }
      vector<long> stars, vols;
      for (size_t kk = 0; kk < decl.size(); kk++) {
        if (tk.punct(decl[kk], '*')) stars.push_back(kk);
        if (tk.code(decl[kk]) == ID_CODE && volatile_qual(tk.text(decl[kk]))) vols.push_back(kk);
      }
      if (idx == 0) {
        base_vol = false;
        for (long kk : vols)
          if (stars.empty() || kk < stars[0]) base_vol = true;
      }
      bool grouped = false;
      for (long k : decl)
        if (tk.punct(k, '(') || tk.punct(k, '[')) grouped = true;
      if (grouped) continue;
      long last_id = -1;
      for (long k : decl)
        if (tk.code(k) == ID_CODE) last_id = k;
      bool vol;
      if (stars.empty()) {
        vol = base_vol;
      } else {
        vol = false;
        for (long kk : vols)
          if (kk > stars.back()) vol = true;
      }
      if (vol && last_id >= 0) names.push_back(tk.text(last_id));
    }
    if (!names.empty()) {
      string r;
      for (const string &nm : names) r += " " + KEEP_NAME + "(&" + nm + ");";
      edits.push_back({tk.stop(e), tk.stop(e), r});
    }
  }
  return edits;
}

// Edits that keep volatile block-scope locals in memory.
vector<Edit> volatile_locals(const Toks &tk) {
  if (tk.balanced) {
    vector<bool> qual(tk.names.size(), false);
    bool any = false;
    for (size_t s = 0; s < tk.names.size(); s++)
      if (volatile_qual(tk.names[s])) qual[s] = any = true;
    if (!any) return {};
    bool hit = false;
    for (const Tok &t : tk.t)
      if (t.code == ID_CODE && qual[t.sym] && t.depth != 0 && t.pdepth == 0) {
        hit = true;
        break;
      }
    if (!hit) return {};
  }
  return volatile_locals_walk(tk);
}

struct OvxType {
  const char *ty;
  int bits, sign;
};
const OvxType OVX_TYPES[] = {{"signed char", 8, 1}, {"unsigned char", 8, 0}, {"short", 16, 1},
                             {"unsigned short", 16, 0}, {"int", 32, 1},       {"unsigned int", 32, 0},
                             {"long", 64, 1},           {"unsigned long", 64, 0}, {"long long", 64, 1},
                             {"unsigned long long", 64, 0}};
const char *OVX_CORE =
    "static int __nfcxx_ovx(int op, unsigned long long a, int as, unsigned long long b, int bs, int w, int rs, unsigned long long *out) {\n"
    "  int an = as && (long long)a < 0, bn = bs && (long long)b < 0, neg;\n"
    "  unsigned long long am = an ? -a : a, bm = bn ? -b : b, hi = 0, lo;\n"
    "  if (op == 2) {\n"
    "    unsigned long long a0 = am & 0xffffffffULL, a1 = am >> 32, b0 = bm & 0xffffffffULL, b1 = bm >> 32;\n"
    "    unsigned long long p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;\n"
    "    unsigned long long mid = (p00 >> 32) + (p01 & 0xffffffffULL) + (p10 & 0xffffffffULL);\n"
    "    lo = (p00 & 0xffffffffULL) | (mid << 32);\n"
    "    hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);\n"
    "    neg = an != bn;\n"
    "  } else {\n"
    "    if (op == 1) bn = !bn;\n"
    "    if (an == bn) { lo = am + bm; hi = lo < am; neg = an; }\n"
    "    else if (am >= bm) { lo = am - bm; neg = an; }\n"
    "    else { lo = bm - am; neg = bn; }\n"
    "  }\n"
    "  if (hi == 0 && lo == 0) neg = 0;\n"
    "  *out = neg ? -lo : lo;\n"
    "  if (hi) return 1;\n"
    "  if (rs) return neg ? lo > (1ULL << (w - 1)) : lo > (1ULL << (w - 1)) - 1;\n"
    "  if (neg) return 1;\n"
    "  return w < 64 && (lo >> w) != 0;\n"
    "}";

string ov_sign(const string &x) {
  return "_Generic(((" + x + ")+0), int: 1, long: 1, long long: 1, unsigned: 0, unsigned long: 0," +
         " unsigned long long: 0, default: " + OV_BAD + "(0))";
}

// C expression for __builtin_OP_overflow(a, b, r) given the argument texts.
string overflow_call(const string &op, const vector<string> &text, OrderedMap &prelude) {
  const string &a = text[0], &b = text[1], &r = text[2];
  prelude.set("__nfcxx_ovx", OVX_CORE);
  prelude.set(OV_BAD, "int " + OV_BAD + "(long long, ...);");
  int opnum = op == "add" ? 0 : (op == "sub" ? 1 : 2);
  vector<string> cases;
  for (const OvxType &x : OVX_TYPES) {
    string ty = x.ty, wname = "__nfcxx_ovx_" + ty;
    std::replace(wname.begin(), wname.end(), ' ', '_');
    prelude.set(wname, "static int " + wname + "(int op, unsigned long long a, int as, unsigned long long b, int bs, " +
                           ty + " *r) { unsigned long long o; int f = __nfcxx_ovx(op, a, as, b, bs, " +
                           std::to_string(x.bits) + ", " + std::to_string(x.sign) + ", &o); *r = (" + ty +
                           ")o; return f; }");
    string mix = wname + "(" + std::to_string(opnum) + ", (unsigned long long)(" + a + "), " + ov_sign(a) +
                 ", (unsigned long long)(" + b + "), " + ov_sign(b) + ", (" + ty + " *)(" + r + "))";
    string sel = mix;
    for (const OvType &f : OV_TYPES) {
      if (ty != f.ty) continue;
      auto [hname, hdef] = ov_helper(op, ty, f.suf, f.u);
      prelude.set(hname, hdef);
      sel = "_Generic((" + a + "), " + ty + ": _Generic((" + b + "), " + ty + ": " + hname + "(" + a + ", " + b + ", (" +
            ty + " *)(" + r + ")), default: " + mix + "), default: " + mix + ")";
    }
    cases.push_back(ty + " *: " + sel);
  }
  return "_Generic((" + r + "), " + join(cases, ", ") + ", default: " + OV_BAD + "(0, " + a + ", " + b + ", " + r + "))";
}

const string MULOV_NAME = "__nfcxx_mulov_ul";
const string MULOV_DEF =
    "static int __nfcxx_mulov_ul(unsigned long a, unsigned long b, unsigned long *r) { unsigned long p = a * b; *r = p; return a != 0 && p / a != b; }";

// \d+(?:[uU][lL]|[lL][uU])
bool ul_const(const string &text) {
  size_t n = text.size();
  if (n < 3) return false;
  int a = (unsigned char)text[n - 2], b = (unsigned char)text[n - 1];
  bool suffix = ((a == 'u' || a == 'U') && (b == 'l' || b == 'L')) || ((a == 'l' || a == 'L') && (b == 'u' || b == 'U'));
  return suffix && all_digits(text, 0, n - 2);
}

const std::map<string, string> ATOMIC_TYPE = {
    {"1", "unsigned char"}, {"2", "unsigned short"}, {"4", "unsigned int"}, {"8", "unsigned long"}};

bool atomic_op(const string &op) {
  if (op == "load" || op == "store" || op == "exchange" || op == "compare_exchange") return true;
  for (const char *o : {"add", "sub", "and", "or", "xor", "nand"})
    if (op == string("fetch_") + o || op == string(o) + "_fetch") return true;
  return false;
}

// `__atomic_OP_N`: op and size.
bool atomic_parts(const string &name, string &op, string &size) {
  if (!(starts_with(name, "__atomic_") && name.size() > 11)) return false;
  size_t n = name.size();
  size = name.substr(n - 1, 1);
  if (!(name[n - 2] == '_' && ATOMIC_TYPE.count(size))) return false;
  op = name.substr(9, n - 11);
  return atomic_op(op);
}

string atomic_prototype(const string &name) {
  string op, size;
  atomic_parts(name, op, size);
  const string &t = ATOMIC_TYPE.at(size);
  if (op == "load") return t + " " + name + "(const volatile void *, int);";
  if (op == "store") return "void " + name + "(volatile void *, " + t + ", int);";
  if (op == "compare_exchange") return "_Bool " + name + "(volatile void *, void *, " + t + ", _Bool, int, int);";
  return t + " " + name + "(volatile void *, " + t + ", int);";
}

// toks[lp] is the '(' of `( x , C , &x )` (or `( x , C , (&x) )`), x an identifier and C an unsigned long constant.
bool mulov_const_shape(const Toks &tk, long lp) {
  if (!tk.punct(lp, '(')) return false;
  long k = lp + 1;
  if (!(tk.code(k) == ID_CODE && tk.punct(k + 1, ','))) return false;
  string xname = tk.text(k);
  if (!(tk.code(k + 2) == NUM_CODE && ul_const(tk.text(k + 2)) && tk.punct(k + 3, ','))) return false;
  k += 4;
  bool paren = tk.punct(k, '(');
  if (paren) k++;
  if (!tk.punct(k, '&') || tk.code(k + 1) != ID_CODE || tk.text(k + 1) != xname) return false;
  k += 2;
  if (paren) {
    if (!tk.punct(k, ')')) return false;
    k++;
  }
  return tk.punct(k, ')');
}

// `__asm__ [volatile] ("int $3\n" : :);` at i: the index just past its `;`, else -1.
long int3_statement_end(const Toks &tk, long i) {
  long j = i + 1;
  if (tk.code(j) == ID_CODE && volatile_qual(tk.text(j))) j++;
  if (!(tk.punct(j, '(') && tk.code(j + 1) == STR_CODE)) return -1;
  string d = decode_str(tk.text(j + 1));
  if (!(d == "int $3\n" || d == "int $3")) return -1;
  const char p[] = {':', ':', ')', ';'};
  for (int k = 0; k < 4; k++)
    if (!tk.punct(j + 2 + k, p[k])) return -1;
  return j + 6;
}

// Names of functions declared or defined with __attribute__((__weak__)).
std::unordered_set<string> weak_function_names(const Toks &tk) {
  std::unordered_set<string> names;
  long n = tk.size();
  if (tk.name_index("__weak__") < 0) return names;
  long as = tk.name_index("__attribute__");
  if (as < 0) return names;
  for (long i = 0; i < n; i++) {
    if (!(tk.t[i].code == ID_CODE && tk.t[i].sym == as && tk.punct(i + 1, '('))) continue;
    long stop = match_fwd(tk, i + 1, '(', ')') + 1;
    bool any = false;
    for (long k = i; k < stop; k++)
      if (tk.id(k, "__weak__")) {
        any = true;
        break;
      }
    if (!any) continue;
    long k = stop;
    while (k < n && !(tk.punct(k, ';') || tk.punct(k, '{') || tk.punct(k, '}'))) {
      if (tk.id(k, "__attribute__") && tk.punct(k + 1, '(')) {
        k = match_fwd(tk, k + 1, '(', ')') + 1;
        continue;
      }
      if (tk.code(k) == ID_CODE && tk.punct(k + 1, '(')) {
        names.insert(tk.text(k));
        break;
      }
      k++;
    }
  }
  return names;
}

// Return type text of the function whose body opens at token brace, or "" when that `{` opens no function body.
string function_return_type(const Toks &tk, long decl, long brace) {
  if (!tk.punct(brace - 1, ')')) return "";
  long lp = match_back(tk, brace - 1, '(', ')');
  if (lp < 1 || tk.code(lp - 1) != ID_CODE) return "";
  long name = lp - 1;
  vector<string> words;
  long k = decl;
  while (k < name) {
    if (tk.id(k, "__attribute__") && tk.punct(k + 1, '(')) {
      k = match_fwd(tk, k + 1, '(', ')') + 1;
      continue;
    }
    if (tk.code(k) == ID_CODE) {
      const string &w = tk.names[tk.sym(k)];
      if (!(w == "static" || w == "extern" || w == "inline" || w == "__inline" || w == "__inline__")) words.push_back(w);
    } else {
      words.push_back(tk.text(k));
    }
    k++;
  }
  return join(words, " ");
}

// Names of the typedefs of void (`typedef void T;`, or of another such name).
std::unordered_set<string> void_typedefs(const Toks &tk) {
  std::unordered_set<string> names;
  long n = tk.size();
  long ts = tk.name_index("typedef");
  if (ts < 0) return names;
  vector<long> cands;
  for (long i = 0; i < n - 3; i++)
    if (tk.t[i].code == ID_CODE && tk.t[i].sym == ts && tk.t[i + 3].code == 59 && tk.t[i + 2].code == ID_CODE)
      cands.push_back(i);
  bool changed = true;
  while (changed) {
    changed = false;
    for (long i : cands) {
      string nm = tk.text(i + 2);
      if (names.count(nm)) continue;
      string base = tk.text(i + 1);
      if (!(base == "void" || names.count(base))) continue;
      names.insert(nm);
      changed = true;
    }
  }
  return names;
}

vector<Edit> bare_return_edits_fast(const Toks &tk) {
  vector<Edit> edits;
  long n = tk.size();
  long rs = tk.name_index("return");
  if (rs < 0) return edits;
  bool have_voids = false;
  std::unordered_set<string> voids;
  string ret;
  bool has_ret = false;
  long close = -1;
  for (long i = 0; i < n - 1; i++) {
    const Tok &t = tk.t[i];
    if (!(t.code == ID_CODE && t.sym == rs && tk.t[i + 1].code == 59 && t.depth != 0)) continue;
    if (i > close) {
      has_ret = false;
      long o = i - 1;
      while (o >= 0 && tk.t[o].depth != 0) o--;
      if (o >= 0 && tk.t[o].code == 123) {
        close = o + 1;
        while (close < n && !(tk.t[close].code == 125 && tk.t[close].depth == 1)) close++;
        long d = o - 1;
        while (d >= 0) {
          const Tok &kd = tk.t[d];
          if (kd.code == 59 && kd.depth == 0) break;
          if (kd.code == 125 && kd.depth == 1) break;
          d--;
        }
        ret = function_return_type(tk, d + 1, o);
        has_ret = !ret.empty();
        if (has_ret) {
          if (!have_voids) {
            voids = void_typedefs(tk);
            have_voids = true;
          }
          if (ret == "void" || voids.count(ret)) has_ret = false;
        }
      }
    }
    if (has_ret) edits.push_back({tk.start(i), tk.stop(i), "return (" + ret + "){}"});
  }
  return edits;
}

vector<Edit> bare_return_edits_walk(const Toks &tk) {
  vector<Edit> edits;
  long n = tk.size();
  std::unordered_set<string> voids = void_typedefs(tk);
  long decl = 0;
  for (long i = 0; i < n; i++) {
    if (tk.punct(i, ';') && tk.depth(i) == 0) {
      decl = i + 1;
    } else if (tk.punct(i, '{') && tk.depth(i) == 0) {
      long close = match_fwd(tk, i, '{', '}');
      if (close < 0) break;
      string ret = function_return_type(tk, decl, i);
      if (!ret.empty() && ret != "void" && !voids.count(ret)) {
        for (long k = i + 1; k < close; k++)
          if (tk.id(k, "return") && tk.punct(k + 1, ';')) edits.push_back({tk.start(k), tk.stop(k), "return (" + ret + "){}"});
      }
      i = close;
      decl = close + 1;
    }
  }
  return edits;
}

vector<Edit> bare_return_edits(const Toks &tk) {
  return tk.balanced ? bare_return_edits_fast(tk) : bare_return_edits_walk(tk);
}

// (?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[lL], with a . or an exponent
bool long_double_literal(const string &text) {
  size_t n = text.size();
  int last = at(text, n - 1);
  if (!(last == 'l' || last == 'L')) return false;
  n--;
  size_t k = 0;
  while (k < n && digit_b(at(text, k))) k++;
  size_t nint = k;
  if (k < n && at(text, k) == '.') {
    k++;
    size_t f0 = k;
    while (k < n && digit_b(at(text, k))) k++;
    if (nint == 0 && k == f0) return false;
  } else if (nint == 0) {
    return false;
  }
  if (k < n && (at(text, k) == 'e' || at(text, k) == 'E')) {
    k++;
    if (k < n && (at(text, k) == '+' || at(text, k) == '-')) k++;
    if (!(k < n && all_digits(text, k, n))) return false;
    k = n;
  }
  return k == n && (text.find_first_of(".eE") != string::npos);
}

// The device image block of pathb-ptx-emit --embed.
bool image_asm(const string &text) {
  vector<string> lines = split_lines(text);
  if (!(lines.size() >= 2 && lines[0] == ".pushsection .rodata" && lines.back() == ".popsection")) return false;
  for (const string &l : lines) {
    if (l == ".pushsection .rodata" || l == ".popsection" || l == ".balign 16" || l == ".byte 0") continue;
    if (starts_with(l, "__nfcxx_image") && ends_with(l, ":")) continue;
    bool ok = false;
    for (const char *pre : {".local __nfcxx_image", ".type __nfcxx_image", ".size __nfcxx_image", ".incbin \""})
      if (starts_with(l, pre)) ok = true;
    if (!ok) return false;
  }
  return true;
}

bool align_text(const string &text) {
  if (!starts_with(text, ".align")) return false;
  size_t k = 6;
  while (k < text.size() && space_b((unsigned char)text[k])) k++;
  return k > 6 && all_digits(text, k);
}

bool asm_name_char(int b, bool dot_dollar) { return (word_b(b) && b < 128) || (dot_dollar && (b == 46 || b == 36)); }

bool globl_name(const string &text, string &name) {
  string rest;
  if (starts_with(text, ".global")) rest = text.substr(7);
  else if (starts_with(text, ".globl")) rest = text.substr(6);
  else return false;
  size_t k = 0;
  while (k < rest.size() && space_b((unsigned char)rest[k])) k++;
  if (k == 0 || k >= rest.size()) return false;
  name = rest.substr(k);
  int b0 = (unsigned char)name[0];
  if (!(idstart_b(b0) || b0 == 46)) return false;
  for (char c : name)
    if (!asm_name_char((unsigned char)c, true)) return false;
  return true;
}

bool set_names(const string &text, string &lhs, string &rhs) {
  size_t n = text.size();
  if (n == 0) return false;
  if (!(idstart_b((unsigned char)text[0]) && text[0] != '$')) return false;
  size_t k = 1;
  while (k < n && word_b((unsigned char)text[k]) && (unsigned char)text[k] < 128) k++;
  lhs = text.substr(0, k);
  while (k < n && space_b((unsigned char)text[k])) k++;
  if (!(k < n && text[k] == '=')) return false;
  k++;
  while (k < n && space_b((unsigned char)text[k])) k++;
  if (!(k < n && idstart_b((unsigned char)text[k]) && text[k] != '$')) return false;
  size_t r0 = k;
  while (k < n && word_b((unsigned char)text[k]) && (unsigned char)text[k] < 128) k++;
  if (k != n) return false;
  rhs = text.substr(r0);
  return true;
}

// ---- --dce: unused static functions ------------------------------------------------------------------------------

const std::set<string> DCE_KEEP_WORDS = {"asm", "__asm", "__asm__", "__attribute__", "__attribute", "used", "__used__",
                                         "constructor", "__constructor__", "destructor", "__destructor__", "alias",
                                         "__alias__", "weak", "__weak__", "section", "__section__", "ifunc", "__ifunc__",
                                         "_Pragma", "__pragma"};

// Token ranges [first, last] of the file-scope static function definitions that no live code refers to.
vector<std::pair<long, long>> dead_static_ranges(const Toks &tk) {
  if (!tk.balanced) return {};
  const vector<string> &names = tk.names;
  long static_sym = tk.name_index("static");
  if (static_sym < 0) return {};
  vector<bool> keep(names.size(), false), live(names.size(), false);
  for (size_t s = 0; s < names.size(); s++)
    if (DCE_KEEP_WORDS.count(names[s])) keep[s] = true;
  long n = tk.size();
  struct Func {
    long first, last;
    vector<int> refs;
  };
  std::map<int, Func> funcs;
  vector<int> funcs_order;
  std::unordered_map<string, int> symidx;
  bool have_symidx = false;
  long decl = 0;
  for (long i = 0; i <= n; i++) {
    bool has_stop = false;  // Ruby's `stop` is not nil
    long stop = 0, fn = -1;  // the last token of the chunk that starts at decl; the `{` of a function definition
    if (i == n) {
      has_stop = true;
      stop = n - 1;
    } else {
      const Tok &ki = tk.t[i];
      if (ki.depth == 0) {
        if (ki.code == 59) {
          has_stop = true;
          stop = i;
        } else if (ki.code == 123) {
          long close = i + 1;
          while (close < n && !(tk.t[close].code == 125 && tk.t[close].depth == 1)) close++;
          if (tk.t[tk.idx(i - 1)].code == 41 && i > decl) {
            fn = i;
            has_stop = true;
            stop = close;
          }
          i = close;
        }
      }
    }
    if (!has_stop) continue;
    if (stop >= decl) {
      bool keepit = false;
      vector<int> refs;
      for (long j = decl; j <= stop; j++) {
        if (tk.t[j].code == ID_CODE) {
          refs.push_back(tk.t[j].sym);
          if (keep[tk.t[j].sym]) keepit = true;
        }
      }
      int removable = 0;  // 0 false, 1 true, 2 a prototype
      if (!keepit) {
        long name_i = -1;
        if (fn >= 0) {
          long lp = match_back(tk, fn - 1, '(', ')');
          if (lp > 0) name_i = lp - 1;
        } else if (tk.t[stop].code == 59 && stop > decl && tk.t[stop - 1].code == 41) {
          long lp = match_back(tk, stop - 1, '(', ')');
          if (lp > 0) name_i = lp - 1;
        }
        if (name_i >= 0 && name_i >= decl && tk.t[name_i].code == ID_CODE) {
          bool plain = false;
          for (long q = decl; q < name_i; q++) {
            int cq = tk.t[q].code;
            if (cq == ID_CODE) {
              if (tk.t[q].sym == static_sym) plain = true;
            } else if (cq != 42) {
              plain = false;
              break;
            }
          }
          if (plain) {
            if (fn < 0) {
              removable = 2;
            } else {
              int nsym = tk.t[name_i].sym;
              if (!funcs.count(nsym)) {
                removable = 1;
                vector<int> r;
                for (int x : refs)
                  if (x != nsym) r.push_back(x);
                funcs[nsym] = Func{decl, stop, r};
                funcs_order.push_back(nsym);
              }
            }
          }
        }
      }
      if (removable == 0) {
        for (int r : refs) live[r] = true;
        if (keepit) {
          if (!have_symidx) {
            for (size_t s = 0; s < names.size(); s++) symidx[names[s]] = (int)s;
            have_symidx = true;
          }
          for (long q = decl; q <= stop; q++) {
            if (tk.t[q].code != STR_CODE) continue;
            string w = tk.text(q);
            size_t pos = 0, wl = w.size();
            while (pos < wl) {
              int b = (unsigned char)w[pos];
              if (idstart_b(b)) {
                size_t e = pos + 1;
                while (e < wl && idcont_b((unsigned char)w[e])) e++;
                auto it = symidx.find(w.substr(pos, e - pos));
                if (it != symidx.end()) live[it->second] = true;
                pos = e;
              } else {
                pos++;
              }
            }
          }
        }
      }
    }
    decl = stop + 1;
  }
  vector<int> queue;
  for (int s : funcs_order)
    if (live[s]) queue.push_back(s);
  while (!queue.empty()) {
    int s = queue.back();
    queue.pop_back();
    for (int r : funcs[s].refs) {
      if (live[r]) continue;
      live[r] = true;
      if (funcs.count(r)) queue.push_back(r);
    }
  }
  vector<std::pair<long, long>> dead;
  for (int s : funcs_order)
    if (!live[s]) dead.emplace_back(funcs[s].first, funcs[s].last);
  std::sort(dead.begin(), dead.end());
  return dead;
}

// Remove the edits that lie in a dead range ([first, last] token ranges, sorted).
vector<Edit> drop_edits_in_dead(const Toks &tk, vector<Edit> edits, const vector<std::pair<long, long>> &dead) {
  if (dead.empty()) return edits;
  vector<std::pair<size_t, size_t>> spans;
  for (auto [a, b] : dead) spans.emplace_back(tk.start(a), tk.stop(b));
  vector<Edit> out;
  for (Edit &e : edits) {
    long lo = 0, hi = (long)spans.size() - 1;
    bool inside = false;
    while (lo <= hi) {
      long mid = (lo + hi) / 2;
      if (e.s < spans[mid].first) hi = mid - 1;
      else if (e.e > spans[mid].second) lo = mid + 1;
      else {
        inside = true;
        break;
      }
    }
    if (!inside) out.push_back(std::move(e));
  }
  return out;
}

bool read_file(const string &path, string &out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::ostringstream ss;
  ss << f.rdbuf();
  out = ss.str();
  return true;
}

// Python's text mode: universal newlines on read.
string read_text(const string &path) {
  string s;
  if (!read_file(path, s)) die("qbe-prep: cannot read " + path);
  if (s.size() >= ((size_t)1 << 32)) die("qbe-prep: " + path + " is 4 GB or more");
  if (s.find('\r') == string::npos) return s;
  string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '\r') {
      out += '\n';
      if (i + 1 < s.size() && s[i + 1] == '\n') i++;
    } else {
      out += s[i];
    }
  }
  return out;
}

// Apply the edits from the end: sorted by (start, end) descending, equal keys in their original order, each edit on the
// result of the previous ones. Non-overlapping edits are spliced in one pass; anything else replays them one by one.
string apply_edits(const string &src, const vector<Edit> &edits) {
  vector<size_t> order(edits.size());
  for (size_t i = 0; i < order.size(); i++) order[i] = i;
  std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
    if (edits[a].s != edits[b].s) return edits[a].s > edits[b].s;
    return edits[a].e > edits[b].e;
  });
  long cursor = (long)src.size();
  vector<const string *> pieces;
  vector<std::pair<size_t, size_t>> slices;
  bool overlap = false;
  for (size_t idx : order) {
    const Edit &ed = edits[idx];
    if ((long)ed.e > cursor) {
      overlap = true;
      break;
    }
    slices.emplace_back(ed.e, cursor - ed.e);
    pieces.push_back(&ed.repl);
    cursor = (long)ed.s;
  }
  if (!overlap) {
    string out = src.substr(0, cursor);
    for (size_t k = slices.size(); k-- > 0;) {
      out += *pieces[k];
      out.append(src, slices[k].first, slices[k].second);
    }
    return out;
  }
  string out = src;
  for (size_t idx : order) {
    const Edit &ed = edits[idx];
    size_t s = std::min(ed.s, out.size()), e = std::min(ed.e, out.size());
    out = out.substr(0, s) + ed.repl + (e < out.size() ? out.substr(e) : "");
  }
  return out;
}

bool special_id(const string &nm) {
  static std::unordered_set<string> ids;
  if (ids.empty()) {
    for (const char *w : {"typedef", "__attribute__", "__asm__", "__asm", "alloca", "__builtin_mul_overflow", "volatile",
                          "__volatile__", "__volatile"})
      ids.insert(w);
    for (auto &kv : LIBC_BUILTINS) ids.insert(kv.first);
    for (auto &kv : HELPER_BUILTINS) ids.insert(kv.first);
    for (auto &kv : OV_OPS) ids.insert(kv.first);
    for (auto &kv : G_OPS) ids.insert(kv.first);
    for (auto &kv : FLOAT_TYPE) ids.insert(kv.first);
  }
  return ids.count(nm) || starts_with(nm, "__atomic_");
}

bool write_file(const string &path, const string &data) {
  FILE *f = fopen(path.c_str(), "wb");
  if (!f) return false;
  bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
  return fclose(f) == 0 && ok;
}

}  // namespace

int main(int argc, char **argv) {
  init_tables();
  bool c_input = false, macho = false, arm64 = false, dce = false;
  int a = 1;
  for (; a < argc; a++) {
    string o = argv[a];
    if (o == "--macho") macho = true;
    else if (o == "--arm64") arm64 = true;
    else if (o == "--dce") dce = true;
    else if (o == "--c-input") c_input = true;
    else break;
  }
  auto label = [&](const string &name) { return macho ? "_" + name : name; };
  if (argc - a != 3) die("usage: qbe-prep.rb [--c-input] [--macho] [--arm64] [--dce] PREPROCESSED_C REWRITTEN_C ASM_TAIL");
  string src_path = argv[a], out_path = argv[a + 1], tail_path = argv[a + 2];
  string src = read_text(src_path);
  Toks tk(src);
  tokenize(tk);
  long n = tk.size();
  vector<Edit> edits;
  vector<string> tail;
  vector<std::pair<long, long>> dead;
  if (dce) dead = dead_static_ranges(tk);
  for (Edit &e : drop_edits_in_dead(tk, bare_return_edits(tk), dead)) edits.push_back(std::move(e));
  for (auto [x, y] : dead) edits.push_back({tk.start(x), tk.stop(y), ""});
  std::unordered_set<string> weak = weak_function_names(tk);
  std::unordered_set<string> weak_marked;
  vector<string> ctors;
  std::set<string> need_float;
  bool need_int3 = false, need_fence = false;
  OrderedMap prelude;
  vector<Edit> keep = drop_edits_in_dead(tk, volatile_locals(tk), dead);
  if (!keep.empty()) {
    for (Edit &e : keep) edits.push_back(std::move(e));
    prelude.set(KEEP_NAME, KEEP_DEF);
  }
  vector<bool> flags(tk.names.size());
  for (size_t s = 0; s < tk.names.size(); s++) flags[s] = special_id(tk.names[s]);

  // _ZTHx is the thread_local init alias for _ZTWx; if the wrapper is COMDAT (weak), so is the alias.
  auto mark_weak_alias = [&](const string &name) {
    if (starts_with(name, "_ZTH") && weak.count("_ZTW" + name.substr(4)) && !weak_marked.count(name)) {
      weak_marked.insert(name);
      tail.push_back(macho ? "\t.weak_definition " + label(name) : "\t.weak " + name);
    }
  };

  long attr_sym = tk.name_index("__attribute__");
  size_t di = 0;
  long dstart = dead.empty() ? n + 1 : dead[0].first;
  long i = 0;
  while (i < n) {
    if (i >= dstart) {
      while (di < dead.size() && dead[di].second < i) di++;
      if (di < dead.size() && i >= dead[di].first) i = dead[di].second + 1;
      dstart = di < dead.size() ? dead[di].first : n + 1;
      continue;
    }
    int c = tk.t[i].code;
    if (c == ID_CODE) {
      bool look = flags[tk.t[i].sym];
      if (!look && i + 1 < n) {
        int c1 = tk.t[i + 1].code;
        look = c1 == 91 || (c1 == ID_CODE && tk.t[i + 1].sym == attr_sym);
      }
      if (!look) {
        i++;
        continue;
      }
    } else if (c == STR_CODE || c == CHR_CODE || (c < 256 && c != 125)) {
      i++;
      continue;
    }
    bool is_id = c == ID_CODE;
    string nm = is_id ? tk.text(i) : string();

    // 0b. volatile is dropped, except on inline asm.
    if (is_id && volatile_qual(nm)) {
      bool on_asm = false;
      if (tk.code(i - 1) == ID_CODE) {
        string p = tk.text(i - 1);
        on_asm = p == "__asm__" || p == "__asm" || p == "asm";
      }
      if (!on_asm) {
        edits.push_back({tk.start(i), tk.stop(i), ""});
        i++;
        continue;
      }
    }

    // 0a. the plain typedef of a mapped floating type is dropped (glibc's <bits/floatn.h>).
    if (is_id && nm == "typedef") {
      long j = i + 1;
      while (j < n && !(tk.punct(j, ';') || tk.punct(j, '{') || tk.punct(j, '(') || tk.punct(j, '['))) j++;
      if (j < n && tk.punct(j, ';') && tk.code(j - 1) == ID_CODE && FLOAT_TYPE.count(tk.text(j - 1))) {
        edits.push_back({tk.start(i), tk.stop(j), ""});
        i = j + 1;
        continue;
      }
    }

    // 0. __attribute__((__constructor__)) after a parameter list: removed, and the function listed.
    if (is_id && nm == "__attribute__") {
      if (tk.punct(i + 1, '(') && tk.punct(i + 2, '(') && tk.id(i + 3, "__constructor__") && tk.punct(i + 4, ')') &&
          tk.punct(i + 5, ')') && tk.punct(i - 1, ')')) {
        long lp = match_back(tk, i - 1, '(', ')');
        long name_i = lp > 0 ? lp - 1 : -1;
        if (name_i < 0 || tk.code(name_i) != ID_CODE) die("qbe-prep: cannot find the name of a constructor declaration");
        string fname = tk.text(name_i);
        if (std::find(ctors.begin(), ctors.end(), fname) == ctors.end()) ctors.push_back(fname);
        edits.push_back({tk.start(i), tk.stop(i + 5), ""});
        i += 6;
        continue;
      }
    }

    // 1a. __asm__ volatile("int $3\n" : :);: a call to the int3 stub.
    if (is_id && (nm == "__asm__" || nm == "__asm") && stmt_ctx(tk, i)) {
      long stop = int3_statement_end(tk, i);
      if (stop >= 0) {
        edits.push_back({tk.start(i), tk.stop(stop - 1), "__nfcxx_int3();"});
        need_int3 = true;
        i = stop;
        continue;
      }
    }

    // 1. __asm__("...") statements.
    if (is_id && (nm == "__asm__" || nm == "__asm") && tk.punct(i + 1, '(') && stmt_ctx(tk, i)) {
      long j = i + 2;
      string joined;
      bool any = false;
      while (j < n && tk.code(j) == STR_CODE) {
        joined += decode_str(tk.text(j));
        any = true;
        j++;
      }
      if (any && tk.punct(j, ')') && tk.punct(j + 1, ';')) {
        string text = py_strip(joined);
        size_t stmt_start = tk.start(i), stmt_end = tk.stop(j + 1);
        if (align_text(text)) {
          edits.push_back({stmt_start, stmt_end, ""});
          i = j + 2;
          continue;
        }
        if (tk.depth(i) == 0 && tk.pdepth(i) == 0 && image_asm(text)) {
          if (macho) die("qbe-prep: device image block with --macho is not supported");
          for (const string &l : split_lines(text)) tail.push_back("\t" + l);
          edits.push_back({stmt_start, stmt_end, ""});
          i = j + 2;
          continue;
        }
        if (tk.depth(i) == 0 && tk.pdepth(i) == 0) {
          string m, s0, s1;
          if (globl_name(text, m)) {
            tail.push_back("\t.globl " + label(m));
            mark_weak_alias(m);
          } else if (set_names(text, s0, s1)) {
            tail.push_back("\t.set " + label(s0) + ", " + label(s1));
            mark_weak_alias(s0);
          } else {
            die("qbe-prep: unsupported top-level asm \"" + text + "\"");
          }
          edits.push_back({stmt_start, stmt_end, ""});
          i = j + 2;
          continue;
        }
      }
    }

    // 2. __attribute__((__aligned__(N))) after a declarator name: _Alignas(N) before the name.
    if (is_id && nm != "__attribute__" && (tk.punct(i + 1, '[') || plain_aligned_object(tk, i))) {
      long j = i + 1;
      while (j < n && tk.punct(j, '[')) {
        j = match_fwd(tk, j, '[', ']');
        if (j < 0) break;
        j++;
      }
      long stop;
      long long nn;
      if (j > 0 && j < n && aligned_group(tk, j, stop, nn)) {
        edits.push_back({tk.start(j), tk.stop(stop - 1), ""});
        edits.push_back({tk.start(i), tk.start(i), "_Alignas(" + std::to_string(nn) + ") "});
        i = stop;
        continue;
      }
    }

    // 3. struct T { ...; } __attribute__((__aligned__(N))); -> _Alignas(N) on the first member.
    if (c == 125) {
      long stop;
      long long nn;
      if (aligned_group(tk, i + 1, stop, nn) && tk.punct(stop, ';')) {
        long o = match_back(tk, i, '{', '}');
        long ob = o < 0 ? n + o : o;
        if (first_member_plain(tk, o, i)) {
          edits.push_back({tk.stop(ob), tk.stop(ob), " _Alignas(" + std::to_string(nn) + ")"});
          edits.push_back({tk.start(i + 1), tk.stop(stop - 1), ""});
          i = stop;
          continue;
        }
      }
    }

    // 4. Floating literals of the types above.
    string body, suffix;
    if (c == NUM_CODE && float_lit(tk.text(i), body, suffix)) {
      bool paren = tk.punct(i - 1, '(') && tk.punct(i + 1, ')');
      if (suffix == "f32") {
        edits.push_back({tk.start(i), tk.stop(i), body + "f"});
      } else if (suffix == "f64" || suffix == "f32x") {
        edits.push_back({tk.start(i), tk.stop(i), body});
      } else if (suffix == "f64x") {
        edits.push_back({tk.start(i), tk.stop(i), body + "L"});
      } else if (suffix == "f16" && paren) {
        edits.push_back({tk.start(i - 1), tk.stop(i + 1),
                         "((_Float16)" + half_literal((unsigned)ieee_bits(body, 10, 5)) + ")"});
        i += 2;
        continue;
      } else if ((suffix == "f128" || suffix == "f128x") && paren) {
        unsigned __int128 bits = ieee_bits(body, 112, 15);
        edits.push_back({tk.start(i - 1), tk.stop(i + 1),
                         "{ { 0x" + hex_pad((uint64_t)bits, 16) + "UL, 0x" + hex_pad((uint64_t)(bits >> 64), 16) +
                             "UL } }"});
        i += 2;
        continue;
      } else {
        die("qbe-prep: float literal " + tk.text(i) + " is not in a supported form");
      }
      i++;
      continue;
    }

    // 4c. (double)LITERALL: the L is dropped.
    if (c_input && c == NUM_CODE && long_double_literal(tk.text(i)) && tk.punct(i - 3, '(') && tk.code(i - 2) >= 0 &&
        (tk.text_is(i - 2, "double") || tk.text_is(i - 2, "float")) && tk.punct(i - 1, ')')) {
      edits.push_back({tk.stop(i) - 1, tk.stop(i), ""});
      i++;
      continue;
    }

    // 4a. alloca (hand-written C): a call becomes cproc's builtin.
    if (c_input && is_id && nm == "alloca" && tk.punct(i + 1, '(') && !tk.punct(i - 1, '*')) {
      edits.push_back({tk.start(i), tk.stop(i), "__builtin_alloca"});
      i++;
      continue;
    }

    // 4b. Builtins cproc lacks.
    if (is_id) {
      auto lb = LIBC_BUILTINS.find(nm);
      auto hb = HELPER_BUILTINS.find(nm);
      if (lb != LIBC_BUILTINS.end()) {
        edits.push_back({tk.start(i), tk.stop(i), lb->second.first});
        prelude.set(lb->second.first, lb->second.second);
      } else if (hb != HELPER_BUILTINS.end()) {
        edits.push_back({tk.start(i), tk.stop(i), hb->second.first});
        prelude.set(hb->second.first, hb->second.second);
      } else if (nm == "__builtin_mul_overflow" && mulov_const_shape(tk, i + 1)) {
        edits.push_back({tk.start(i), tk.stop(i), MULOV_NAME});
        prelude.set(MULOV_NAME, MULOV_DEF);
      } else if (G_OPS.count(nm) && tk.punct(i + 1, '(')) {
        vector<std::pair<long, long>> ranges;
        long rp;
        const string &op = G_OPS.at(nm);
        bool two = op == "clz" || op == "ctz";
        bool ok = split_args(tk, i + 1, ranges, rp);
        if (!ok || !(ranges.size() == 1 || (two && ranges.size() == 2)))
          die("qbe-prep: " + nm + " expects " + (two ? "1 or 2" : "1") + " argument(s)");
        // an empty argument is Ruby's nil (byteslice with a negative length)
        vector<std::pair<bool, string>> text;
        for (auto [x, y] : ranges) {
          long len = (long)tk.stop(y - 1) - (long)tk.start(x);
          text.emplace_back(len >= 0, len >= 0 ? src.substr(tk.start(x), len) : string());
        }
        string xs = text[0].second;
        string d = text.size() > 1 && text[1].first ? text[1].second : "sizeof(" + xs + ") * 8";
        string name = "__nfcxx_" + nm.substr(10);
        prelude.set(name, "static int " + name + "(unsigned long long x, int bits, int d) { " + G_MASK + " " +
                              G_BODY.at(op) + " }");
        edits.push_back({tk.start(i), tk.stop(rp), name + "((unsigned long long)(" + xs + "), sizeof(" + xs + ") * 8, " + d + ")"});
        i = rp + 1;
        continue;
      } else if (OV_OPS.count(nm) && tk.punct(i + 1, '(')) {
        vector<std::pair<long, long>> ranges;
        long rp;
        if (!split_args(tk, i + 1, ranges, rp) || ranges.size() != 3) die("qbe-prep: " + nm + " expects three arguments");
        vector<string> text;
        for (auto [x, y] : ranges) {
          long len = (long)tk.stop(y - 1) - (long)tk.start(x);
          text.push_back(len >= 0 ? src.substr(tk.start(x), len) : string());
        }
        edits.push_back({tk.start(i), tk.stop(rp), overflow_call(OV_OPS.at(nm), text, prelude)});
        i = rp + 1;
        continue;
      } else if (nm == "__atomic_thread_fence" || nm == "__atomic_signal_fence") {
        edits.push_back({tk.start(i), tk.stop(i), "__nfcxx_fence"});
        prelude.set("__nfcxx_fence", "void __nfcxx_fence(int);");
        need_fence = true;
      } else {
        string op, size;
        if (starts_with(nm, "__atomic_") && atomic_parts(nm, op, size)) prelude.set(nm, atomic_prototype(nm));
      }
    }

    // 5. Floating types cproc lacks.
    if (is_id) {
      auto ft = FLOAT_TYPE.find(nm);
      if (ft != FLOAT_TYPE.end()) {
        edits.push_back({tk.start(i), tk.stop(i), ft->second});
        need_float.insert(ft->second);
      }
    }
    i++;
  }

  vector<string> decls;
  for (const char *t : {"struct __nfcxx_half16", "struct __nfcxx_float128"})
    if (need_float.count(t)) decls.push_back(FLOAT_DECL[t]);
  if (need_int3) {
    prelude.set("__nfcxx_int3", "void __nfcxx_int3(void);");
    tail.push_back(INT3_STUB);
  }
  if (need_fence) {
    if (macho) {
      for (string l : {string("\t.section __TEXT,__text,regular,pure_instructions"), string("\t.globl ___nfcxx_fence"),
                       string("\t.weak_definition ___nfcxx_fence"), string("___nfcxx_fence:"),
                       string("\t") + (arm64 ? "dmb ish" : "mfence"), string("\tret")})
        tail.push_back(l);
    } else {
      tail.push_back(arm64 ? FENCE_STUB_ARM64 : FENCE_STUB);
    }
  }
  for (auto &kv : prelude.items) decls.push_back(kv.second);
  if (!decls.empty()) edits.push_back({0, 0, join(decls, "\n") + "\n"});
  if (!ctors.empty()) {
    if (macho) {
      tail.push_back("\t.section __DATA,__mod_init_func,mod_init_funcs");
      tail.push_back("\t.p2align 3");
      for (const string &name : ctors) tail.push_back("\t.quad _" + name);
    } else {
      tail.push_back("\t.pushsection .init_array,\"aw\"");
      tail.push_back("\t.p2align 3");
      for (const string &name : ctors) tail.push_back("\t.quad " + name);
      tail.push_back("\t.popsection");
    }
  }
  if (!write_file(out_path, apply_edits(src, edits))) die("qbe-prep: cannot write " + out_path);
  if (!write_file(tail_path, tail.empty() ? string() : join(tail, "\n") + "\n")) die("qbe-prep: cannot write " + tail_path);
  return 0;
}
