// C++ port of scripts/cuda-rewrite.rb (the Ruby script is the reference: same names, same comments, same output).
//
// CUDA launch rewrite for nfcxx: turns the kernel launch syntax of a .cu file into a call of __nfcxx_cuda_launch
// (lib/cuda/nfcxx_cuda.h), so the EDG front end sees only C++.
//   name<<<grid, block[, shmem[, stream]]>>>(args)  ->  __nfcxx_cuda_launch(name, grid, block, shmem, stream, args)
// Usage: build/cuda-rewrite [-I DIR]... [--device [--kernels=FILE]] [--edg-launches] FILE.cu > FILE.cpp
//
// Strings are byte strings, as in Ruby on mruby: indexes are byte offsets and a position past the end reads as
// "absent" (ch() returns -1), where Ruby's s[i] returns nil.
//
// PORT STATUS: the lexical layer (this file's first section) is ported. The remaining passes are listed in
// tools/cuda-rewrite/PORTING.md; until they are ported, main() refuses with exit 2 and the driver keeps the Ruby script.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

namespace {

// ---- basic character helpers (Ruby: s[i], white?, ident_char?, refuse) ---------------------------------------------

// The byte at i, or -1 when i is outside the string (Ruby's nil).
int ch(const std::string &s, long i) {
  if (i < 0 || i >= (long)s.size()) return -1;
  return (unsigned char)s[(size_t)i];
}

bool white_c(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

bool ident_c(int c) {
  if (c < 0) return false;
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

[[noreturn]] void refuse(const std::string &msg) {
  std::fprintf(stderr, "refused: %s\n", msg.c_str());
  std::exit(3);
}

// Ruby's s.index(sub, from): the first index >= from where sub starts, or -1.
long str_index(const std::string &s, const std::string &sub, long from) {
  if (from < 0) from = 0;
  if (from > (long)s.size()) return -1;
  size_t p = s.find(sub, (size_t)from);
  return p == std::string::npos ? -1 : (long)p;
}

// The character before position i, skipping whitespace; "" at the start.
std::string text_before(const std::string &text, long i) {
  long j = i - 1;
  while (j >= 0 && white_c(ch(text, j))) j -= 1;
  return j < 0 ? std::string() : std::string(1, text[(size_t)j]);
}

// The [start, end) range of a sorted, non-overlapping list that holds position i, or nullptr. A scan asks it at
// increasing positions, so cursor only moves forward (see piece_at in the Ruby script).
struct Range { long start, end; };
const Range *piece_at(const std::vector<Range> &ranges, size_t &cursor, long i) {
  while (cursor < ranges.size() && ranges[cursor].end <= i) cursor += 1;
  if (cursor >= ranges.size()) return nullptr;
  return ranges[cursor].start <= i ? &ranges[cursor] : nullptr;
}

// ---- literals, comments and brackets (Ruby: skip_literal, matching_paren, split_config, split_top) ------------------

// If a literal or comment starts at s[i], returns the index just past it; otherwise -1 (Ruby's nil).
long skip_literal(const std::string &s, long i) {
  long n = (long)s.size();
  int c = ch(s, i);
  if (c == '/' && ch(s, i + 1) == '/') {
    long j = str_index(s, "\n", i);
    return j < 0 ? n : j;
  }
  if (c == '/' && ch(s, i + 1) == '*') {
    long j = str_index(s, "*/", i + 2);
    if (j < 0) refuse("unterminated comment");
    return j + 2;
  }
  if (c == 'R' && ch(s, i + 1) == '"' && !(i > 0 && ident_c(ch(s, i - 1)))) {
    long paren = str_index(s, "(", i + 2);
    if (paren < 0) refuse("raw string delimiter");
    std::string delim = s.substr((size_t)(i + 2), (size_t)(paren - (i + 2)));
    long close = str_index(s, ")" + delim + "\"", paren + 1);
    if (close < 0) refuse("unterminated raw string");
    return close + (long)delim.size() + 2;
  }
  // A quote after a digit is a digit separator (1'000), not a character literal.
  if (c == '\'' && i > 0 && ch(s, i - 1) >= '0' && ch(s, i - 1) <= '9') return -1;
  if (c == '"' || c == '\'') {
    long j = i + 1;
    while (j < n) {
      if (ch(s, j) == '\\') {
        j += 2;
      } else if (ch(s, j) == c) {
        return j + 1;
      } else {
        j += 1;
      }
    }
    refuse("unterminated literal");
  }
  return -1;
}

// Index of the bracket that closes the one at s[open] (which is `(`), skipping literals; -1 if none.
long matching_paren(const std::string &s, long open) {
  long depth = 0;
  long i = open;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}') {
      depth -= 1;
      if (depth == 0) return i;
    }
    i += 1;
  }
  return -1;
}

// Ruby's String#strip: leading and trailing ASCII whitespace (space, \t, \n, \v, \f, \r) and NUL.
std::string strip(const std::string &s) {
  auto sp = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' || c == '\0'; };
  size_t a = 0, b = s.size();
  while (a < b && sp(s[a])) a += 1;
  while (b > a && sp(s[b - 1])) b -= 1;
  return s.substr(a, b - a);
}

// Splits the launch configuration text at its top-level commas.
std::vector<std::string> split_config(const std::string &s, long from, long to) {
  std::vector<std::string> items;
  long depth = 0;
  long start = from;
  long i = from;
  while (i < to) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}') {
      depth -= 1;
    } else if (c == ',' && depth == 0) {
      items.push_back(strip(s.substr((size_t)start, (size_t)(i - start))));
      start = i + 1;
    }
    i += 1;
  }
  items.push_back(strip(s.substr((size_t)start, (size_t)(to - start))));
  return items;
}

// Splits at top-level commas, counting <...> as brackets too; empty parts are dropped (Ruby: split_top).
std::vector<std::string> split_top(const std::string &s) {
  std::vector<std::string> parts;
  long depth = 0;
  long start = 0;
  long i = 0;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    int c = ch(s, i);
    if (c == '(' || c == '[' || c == '{' || c == '<') {
      depth += 1;
    } else if (c == ')' || c == ']' || c == '}' || c == '>') {
      depth -= 1;
    } else if (c == ',' && depth == 0) {
      parts.push_back(strip(s.substr((size_t)start, (size_t)(i - start))));
      start = i + 1;
    }
    i += 1;
  }
  parts.push_back(strip(s.substr((size_t)start)));
  std::vector<std::string> kept;
  for (const auto &p : parts)
    if (!p.empty()) kept.push_back(p);
  return kept;
}

// Index of the first character c at or after from, outside comments and literals; -1 if none.
long index_code(const std::string &s, int c, long from) {
  long i = from;
  while (i < (long)s.size()) {
    long e = skip_literal(s, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (ch(s, i) == c) return i;
    i += 1;
  }
  return -1;
}

// Ruby's sanitize: every non-identifier byte becomes "_", then each "__" becomes "_" (gsub, left to right).
std::string sanitize(const std::string &s) {
  std::string out;
  for (char c : s) out.push_back(ident_c((unsigned char)c) ? c : '_');
  std::string res;
  for (size_t i = 0; i < out.size();) {
    if (out.compare(i, 2, "__") == 0) {
      res.push_back('_');
      i += 2;
    } else {
      res.push_back(out[i]);
      i += 1;
    }
  }
  return res;
}

// The name of the C-linkage wrapper of a template launch (Ruby: wrapper_name).
std::string wrapper_name(const std::string &name, const std::string &targs) {
  return "__nfcxx_k_" + sanitize(name) + "_" + sanitize(targs);
}

// ---- template kernels and launches (Ruby lines 190-690) ------------------------------------------------------------

// Ruby: $expanded, $kernel_text, $sites (insertion-ordered: a Ruby Hash keeps its order).
std::string g_expanded;
bool g_has_kernel_text = false;
std::string g_kernel_text;
struct Site {
  std::string wrapper, name, targs, decl;
  std::vector<std::string> call;
};
std::vector<Site> g_sites;
std::map<std::string, size_t> g_site_index;

// Ruby slicing text[a...b] / text[a, n] with the bounds clipped to the string (a past the end gives "").
std::string sl(const std::string &s, long a, long b) {
  long n = (long)s.size();
  if (a < 0) a = 0;
  if (b > n) b = n;
  if (a >= b) return std::string();
  return s.substr((size_t)a, (size_t)(b - a));
}
std::string sl_n(const std::string &s, long a, long count) { return sl(s, a, a + count); }

// Ruby: s.split("=")[0] (the text before the first "="; the text itself when there is none).
std::string ruby_split_eq0(const std::string &s) {
  size_t p = s.find('=');
  return p == std::string::npos ? s : s.substr(0, p);
}

// Ruby Array#join(sep).
std::string join(const std::vector<std::string> &v, const std::string &sep) {
  std::string out;
  for (size_t i = 0; i < v.size(); i++) {
    if (i) out += sep;
    out += v[i];
  }
  return out;
}

bool word_at(const std::string &s, long i, const std::string &w) {
  if (sl_n(s, i, (long)w.size()) != w) return false;
  if (i > 0 && ident_c(ch(s, i - 1))) return false;
  if (ident_c(ch(s, i + (long)w.size()))) return false;
  return true;
}

// Forward declarations of the passes that follow in the Ruby order.
std::vector<std::string> tokens_of(const std::string &s);
std::string remove_words(const std::string &s, const std::vector<std::string> &words);
std::string function_name(const std::string &text);
struct Piece {
  long st, en;
  std::string kind;   // "code", "directive", "other" (Ruby symbols)
  bool body;
};
std::vector<Piece> top_pieces(const std::string &text);
std::string member_qualifier_placeholder();  // replaced by the real member_qualifier below

// Ruby: DEVICE_QUALIFIERS (line 1521).
const std::vector<std::string> DEVICE_QUALIFIERS = {"__global__", "__device__", "__host__", "__forceinline__"};

// Ruby kernel_template_uncached (line 202): the template header of the __global__ template named name.
struct KernelTemplate {
  std::vector<std::string> names;
  std::string params;
  bool has_pack = false;
  long pack = 0;
};
bool g_kernel_pieces_ready = false;
std::string g_kernel_pieces_for;
std::vector<Piece> g_kernel_pieces;

bool kernel_template_uncached(const std::string &name, const std::string &src, KernelTemplate &out) {
  if (!g_kernel_pieces_ready || g_kernel_pieces_for != src) {
    g_kernel_pieces = top_pieces(src);
    g_kernel_pieces_for = src;
    g_kernel_pieces_ready = true;
  }
  for (const auto &pc : g_kernel_pieces) {
    if (!(pc.kind == "code" && pc.body)) continue;
    std::string t = sl(src, pc.st, pc.en);
    std::vector<std::string> toks = tokens_of(t);
    bool has_global = false;
    for (const auto &x : toks) has_global = has_global || x == "__global__";
    if (!(!toks.empty() && toks.front() == "template" && has_global)) continue;
    std::string q = remove_words(t, DEVICE_QUALIFIERS);
    if (function_name(q) != name) continue;
    long lt = index_code(q, '<', 0);
    long depth = 0;
    long k = lt;
    while (k < (long)q.size()) {
      if (ch(q, k) == '<') depth += 1;
      if (ch(q, k) == '>') depth -= 1;
      if (depth == 0) break;
      k += 1;
    }
    std::vector<std::string> parts = split_top(sl(q, lt + 1, k));
    std::vector<std::string> names;
    bool pack_found = false;
    long pack = 0;
    for (size_t idx = 0; idx < parts.size(); idx++) {
      std::vector<std::string> pt = tokens_of(ruby_split_eq0(parts[idx]));
      if (!pt.empty()) names.push_back(pt.back());
      if (!pack_found && parts[idx].find("...") != std::string::npos) {
        pack_found = true;
        pack = (long)idx;
      }
    }
    long open = index_code(q, '(', k);
    long close = matching_paren(q, open);
    if (close < 0) refuse("unterminated parameter list for " + name);
    out.names = names;
    out.params = sl(q, open + 1, close);
    out.has_pack = pack_found;
    out.pack = pack;
    return true;
  }
  return false;
}

// Ruby kernel_template (line 192): memoized per unit. The memo is keyed by the unit's identity (the same unit string
// object); here the unit is the g_kernel_text or g_expanded string, compared by value.
std::map<std::string, KernelTemplate> g_kernel_memo;
std::map<std::string, bool> g_kernel_memo_found;
std::string g_kernel_memo_for;
bool g_kernel_memo_valid = false;

bool kernel_template(const std::string &name, KernelTemplate &out) {
  const std::string &src = g_has_kernel_text ? g_kernel_text : g_expanded;
  if (!g_kernel_memo_valid || g_kernel_memo_for != src) {
    g_kernel_memo.clear();
    g_kernel_memo_found.clear();
    g_kernel_memo_for = src;
    g_kernel_memo_valid = true;
  }
  auto it = g_kernel_memo_found.find(name);
  if (it != g_kernel_memo_found.end()) {
    if (it->second) out = g_kernel_memo[name];
    return it->second;
  }
  bool found = kernel_template_uncached(name, src, out);
  g_kernel_memo_found[name] = found;
  if (found) g_kernel_memo[name] = out;
  return found;
}

// Ruby substitute (line 238): replaces the template parameter names in the parameter list by the explicit arguments.
std::string substitute(const std::string &text, const std::vector<std::string> &names,
                       const std::vector<std::string> &args, bool has_pack, long pack) {
  // Each name maps to a list of replacement texts (Ruby: map[n] is a String or an Array).
  std::map<std::string, std::vector<std::string>> map;
  if (!has_pack) {
    for (size_t idx = 0; idx < names.size(); idx++)
      map[names[idx]] = {idx < args.size() ? args[idx] : std::string()};
  } else {
    long size = (long)args.size() - ((long)names.size() - 1);
    for (size_t idx = 0; idx < names.size(); idx++) {
      long ii = (long)idx;
      if (ii < pack) {
        map[names[idx]] = {args[idx]};
      } else if (ii == pack) {
        std::vector<std::string> v;
        for (long q = 0; q < size && pack + q < (long)args.size(); q++) v.push_back(args[(size_t)(pack + q)]);
        map[names[idx]] = v;
      } else {
        long at = ii - 1 + size;
        map[names[idx]] = {at >= 0 && at < (long)args.size() ? args[(size_t)at] : std::string()};
      }
    }
  }
  std::string out;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      out += sl(text, i, e);
      i = e;
      continue;
    }
    if (ident_c(ch(text, i)) && !(ch(text, i) >= '0' && ch(text, i) <= '9')) {
      long j = i;
      while (j < n && ident_c(ch(text, j))) j += 1;
      std::string w = sl(text, i, j);
      if (has_pack && pack < (long)names.size() && names[(size_t)pack] == w && map.count(w)) {
        long k = j;
        while (k < n && white_c(ch(text, k))) k += 1;
        if (sl_n(text, k, 3) != "...") refuse("parameter pack " + w + " used without ...");
        const auto &vals = map[w];
        for (size_t q = 0; q < vals.size(); q++) {
          if (q) out += ", ";
          out += vals[q];
        }
        i = k + 3;
        continue;
      }
      auto it = map.find(w);
      if (it != map.end()) {
        // Ruby: an Array value prints its first element (v[0].to_s); nil (an empty pack) prints "".
        out += it->second.empty() ? std::string() : it->second.front();
      } else {
        out += w;
      }
      i = j;
    } else {
      out.push_back(text[(size_t)i]);
      i += 1;
    }
  }
  return out;
}

// Ruby template_site (line 288): the wrapper of a template launch. Registers it in g_sites.
std::string template_site(const std::string &name, const std::string &targs) {
  KernelTemplate kt;
  if (!kernel_template(name, kt)) refuse("template kernel " + name + ": no __global__ template of that name in the source");
  std::vector<std::string> args = split_top(targs);
  bool bad = kt.has_pack ? (long)args.size() < (long)kt.names.size() - 1 : args.size() != kt.names.size();
  if (bad) refuse("template kernel " + name + "<" + targs + ">: explicit arguments must give every template parameter");
  std::string decl = substitute(kt.params, kt.names, args, kt.has_pack, kt.pack);
  std::vector<std::string> call;
  for (const auto &part : split_top(decl)) {
    std::vector<std::string> pt = tokens_of(ruby_split_eq0(part));
    if (pt.empty()) refuse("template kernel " + name + ": unnamed parameter " + part);
    call.push_back(pt.back());
  }
  std::string w = wrapper_name(name, targs);
  if (!g_site_index.count(w)) {
    g_site_index[w] = g_sites.size();
    g_sites.push_back(Site{w, name, targs, decl, call});
  }
  return w;
}

// Ruby dependent_on_template (line 311): the parameter name a launch's template arguments use, or "" (nil).
std::string dependent_on_template(const std::string &text, long i, const std::string &targs, bool &found);

// Ruby angle_index (line 323): every code `<` of the text, with its matching `>` (or -1), indexed once per text.
std::map<long, long> g_angle_index;
const std::string *g_angle_index_for = nullptr;
std::string g_angle_index_text;

const std::map<long, long> &angle_index(const std::string &s) {
  if (g_angle_index_for && g_angle_index_text == s) return g_angle_index;
  std::map<long, long> idx;
  std::vector<long> stack;
  long k = 0;
  long n = (long)s.size();
  while (k < n) {
    long e = skip_literal(s, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    if (ch(s, k) == '<') {
      idx[k] = -1;
      stack.push_back(k);
    } else if (ch(s, k) == '>' && !stack.empty()) {
      idx[stack.back()] = k;
      stack.pop_back();
    }
    k += 1;
  }
  g_angle_index = idx;
  g_angle_index_text = s;
  g_angle_index_for = &g_angle_index_text;
  return g_angle_index;
}

// Ruby matching_angle (line 347): the `>` closing the `<` at open, or -1 (nil).
long matching_angle(const std::string &s, long open) {
  if ((long)s.size() >= 4000) {
    const auto &idx = angle_index(s);
    auto it = idx.find(open);
    if (it != idx.end()) return it->second;
  }
  long depth = 0;
  long k = open;
  long n = (long)s.size();
  while (k < n) {
    long e = skip_literal(s, k);
    if (e >= 0) {
      k = e;
      continue;
    }
    if (ch(s, k) == '<') depth += 1;
    if (ch(s, k) == '>') {
      depth -= 1;
      if (depth == 0) return k;
    }
    k += 1;
  }
  return -1;
}

// Ruby directive_spans (line 372): [start, end) of each directive, continuation lines included.
std::vector<std::pair<long, long>> directive_spans(const std::string &text) {
  std::vector<std::pair<long, long>> spans;
  long n = (long)text.size();
  long i = 0;
  bool bol = true;
  while (i < n) {
    if (bol) {
      long j = i;
      while (j < n && (text[(size_t)j] == ' ' || text[(size_t)j] == '\t')) j += 1;
      if (j < n && text[(size_t)j] == '#') {
        long k = j;
        while (true) {
          long nl = str_index(text, "\n", k);
          if (nl < 0) nl = n;
          if (nl < n && nl > 0 && text[(size_t)(nl - 1)] == '\\') {
            k = nl + 1;
          } else {
            k = nl;
            break;
          }
        }
        spans.push_back({i, k});
        i = k;
        bol = false;
        continue;
      }
    }
    bol = (ch(text, i) == '\n');
    i += 1;
  }
  return spans;
}

// Ruby directive_ends (line 406): start index => end index.
std::map<long, long> directive_ends(const std::string &text) {
  std::map<long, long> out;
  for (const auto &sp : directive_spans(text)) out[sp.first] = sp.second;
  return out;
}

// Ruby local_constant_visible (line 415): the value of the nearest visible local constant `name = VALUE` before pos.
bool local_constant_visible(const std::string &text, long pos, const std::string &name, std::string &value);

// Ruby int_expr_value (line 440): a recursive-descent reader of integer expressions over literals and local constants.
bool int_expr_value(const std::string &text, long pos, const std::string &s, long &value, int depth = 0);

// Ruby resolve_local_constants (line 517): replaces the names of local constants in a launch's template arguments.
std::string resolve_local_constants(const std::string &text, const std::string &targs, long pos);


// 1-based line number of position pos: the newlines before pos, plus one (Ruby: text[0...pos].count("\n") + 1).
long line_of(const std::string &text, long pos) {
  long n = 1;
  for (long i = 0; i < pos && i < (long)text.size(); i++)
    if (text[(size_t)i] == '\n') n++;
  return n;
}

// Ruby local_constant (line 685): the value of a local constant `T name = VALUE;` before pos, in the body at open.
bool local_constant(const std::string &text, long open, long pos, const std::string &name, std::string &value) {
  std::string seg = sl(text, open, pos);
  bool found = false;
  long i = 0;
  while (true) {
    long k = str_index(seg, name, i);
    if (k < 0) break;
    long e = k + (long)name.size();
    i = e;
    if ((k > 0 && ident_c(ch(seg, k - 1))) || (e < (long)seg.size() && ident_c(ch(seg, e)))) continue;
    long b = k - 1;
    while (b >= 0 && white_c(ch(seg, b))) b -= 1;
    if (!(b >= 0 && ident_c(ch(seg, b)))) continue;
    long a = e;
    while (a < (long)seg.size() && white_c(ch(seg, a))) a += 1;
    if (!(ch(seg, a) == '=' && ch(seg, a + 1) != '=')) continue;
    long semi = str_index(seg, ";", a);
    if (semi < 0) continue;
    found = true;
    value = strip(sl(seg, a + 1, semi));
  }
  return found;
}

// Ruby member_qualifier (line 707): `Q<args>::member` in a header; false when none.
struct MemberQualifier {
  std::string name;
  std::vector<std::string> args;
};
bool member_qualifier(const std::string &header, MemberQualifier &out) {
  long cc = str_index(header, "::", 0);
  if (cc < 0) return false;
  std::string before = header.substr(0, (size_t)cc);
  // Ruby rstrip: trailing ASCII whitespace.
  while (!before.empty() && (before.back() == ' ' || before.back() == '\t' || before.back() == '\n' ||
                             before.back() == '\r' || before.back() == '\v' || before.back() == '\f' || before.back() == '\0'))
    before.pop_back();
  if (before.empty() || before.back() != '>') return false;
  long open = (long)before.size() - 1;
  long depth = 0;
  while (open >= 0) {
    if (ch(before, open) == '>') depth += 1;
    if (ch(before, open) == '<') depth -= 1;
    if (depth == 0) break;
    open -= 1;
  }
  if (open < 0) return false;
  long name_start = open;
  while (name_start > 0 && ident_c(ch(before, name_start - 1))) name_start -= 1;
  std::string name = sl(before, name_start, open);
  if (name.empty()) return false;
  out.name = name;
  out.args = split_top(sl(before, open + 1, (long)before.size() - 1));
  return true;
}

// Ruby member_instances (line 730): the explicit instantiations of the class template, mapped onto the member
// template's names (one list per instance, in the member's parameter order).
struct OuterTemplate {
  long st = 0, open = 0;
  std::vector<std::string> names;
  std::vector<std::string> decls;
  std::string fname;
  bool has_qual = false;
  MemberQualifier qual;
  bool has_pack = false;
  long pack = 0;
};

std::vector<std::vector<std::string>> member_instances(const OuterTemplate &outer, const std::string &text) {
  const MemberQualifier &q = outer.qual;
  std::vector<std::vector<std::string>> raw;
  long i = 0;
  long n = (long)text.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (word_at(text, i, "template")) {
      long k = i + 8;
      while (k < n && white_c(ch(text, k))) k += 1;
      if (word_at(text, k, "class") || word_at(text, k, "struct")) {
        k += (sl_n(text, k, 5) == "class" ? 5 : 6);
        while (k < n && white_c(ch(text, k))) k += 1;
        if (word_at(text, k, q.name)) {
          k += (long)q.name.size();
          while (k < n && white_c(ch(text, k))) k += 1;
          if (ch(text, k) == '<') {
            long close = matching_angle(text, k);
            if (close >= 0) raw.push_back(split_top(sl(text, k + 1, close)));
          }
        }
      }
    }
    i += 1;
  }
  std::vector<std::vector<std::string>> out;
  for (const auto &args : raw) {
    if (args.size() != q.args.size())
      refuse("member template " + outer.fname + ": the class instance " + q.name + "<" + join(args, ", ") +
             "> does not give all its arguments");
    std::vector<std::string> one;
    for (const auto &nm : outer.names) {
      long k = -1;
      for (size_t x = 0; x < q.args.size(); x++)
        if (q.args[x] == nm) {
          k = (long)x;
          break;
        }
      if (k < 0) refuse("member template " + outer.fname + ": its parameter " + nm + " is not a parameter of " + q.name);
      one.push_back(args[(size_t)k]);
    }
    if (std::find(out.begin(), out.end(), one) == out.end()) out.push_back(one);  // Ruby uniq
  }
  return out;
}

// Ruby call_sites (line 770): the explicit template-argument lists of the calls of template function name, indexed
// once per text. Each entry is { targs, position }.
struct CallSite {
  std::vector<std::string> targs;  // unused for the text form (see call_sites)
  std::string text_targs;
  long pos;
};
std::map<std::string, std::vector<std::pair<std::string, long>>> g_call_index;
std::string g_call_index_text;
bool g_call_index_ready = false;

const std::vector<std::pair<std::string, long>> &call_sites(const std::string &text, const std::string &name) {
  static const std::vector<std::pair<std::string, long>> none;
  if (!g_call_index_ready || g_call_index_text != text) {
    std::map<std::string, std::vector<std::pair<std::string, long>>> index;
    // Directives are not code: a #define's body names its parameters (DECL_MMQ_CASE(type)), which are not calls.
    std::vector<Range> pp;
    for (const auto &pc : top_pieces(text))
      if (pc.kind == "pp") pp.push_back(Range{pc.st, pc.en});
    size_t pp_cursor = 0;
    long i = 0;
    long n = (long)text.size();
    while (i < n) {
      long e = skip_literal(text, i);
      if (e >= 0) {
        i = e;
        continue;
      }
      if (const Range *hit = piece_at(pp, pp_cursor, i)) {
        i = hit->end;
        continue;
      }
      if (ident_c(ch(text, i)) && !(i > 0 && ident_c(ch(text, i - 1))) && !(ch(text, i) >= '0' && ch(text, i) <= '9')) {
        long j = i;
        while (j < n && ident_c(ch(text, j))) j += 1;
        std::string id = sl(text, i, j);
        long k = j;
        while (k < n && white_c(ch(text, k))) k += 1;
        if (ch(text, k) == '<') {
          long close = matching_angle(text, k);
          if (close >= 0) {
            long m = close + 1;
            while (m < n && white_c(ch(text, m))) m += 1;
            if (ch(text, m) == '(') index[id].push_back({strip(sl(text, k + 1, close)), i});
          }
        }
        i = j;
        continue;
      }
      i += 1;
    }
    g_call_index = index;
    g_call_index_text = text;
    g_call_index_ready = true;
  }
  auto it = g_call_index.find(name);
  return it != g_call_index.end() ? it->second : none;
}

// Ruby DECL_WORDS (line 817).
const std::vector<std::string> DECL_WORDS = {"void", "static", "inline", "int", "float", "double", "bool", "size_t",
                                             "unsigned", "long", "char", "short", "template", "__device__", "__host__",
                                             "__global__", "__forceinline__", "constexpr", "auto"};

// Ruby plain_call_sites (line 819): the unqualified calls name(args) of a template function, as {args, position}.
std::vector<std::pair<std::vector<std::string>, long>> plain_call_sites(const std::string &text, const std::string &name) {
  std::vector<std::pair<std::vector<std::string>, long>> out;
  std::vector<Range> pp;
  for (const auto &pc : top_pieces(text))
    if (pc.kind == "pp") pp.push_back(Range{pc.st, pc.en});
  size_t pp_cursor = 0;
  long i = 0;
  long n = (long)text.size();
  long nl = (long)name.size();
  while (i < n) {
    long e = skip_literal(text, i);
    if (e >= 0) {
      i = e;
      continue;
    }
    if (const Range *hit = piece_at(pp, pp_cursor, i)) {
      i = hit->end;
      continue;
    }
    // A qualified call (`cg::reduce(...)`) or a member call (`x.reduce(...)`) names another function.
    bool qualified = (i >= 2 && sl_n(text, i - 2, 2) == "::") || (i >= 1 && ch(text, i - 1) == '.') ||
                     (i >= 2 && sl_n(text, i - 2, 2) == "->");
    if (sl_n(text, i, nl) == name && !qualified && !(i > 0 && ident_c(ch(text, i - 1))) &&
        !ident_c(ch(text, i + nl) < 0 ? ' ' : ch(text, i + nl))) {
      long k = i + nl;
      while (k < n && white_c(ch(text, k))) k += 1;
      if (ch(text, k) == '(') {
        long close = matching_paren(text, k);
        if (close >= 0) {
          long after = close + 1;
          while (after < n && white_c(ch(text, after))) after += 1;
          long b = i - 1;
          while (b >= 0 && white_c(ch(text, b))) b -= 1;
          long e2 = b;
          while (b >= 0 && ident_c(ch(text, b))) b -= 1;
          std::string prev = sl(text, b + 1, e2 + 1);
          bool is_decl = std::find(DECL_WORDS.begin(), DECL_WORDS.end(), prev) != DECL_WORDS.end() ||
                         ch(text, after) == '{';
          if (!is_decl) out.push_back({split_top(sl(text, k + 1, close)), i});
        }
      }
    }
    i += 1;
  }
  return out;
}

// Ruby caller_arg_type (line 860): the type of a call argument in the caller.
std::vector<std::string> argument_type(const std::string &text, long pos, const std::string &arg, const std::string &nm);
std::vector<std::string> type_tokens(const std::string &s);
std::vector<std::string> caller_arg_type(const std::string &text, long pos, const std::string &arg, const std::string &name) {
  std::string a = strip(arg);
  if (!a.empty() && a[0] == '(') {
    long close = matching_paren(a, 0);
    if (close >= 0 && close + 1 < (long)a.size()) {
      std::string rest = strip(sl(a, close + 1, (long)a.size()));
      if (!rest.empty() && ident_c(ch(rest, 0))) return type_tokens(sl(a, 1, close));
    }
  }
  return argument_type(text, pos, a, name);
}

// Ruby template_head_of (line 872): the parameter names and parts of a template function's definition.
struct TemplateHead {
  std::vector<std::string> names;
  std::vector<std::string> parts;
  long pos = 0;
};
bool template_head_of(const std::string &text, const std::string &name, TemplateHead &out);

// Ruby deduce_call_targs (line 889): the explicit template arguments of a call, deduced from its arguments' types.
// Returns false when the template is unknown (Ruby nil).
bool deduce_call_targs(const std::string &text, const std::string &name, long pos,
                       const std::vector<std::string> &args, std::vector<std::string> &out);

}  // namespace

int main(int argc, char **argv) {
  // The CLI is ported with the passes. Until then the Ruby script is the rewriter (the driver calls it).
  (void)argc;
  (void)argv;
  std::fprintf(stderr, "cuda-rewrite: not ported yet (see tools/cuda-rewrite/PORTING.md); use scripts/cuda-rewrite.rb\n");
  return 2;
}
